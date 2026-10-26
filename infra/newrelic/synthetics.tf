# =============================================================================
# Synthetics: checks from outside, on a schedule, whether or not anyone is
# using the site.
#
# Ping (simple) monitor: is the portal up? Every 5 minutes from two US public
# locations. Ping checks are free on every New Relic plan.
#
# A scripted browser monitor (a real Chrome walking the resident outage report
# form) was planned too, but this account's plan refuses scripted monitors
# (PAYMENT_REQUIRED). On a paid plan it would sit here as a
# newrelic_synthetics_script_monitor resource.
# =============================================================================

resource "newrelic_synthetics_monitor" "portal_ping" {
  status           = "ENABLED"
  name             = "Larkspur Ridge portal availability"
  type             = "SIMPLE"
  uri              = "${var.portal_url}/healthz"
  period           = "EVERY_5_MINUTES"
  locations_public = ["US_EAST_1", "US_WEST_2"]

  treat_redirect_as_failure = true
  bypass_head_request       = true

  tag {
    key    = "program"
    values = ["smart-lighting"]
  }
}
