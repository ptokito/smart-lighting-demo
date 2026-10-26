# =============================================================================
# New Relic AWS integration (API polling).
#
# New Relic's AWS account assumes a read-only IAM role in your account and
# pulls CloudWatch metrics and inventory for the services enabled below. This
# is how New Relic sees AWS-managed pieces no agent can run on: the S3 log
# archive, the export Lambda, EBS volumes, and EC2 instance status.
#
# The role name is project-specific: last time a generic name collided with a
# role that already existed in the account.
# =============================================================================

resource "aws_iam_role" "newrelic_integration" {
  name = "${var.name_prefix}-newrelic-integration"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # New Relic's own AWS account, which performs the polling.
      Principal = { AWS = "arn:aws:iam::754728514883:root" }
      Action    = "sts:AssumeRole"
      # The external ID (your New Relic account ID) stops any other New Relic
      # customer from using this role (the "confused deputy" protection).
      Condition = { StringEquals = { "sts:ExternalId" = tostring(var.account_id) } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "newrelic_read_only" {
  role       = aws_iam_role.newrelic_integration.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "newrelic_cloud_aws_link_account" "this" {
  account_id             = var.account_id
  name                   = "smart-lighting-demo"
  arn                    = aws_iam_role.newrelic_integration.arn
  metric_collection_mode = "PULL"
  # IAM changes take a few seconds to propagate before New Relic can assume the role.
  depends_on = [aws_iam_role_policy_attachment.newrelic_read_only]
}

resource "newrelic_cloud_aws_integrations" "this" {
  account_id        = var.account_id
  linked_account_id = newrelic_cloud_aws_link_account.this.id

  # EC2: instance status, CPU credits, network, as seen by AWS (complements
  # the infrastructure agent's view from inside the instance).
  ec2 {
    aws_regions              = [var.aws_region]
    metrics_polling_interval = 300
    fetch_ip_addresses       = true
  }

  # EBS: disk throughput and queue length for both root volumes.
  ebs {
    aws_regions              = [var.aws_region]
    metrics_polling_interval = 900
  }

  # S3: size and object count of the log archive bucket.
  s3 {
    metrics_polling_interval = 3600
    fetch_tags               = true
  }

  # Lambda: invocations, errors and duration of the hourly log export.
  lambda {
    aws_regions              = [var.aws_region]
    metrics_polling_interval = 300
    fetch_tags               = true
  }
}
