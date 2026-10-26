# =============================================================================
# New Relic configuration as code: AWS integration, service levels (SLOs),
# alerts and notifications, Synthetics monitors, and the dashboard.
#
# Apply this AFTER infra/aws is up and data has been flowing for about 10
# minutes: the service levels attach to APM entities that only exist once the
# agents have reported.
#
# Credentials, set as environment variables (never in files):
#   export NEW_RELIC_API_KEY='NRAK-...'   # a USER key, not the license key
#   AWS credentials from your usual profile (for the integration IAM role)
#
# Destroy this BEFORE infra/aws, so New Relic stops polling AWS before the
# role it uses disappears.
# =============================================================================
terraform {
  required_version = ">= 1.6"

  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.40"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "newrelic" {
  account_id = var.account_id
  region     = "US"
  # api_key is read from the NEW_RELIC_API_KEY environment variable.
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "smart-lighting-demo"
      ManagedBy = "terraform"
    }
  }
}
