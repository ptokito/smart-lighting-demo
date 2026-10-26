#!/usr/bin/env bash
# =============================================================================
# k3s-bootstrap.sh: builds the Kubernetes node (lighting-k3s) from a blank
# Ubuntu 24.04.
#
# Run automatically, once, by EC2 user data (infra/aws/templates/
# k3s-user-data.sh). Output goes to /var/log/smart-lighting-bootstrap.log.
# Safe to re-run:  sudo bash /opt/smart-lighting/scripts/k3s-bootstrap.sh
#
# Settings come from /etc/smart-lighting/bootstrap.env, written by user data:
#   AWS_REGION, PARAM_PREFIX, HOST_IP, LOG_GROUP, CLUSTER_NAME, REPO_REF
#
# What ends up on this node:
#   k3s (lightweight Kubernetes) with Traefik disabled (NGINX on the host VM
#   is the entry point, so no ingress controller is needed)
#   Docker, only to build the service images locally
#   Helm and the New Relic Kubernetes integration (nri-bundle)
#   The four services in the "lighting" namespace
#   Amazon CloudWatch agent for the pod logs
# =============================================================================
set -euo pipefail

REPO=/opt/smart-lighting
source /etc/smart-lighting/bootstrap.env
source "${REPO}/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

step "Install packages (Docker for image builds, tools)"
retry 3 apt-get update -q
retry 3 apt-get install -y -q docker.io git jq curl gettext-base
systemctl enable --now docker
install_aws_cli

step "Install k3s (single-node Kubernetes)"
if ! command -v k3s >/dev/null 2>&1; then
  # --disable traefik: no ingress controller needed.
  # --write-kubeconfig-mode 644: lets kubectl run without sudo for the ssm-user.
  # Pod and service networks moved off 10.42.0.0/16, which overlaps the VPC.
  # Pod and service networks moved off 10.42.0.0/16, which overlaps the VPC.
  retry 3 bash -c 'curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644 --cluster-cidr 10.52.0.0/16 --service-cidr 10.53.0.0/16" sh -'
fi
# Wait until the node reports Ready.
for i in $(seq 1 30); do
  kubectl get nodes 2>/dev/null | grep -q " Ready" && break
  sleep 5
done
kubectl get nodes

step "Install Helm"
if ! command -v helm >/dev/null 2>&1; then
  retry 3 bash -c 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
fi

step "Install the New Relic Kubernetes integration (nri-bundle)"
NEW_RELIC_LICENSE_KEY=$(param newrelic-license-key)
retry 3 helm repo add newrelic https://helm-charts.newrelic.com --force-update
retry 3 helm repo update newrelic
# What each setting does:
#   global.cluster ............ cluster name shown in New Relic's Kubernetes UI
#   newrelic-infrastructure ... node, pod and container metrics (DaemonSet)
#   kube-state-metrics ........ deployment and replica status
#   kubeEvents ................ Kubernetes events (pod restarts, failed scheduling)
#   nri-metadata-injection .... adds pod and node names to APM data, linking
#                               each trace to the pod that served it
#   logging=false ............. pod logs are already sent by the APM agents
#                               and OpenTelemetry; sending them again here
#                               would duplicate every line
#   prometheus agent=false .... not needed for this demo; saves memory
#   controlPlane=false ........ k3s runs the control plane inside one binary,
#                               which the integration cannot scrape
retry 3 helm upgrade --install newrelic-bundle newrelic/nri-bundle \
  --namespace newrelic --create-namespace --wait --timeout 10m \
  --set global.licenseKey="${NEW_RELIC_LICENSE_KEY}" \
  --set global.cluster="${CLUSTER_NAME}" \
  --set newrelic-infrastructure.privileged=true \
  --set newrelic-infrastructure.controlPlane.enabled=false \
  --set kube-state-metrics.enabled=true \
  --set kubeEvents.enabled=true \
  --set nri-metadata-injection.enabled=true \
  --set logging.enabled=false \
  --set newrelic-prometheus-agent.enabled=false
kubectl -n newrelic get pods

step "Wait for the host VM (database seeded, device-gateway up)"
# The services crash on start if PostgreSQL is not ready, which would make the
# rollout below time out. device-gateway only starts after the database is
# seeded, so its health check is a good "host is ready" signal.
for i in $(seq 1 120); do
  if curl -fsS "http://${HOST_IP}:8081/healthz" >/dev/null 2>&1; then
    echo "Host VM is ready"
    break
  fi
  [ "$i" -eq 120 ] && { echo "Host VM not ready after 20 minutes" >&2; exit 1; }
  sleep 10
done

step "Build and deploy the lighting services"
bash "${REPO}/scripts/deploy-k3s.sh" "${REPO_REF}"

step "Restart app pods once so the metadata-injection webhook decorates them"
# The webhook only changes pods created after it is running. Restarting once
# guarantees every pod carries its Kubernetes metadata into New Relic APM.
kubectl -n lighting rollout restart deployment
for d in portal lighting-api crew-dispatch simulator; do
  kubectl -n lighting rollout status "deployment/${d}" --timeout=300s
done

step "Install the CloudWatch agent for pod logs"
install_cloudwatch_agent "${REPO}/host/cloudwatch/k3s-agent-config.json"

mkdir -p /var/lib/smart-lighting && date -u > /var/lib/smart-lighting/bootstrap-done
kubectl -n lighting get pods -o wide
echo
echo "=== k3s bootstrap complete ==="
