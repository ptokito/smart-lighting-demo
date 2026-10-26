# =============================================================================
# Workloads: one view per team, plus one program view for leadership.
#
# A workload groups related entities (services, hosts, monitors, service
# levels, dashboards) and rolls their health up into a single status, so each
# team opens one page that shows only what it owns. The demo panel can play
# these roles:
#
#   Developer         the code: the four services and the Browser app
#   Operations        what it runs on: hosts, NGINX, PostgreSQL, Redis,
#                     Kubernetes and the AWS resources
#   SRE               reliability: services, platform, service levels and the
#                     outside-in Synthetics check
#   Executive Buyer   outcomes: service levels, the resident-facing portal,
#                     availability and the program dashboard
#   Program           a workload of the four workloads above: one status for
#                     the whole Smart Lighting program
#
# Entities are selected with entity search queries rather than fixed IDs, so a
# rebuilt instance or redeployed service is picked up automatically. Every
# query requires reporting = 'true' so stale entities (such as the old
# corridor demo's) never pull a workload's status down. Several query blocks
# in one workload are combined with OR.
# =============================================================================

locals {
  # Reused selections.
  q_services   = "domain IN ('APM', 'EXT') AND type IN ('APPLICATION', 'SERVICE') AND name LIKE 'lighting-%' AND reporting = 'true'"
  q_browser    = "domain = 'BROWSER' AND name = 'lighting-portal' AND reporting = 'true'"
  q_hosts      = "domain = 'INFRA' AND type = 'HOST' AND (name = 'lighting-host' OR name = 'ip-10-42-1-20') AND reporting = 'true'"
  q_onhost     = "domain = 'INFRA' AND type IN ('NGINXSERVER', 'POSTGRESQLINSTANCE', 'REDISINSTANCE') AND reporting = 'true'"
  q_cluster    = "domain = 'INFRA' AND type = 'KUBERNETESCLUSTER' AND name = '${var.k8s_cluster_name}'"
  q_aws        = "domain = 'INFRA' AND type IN ('AWSEC2INSTANCE', 'AWSLAMBDAFUNCTION', 'AWSS3BUCKET') AND (name LIKE 'lighting-%' OR name LIKE 'smart-lighting%')"
  q_synthetics = "domain = 'SYNTH' AND type = 'MONITOR' AND name LIKE 'Larkspur Ridge%'"
  q_slos       = "domain = 'EXT' AND type = 'SERVICE_LEVEL' AND (name LIKE 'Light commands%' OR name LIKE 'Lighting API%')"
  q_dashboard  = "domain = 'VIZ' AND type = 'DASHBOARD' AND name = 'Larkspur Ridge Smart Lighting'"
}

resource "newrelic_workload" "developer" {
  account_id        = var.account_id
  scope_account_ids = [var.account_id]
  name              = "Smart Lighting: Developer"
  description       = "Application code: portal (Node.js, Browser), lighting-api, device-gateway and crew-dispatch (OpenTelemetry). Start here for errors, slow transactions, slow SQL and deployment impact."

  entity_search_query { query = local.q_services }
  entity_search_query { query = local.q_browser }
}

resource "newrelic_workload" "operations" {
  account_id        = var.account_id
  scope_account_ids = [var.account_id]
  name              = "Smart Lighting: Operations"
  description       = "Platform: the host VM and k3s node, NGINX, PostgreSQL, Redis, the Kubernetes cluster, and AWS EC2, Lambda and the S3 log archive."

  entity_search_query { query = local.q_hosts }
  entity_search_query { query = local.q_onhost }
  entity_search_query { query = local.q_cluster }
  entity_search_query { query = local.q_aws }
}

resource "newrelic_workload" "sre" {
  account_id        = var.account_id
  scope_account_ids = [var.account_id]
  name              = "Smart Lighting: SRE"
  description       = "Reliability: every service, the platform it runs on, the three service levels and the outside-in Synthetics check."

  entity_search_query { query = local.q_services }
  entity_search_query { query = local.q_hosts }
  entity_search_query { query = local.q_cluster }
  entity_search_query { query = local.q_onhost }
  entity_search_query { query = local.q_slos }
  entity_search_query { query = local.q_synthetics }
}

resource "newrelic_workload" "executive" {
  account_id        = var.account_id
  scope_account_ids = [var.account_id]
  name              = "Smart Lighting: Executive Buyer"
  description       = "Outcomes for residents: are lights responding on time (service levels), is the portal up (Synthetics), how residents experience it (Browser), and the program dashboard."

  entity_search_query { query = local.q_slos }
  entity_search_query { query = local.q_synthetics }
  entity_search_query { query = local.q_browser }
  entity_search_query { query = local.q_dashboard }
}

# The program view: a workload whose members are the four team workloads.
# Its status is the worst of theirs, so leadership sees one answer to
# "is the Smart Lighting program healthy?" and can drill into the team view
# that is not.
resource "newrelic_workload" "program" {
  account_id        = var.account_id
  scope_account_ids = [var.account_id]
  name              = "Larkspur Ridge Smart Lighting Program"
  description       = "All four team workloads in one place for city leadership."

  entity_guids = [
    newrelic_workload.developer.guid,
    newrelic_workload.operations.guid,
    newrelic_workload.sre.guid,
    newrelic_workload.executive.guid,
  ]
}
