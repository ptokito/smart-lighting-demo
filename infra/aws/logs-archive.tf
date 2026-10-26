# =============================================================================
# Log pipeline: CloudWatch Logs (hot, 3 days) -> S3 archive (after 24 hours).
#
#   1. The CloudWatch agent on both instances ships every application, NGINX,
#      PostgreSQL and pod log line to one CloudWatch log group.
#   2. Every hour, an AWS Lambda function exports the hour of logs that has
#      just turned 24 hours old to a dedicated S3 bucket.
#   3. The bucket is encrypted, private, and has a lifecycle rule: after 30
#      days objects move to a cheaper storage class, after a year they are
#      deleted.
#
# The same logs also go to New Relic in real time (by the APM agents,
# OpenTelemetry and the infrastructure agent), so troubleshooting happens in
# New Relic and long-term retention happens in S3.
# =============================================================================

# ---- 1. Hot storage in CloudWatch -------------------------------------------
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/${var.name_prefix}/demo/app-logs"
  retention_in_days = var.log_hot_retention_days
}

# ---- 3. The archive bucket --------------------------------------------------
# A random suffix makes the name globally unique (S3 names are shared across
# all AWS customers).
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "log_archive" {
  bucket = "${var.name_prefix}-log-archive-${random_id.bucket_suffix.hex}"
  # Lets `terraform destroy` delete the bucket even when it holds exports.
  # Fine for a demo; a customer would leave this false to protect records.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "log_archive" {
  bucket                  = aws_s3_bucket.log_archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Server-side encryption with S3-managed keys. CloudWatch export supports this
# without extra key policy work.
resource "aws_s3_bucket_server_side_encryption_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  rule {
    id     = "archive-then-expire"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "GLACIER_IR" # Glacier Instant Retrieval: cheap, still readable in milliseconds
    }
    expiration {
      days = var.archive_retention_days
    }
  }
}

# The CloudWatch Logs service writes the export files, so the bucket policy
# must allow it, but only for log groups in this account and region.
resource "aws_s3_bucket_policy" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchLogsAclCheck"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.log_archive.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*" }
        }
      },
      {
        Sid       = "AllowCloudWatchLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.log_archive.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*" }
        }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.log_archive]
}

# ---- 2. The hourly export function ------------------------------------------
data "archive_file" "export_logs" {
  type        = "zip"
  source_file = "${path.module}/lambda/export_logs.py"
  output_path = "${path.module}/.build/export_logs.zip"
}

resource "aws_iam_role" "export_logs" {
  name = "${var.name_prefix}-export-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets the function write its own logs to CloudWatch.
resource "aws_iam_role_policy_attachment" "export_logs_basic" {
  role       = aws_iam_role.export_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "export_logs" {
  name = "create-export-tasks"
  role = aws_iam_role.export_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateExportTask", "logs:DescribeExportTasks"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [aws_s3_bucket.log_archive.arn, "${aws_s3_bucket.log_archive.arn}/*"]
      },
    ]
  })
}

# Its own log group with a short retention, created before the function so
# Lambda does not create one with "never expire".
resource "aws_cloudwatch_log_group" "export_logs_fn" {
  name              = "/aws/lambda/${var.name_prefix}-export-logs"
  retention_in_days = 7
}

resource "aws_lambda_function" "export_logs" {
  function_name    = "${var.name_prefix}-export-logs"
  description      = "Exports each hour of smart-lighting logs to S3 once it is ${var.export_age_hours} hours old"
  role             = aws_iam_role.export_logs.arn
  runtime          = "python3.12"
  handler          = "export_logs.handler"
  filename         = data.archive_file.export_logs.output_path
  source_code_hash = data.archive_file.export_logs.output_base64sha256
  timeout          = 300 # up to 5 minutes: retries plus waiting for the export

  environment {
    variables = {
      LOG_GROUP        = aws_cloudwatch_log_group.app_logs.name
      BUCKET           = aws_s3_bucket.log_archive.bucket
      PREFIX           = "cloudwatch-exports"
      EXPORT_AGE_HOURS = tostring(var.export_age_hours)
    }
  }

  depends_on = [aws_cloudwatch_log_group.export_logs_fn, aws_iam_role_policy_attachment.export_logs_basic]
}

# Run at five minutes past every hour.
resource "aws_cloudwatch_event_rule" "hourly_export" {
  name                = "${var.name_prefix}-hourly-log-export"
  description         = "Export logs older than ${var.export_age_hours} hours to S3"
  schedule_expression = "cron(5 * * * ? *)"
}

resource "aws_cloudwatch_event_target" "hourly_export" {
  rule = aws_cloudwatch_event_rule.hourly_export.name
  arn  = aws_lambda_function.export_logs.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.export_logs.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hourly_export.arn
}
