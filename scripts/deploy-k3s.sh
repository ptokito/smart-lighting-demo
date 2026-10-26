#!/usr/bin/env bash
# =============================================================================
# deploy-k3s.sh REF: build the four service images at a Git ref and roll them
# out on k3s.
#
# Called by:
#   * k3s-bootstrap.sh on first boot (REF = main)
#   * GitHub Actions on every push to main, through AWS Systems Manager
#     Run Command (REF = the exact commit SHA being deployed)
#
# Images are tagged with the short commit SHA. Because the tag changes on every
# deploy, the pod spec changes and Kubernetes performs a rolling update; the
# tag also lands in OpenTelemetry's service.version, tying the running code to
# the New Relic change marker for the same commit.
# =============================================================================
set -euo pipefail

REF=${1:-main}
REPO=/opt/smart-lighting
source /etc/smart-lighting/bootstrap.env
source "${REPO}/scripts/lib.sh"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

step "Check out ${REF}"
checkout_ref "${REF}"
IMAGE_TAG=$(git -C "${REPO}" rev-parse --short HEAD)

step "Build images with tag ${IMAGE_TAG} and import them into k3s"
# k3s uses containerd, not Docker, so each image built with Docker is exported
# (docker save) and imported into k3s's containerd image store.
for svc in portal lighting-api crew-dispatch simulator; do
  echo "--- ${svc}"
  docker build --quiet -t "smart-lighting/${svc}:${IMAGE_TAG}" "${REPO}/services/${svc}"
  docker save "smart-lighting/${svc}:${IMAGE_TAG}" | k3s ctr images import - >/dev/null
done

step "Create or update the namespace and the Kubernetes Secret"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: lighting
EOF
# Secret values come straight from Parameter Store; they never touch the repo.
# --dry-run | apply makes this an update when the Secret already exists.
kubectl -n lighting create secret generic lighting-secrets \
  --from-literal=NEW_RELIC_LICENSE_KEY="$(param newrelic-license-key)" \
  --from-literal=DB_PASSWORD="$(param db-password)" \
  --from-literal=REDIS_PASSWORD="$(param redis-password)" \
  --dry-run=client -o yaml | kubectl apply -f -

step "Apply manifests"
# Only these two variables are substituted, so Kubernetes' own $(VAR) syntax
# inside the manifest is left untouched.
export IMAGE_TAG HOST_IP
envsubst '${IMAGE_TAG} ${HOST_IP}' < "${REPO}/k8s/apps.yaml" | kubectl apply -f -

step "Wait for the rollout"
for d in portal lighting-api crew-dispatch simulator; do
  kubectl -n lighting rollout status "deployment/${d}" --timeout=300s
done

# Remove images from earlier deploys so the 30 GB disk does not fill up.
docker image prune -af --filter "until=24h" >/dev/null 2>&1 || true

echo "DEPLOYED ${IMAGE_TAG}"
