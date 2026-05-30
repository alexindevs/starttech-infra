# System Architecture

## Overview

StartTech runs a React SPA frontend and a Golang REST API backend, backed by MongoDB Atlas and ElastiCache Redis, deployed entirely on AWS.

```
Internet
   │
   ├─── HTTPS ──► CloudFront ──► S3 (React SPA)
   │
   └─── HTTP ───► ALB (public subnets)
                    │
                    └─► EC2 ASG (private subnets, port 8080)
                              │
                              ├─► MongoDB Atlas (external, TLS)
                              └─► ElastiCache Redis (private subnets, port 6379)
```

## Network Layout

All compute runs inside a dedicated VPC (`10.0.0.0/16`) across two availability zones (`us-east-1a`, `us-east-1b`).

| Subnet type | CIDRs | What lives here |
|-------------|-------|-----------------|
| Public | `10.0.0.0/24`, `10.0.1.0/24` | ALB, NAT Gateway EIP |
| Private | `10.0.10.0/24`, `10.0.11.0/24` | EC2 instances, ElastiCache |

Outbound internet access from private subnets flows through a single NAT Gateway in `us-east-1a`. This is a cost/availability trade-off — for production HA, a NAT Gateway per AZ is recommended.

## Security Groups

Traffic is restricted by least-privilege security group chaining:

```
0.0.0.0/0 ──► alb-sg (80, 443)
                │
                └──► ec2-sg (8080, from alb-sg only)
                          │
                          └──► redis-sg (6379, from ec2-sg only)
```

EC2 instances have no inbound SSH (port 22). Remote access is via AWS SSM Session Manager, which requires no open ports.

## Compute: EC2 Auto Scaling Group

- **Launch template**: Amazon Linux 2023, pulls the latest Docker image from ECR on boot via `userdata.sh`.
- **ASG**: min 1 / desired 1 / max 3 instances. Uses `instance_refresh` with rolling strategy (50% min healthy) so deployments don't drop traffic.
- **Scaling**: CPU-based. Scale-out at >70% CPU for 10 minutes; scale-in at <30% CPU for 20 minutes.
- **Health checks**: ALB health check type, hitting `GET /health` on port 8080. The health endpoint checks both MongoDB connectivity and Redis (if enabled).

## Frontend: S3 + CloudFront

- S3 bucket has all public access blocked. CloudFront accesses it via Origin Access Control (OAC) with SigV4 signing — no public S3 URLs.
- CloudFront is configured as an SPA host: 403 and 404 responses are rewritten to `index.html` with HTTP 200, so client-side routing works correctly.
- Static assets (JS/CSS with content hashes) are cached for 1 year (`max-age=31536000, immutable`). `index.html` is served with `no-cache` so users always get the latest entry point.
- HTTPS is enforced via `redirect-to-https` viewer protocol policy.

## Container Registry: ECR

- Single ECR repository (`starttech-backend`). Images are tagged with the Git commit SHA and `latest`.
- ECR `scan_on_push` is enabled — images are scanned for OS and package vulnerabilities on every push.
- Lifecycle policy retains the last 10 images and expires older ones.

## Caching: ElastiCache Redis

- Single-node `cache.t3.micro` Redis 7 cluster in private subnets.
- Used by the backend for username uniqueness checks (preloaded on startup) and session data.
- Redis is optional — the backend degrades gracefully when `ENABLE_CACHE=false`.

## Observability

| Component | Where logs go |
|-----------|---------------|
| Backend app logs | `/var/log/starttech/app.log` → CloudWatch log group `/starttech/production/app` (via CW agent) |
| Access logs | `/starttech/production/access` (30-day retention) |
| CloudFront access logs | Not currently enabled (can be added to the storage module) |

CloudWatch alarms:

| Alarm | Threshold | Action |
|-------|-----------|--------|
| `production-cpu-high` | CPU > 70% for 10 min | Scale out (+1 instance) |
| `production-cpu-low` | CPU < 30% for 20 min | Scale in (-1 instance) |
| `production-alb-5xx-high` | >10 5xx/min for 2 periods | Notify (no auto-action) |
| `production-alb-unhealthy-hosts` | >0 unhealthy hosts for 2 periods | Notify (no auto-action) |

## IAM

EC2 instances have a single instance profile with three policies:

| Policy | Purpose |
|--------|---------|
| `CloudWatchAgentServerPolicy` (AWS managed) | Write logs and metrics to CloudWatch |
| `AmazonSSMManagedInstanceCore` (AWS managed) | SSM Session Manager access (no SSH needed) |
| `production-ecr-pull` (inline) | Pull images from ECR |

## Terraform Module Dependency Graph

```
variables.tf
     │
     ├─► module.networking  (no dependencies)
     ├─► module.storage     (no dependencies)
     ├─► module.monitoring  (no dependencies)
     └─► module.compute     (depends on networking, storage, monitoring)
```

`monitoring` must be created before `compute` because compute's launch template needs the CloudWatch log group name. This is the only cross-module ordering constraint.
