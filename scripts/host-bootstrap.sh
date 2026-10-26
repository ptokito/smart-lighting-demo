#!/usr/bin/env bash
# =============================================================================
# host-bootstrap.sh: builds the host VM (lighting-host) from a blank Ubuntu 24.04.
#
# Run automatically, once, by the EC2 user data that Terraform attaches to the
# instance (infra/aws/templates/host-user-data.sh). Output goes to
# /var/log/smart-lighting-bootstrap.log. Safe to re-run by hand if a step
# fails:  sudo bash /opt/smart-lighting/scripts/host-bootstrap.sh
#
# Settings come from /etc/smart-lighting/bootstrap.env, written by user data:
#   AWS_REGION, PARAM_PREFIX, K3S_IP, VPC_CIDR, LOG_GROUP
#
# What ends up on this VM:
#   PostgreSQL 16 ... devices, readings (15.5M rows), commands, work orders
#   Redis ........... status cache and the demo fault switches
#   NGINX ........... public entry point, proxies to the portal on k3s
#   device-gateway .. Python service with the New Relic APM agent (systemd)
#   New Relic infrastructure agent + NGINX, PostgreSQL and Redis integrations
#   Amazon CloudWatch agent (logs to CloudWatch, then the S3 archive)
# =============================================================================
set -euo pipefail

REPO=/opt/smart-lighting
source /etc/smart-lighting/bootstrap.env
source "${REPO}/scripts/lib.sh"
export DEBIAN_FRONTEND=noninteractive    # never stop to ask apt questions

step "Install packages (PostgreSQL, Redis, NGINX, Python, tools)"
retry 3 apt-get update -q
retry 3 apt-get install -y -q postgresql redis-server nginx python3-venv python3-pip \
  git jq curl gnupg gettext-base
install_aws_cli

step "Read secrets from Parameter Store"
NEW_RELIC_LICENSE_KEY=$(param newrelic-license-key)
DB_PASSWORD=$(param db-password)
REDIS_PASSWORD=$(param redis-password)
NR_DB_PASSWORD=$(param newrelic-db-password)
echo "Read 4 parameters under ${PARAM_PREFIX} (values not printed)"

step "Configure PostgreSQL: listen on the VPC, log slow statements"
PG_CONF=/etc/postgresql/16/main/postgresql.conf
PG_HBA=/etc/postgresql/16/main/pg_hba.conf
# Accept connections from the k3s node (security group limits who can reach 5432).
grep -q "^listen_addresses = '\*'" "$PG_CONF" || echo "listen_addresses = '*'" >> "$PG_CONF"
# Write any statement slower than 500 ms to the PostgreSQL log. That log goes
# to New Relic and CloudWatch, so the slow-query demo leaves a written record.
grep -q "^log_min_duration_statement" "$PG_CONF" || echo "log_min_duration_statement = 500" >> "$PG_CONF"
# Allow the lighting app user from inside the VPC, with password (scram) auth.
grep -q "smart-lighting" "$PG_HBA" || \
  echo "host lighting lighting ${VPC_CIDR} scram-sha-256  # smart-lighting" >> "$PG_HBA"
systemctl restart postgresql

step "Create database users and the lighting database"
# Run as the postgres superuser. Each statement checks before creating, so a
# re-run does not fail. Passwords are passed as psql variables (:'name'),
# which quotes them safely.
sudo -u postgres psql -v ON_ERROR_STOP=1 -q \
  -v app_pw="${DB_PASSWORD}" -v nr_pw="${NR_DB_PASSWORD}" <<'SQL'
SELECT 'CREATE ROLE lighting LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'lighting') \gexec
ALTER ROLE lighting PASSWORD :'app_pw';
-- Read-only monitoring user for the New Relic PostgreSQL integration.
SELECT 'CREATE ROLE newrelic LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'newrelic') \gexec
ALTER ROLE newrelic PASSWORD :'nr_pw';
GRANT pg_monitor TO newrelic;
SELECT 'CREATE DATABASE lighting OWNER lighting' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'lighting') \gexec
SQL

step "Load schema and seed data (about 15.5 million readings; 2 to 4 minutes)"
export PGPASSWORD="${DB_PASSWORD}"
psql -h 127.0.0.1 -U lighting -d lighting -v ON_ERROR_STOP=1 -q -f "${REPO}/db/schema.sql"
psql -h 127.0.0.1 -U lighting -d lighting -v ON_ERROR_STOP=1 -q -f "${REPO}/db/seed.sql"
psql -h 127.0.0.1 -U lighting -d lighting -tAc \
  "SELECT 'devices=' || (SELECT count(*) FROM devices) || ' readings=' || (SELECT count(*) FROM readings)"
unset PGPASSWORD

step "Configure Redis: password, reachable from the VPC"
REDIS_CONF=/etc/redis/redis.conf
# Later lines in redis.conf override earlier ones, so appending is enough.
# Remove our previous block first so re-runs do not stack duplicates.
sed -i '/# smart-lighting begin/,/# smart-lighting end/d' "$REDIS_CONF"
cat >> "$REDIS_CONF" <<EOF
# smart-lighting begin
bind 0.0.0.0
protected-mode yes
requirepass ${REDIS_PASSWORD}
# smart-lighting end
EOF
systemctl restart redis-server

step "Configure NGINX as the reverse proxy to the portal on k3s (${K3S_IP})"
K3S_IP="${K3S_IP}" envsubst '${K3S_IP}' < "${REPO}/host/nginx/smart-lighting.conf" \
  > /etc/nginx/sites-available/smart-lighting
ln -sf /etc/nginx/sites-available/smart-lighting /etc/nginx/sites-enabled/smart-lighting
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

step "Install device-gateway (Python + New Relic APM agent) as a systemd service"
id lighting >/dev/null 2>&1 || useradd --system --home /opt/smart-lighting --shell /usr/sbin/nologin lighting
mkdir -p /var/log/smart-lighting /etc/smart-lighting
chown lighting:lighting /var/log/smart-lighting
[ -d /opt/smart-lighting/venv ] || python3 -m venv /opt/smart-lighting/venv
retry 3 /opt/smart-lighting/venv/bin/pip install -q --upgrade -r "${REPO}/services/device-gateway/requirements.txt"
# Environment file with secrets: owned by root, readable only by root
# (systemd reads it as root before switching to the lighting user).
install -m 600 /dev/null /etc/smart-lighting/device-gateway.env
cat > /etc/smart-lighting/device-gateway.env <<EOF
NEW_RELIC_LICENSE_KEY=${NEW_RELIC_LICENSE_KEY}
NEW_RELIC_APP_NAME=lighting-device-gateway
NEW_RELIC_LABELS=env:demo;program:smart-lighting;team:city-sre;runtime:vm
NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_ENABLED=true
NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
DB_HOST=127.0.0.1
DB_PASSWORD=${DB_PASSWORD}
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
cp "${REPO}/host/systemd/device-gateway.service" /etc/systemd/system/device-gateway.service
systemctl daemon-reload
systemctl enable --now device-gateway
systemctl restart device-gateway

step "Install the New Relic infrastructure agent and on-host integrations"
# Config first, so the agent starts with the right license key and name.
install -m 600 /dev/null /etc/newrelic-infra.yml
NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY}" envsubst '${NEW_RELIC_LICENSE_KEY}' \
  < "${REPO}/host/newrelic/newrelic-infra.yml" > /etc/newrelic-infra.yml
# New Relic's signed apt repository for Ubuntu 24.04 (noble).
install -d -m 755 /etc/apt/keyrings
retry 3 curl -fsSL https://download.newrelic.com/infrastructure_agent/gpg/newrelic-infra.gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/newrelic-infra.gpg
echo "deb [signed-by=/etc/apt/keyrings/newrelic-infra.gpg] https://download.newrelic.com/infrastructure_agent/linux/apt noble main" \
  > /etc/apt/sources.list.d/newrelic-infra.list
retry 3 apt-get update -q
retry 3 apt-get install -y -q newrelic-infra nri-nginx nri-postgresql nri-redis
# Integration and log-forwarding configs. Files holding passwords are root-only.
mkdir -p /etc/newrelic-infra/integrations.d /etc/newrelic-infra/logging.d
cp "${REPO}/host/newrelic/integrations.d/nginx-config.yml" /etc/newrelic-infra/integrations.d/
install -m 600 /dev/null /etc/newrelic-infra/integrations.d/postgresql-config.yml
NR_DB_PASSWORD="${NR_DB_PASSWORD}" envsubst '${NR_DB_PASSWORD}' \
  < "${REPO}/host/newrelic/integrations.d/postgresql-config.yml" > /etc/newrelic-infra/integrations.d/postgresql-config.yml
install -m 600 /dev/null /etc/newrelic-infra/integrations.d/redis-config.yml
REDIS_PASSWORD="${REDIS_PASSWORD}" envsubst '${REDIS_PASSWORD}' \
  < "${REPO}/host/newrelic/integrations.d/redis-config.yml" > /etc/newrelic-infra/integrations.d/redis-config.yml
cp "${REPO}/host/newrelic/logging.d/host-logs.yml" /etc/newrelic-infra/logging.d/
systemctl restart newrelic-infra

step "Install the CloudWatch agent (logs to CloudWatch, then the S3 archive)"
install_cloudwatch_agent "${REPO}/host/cloudwatch/host-agent-config.json"

step "Smoke test"
for i in $(seq 1 12); do
  if curl -fsS http://127.0.0.1:8081/healthz >/dev/null; then
    echo "device-gateway is answering on :8081"
    break
  fi
  sleep 5
done
systemctl is-active postgresql redis-server nginx device-gateway newrelic-infra amazon-cloudwatch-agent

mkdir -p /var/lib/smart-lighting && date -u > /var/lib/smart-lighting/bootstrap-done
echo
echo "=== Host bootstrap complete ==="
