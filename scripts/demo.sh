#!/usr/bin/env bash
# =============================================================================
# demo.sh: run fault.sh on the host VM from your workstation (your Ubuntu VM),
# without opening an interactive session.
#
#   ./scripts/demo.sh gateway-lag RV
#   ./scripts/demo.sh slow-query on
#   ./scripts/demo.sh dispatch-timeout on
#   ./scripts/demo.sh status
#   ./scripts/demo.sh all-off
#
# How it works: reads the host VM's instance ID and region from Terraform's
# outputs, sends the command with AWS Systems Manager Run Command, then polls
# until it finishes and prints the output. Using Run Command instead of an
# interactive Session Manager session avoids the session timing out mid-demo,
# which interrupted a rollback last time.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
INSTANCE_ID=$(terraform -chdir=infra/aws output -raw host_instance_id)
REGION=$(terraform -chdir=infra/aws output -raw aws_region)
ARGS="$*"

# Send the command. The parameters JSON is built with jq so arguments are
# quoted correctly.
CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "smart-lighting demo: ${ARGS:-status}" \
  --parameters "$(jq -cn --arg c "bash /opt/smart-lighting/scripts/fault.sh ${ARGS}" '{commands: [$c]}')" \
  --query Command.CommandId --output text)

# Poll every 2 seconds until the command is no longer pending or running.
while :; do
  STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed) sleep 2 ;; *) break ;; esac
done

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text
[ "$STATUS" = "Success" ] || { echo "Command finished with status: $STATUS" >&2; exit 1; }
