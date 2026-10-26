#!/usr/bin/env bash
# =============================================================================
# fault.sh: switch the demo incidents on and off. Runs ON THE HOST VM.
#
# From your workstation you normally call it through scripts/demo.sh, which
# sends it to the host VM with AWS Systems Manager. On the VM itself:
#   sudo bash /opt/smart-lighting/scripts/fault.sh <fault> <on|off|DISTRICT>
#
# Faults
#   gateway-lag RV|OM|CS|CH|ALL   commands to that district take 4 to 8 s
#   gateway-lag off
#   slow-query on                 drop the readings index (full table scans)
#   slow-query off                rebuild the index (about 20 seconds)
#   dispatch-timeout on|off       crew-dispatch hangs 8 s, callers time out
#   status                        show what is currently switched on
#   all-off                       reset everything
#
# The fourth incident, the bad release, is not here on purpose: it is a real
# code change pushed to GitHub, so the change marker comes from the pipeline.
#
# Every switch is appended to /var/log/smart-lighting/fault.log, which is
# shipped to CloudWatch and archived to S3 with the other logs.
# =============================================================================
set -euo pipefail

source /etc/smart-lighting/bootstrap.env
source /opt/smart-lighting/scripts/lib.sh
REDIS_PASSWORD=$(param redis-password)
DB_PASSWORD=$(param db-password)

# Wrappers so the passwords never appear in the process list or in the output.
rcli() { REDISCLI_AUTH="${REDIS_PASSWORD}" redis-cli --no-auth-warning "$@"; }
psql_app() { PGPASSWORD="${DB_PASSWORD}" psql -h 127.0.0.1 -U lighting -d lighting -v ON_ERROR_STOP=1 -tA "$@"; }

note() {
  echo "$(date -u +%FT%TZ) $*" | tee -a /var/log/smart-lighting/fault.log
}

index_exists() {
  [ "$(psql_app -c "SELECT count(*) FROM pg_indexes WHERE indexname = 'idx_readings_device_ts'")" = "1" ]
}

status() {
  echo "gateway-lag ......... $(rcli GET fault:gateway-lag | sed 's/^$/off/')"
  echo "dispatch-timeout .... $(rcli GET fault:dispatch-timeout | sed 's/^$/off/')"
  if index_exists; then echo "slow-query .......... off (index present)"; else echo "slow-query .......... ON (index dropped)"; fi
  echo "release ............. $(curl -fsS "http://127.0.0.1/api/summary" | jq -r .release 2>/dev/null || echo unknown)"
}

case "${1:-status}:${2:-}" in
  gateway-lag:off)
    rcli DEL fault:gateway-lag >/dev/null
    note "gateway-lag OFF" ;;
  gateway-lag:RV|gateway-lag:OM|gateway-lag:CS|gateway-lag:CH|gateway-lag:ALL)
    rcli SET fault:gateway-lag "$2" >/dev/null
    note "gateway-lag ON for district $2"
    echo "Watch: LightCommand ackMs by district, the light-command SLO, lighting-device-gateway response time." ;;
  slow-query:on)
    psql_app -c "DROP INDEX IF EXISTS idx_readings_device_ts" >/dev/null
    note "slow-query ON (idx_readings_device_ts dropped)"
    echo "Watch: lighting-api Databases tab, slow SQL traces, PostgreSQL log lines over 500 ms." ;;
  slow-query:off)
    # CONCURRENTLY builds the index without blocking the gateway's inserts.
    psql_app -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_readings_device_ts ON readings (device_id, ts DESC)" >/dev/null
    note "slow-query OFF (index rebuilt)" ;;
  dispatch-timeout:on)
    rcli SET fault:dispatch-timeout on >/dev/null
    note "dispatch-timeout ON"
    echo "Watch: Errors Inbox (ReadTimeout), 504s on lighting-api, the timeout alert." ;;
  dispatch-timeout:off)
    rcli DEL fault:dispatch-timeout >/dev/null
    note "dispatch-timeout OFF" ;;
  all-off:*)
    rcli DEL fault:gateway-lag fault:dispatch-timeout >/dev/null
    index_exists || psql_app -c "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_readings_device_ts ON readings (device_id, ts DESC)" >/dev/null
    note "all faults OFF" ;;
  status:*) ;;
  *)
    sed -n '2,25p' "$0"
    exit 1 ;;
esac
echo
status
