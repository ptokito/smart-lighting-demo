# =============================================================================
# Alerts as code: one policy, eleven conditions, email notifications.
#
# Conditions are ordered from the business outcome down to the infrastructure,
# mirroring how the story is told in the demo:
#   1  light commands slow to acknowledge     (business: "a light takes too long")
#   2  light command SLO burning too fast     (business: error budget)
#   3  devices not checking in                (field network / devices offline)
#   4  service response time high             (APM latency, all services except commands)
#   5  service error rate high                (APM errors, all services)
#   6  timeout errors on lighting-api         (calls to crew-dispatch timing out)
#   7  slow database queries                  (PostgreSQL time per request)
#   8  crew-dispatch (OpenTelemetry) errors   (spans with error status)
#   9  Kubernetes containers restarting       (k3s)
#  10  host not reporting                     (either EC2 instance)
#  11  Synthetics check failing               (outside-in availability)
#
# Each condition has a description and a runbook-style title so the email
# tells the on-call engineer what is wrong and where to look.
# =============================================================================

resource "newrelic_alert_policy" "lighting" {
  name = "Larkspur Ridge Smart Lighting"
  # One incident per condition and per facet (e.g. per district), so a
  # Riverside problem and a Cedar Hollow problem are tracked separately.
  incident_preference = "PER_CONDITION_AND_TARGET"
}

# Shared settings for event-based NRQL conditions. event_flow evaluates each
# 1-minute window once data for it has arrived, and waits 2 minutes for late
# data, which suits steady streams like ours.
locals {
  window = 60
  delay  = 120
}

# ---- 1. Business: light commands slow ---------------------------------------
resource "newrelic_nrql_alert_condition" "light_commands_slow" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Light commands slow to acknowledge"
  description                  = "95th percentile acknowledgement time for streetlight and signal commands, per district. Above 2 s means residents and operators see lights respond late. Check device-gateway traces for the district and the field network gateway."
  title_template               = "Lights in {{tags.district}} are slow to respond to commands"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT percentile(ackMs, 95) FROM LightCommand FACET district"
  }
  critical {
    operator              = "above"
    threshold             = 2000
    threshold_duration    = 180
    threshold_occurrences = "all"
  }
  warning {
    operator              = "above"
    threshold             = 1500
    threshold_duration    = 120
    threshold_occurrences = "all"
  }
}

# ---- 2. Business: SLO burn rate ---------------------------------------------
# Burn rate = how fast the error budget is being spent. 1 means "exactly on
# budget for the week"; 10 means the week's budget would be gone in under a
# day. A high burn rate over a few minutes catches a real incident quickly.
resource "newrelic_nrql_alert_condition" "light_slo_burn" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Light response SLO burning error budget fast"
  description                  = "The 'Light commands acknowledged within 2 seconds' SLO (target 99%) is spending its weekly error budget more than 10 times faster than sustainable."
  title_template               = "Light response SLO burn rate high"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "FROM Metric SELECT (100 - clamp_max(sum(newrelic.sli.good) / sum(newrelic.sli.valid) * 100, 100)) / (100 - 99) AS 'Burn rate' WHERE sli.guid = '${newrelic_service_level.light_response.sli_guid}'"
  }
  critical {
    operator              = "above"
    threshold             = 10
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---- 3. Devices not checking in ---------------------------------------------
resource "newrelic_nrql_alert_condition" "devices_silent" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Devices not checking in"
  description                  = "Fewer than 55 of the 60 streetlights and signals sent a heartbeat in the last minute, or no heartbeats at all for 5 minutes. Check device-gateway and the field network."
  title_template               = "Streetlights or signals have stopped checking in"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay
  # Loss of signal: if the whole stream stops, open an incident anyway.
  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = false

  nrql {
    query = "SELECT uniqueCount(deviceId) FROM LightingCheckIn"
  }
  critical {
    operator              = "below"
    threshold             = 55
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---- 4. APM response time ---------------------------------------------------
resource "newrelic_nrql_alert_condition" "response_time" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Service response time high"
  description                  = "95th percentile web response time above 0.75 s for any lighting service (warning above 0.4 s), excluding light commands, whose time is set by the field network and is watched by the light-command alert and SLO. Open the service in APM, check the Transactions and Databases tabs, then a slow trace."
  title_template               = "{{tags.appName}} is responding slowly"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT percentile(duration, 95) FROM Transaction WHERE appName LIKE 'lighting-%' AND transactionType = 'Web' AND name NOT LIKE '%command%' FACET appName"
  }
  critical {
    operator              = "above"
    threshold             = 0.75
    threshold_duration    = 180
    threshold_occurrences = "all"
  }
  warning {
    operator              = "above"
    threshold             = 0.4
    threshold_duration    = 180
    threshold_occurrences = "all"
  }
}

# ---- 5. APM error rate ------------------------------------------------------
resource "newrelic_nrql_alert_condition" "error_rate" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Service error rate high"
  description                  = "More than 5% of web requests to a lighting service ended in an error for 5 minutes. Open Errors Inbox, grouped by error class."
  title_template               = "{{tags.appName}} error rate above 5%"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName LIKE 'lighting-%' AND transactionType = 'Web' FACET appName"
  }
  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---- 6. Timeout errors ------------------------------------------------------
resource "newrelic_nrql_alert_condition" "timeouts" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Timeout errors calling crew-dispatch"
  description                  = "lighting-api is recording timeout errors (ReadTimeout) when asking crew-dispatch to assign a crew. Residents get 'crew assignment delayed'. Check crew-dispatch spans and its pod."
  title_template               = "Outage reports are timing out at crew dispatch"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT count(*) FROM TransactionError WHERE appName = 'lighting-api' AND error.class LIKE '%Timeout%'"
  }
  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 120
    threshold_occurrences = "at_least_once"
  }
}

# ---- 7. Slow database queries -----------------------------------------------
resource "newrelic_nrql_alert_condition" "slow_db" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Slow database queries"
  description                  = "Average time lighting-api spends in PostgreSQL per device-history request is above 300 ms. Usually a missing index or a sequential scan: check the Databases tab, the slow SQL trace's explain plan, and PostgreSQL logs."
  title_template               = "Database queries for device history are slow"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay
  # History requests are occasional, so empty windows are normal: do not
  # treat them as zero or as a problem.
  fill_option = "none"

  nrql {
    query = "SELECT average(databaseDuration) FROM Transaction WHERE appName = 'lighting-api' AND name LIKE '%device_history%'"
  }
  critical {
    operator              = "above"
    threshold             = 0.3
    threshold_duration    = 120
    threshold_occurrences = "at_least_once"
  }
}

# ---- 8. OpenTelemetry service errors ----------------------------------------
resource "newrelic_nrql_alert_condition" "otel_errors" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "crew-dispatch errors (OpenTelemetry)"
  description                  = "Server spans from the OpenTelemetry-instrumented crew-dispatch service are ending with an error status."
  title_template               = "crew-dispatch is returning errors"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT count(*) FROM Span WHERE service.name = 'lighting-crew-dispatch' AND span.kind = 'server' AND otel.status_code = 'ERROR'"
  }
  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---- 9. Kubernetes restarts -------------------------------------------------
resource "newrelic_nrql_alert_condition" "k8s_restarts" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Containers restarting in the lighting namespace"
  description                  = "A container in the lighting namespace restarted more than twice in 5 minutes (crash loop). Check the pod's events and logs in the Kubernetes cluster explorer."
  title_template               = "{{tags.containerName}} is restarting repeatedly"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay

  nrql {
    query = "SELECT sum(restartCountDelta) FROM K8sContainerSample WHERE clusterName = '${var.k8s_cluster_name}' AND namespaceName = 'lighting' FACET containerName"
  }
  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

# ---- 10. Host not reporting -------------------------------------------------
resource "newrelic_nrql_alert_condition" "host_not_reporting" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Host not reporting"
  description                  = "An EC2 instance (host VM or k3s node) stopped sending infrastructure data for 5 minutes: stopped, crashed, or Spot reclaimed."
  title_template               = "{{tags.hostname}} has stopped reporting"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = local.window
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay
  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = true

  nrql {
    query = "SELECT count(*) FROM SystemSample WHERE hostname LIKE 'lighting-%' OR clusterName = '${var.k8s_cluster_name}' FACET hostname"
  }
  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
}

# ---- 11. Synthetics ---------------------------------------------------------
resource "newrelic_nrql_alert_condition" "synthetics_failing" {
  policy_id                    = newrelic_alert_policy.lighting.id
  name                         = "Synthetics check failing"
  description                  = "A New Relic Synthetics monitor failed from a public location: the portal or the resident report journey is broken from the outside."
  title_template               = "{{tags.monitorName}} is failing"
  type                         = "static"
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = 300
  aggregation_method           = "event_flow"
  aggregation_delay            = local.delay
  fill_option                  = "none"

  nrql {
    query = "SELECT count(*) FROM SyntheticCheck WHERE monitorName LIKE 'Larkspur Ridge%' AND result = 'FAILED' FACET monitorName"
  }
  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }
}

# =============================================================================
# Notifications: email destination, channel, and a workflow that sends every
# incident from this policy, including when it is acknowledged and closed.
# =============================================================================
resource "newrelic_notification_destination" "email" {
  name = "Smart Lighting SRE email"
  type = "EMAIL"
  property {
    key   = "email"
    value = var.alert_email
  }
  lifecycle {
    ignore_changes = [property]
  }
}

resource "newrelic_notification_channel" "email" {
  name           = "Smart Lighting SRE email"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.email.id
  product        = "IINT" # incident intelligence (workflows)
  property {
    key   = "subject"
    value = "[Larkspur Ridge] {{issueTitle}}"
  }
}

resource "newrelic_workflow" "email" {
  name                  = "Smart Lighting incidents to SRE email"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "Smart Lighting policy"
    type = "FILTER"
    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.lighting.id]
    }
  }

  destination {
    channel_id            = newrelic_notification_channel.email.id
    notification_triggers = ["ACTIVATED", "ACKNOWLEDGED", "CLOSED"]
  }
}
