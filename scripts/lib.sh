#!/usr/bin/env bash
# =============================================================================
# Shared helpers sourced by the bootstrap and deploy scripts on both EC2
# instances. Not meant to be run on its own.
# =============================================================================

# step "description": prints a numbered, timestamped banner so the bootstrap
# log (/var/log/smart-lighting-bootstrap.log) reads like a checklist and you
# can see exactly where a failure happened. We use this instead of `set -x`,
# which would print every command, including ones that handle secrets.
# Scripts started by cloud-init or Run Command have no HOME set, and git,
# helm and docker all expect one, so default it to /root.
export HOME="${HOME:-/root}"

# Scripts started by cloud-init or Run Command have no HOME set, and git,
# helm and docker all expect one, so default it to /root.
export HOME="${HOME:-/root}"

STEP_NO=0
step() {
  STEP_NO=$((STEP_NO + 1))
  echo
  echo "=== [$(date -u +%H:%M:%S)] Step ${STEP_NO}: $* ==="
}

# param NAME: read one SecureString from AWS Systems Manager Parameter Store
# (decrypted) under this environment's prefix, e.g. param db-password.
# The instance role grants read access to that prefix only.
param() {
  aws ssm get-parameter --region "${AWS_REGION}" --with-decryption \
    --name "${PARAM_PREFIX}/$1" --query Parameter.Value --output text
}

# retry N CMD...: run a command up to N times, 10 seconds apart. Package
# mirrors and download sites occasionally fail on a fresh instance.
retry() {
  local attempts=$1; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "Command failed after ${attempts} attempts: $*" >&2
      return 1
    fi
    echo "Attempt ${n} failed, retrying in 10s: $*"
    n=$((n + 1))
    sleep 10
  done
}

# checkout_ref REF: move the repo in /opt/smart-lighting to a branch name or a
# commit SHA. Used by the first bootstrap ("main") and by every GitHub Actions
# deploy (an exact commit SHA).
checkout_ref() {
  local ref=$1
  git config --system --add safe.directory /opt/smart-lighting
  cd /opt/smart-lighting || return 1
  retry 3 git fetch --quiet origin
  git checkout --quiet --force --detach "origin/${ref}" 2>/dev/null \
    || git checkout --quiet --force --detach "${ref}"
  echo "Repo now at $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"
}

# install_aws_cli: Ubuntu 24.04 no longer ships the AWS CLI as an apt package,
# so it comes from the official snap.
install_aws_cli() {
  if ! command -v aws >/dev/null 2>&1; then
    retry 3 snap install aws-cli --classic
  fi
}

# install_cloudwatch_agent CONFIG_TEMPLATE: install the Amazon CloudWatch agent,
# fill the log group name into its config and start it.
install_cloudwatch_agent() {
  local template=$1
  if ! dpkg -s amazon-cloudwatch-agent >/dev/null 2>&1; then
    retry 3 curl -fsSL -o /tmp/amazon-cloudwatch-agent.deb \
      "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
    dpkg -i /tmp/amazon-cloudwatch-agent.deb
  fi
  LOG_GROUP="${LOG_GROUP}" envsubst '${LOG_GROUP}' < "${template}" \
    > /opt/aws/amazon-cloudwatch-agent/etc/smart-lighting.json
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/smart-lighting.json
}
