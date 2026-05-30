#!/bin/bash
set -euxo pipefail

yum update -y
yum install -y docker amazon-cloudwatch-agent

systemctl enable docker
systemctl start docker
usermod -a -G docker ec2-user

mkdir -p /var/log/starttech /etc/starttech
chmod 777 /var/log/starttech

# CloudWatch agent config
# NOTE: ${log_group_name} is a Terraform templatefile variable (replaced at apply time)
# NOTE: {instance_id} (no dollar) is a CloudWatch agent placeholder (resolved at runtime)
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [{
          "file_path": "/var/log/starttech/app.log",
          "log_group_name": "${log_group_name}",
          "log_stream_name": "{instance_id}/app",
          "timestamp_format": "%Y-%m-%dT%H:%M:%S"
        }]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "cpu": { "measurement": ["cpu_usage_active"], "metrics_collection_interval": 60 },
      "mem": { "measurement": ["mem_used_percent"],  "metrics_collection_interval": 60 }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Get current region from instance metadata (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

# Login to ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin ${ecr_repository_url}

# Write base (non-secret) env file
cat > /etc/starttech/app.env << APPEOF
ENVIRONMENT=${environment}
LOG_FILE=/var/log/starttech/app.log
LOG_FORMAT=json
PORT=8080
AWS_REGION=$REGION
APPEOF

# Fetch secrets from SSM Parameter Store and append to env file
# Using JSON output + python3 to safely handle special characters in values (e.g. & in URIs)
echo "Fetching secrets from SSM path /starttech/${environment}..."
aws ssm get-parameters-by-path \
  --path "/starttech/${environment}" \
  --with-decryption \
  --region "$REGION" \
  --query 'Parameters[*].{Name:Name,Value:Value}' \
  --output json | python3 -c "
import json, sys, os
params = json.load(sys.stdin)
with open('/etc/starttech/app.env', 'a') as f:
    for p in params:
        key = os.path.basename(p['Name'])
        value = p['Value']
        f.write(key + '=' + value + '\n')
"
chmod 644 /etc/starttech/app.env

# Pull and start the container (safe to fail on first boot before image exists)
if docker pull ${ecr_repository_url}:latest 2>/dev/null; then
  docker run -d \
    --name starttech-backend \
    --restart always \
    -p 8080:8080 \
    -v /var/log/starttech:/var/log/starttech \
    -v /etc/starttech/app.env:/.env:ro \
    ${ecr_repository_url}:latest
fi
