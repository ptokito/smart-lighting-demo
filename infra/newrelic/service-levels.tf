# =============================================================================
# Service levels: the SLIs (what we measure) and SLOs (the target).
#
# Each one is "good events / valid events" over a rolling 7-day window.
# New Relic turns them into newrelic.sli.* metrics, which the dashboard and the
# burn-rate alert in alerts.tf query.
# =============================================================================

# 1. The business promise: a light responds to a command within 2 seconds.
#    This is the SLO the city's operations manager cares about.
resource "newrelic_service_level" "light_response" {
  guid        = data.newrelic_entity.device_gateway.guid
  name        = "Light commands acknowledged within 2 seconds"
  description = "Share of streetlight and signal commands that the device acknowledges within 2,000 ms."

  events {
    account_id = var.account_id
    valid_events {
      from  = "LightCommand"
      where = "deviceId IS NOT NULL"
    }
    good_events {
      from  = "LightCommand"
      where = "ackMs <= 2000"
    }
  }

  objective {
    target = 99.0
    time_window {
      rolling {
        count = 7
        unit  = "DAY"
      }
    }
  }
}

# 2. API availability: requests that did not end in an error.
resource "newrelic_service_level" "api_availability" {
  guid        = data.newrelic_entity.lighting_api.guid
  name        = "Lighting API availability"
  description = "Share of lighting-api web requests that completed without an error."

  events {
    account_id = var.account_id
    valid_events {
      from  = "Transaction"
      where = "appName = 'lighting-api' AND transactionType = 'Web'"
    }
    bad_events {
      from  = "TransactionError"
      where = "appName = 'lighting-api' AND error.expected IS NOT true"
    }
  }

  objective {
    target = 99.5
    time_window {
      rolling {
        count = 7
        unit  = "DAY"
      }
    }
  }
}

# 3. API latency: requests answered in under half a second. Command requests
#    are excluded because their duration is dominated by the field network,
#    which SLO 1 already covers.
resource "newrelic_service_level" "api_latency" {
  guid        = data.newrelic_entity.lighting_api.guid
  name        = "Lighting API latency under 500 ms"
  description = "Share of non-command lighting-api web requests answered in under 500 ms."

  events {
    account_id = var.account_id
    valid_events {
      from  = "Transaction"
      where = "appName = 'lighting-api' AND transactionType = 'Web' AND name NOT LIKE '%send_command%'"
    }
    good_events {
      from  = "Transaction"
      where = "appName = 'lighting-api' AND transactionType = 'Web' AND name NOT LIKE '%send_command%' AND duration < 0.5"
    }
  }

  objective {
    target = 95.0
    time_window {
      rolling {
        count = 7
        unit  = "DAY"
      }
    }
  }
}
