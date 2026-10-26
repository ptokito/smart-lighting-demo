# Inputs for the New Relic configuration. Set them in terraform.tfvars.

variable "account_id" {
  description = "New Relic account ID (the clean demo account)."
  type        = number
  default     = 8656494
}

variable "alert_email" {
  description = "Email address that receives alert notifications."
  type        = string
}

variable "aws_region" {
  description = "Region of the AWS environment (must match infra/aws)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for AWS resource names (must match infra/aws)."
  type        = string
  default     = "smart-lighting"
}

variable "portal_url" {
  description = "Public portal URL: the portal_url output of infra/aws, e.g. http://203.0.113.10"
  type        = string
}

variable "k8s_cluster_name" {
  description = "Cluster name given to the New Relic Kubernetes integration (k8s_cluster_name output of infra/aws)."
  type        = string
  default     = "smart-lighting-k3s"
}
