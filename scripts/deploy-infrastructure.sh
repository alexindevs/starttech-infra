#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-production}"
cd "$SCRIPT_DIR/../terraform"
echo "==> Deploying infrastructure [$ENV]"
terraform init
terraform fmt -check || { echo "Run: terraform fmt"; exit 1; }
terraform validate
terraform plan -var="environment=$ENV" -out=tfplan
read -rp "Apply? (yes/no): " OK
[ "$OK" = "yes" ] || { rm -f tfplan; exit 0; }
terraform apply tfplan && rm -f tfplan
echo "==> Done."
