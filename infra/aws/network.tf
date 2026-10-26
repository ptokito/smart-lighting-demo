# =============================================================================
# Network: a small dedicated VPC with one public subnet.
#
# A dedicated VPC (rather than the account's default VPC) means the private IP
# addresses are known in advance, so each instance can be told the other's
# address at boot without a chicken-and-egg dependency:
#   host VM    10.42.1.10
#   k3s node   10.42.1.20
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# Instances get public IPs so they can download packages and reach New Relic
# without a NAT gateway (which would cost about $1 a day). Inbound access is
# still locked down by the security groups below; there is no SSH at all.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # 10.42.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public" }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

locals {
  host_private_ip = cidrhost(aws_subnet.public.cidr_block, 10)
  k3s_private_ip  = cidrhost(aws_subnet.public.cidr_block, 20)
}

# -----------------------------------------------------------------------------
# Security groups
# -----------------------------------------------------------------------------

# Host VM: port 80 for the public site; database, cache and gateway ports only
# from the k3s node.
resource "aws_security_group" "host" {
  name        = "${var.name_prefix}-host"
  description = "Host VM: public HTTP, internal PostgreSQL, Redis and device-gateway"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "host_http_public" {
  for_each          = toset(var.allowed_http_cidrs)
  security_group_id = aws_security_group.host.id
  description       = "Portal over HTTP (users and New Relic Synthetics)"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# The simulator on k3s reaches the portal through NGINX, even if the public
# rule above is tightened later.
resource "aws_vpc_security_group_ingress_rule" "host_from_k3s" {
  for_each = {
    http     = 80
    postgres = 5432
    redis    = 6379
    gateway  = 8081
  }
  security_group_id            = aws_security_group.host.id
  description                  = "${each.key} from the k3s node"
  referenced_security_group_id = aws_security_group.k3s.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "host_all" {
  security_group_id = aws_security_group.host.id
  description       = "Outbound for packages, New Relic and AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# k3s node: only NGINX on the host VM may reach the portal NodePort.
resource "aws_security_group" "k3s" {
  name        = "${var.name_prefix}-k3s"
  description = "k3s node: portal NodePort from the host VM only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.name_prefix}-k3s" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_portal_from_host" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Portal NodePort from NGINX on the host VM"
  referenced_security_group_id = aws_security_group.host.id
  from_port                    = 30080
  to_port                      = 30080
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_all" {
  security_group_id = aws_security_group.k3s.id
  description       = "Outbound for packages, New Relic, AWS APIs and the host VM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
