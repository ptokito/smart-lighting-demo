#!/bin/bash
# =============================================================================
# EC2 user data for the host VM. Terraform fills in the placeholder values below
# (templatefile), and cloud-init runs this once, as root, on first boot.
#
# It only does three things: write the settings file, clone the repository,
# and hand over to scripts/host-bootstrap.sh, which does the real work. Keeping
# this file tiny means almost all logic lives in the repo, where it is
# readable, commented and testable.
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/smart-lighting-bootstrap.log) 2>&1
echo "User data started at $(date -u)"

mkdir -p /etc/smart-lighting
cat > /etc/smart-lighting/bootstrap.env <<'EOF'
AWS_REGION=${aws_region}
PARAM_PREFIX=${param_prefix}
LOG_GROUP=${log_group}
K3S_IP=${k3s_ip}
VPC_CIDR=${vpc_cidr}
REPO_REF=${repo_ref}
EOF

apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q git
[ -d /opt/smart-lighting/.git ] || git clone --quiet --branch ${repo_ref} ${repo_url} /opt/smart-lighting

bash /opt/smart-lighting/scripts/host-bootstrap.sh
