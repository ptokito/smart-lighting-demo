# =============================================================================
# Synthetics: checks from outside, on a schedule, whether or not anyone is
# using the site.
#
#   1. Ping (simple) monitor: is the portal up? Every 5 minutes from two
#      US public locations.
# =============================================================================

resource "newrelic_synthetics_monitor" "portal_ping" {
  status           = "ENABLED"
  name             = "Larkspur Ridge portal availability"
  type             = "SIMPLE"
  uri              = "${var.portal_url}/healthz"
  period           = "EVERY_5_MINUTES"
  locations_public = ["AWS_US_EAST_1", "AWS_US_WEST_2"]

  treat_redirect_as_failure = true
  bypass_head_request       = true

  tag {
    key    = "program"
    values = ["smart-lighting"]
  }
}

