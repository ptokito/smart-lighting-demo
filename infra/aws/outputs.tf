# =============================================================================
# Values printed after `terraform apply`. Scripts in /scripts read these with
# `terraform output -raw <name>`, and the GitHub setup step copies three of
# them into repository variables.
# =============================================================================

output "aws_region" {
  value = var.aws_region
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "portal_url" {
  description = "Public URL of the portal (through NGINX on the host VM)."
  value       = "http://${aws_instance.host.public_ip}"
}

output "host_instance_id" {
  value = aws_instance.host.id
}

output "k3s_instance_id" {
  value = aws_instance.k3s.id
}

output "connect_host" {
  description = "Open a shell on the host VM through Session Manager (no SSH)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.host.id}"
}

output "connect_k3s" {
  description = "Open a shell on the k3s node through Session Manager."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.k3s.id}"
}

output "log_group" {
  value = aws_cloudwatch_log_group.app_logs.name
}

output "log_archive_bucket" {
  value = aws_s3_bucket.log_archive.bucket
}

output "export_lambda_name" {
  value = aws_lambda_function.export_logs.function_name
}

output "github_deploy_role_arn" {
  description = "Put this in the GitHub repository variable AWS_DEPLOY_ROLE_ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "k8s_cluster_name" {
  value = local.cluster_name
}
