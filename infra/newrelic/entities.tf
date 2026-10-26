# =============================================================================
# Look up the entities the agents created, so service levels can attach to
# them. If `terraform plan` fails here with "no entities found", the agents
# have not reported yet: wait a few minutes after the AWS build and retry.
# =============================================================================

data "newrelic_entity" "lighting_api" {
  name   = "lighting-api"
  domain = "APM"
  type   = "APPLICATION"
}

data "newrelic_entity" "device_gateway" {
  name   = "lighting-device-gateway"
  domain = "APM"
  type   = "APPLICATION"
}
