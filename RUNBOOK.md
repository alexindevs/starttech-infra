# Operations Runbook

Day-to-day operational procedures for the StartTech infrastructure.

---

## Deploying Infrastructure Changes

### Normal workflow (recommended)

1. Open a pull request targeting `main`.
2. The CI pipeline runs `terraform plan` and posts the output as a PR comment.
3. Review the plan — confirm only expected resources are changing.
4. Merge the PR. CI runs `terraform apply` automatically.

### Emergency / manual apply

```bash
cd terraform
terraform init -backend-config="bucket=$TF_STATE_BUCKET" \
               -backend-config="key=production/terraform.tfstate" \
               -backend-config="region=us-east-1"
terraform plan -out=tfplan
terraform apply tfplan
```

---

## Deploying a New Backend Image

The backend CI/CD pipeline (in the application repo) handles this automatically on every push to `main`. To deploy manually:

```bash
# From the application repo root
export ECR_REGISTRY=$(aws ecr describe-repositories \
  --repository-names starttech-backend \
  --query 'repositories[0].repositoryUri' --output text | cut -d/ -f1)
export ECR_REPOSITORY=starttech-backend
export IMAGE_TAG=<git-sha-or-tag>
export ASG_NAME=production-backend-asg
export AWS_REGION=us-east-1

bash scripts/deploy-backend.sh
```

The script pulls the new image on each in-service instance via SSM and restarts the container.

---

## Rolling Back the Backend

Pass the image tag you want to roll back to:

```bash
bash scripts/rollback.sh <previous-image-tag>
```

To find available tags:

```bash
aws ecr list-images --repository-name starttech-backend \
  --query 'imageIds[*].imageTag' --output table
```

---

## Deploying the Frontend

The frontend CI/CD pipeline handles this automatically. To deploy manually:

```bash
export S3_BUCKET=$(cd terraform && terraform output -raw s3_bucket_name)
export CLOUDFRONT_DISTRIBUTION_ID=$(cd terraform && terraform output -raw cloudfront_distribution_id)
export AWS_REGION=us-east-1

bash scripts/deploy-frontend.sh   # from the application repo
```

---

## Deploying the CloudWatch Dashboard

After `terraform apply`, the ALB ARN suffix is available from Terraform outputs. The dashboard JSON uses a placeholder `<ALB_ARN_SUFFIX>` that must be replaced before deploying:

```bash
# Get the full ALB ARN from Terraform
ALB_FULL_ARN=$(cd terraform && terraform output -json | jq -r '.alb_dns_name.value')
# The ARN suffix is the loadbalancer/* portion — get it from the AWS CLI
ALB_ARN_SUFFIX=$(aws elbv2 describe-load-balancers \
  --names production-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text \
  | sed 's|.*:loadbalancer/||')

# Substitute and deploy
sed "s|app/production-alb/<ALB_ARN_SUFFIX>|app/${ALB_ARN_SUFFIX}|g" \
  monitoring/cloudwatch-dashboard.json > /tmp/dashboard.json

aws cloudwatch put-dashboard \
  --dashboard-name starttech-production \
  --dashboard-body file:///tmp/dashboard.json \
  --region us-east-1
```

---

## Health Checks

### Check ALB health

```bash
ALB_DNS=$(cd terraform && terraform output -raw alb_dns_name)
curl -sf "http://$ALB_DNS/health" | jq .
# Expected: {"database":"ok","cache":"ok"}
```

### Check individual EC2 instance health

```bash
INSTANCE_ID=<instance-id>
aws ssm start-session --target "$INSTANCE_ID"
# Inside the session:
curl -s http://localhost:8080/health
docker ps
docker logs starttech-backend --tail 50
```

### Check CloudFront

```bash
CF_DOMAIN=$(cd terraform && terraform output -raw cloudfront_domain)
curl -sI "https://$CF_DOMAIN" | grep -E "HTTP|x-cache"
```

---

## Scaling

### Manual scale-out (e.g. before a traffic spike)

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name production-backend-asg \
  --desired-capacity 3 \
  --region us-east-1
```

### Check current ASG state

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names production-backend-asg \
  --query 'AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:Instances[*].{ID:InstanceId,State:LifecycleState,Health:HealthStatus}}' \
  --output json
```

---

## Viewing Logs

### Live tail (last 5 minutes)

```bash
aws logs tail /starttech/production/app --follow --region us-east-1
```

### Filter errors

```bash
aws logs filter-log-events \
  --log-group-name /starttech/production/app \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region us-east-1 \
  --query 'events[*].message' --output text
```

### Logs Insights queries

Pre-written queries are in [monitoring/log-insights-queries.txt](monitoring/log-insights-queries.txt). Run them at:
`AWS Console → CloudWatch → Logs Insights → select /starttech/production/app`

---

## Alarm Reference

| Alarm name | Meaning | Typical cause |
|------------|---------|---------------|
| `production-cpu-high` | CPU > 70% sustained | Traffic spike; ASG will scale out automatically |
| `production-cpu-low` | CPU < 30% sustained | Low traffic; ASG will scale in automatically |
| `production-alb-5xx-high` | >10 HTTP 5xx/min | App crash, OOM, or bad deploy — check logs |
| `production-alb-unhealthy-hosts` | ALB target unhealthy | Container not starting, health check failing |
| `starttech-redis-cpu` | Redis CPU > 80% | Cache hot-key or cache size too small |

---

## Incident Response

### Backend instances failing health checks

1. Check alarm: `production-alb-unhealthy-hosts`
2. Describe target health: `aws elbv2 describe-target-health --target-group-arn <tg-arn>`
3. SSM into the failing instance and check: `docker ps`, `docker logs starttech-backend --tail 100`
4. If the container crashed: `docker inspect starttech-backend` for exit code
5. If the image is bad: roll back with `bash scripts/rollback.sh <previous-tag>`

### High 5xx error rate

1. Check `production-alb-5xx-high` alarm history
2. Correlate with recent deployments: `git log --oneline -10` in the application repo
3. Filter CloudWatch Logs for ERROR lines (see Logs section above)
4. Roll back if the issue started after a deploy

### Cannot connect to Redis

1. Verify `ENABLE_CACHE=true` in the container's env file (`/etc/starttech/app.env`)
2. Check security group: EC2 instance must be in `production-ec2-sg`
3. Test connectivity from the instance: `nc -zv <redis-endpoint> 6379`
4. Check ElastiCache cluster status in the console

---

## Destroying Infrastructure

> Only do this in non-production or when decommissioning.

```bash
cd terraform
terraform destroy
```

You will be prompted to confirm. Type `yes`. This is irreversible — S3 objects, ECR images, and all AWS resources will be deleted.
