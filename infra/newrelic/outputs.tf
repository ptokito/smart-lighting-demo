output "dashboard_url" {
  description = "Open this to see the Larkspur Ridge dashboard."
  value       = newrelic_one_dashboard.lighting.permalink
}

output "alert_policy_id" {
  value = newrelic_alert_policy.lighting.id
}

output "light_response_sli_guid" {
  value = newrelic_service_level.light_response.sli_guid
}
