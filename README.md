# StartTech Infrastructure

Terraform-managed AWS infrastructure for the StartTech full-stack application. Provisions networking, compute (EC2 ASG + ALB), storage (S3 + CloudFront + ECR), ElastiCache Redis, and CloudWatch monitoring.

## Repository Structure

```
starttech-infra/
├── .github/workflows/
│   └── infrastructure-deploy.yml   # CI/CD: plan on PR, apply on merge to main
├── terraform/
│   ├── main.tf                     # Root module — wires all child modules
│   ├── variables.tf                # Input variable declarations
│   ├── outputs.tf                  # Key outputs (ALB DNS, CloudFront domain, etc.)
│   ├── terraform.tfvars.example    # Copy to terraform.tfvars for local runs
│   └── modules/
│       ├── networking/             # VPC, subnets, IGW, NAT, security groups
│       ├── compute/                # ALB, ASG, launch template, Redis, CW alarms
│       ├── storage/                # S3, CloudFront, ECR
│       └── monitoring/             # CloudWatch log groups
├── monitoring/
│   ├── cloudwatch-dashboard.json   # Dashboard definition (deploy with AWS CLI)
│   ├── alarm-definitions.json      # Alarm reference (managed by Terraform)
│   └── log-insights-queries.txt    # Saved Logs Insights queries
└── scripts/
    └── deploy-infrastructure.sh    # Wrapper for local terraform plan/apply
```

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.15.0
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) v2, configured with credentials that have sufficient IAM permissions
- An S3 bucket for Terraform remote state (set `TF_STATE_BUCKET` env var or update `main.tf`)

## First-Time Setup

### 1. Configure variables

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — values are safe to commit except secrets
```

### 2. Initialise Terraform

```bash
cd terraform
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=production/terraform.tfstate" \
  -backend-config="region=us-east-1"
```

### 3. Review the plan

```bash
terraform plan
```

### 4. Apply

```bash
terraform apply
```

After apply, note the outputs — you will need them for the application pipelines:

```bash
terraform output
```

Key outputs:

| Output | Used by |
|--------|---------|
| `alb_dns_name` | Backend smoke tests, health checks |
| `cloudfront_domain` | Frontend CORS / `VITE_API_BASE_URL` |
| `s3_bucket_name` | Frontend deploy script |
| `cloudfront_distribution_id` | Frontend deploy script (cache invalidation) |
| `ecr_repository_url` | Backend Docker build & deploy |

## CI/CD Pipeline

The GitHub Actions workflow runs automatically:

- **On pull request** → `terraform fmt`, `terraform validate`, `terraform plan`. The plan is posted as a PR comment so reviewers can see what will change before merging.
- **On push to `main`** → `terraform apply -auto-approve` with the saved plan.
- **On `workflow_dispatch`** → manual trigger for either event type.

Required GitHub Secrets:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user/role with Terraform permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret |
| `TF_STATE_BUCKET` | S3 bucket name for remote state |

## Deploying the CloudWatch Dashboard

The dashboard is not managed by Terraform (it contains ALB ARN suffixes that are only known after apply). After a successful `terraform apply`:

```bash
# Get the ALB ARN suffix from Terraform outputs
ALB_ARN=$(cd terraform && terraform output -raw alb_dns_name)

# Deploy the dashboard (replace <ALB_ARN_SUFFIX> in the JSON first)
aws cloudwatch put-dashboard \
  --dashboard-name starttech-production \
  --dashboard-body file://monitoring/cloudwatch-dashboard.json \
  --region us-east-1
```

See [RUNBOOK.md](RUNBOOK.md) for the full substitution procedure.

## Destroying Infrastructure

```bash
cd terraform
terraform destroy
```

> **Warning:** This will delete all resources including the S3 frontend bucket and ECR images. Back up any data you need first.
