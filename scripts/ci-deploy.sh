#!/usr/bin/env bash
# =============================================================================
# ci-deploy.sh: used by GitHub Actions to deploy the commit being built.
#
# Sends deploy-host.sh to the host VM and deploy-k3s.sh to the k3s node with
# AWS Systems Manager Run Command, waits for each, and prints their output in
# the Actions log. Needs AWS credentials (from the OIDC role) and these
# environment variables: AWS_REGION, HOST_INSTANCE_ID, K3S_INSTANCE_ID,
# GITHUB_SHA (set automatically by GitHub).
# =============================================================================
set -euo pipefail

# run_remote INSTANCE_ID LABEL COMMAND: send one command and wait (up to 20 min).
run_remote() {
  local instance=$1 label=$2 command=$3
  echo "::group::${label}"
  local cmd_id
  cmd_id=$(aws ssm send-command --instance-ids "$instance" \
    --document-name AWS-RunShellScript \
    --comment "GitHub Actions ${GITHUB_SHA:0:7}: ${label}" \
    --timeout-seconds 1200 \
    --parameters "$(jq -cn --arg c "$command" '{commands: [$c], executionTimeout: ["1200"]}')" \
    --query Command.CommandId --output text)

  local status=Pending
  for _ in $(seq 1 240); do
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending|InProgress|Delayed) sleep 5 ;; *) break ;; esac
  done

  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$instance" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text
  echo "::endgroup::"
  if [ "$status" != "Success" ]; then
    echo "::error::${label} finished with status ${status}"
    return 1
  fi
}

run_remote "$HOST_INSTANCE_ID" "Deploy device-gateway on the host VM" \
  "bash /opt/smart-lighting/scripts/deploy-host.sh ${GITHUB_SHA}"
run_remote "$K3S_INSTANCE_ID" "Build and deploy services on k3s" \
  "bash /opt/smart-lighting/scripts/deploy-k3s.sh ${GITHUB_SHA}"
