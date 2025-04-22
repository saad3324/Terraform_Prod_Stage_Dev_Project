# Provider and Backend Configuration
terraform {
  backend "s3" {
    bucket = "vpc-testings123"
    key    = "state/staging/terraform.tfstate"
    region = "ap-south-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Variables
variable "app_name" {
  description = "Application name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "Environment must be one of: dev, stage, prod."
  }
}

variable "selected_dbs" {
  description = "List of databases to create (mysql, redis, documentdb)"
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for db in var.selected_dbs : contains(["mysql", "redis", "documentdb"], db)])
    error_message = "Invalid database type. Allowed values: mysql, redis, documentdb."
  }
}

variable "compute_type" {
  description = "ECS compute type (fargate/ec2)"
  type        = string
  default     = "fargate"
  validation {
    condition     = contains(["fargate", "ec2"], var.compute_type)
    error_message = "Compute type must be one of: fargate, ec2."
  }
}

variable "enable_autoscaling" {
  description = "Enable autoscaling"
  type        = bool
  default     = false
}

variable "resource_prefix" {
  description = "Prefix for all resources"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    ManagedBy   = "terraform"
    Environment = "staging"
    CreatedBy   = "saad"
  }
}

# Local Variables for Standardization
locals {
  name_prefix = var.resource_prefix != "" ? var.resource_prefix : "${var.app_name}-${var.environment}"
  common_tags = merge(var.tags, { Environment = var.environment })
}

# Data Sources
data "aws_availability_zones" "available" {}
data "aws_iam_role" "ecs_task_execution" {
  name = "ecsTaskExecutionRole"
}

# ECR Repository
resource "aws_ecr_repository" "app_repository" {
  name                 = "${local.name_prefix}-ecr"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.common_tags
}

# VPC Configuration
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${local.name_prefix}-vpc" })
}

# Public Subnets
resource "aws_subnet" "app_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.app_vpc.cidr_block, 4, count.index)
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  tags                    = merge(local.common_tags, { Name = "${local.name_prefix}-public-subnet-${count.index}" })
}

# Private Subnets
resource "aws_subnet" "private_subnet" {
  count             = 2
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.app_vpc.cidr_block, 4, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(local.common_tags, { Name = "${local.name_prefix}-private-subnet-${count.index}" })
}

# Internet Gateway
resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-igw" })
}

# NAT Elastic IPs
resource "aws_eip" "nat" {
  count  = 2
  vpc   = true
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-nat-eip-${count.index}" })
}

# NAT Gateways
resource "aws_nat_gateway" "nat" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.app_subnet[count.index].id
  tags          = merge(local.common_tags, { Name = "${local.name_prefix}-nat-${count.index}" })
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.app_vpc.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-public-rt" })
}

# Public Route
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.app_igw.id
}

# Public Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.app_subnet[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.app_vpc.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-private-rt-${count.index}" })
}

# Private Routes to NAT
resource "aws_route" "private_nat" {
  count                  = 2
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[count.index].id
}

# Private Route Table Associations
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private_subnet[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Security Groups

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_sg" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "Security group for ECS tasks to allow HTTP traffic"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ecs-sg" })
}

# Security Group for MySQL
resource "aws_security_group" "mysql_sg" {
  count       = contains(var.selected_dbs, "mysql") ? 1 : 0
  name        = "${local.name_prefix}-mysql-sg"
  description = "Security group for MySQL database"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-mysql-sg" })
}

# Security Group for Redis
resource "aws_security_group" "redis_sg" {
  count       = contains(var.selected_dbs, "redis") ? 1 : 0
  name        = "${local.name_prefix}-redis-sg"
  description = "Security group for Redis cluster"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-redis-sg" })
}

# Security Group for DocumentDB
resource "aws_security_group" "docdb_sg" {
  count       = contains(var.selected_dbs, "documentdb") ? 1 : 0
  name        = "${local.name_prefix}-docdb-sg"
  description = "Security group for DocumentDB cluster"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-docdb-sg" })
}

# Security Group for Bastion Host
resource "aws_security_group" "bastion_sg" {
  count       = length(var.selected_dbs) > 0 ? 1 : 0
  name        = "${local.name_prefix}-bastion-sg"
  description = "Security group for bastion host (SSH access)"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-bastion-sg" })
}

# Bastion Host Configuration
resource "aws_instance" "bastion" {
  count = length(var.selected_dbs) > 0 ? 1 : 0

  ami                    = "ami-00bb6a80f01f03502"
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.app_subnet[0].id
  vpc_security_group_ids = [aws_security_group.bastion_sg[0].id]
  key_name               = "test-vp"
  tags                   = merge(local.common_tags, { Name = "${local.name_prefix}-bastion" })
}

# Load Balancer Configuration
resource "aws_lb" "app_lb" {
  name               = "${local.name_prefix}-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ecs_sg.id]
  subnets            = aws_subnet.app_subnet[*].id
  tags               = merge(local.common_tags, { Name = "${local.name_prefix}-lb" })
}

resource "aws_lb_target_group" "app_tg" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.app_vpc.id
  target_type = var.compute_type == "ec2" ? "instance" : "ip"

  health_check {
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = local.common_tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ECS Configuration
resource "aws_ecs_cluster" "app_cluster" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
  tags              = local.common_tags
}

resource "aws_ecs_task_definition" "app_task" {
  family = "${local.name_prefix}-task"

  # Dynamic configuration based on compute type
  network_mode             = var.compute_type == "ec2" ? "bridge" : "awsvpc"
  requires_compatibilities = var.compute_type == "ec2" ? ["EC2"] : ["FARGATE"]
  cpu                      = var.compute_type == "ec2" ? null : "256"
  memory                   = var.compute_type == "ec2" ? null : "512"

  execution_role_arn = data.aws_iam_role.ecs_task_execution.arn
  task_role_arn      = data.aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name  = "${local.name_prefix}-container"
    image = "${aws_ecr_repository.app_repository.repository_url}:latest"
    cpu   = var.compute_type == "ec2" ? 512 : null
    memory = var.compute_type == "ec2" ? 1024 : null
    portMappings = [{
      containerPort = 3000
      hostPort      = var.compute_type == "ec2" ? 0 : 3000
    }]
    environment = concat(
      [
        {
          name  = "ENVIRONMENT"
          value = var.environment
        }
      ],
      (length(aws_db_instance.mysql) > 0 ? [
        {
          name  = "MYSQL_ENDPOINT"
          value = aws_db_instance.mysql[0].endpoint
        }
      ] : []),
      (length(aws_elasticache_cluster.app_redis_cluster) > 0 ? [
        {
          name  = "REDIS_ENDPOINT"
          value = aws_elasticache_cluster.app_redis_cluster[0].configuration_endpoint
        }
      ] : []),
      (length(aws_docdb_cluster.app_docdb_cluster) > 0 ? [
        {
          name  = "DOCDB_ENDPOINT"
          value = aws_docdb_cluster.app_docdb_cluster[0].endpoint
        }
      ] : [])
    )
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = local.common_tags
}

# Database Configurations

# MySQL Configuration
resource "aws_db_subnet_group" "app_db_subnet_group" {
  count      = contains(var.selected_dbs, "mysql") ? 1 : 0
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private_subnet[*].id
  tags       = merge(local.common_tags, { Name = "${local.name_prefix}-db-subnet-group" })
}

resource "aws_db_instance" "mysql" {
  count = contains(var.selected_dbs, "mysql") ? 1 : 0

  identifier           = "${local.name_prefix}-mysql"
  allocated_storage    = 20
  instance_class       = "db.t3.micro"
  engine               = "mysql"
  engine_version       = "8.0"
  db_name              = replace("${var.app_name}_${var.environment}_db", "-", "_")
  username             = "admin"
  password             = "your_password"
  vpc_security_group_ids = [aws_security_group.mysql_sg[0].id]
  db_subnet_group_name  = aws_db_subnet_group.app_db_subnet_group[0].name
  multi_az             = false
  publicly_accessible  = false
  skip_final_snapshot  = true
  tags                 = merge(local.common_tags, { Name = "${local.name_prefix}-mysql" })
}

# Redis Configuration
resource "aws_elasticache_subnet_group" "app_redis_subnet_group" {
  count      = contains(var.selected_dbs, "redis") ? 1 : 0
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = aws_subnet.private_subnet[*].id
}

resource "aws_elasticache_cluster" "app_redis_cluster" {
  count = contains(var.selected_dbs, "redis") ? 1 : 0

  cluster_id         = "${local.name_prefix}-redis"
  engine             = "redis"
  node_type          = "cache.t3.micro"
  num_cache_nodes    = 1
  subnet_group_name  = aws_elasticache_subnet_group.app_redis_subnet_group[0].name
  security_group_ids = [aws_security_group.redis_sg[0].id]
  tags               = local.common_tags
}

# DocumentDB Configuration
resource "aws_docdb_subnet_group" "app_docdb_subnet_group" {
  count      = contains(var.selected_dbs, "documentdb") ? 1 : 0
  name       = "${local.name_prefix}-docdb-subnet-group"
  subnet_ids = aws_subnet.private_subnet[*].id
  tags       = local.common_tags
}

resource "aws_docdb_cluster" "app_docdb_cluster" {
  count = contains(var.selected_dbs, "documentdb") ? 1 : 0

  cluster_identifier     = "${local.name_prefix}-docdb"
  engine                 = "docdb"
  master_username        = "health_stage"
  master_password        = "THD10!1122"
  vpc_security_group_ids = [aws_security_group.docdb_sg[0].id]
  db_subnet_group_name   = aws_docdb_subnet_group.app_docdb_subnet_group[0].name
  skip_final_snapshot    = true
  tags                   = local.common_tags
}

resource "aws_docdb_cluster_instance" "app_docdb_instance" {
  count = contains(var.selected_dbs, "documentdb") ? 1 : 0

  identifier         = "${local.name_prefix}-docdb-instance"
  cluster_identifier = aws_docdb_cluster.app_docdb_cluster[0].id
  instance_class     = "db.r5.large"
  engine             = "docdb"
  tags               = local.common_tags
}

# EC2 Infrastructure
resource "aws_iam_role" "ecs_ec2_instance_role" {
  count = var.compute_type == "ec2" ? 1 : 0

  name = "${local.name_prefix}-ec2-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_ec2_policy" {
  count = var.compute_type == "ec2" ? 1 : 0

  role       = aws_iam_role.ecs_ec2_instance_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_ec2_instance_profile" {
  count = var.compute_type == "ec2" ? 1 : 0

  name = "${local.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ecs_ec2_instance_role[0].name
}

resource "aws_launch_template" "ecs_ec2_launch_template" {
  count = var.compute_type == "ec2" ? 1 : 0

  name_prefix   = "${local.name_prefix}-ec2-template-"
  image_id      = "ami-0fd05997b4dff7aac" # Amazon ECS-optimized AMI
  instance_type = "t2.micro"
  key_name      = "terraform-key"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_ec2_instance_profile[0].name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ecs_sg.id]
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-ec2-instance"
    })
  }

  user_data = base64encode(<<EOF
#!/bin/bash
echo ECS_CLUSTER=${aws_ecs_cluster.app_cluster.name} >> /etc/ecs/ecs.config
EOF
  )
}

resource "aws_autoscaling_group" "ecs_ec2_asg" {
  count = var.compute_type == "ec2" ? 1 : 0

  name                      = "${local.name_prefix}-ec2-asg"
  min_size                  = 1
  max_size                  = 3
  desired_capacity          = 1
  vpc_zone_identifier       = aws_subnet.app_subnet[*].id
  health_check_grace_period = 300
  health_check_type         = "EC2"

  launch_template {
    id      = aws_launch_template.ecs_ec2_launch_template[0].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-ec2-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}

# ECS Service
resource "aws_ecs_service" "app_service" {
  name            = "${local.name_prefix}-service"
  cluster         = aws_ecs_cluster.app_cluster.id
  task_definition = aws_ecs_task_definition.app_task.arn
  desired_count   = 1
  launch_type     = var.compute_type == "ec2" ? "EC2" : "FARGATE"

  # Dynamic network configuration
  dynamic "network_configuration" {
    for_each = var.compute_type == "fargate" ? [1] : []
    content {
      subnets          = aws_subnet.app_subnet[*].id
      security_groups  = [aws_security_group.ecs_sg.id]
      assign_public_ip = true
    }
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_tg.arn
    container_name   = "${local.name_prefix}-container"
    container_port   = 3000
  }

  tags = local.common_tags
}

# Outputs
output "ecr_repository_url" {
  value = aws_ecr_repository.app_repository.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.app_cluster.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app_service.name
}

output "alb_endpoint" {
  value = aws_lb.app_lb.dns_name
}

output "bastion_public_ip" {
  value = length(aws_instance.bastion) > 0 ? aws_instance.bastion[0].public_ip : null
}

output "mysql_endpoint" {
  value = length(aws_db_instance.mysql) > 0 ? aws_db_instance.mysql[0].endpoint : null
}

output "redis_endpoint" {
  value = length(aws_elasticache_cluster.app_redis_cluster) > 0 ? aws_elasticache_cluster.app_redis_cluster[0].configuration_endpoint : null
}

output "docdb_endpoint" {
  value = length(aws_docdb_cluster.app_docdb_cluster) > 0 ? aws_docdb_cluster.app_docdb_cluster[0].endpoint : null
}
