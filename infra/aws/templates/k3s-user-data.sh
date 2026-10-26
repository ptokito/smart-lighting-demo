#!/bin/bash
# =============================================================================
# EC2 user data for the k3s node. Terraform fills in the placeholder values below;
# cloud-init runs this once, as root, on first boot. Same pattern as the host
# VM: write settings, clone the repo, run scripts/k3s-bootstrap.sh.
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/smart-lighting-bootstrap.log) 2>&1
echo "User data started at $(date -u)"

mkdir -p /etc/smart-lighting
cat > /etc/smart-lighting/bootstrap.env <<'EOF'
AWS_REGION=${aws_region}
PARAM_PREFIX=${param_prefix}
LOG_GROUP=${log_group}
HOST_IP=${host_ip}
CLUSTER_NAME=${cluster_name}
REPO_REF=${repo_ref}
EOF

apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q git
[ -d /opt/smart-lighting/.git ] || git clone --quiet --branch ${repo_ref} ${repo_url} /opt/smart-lighting

bash /opt/smart-lighting/scripts/k3s-bootstrap.sh
