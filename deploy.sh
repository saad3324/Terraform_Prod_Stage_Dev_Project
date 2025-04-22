#!/bin/bash
set -eo pipefail

# Function to validate AWS resources
check_resource_exists() {
  local resource_type=$1
  local resource_name=$2
  case "$resource_type" in
    "vpc")
      aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$resource_name" --region "$REGION" 2>/dev/null \
        | jq -e '.Vpcs | length > 0' >/dev/null 2>&1
      return $?  # Return the actual exit code of jq
      ;;
    "ecr")
      aws ecr describe-repositories --repository-names "$resource_name" --region "$REGION" >/dev/null 2>&1
      return $?
      ;;
    "ecs")
      aws ecs describe-clusters --clusters "$resource_name" --region "$REGION" 2>/dev/null \
        | jq -e '.clusters | length > 0' >/dev/null 2>&1
      return $?
      ;;
    *)
      echo "Invalid resource type: $resource_type"
      exit 1
      ;;
  esac
}

# Collect User Inputs
read -p "Enter project name (lowercase): " PROJECT_NAME
read -p "Enter AWS region [ap-south-1]: " REGION
REGION=${REGION:-"ap-south-1"}
read -p "Enter environment (dev/stage/prod): " ENVIRONMENT
read -p "Compute type [fargate] (fargate/ec2): " COMPUTE_TYPE
COMPUTE_TYPE=${COMPUTE_TYPE:-"fargate"}
read -p "Enable autoscaling [true/false]: " AUTOSCALING
read -p "Resource prefix [${PROJECT_NAME}-${ENVIRONMENT}]: " PREFIX
PREFIX=${PREFIX:-"${PROJECT_NAME}-${ENVIRONMENT}"}

# Database Selection
echo "Select databases to create (comma-separated, e.g., mysql,redis,documentdb):"
echo "Options: mysql, redis, documentdb"
read -p "Leave blank to skip database creation: " SELECTED_DBS
SELECTED_DBS=$(echo "$SELECTED_DBS" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs) # Normalize input

# Validate Resource Names
RESOURCE_NAMES=(
  "${PREFIX}-vpc"
  "${PREFIX}-ecr"
  "${PREFIX}-cluster"
)

RESOURCE_TYPES=(
  "vpc"
  "ecr"
  "ecs"
)

for i in "${!RESOURCE_NAMES[@]}"; do
  if check_resource_exists "${RESOURCE_TYPES[$i]}" "${RESOURCE_NAMES[$i]}"; then
    echo "ERROR: ${RESOURCE_TYPES[$i]} '${RESOURCE_NAMES[$i]}' already exists in $REGION!"
    exit 1
  fi
done

# Generate terraform.tfvars
cat > terraform.tfvars <<EOF
app_name = "$PROJECT_NAME"
region = "$REGION"
environment = "$ENVIRONMENT"
selected_dbs = [$(echo "$SELECTED_DBS" | sed -E 's/\b(\w+)\b/"\1"/g' | tr ' ' ',')]
compute_type = "$COMPUTE_TYPE"
enable_autoscaling = $AUTOSCALING
resource_prefix = "$PREFIX"
EOF

# Rollback Mechanism
trap "echo 'Error occurred. Rolling back...'; terraform destroy -auto-approve; exit 1" ERR

# Terraform Execution
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply -auto-approve tfplan

# Cleanup
rm -f tfplan
echo "Deployment completed successfully!"
