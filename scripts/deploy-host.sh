#!/usr/bin/env bash
# =============================================================================
# deploy-host.sh REF: update device-gateway on the host VM to a Git ref.
#
# Called by GitHub Actions (through AWS Systems Manager Run Command) on every
# push to main, alongside deploy-k3s.sh on the Kubernetes node.
# =============================================================================
set -euo pipefail

REF=${1:-main}
REPO=/opt/smart-lighting
source /etc/smart-lighting/bootstrap.env
source "${REPO}/scripts/lib.sh"

step "Check out ${REF}"
checkout_ref "${REF}"

step "Install Python dependencies and restart device-gateway"
retry 3 /opt/smart-lighting/venv/bin/pip install -q --upgrade -r "${REPO}/services/device-gateway/requirements.txt"
cp "${REPO}/host/systemd/device-gateway.service" /etc/systemd/system/device-gateway.service
systemctl daemon-reload
systemctl restart device-gateway

step "Health check"
for i in $(seq 1 12); do
  if curl -fsS http://127.0.0.1:8081/healthz >/dev/null; then
    echo "DEPLOYED $(git -C "${REPO}" rev-parse --short HEAD)"
    exit 0
  fi
  sleep 5
done
echo "device-gateway did not become healthy" >&2
journalctl -u device-gateway -n 30 --no-pager >&2
exit 1
