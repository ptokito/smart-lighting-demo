# =============================================================================
# Terraform and provider versions for the AWS environment.
# =============================================================================
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource Terraform creates carries these tags, which makes cost
  # tracking and cleanup easy, and they show up on the entities New Relic's
  # AWS integration discovers.
  default_tags {
    tags = {
      Project     = "smart-lighting-demo"
      Environment = "demo"
      Owner       = "city-sre"
      ManagedBy   = "terraform"
    }
  }
}
