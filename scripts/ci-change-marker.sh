#!/usr/bin/env bash
# =============================================================================
# ci-change-marker.sh VERSION: record a New Relic change tracking marker
# (a "deployment") on each lighting service for the commit just deployed.
#
# Uses New Relic's GraphQL API (NerdGraph):
#   1. entitySearch finds each service's entity GUID by name
#   2. changeTrackingCreateDeployment records the marker with the version,
#      commit SHA, author, commit message and a link back to the commit
#
# The markers appear as vertical lines on every APM chart for these services,
# and each opens a deployment analysis page comparing before and after.
#
# Needs: NEW_RELIC_API_KEY (user key, GitHub secret), NEW_RELIC_ACCOUNT_ID,
# plus GITHUB_* variables that GitHub Actions sets automatically.
# =============================================================================
set -euo pipefail

VERSION="${1}+${GITHUB_SHA:0:7}"
COMMIT_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
MESSAGE=$(git log -1 --pretty=%s)
SERVICES="lighting-portal lighting-api lighting-device-gateway lighting-crew-dispatch"

# nerdgraph QUERY VARIABLES_JSON: POST a GraphQL request and print the response.
nerdgraph() {
  curl -fsS https://api.newrelic.com/graphql \
    -H "Content-Type: application/json" \
    -H "API-Key: ${NEW_RELIC_API_KEY}" \
    -d "$(jq -cn --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}')"
}

FIND_ENTITY='query($q: String!) { actor { entitySearch(query: $q) { results { entities { guid name domain } } } } }'
CREATE_MARKER='mutation($d: ChangeTrackingDeploymentInput!) { changeTrackingCreateDeployment(deployment: $d) { deploymentId entityGuid } }'

for svc in $SERVICES; do
  # APM for agent-instrumented services, EXT for the OpenTelemetry service.
  search="name = '${svc}' AND domain IN ('APM', 'EXT') AND accountId = ${NEW_RELIC_ACCOUNT_ID}"
  guid=$(nerdgraph "$FIND_ENTITY" "$(jq -cn --arg q "$search" '{q: $q}')" \
    | jq -r '.data.actor.entitySearch.results.entities[0].guid // empty')
  if [ -z "$guid" ]; then
    echo "::warning::No New Relic entity named ${svc} yet; skipping its marker"
    continue
  fi

  deployment=$(jq -cn \
    --arg guid "$guid" --arg version "$VERSION" --arg user "$GITHUB_ACTOR" \
    --arg description "$MESSAGE" --arg commit "$GITHUB_SHA" --arg link "$COMMIT_URL" \
    --arg group "github-run-${GITHUB_RUN_ID}" \
    '{d: {entityGuid: $guid, version: $version, user: $user, description: $description,
          commit: $commit, deepLink: $link, groupId: $group, deploymentType: "BASIC",
          changelog: ("See " + $link)}}')
  result=$(nerdgraph "$CREATE_MARKER" "$deployment")
  if echo "$result" | jq -e '.errors' >/dev/null; then
    echo "::error::Marker for ${svc} failed: $(echo "$result" | jq -c .errors)"
    exit 1
  fi
  echo "Marker recorded on ${svc} (${guid}): ${VERSION} \"${MESSAGE}\""
done
