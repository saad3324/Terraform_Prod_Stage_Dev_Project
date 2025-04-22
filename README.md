# AWS Infrastructure Automation with Terraform 🚀

![Terraform Version](https://img.shields.io/badge/terraform-%3E%3D1.3.0-blue)
![AWS Provider](https://img.shields.io/badge/AWS-4.0%2B-orange)

A Terraform project to deploy a **secure**, **scalable**, and **multi-environment** AWS infrastructure with ECS, managed databases, and automated workflows.

---

## 📋 Overview

This project provisions the following AWS resources:
- **VPC** with public/private subnets, NAT/Internet Gateways
- **ECS Cluster** (Fargate/EC2) with ALB integration
- **Managed Databases**: MySQL (RDS), Redis (ElastiCache), DocumentDB
- **Bastion Host** for secure SSH access to databases
- **Security Groups** with least-privilege rules
- CloudWatch Logging & Optional Auto-Scaling

---

## ✨ Features

- **Multi-Environment Support**: Deploy to `dev`/`stage`/`prod` with variable-driven configurations
- **Modular Design**: Toggle databases (`mysql`, `redis`, `documentdb`) via `selected_dbs`
- **Compute Flexibility**: Choose between `fargate` or `ec2` for ECS tasks
- **Auto-Scaling**: Enabled for EC2 launch configurations
- **Security-First**: Private databases, restricted bastion access, encrypted ECR

---

## 🛠️ Prerequisites

1. **AWS CLI** configured with IAM credentials
2. **Terraform** (>=1.3.0)
3. IAM roles/policies:
   - `ecsTaskExecutionRole`
   - Permissions for VPC, ECS, RDS, ElastiCache, etc.

---

## 🚀 Usage

### 1. Clone the Repository
```bash
git clone https://github.com/your-repo/aws-terraform-infra.git
cd aws-terraform-infra
```

### 2. Initialize Terraform
```bash
terraform init
```

### 3. Deploy via Interactive Script
```bash
chmod +x deploy.sh
./deploy.sh
```
*Follow prompts to provide inputs (app name, environment, etc.).*

### Manual Deployment (Advanced)
1. Create `terraform.tfvars` (see [Variables](#variables)).
2. Deploy:
```bash
terraform plan -out=tfplan
terraform apply tfplan
```

---

📌 Variables

| Variable             | Description                          | Default       |
|----------------------|--------------------------------------|---------------|
| `app_name`           | Application name (lowercase)        | *Required*    |
| `environment`        | `dev`/`stage`/`prod`                | `dev`         |
| `selected_dbs`       | List of databases to enable         | `[]`          |
| `compute_type`       | `fargate` or `ec2`                  | `fargate`     |
| `enable_autoscaling` | Enable EC2 auto-scaling             | `false`       |
| `resource_prefix`    | Custom prefix for resource names    | `""`          |
| `vpc_cidr`           | VPC CIDR block                      | `10.0.0.0/16` |

*Full list in [variables.tf](./variables.tf).*

---

🔒 Security Considerations

### Critical Fixes Needed
- **Replace Hardcoded Secrets**:  
  **DO NOT USE** `your_password` (MySQL) or `xyz` (DocumentDB) in production. Use **AWS Secrets Manager**.
- **Restrict Bastion Access**:  
  Update the `bastion_sg` ingress rule to allow only trusted IPs.
- **Audit IAM Roles**: Ensure `ecsTaskExecutionRole` follows least privilege.

### Recommendations
- Encrypt ECR repositories with KMS
- Enable RDS/DocumentDB encryption
- Use Terraform remote state with S3 backend encryption

---

## 📤 Outputs
- **ALB DNS Name**: `alb_endpoint`
- **ECR Repository URL**: `ecr_repository_url`
- **Database Endpoints**: `mysql_endpoint`, `redis_endpoint`, etc.
- **Bastion Public IP**: `bastion_public_ip`

---

## 🤝 Contributing
Pull requests welcome! Ensure:
1. No hardcoded credentials
2. Update documentation
3. Test with `terraform validate`

---


*Created with ❤️ by [saad]. Feedback? Open an issue!*
```
