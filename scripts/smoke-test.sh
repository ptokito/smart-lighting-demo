#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh: check the public site end to end from your workstation.
# Every request goes through NGINX, the portal, lighting-api and (for the last
# two) device-gateway and crew-dispatch, so a pass means every hop works.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
URL=$(terraform -chdir=infra/aws output -raw portal_url)

check() {
  local label=$1; shift
  if out=$("$@" 2>&1); then echo "PASS  ${label}"; else echo "FAIL  ${label}: ${out}"; FAILED=1; fi
}
FAILED=0
check "portal home page"          curl -fsS -o /dev/null "${URL}/"
check "resident report page"      curl -fsS -o /dev/null "${URL}/report"
check "summary API"               curl -fsS "${URL}/api/summary"
check "device list API"           curl -fsS -o /dev/null "${URL}/api/devices"
check "command via gateway"       curl -fsS -H 'Content-Type: application/json' \
                                  -d '{"device_id":"SL-RV-001","command":"on","source":"operator"}' "${URL}/api/commands"
check "report via crew-dispatch"  curl -fsS -H 'Content-Type: application/json' \
                                  -d '{"device_id":"SL-CS-002","description":"Smoke test, please ignore","source":"operator"}' "${URL}/api/reports"
exit $FAILED
