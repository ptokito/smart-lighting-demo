# =============================================================================
# Inputs for the AWS environment. Set them in terraform.tfvars (git-ignored),
# except the license key, which is passed as an environment variable:
#   export TF_VAR_newrelic_license_key='...'
# =============================================================================

variable "aws_region" {
  description = "AWS region for everything in this project."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. Kept project-specific to avoid colliding with resources from earlier labs (an IAM role name clash bit us last time)."
  type        = string
  default     = "smart-lighting"
}

variable "newrelic_license_key" {
  description = "New Relic INGEST - LICENSE key (40 characters, ends in NRAL). Stored in Parameter Store, never on disk in the repo."
  type        = string
  sensitive   = true

  # A malformed key pasted from the UI cost us an hour last time; fail fast.
  validation {
    condition     = length(var.newrelic_license_key) == 40
    error_message = "The New Relic license key must be exactly 40 characters. Copy the INGEST - LICENSE key, not a user key."
  }
}

variable "repo_url" {
  description = "HTTPS URL of the public GitHub repository the instances clone at boot."
  type        = string
  default     = "https://github.com/ptokito/smart-lighting-demo.git"
}

variable "repo_ref" {
  description = "Branch the instances check out at first boot."
  type        = string
  default     = "main"
}

variable "github_repository" {
  description = "owner/name of the GitHub repository allowed to deploy through the OIDC role."
  type        = string
  default     = "ptokito/smart-lighting-demo"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC identity provider. Set to false if your account already has one (for example from the k8s security lab); only one can exist per account."
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "Address range of the demo VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "allowed_http_cidrs" {
  description = "Who may reach the portal on port 80. Open to the internet by default because New Relic Synthetics checks from public locations."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "host_instance_type" {
  description = "Instance type for the host VM (PostgreSQL, Redis, NGINX, device-gateway)."
  type        = string
  default     = "t3.medium"
}

variable "k3s_instance_type" {
  description = "Instance type for the Kubernetes node. t3.large (8 GB) leaves room for image builds and the New Relic Kubernetes integration."
  type        = string
  default     = "t3.large"
}

variable "use_spot" {
  description = "Run both instances as Spot to cut cost by roughly 60 to 70 percent. Spot can be reclaimed by AWS, so leave false for the day of the presentation."
  type        = bool
  default     = false
}

variable "log_hot_retention_days" {
  description = "Days CloudWatch Logs keeps logs. Must be longer than export_age_hours, or logs could expire before the export reaches them. 3 is the smallest CloudWatch value that is safe for a 24-hour export."
  type        = number
  default     = 3
}

variable "export_age_hours" {
  description = "Logs are exported to S3 once they are this many hours old."
  type        = number
  default     = 24
}

variable "archive_retention_days" {
  description = "Days the S3 archive keeps exported logs before deleting them (records-retention policy for the demo)."
  type        = number
  default     = 365
}
