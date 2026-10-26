# =============================================================================
# Synthetics: checks from outside, on a schedule, whether or not anyone is
# using the site.
#
#   1. Ping (simple) monitor: is the portal up? Every 5 minutes from two
#      US public locations.
#   2. Scripted browser monitor: can a resident actually report an outage?
#      Every 10 minutes, a real Chrome browser fills in and submits the form.
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

resource "newrelic_synthetics_script_monitor" "report_journey" {
  status           = "ENABLED"
  name             = "Larkspur Ridge resident outage report journey"
  type             = "SCRIPT_BROWSER"
  period           = "EVERY_10_MINUTES"
  locations_public = ["AWS_US_EAST_1", "AWS_US_WEST_2"]

  script               = templatefile("${path.module}/synthetics/report-journey.js", { portal_url = var.portal_url })
  script_language      = "JAVASCRIPT"
  runtime_type         = "CHROME_BROWSER"
  runtime_type_version = "100"

  enable_screenshot_on_failure_and_script = true

  tag {
    key    = "program"
    values = ["smart-lighting"]
  }
}
