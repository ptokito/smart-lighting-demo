# =============================================================================
# The two EC2 instances: the host VM and the k3s Kubernetes node.
#
# Both run Ubuntu 24.04 and are configured entirely by their boot scripts
# (EC2 user data), which clone this repository and run
# scripts/host-bootstrap.sh or scripts/k3s-bootstrap.sh. Total time from
# `terraform apply` to a working site is about 10 to 15 minutes.
# =============================================================================

# Latest official Ubuntu 24.04 LTS image published by Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

locals {
  cluster_name = "${var.name_prefix}-k3s"

  # Settings both boot scripts need; written to /etc/smart-lighting/bootstrap.env.
  common_env = {
    aws_region   = var.aws_region
    param_prefix = local.param_prefix
    log_group    = aws_cloudwatch_log_group.app_logs.name
    repo_url     = var.repo_url
    repo_ref     = var.repo_ref
  }
}

resource "aws_instance" "host" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.host_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.host_private_ip
  vpc_security_group_ids = [aws_security_group.host.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  user_data = templatefile("${path.module}/templates/host-user-data.sh", merge(local.common_env, {
    k3s_ip   = local.k3s_private_ip
    vpc_cidr = var.vpc_cidr
  }))
  # Changing the boot script rebuilds the instance, so the script always matches.
  user_data_replace_on_change = true

  # Require IMDSv2 (session tokens for the instance metadata service), an AWS
  # security best practice that blocks a class of SSRF credential theft.
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
    }
  }

  # The parameters must exist before the boot script tries to read them.
  depends_on = [
    aws_ssm_parameter.newrelic_license_key,
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.redis_password,
    aws_ssm_parameter.newrelic_db_password,
    aws_route_table_association.public,
  ]

  tags = { Name = "lighting-host", Role = "host-vm" }
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k3s_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.k3s_private_ip
  vpc_security_group_ids = [aws_security_group.k3s.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  user_data = templatefile("${path.module}/templates/k3s-user-data.sh", merge(local.common_env, {
    host_ip      = local.host_private_ip
    cluster_name = local.cluster_name
  }))
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
    }
  }

  depends_on = [
    aws_ssm_parameter.newrelic_license_key,
    aws_ssm_parameter.db_password,
    aws_ssm_parameter.redis_password,
    aws_route_table_association.public,
  ]

  tags = { Name = "lighting-k3s", Role = "kubernetes-node" }
}
