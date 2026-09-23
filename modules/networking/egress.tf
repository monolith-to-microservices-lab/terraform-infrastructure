# -----------------------------------------------------------------------------
# Private-subnet egress. See docs/adr/0006-network-egress.md.
#
#   nat_instance  ~ USD 4/month  (t4g.nano + 1 public IPv4) - lab default
#   nat_gateway   ~ USD 33/month + USD 0.045/GB processed  - prod-like
# -----------------------------------------------------------------------------

locals {
  use_nat_instance = var.egress_mode == "nat_instance"
  use_nat_gateway  = var.egress_mode == "nat_gateway"
}

# --- Option A: NAT Gateway ------------------------------------------------------
resource "aws_eip" "nat" {
  count = local.use_nat_gateway ? 1 : 0

  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count = local.use_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${var.name}-nat-gw" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route" "private_nat_gateway" {
  count = local.use_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# --- Option B: NAT instance -----------------------------------------------------
data "aws_ssm_parameter" "al2023_arm64" {
  count = local.use_nat_instance ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "nat" {
  count = local.use_nat_instance ? 1 : 0

  name        = "${var.name}-nat"
  description = "NAT instance: forwards traffic from private subnets only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-nat" }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_private" {
  for_each = local.use_nat_instance ? toset(local.private_cidrs) : toset([])

  security_group_id = aws_security_group.nat[0].id
  description       = "All traffic from private subnet ${each.value}"
  ip_protocol       = "-1"
  cidr_ipv4         = each.value
}

#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "nat_out" {
  count = local.use_nat_instance ? 1 : 0

  security_group_id = aws_security_group.nat[0].id
  description       = "Forward to the internet (the whole point of a NAT)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "nat_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nat" {
  count = local.use_nat_instance ? 1 : 0

  name                 = "${var.name}-nat-instance"
  assume_role_policy   = data.aws_iam_policy_document.nat_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

# SSM Session Manager instead of SSH: no key pair, no port 22.
resource "aws_iam_role_policy_attachment" "nat_ssm" {
  count = local.use_nat_instance ? 1 : 0

  role       = aws_iam_role.nat[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  count = local.use_nat_instance ? 1 : 0

  name = "${var.name}-nat-instance"
  role = aws_iam_role.nat[0].name
}

resource "aws_instance" "nat" {
  count = local.use_nat_instance ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64[0].insecure_value
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat[0].id]
  iam_instance_profile        = aws_iam_instance_profile.nat[0].name
  associate_public_ip_address = true
  source_dest_check           = false
  user_data_replace_on_change = true

  user_data = file("${path.module}/templates/nat-instance.sh")

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = { Name = "${var.name}-nat-instance" }

  lifecycle {
    # New AMI releases would otherwise replace the NAT on every plan. Patching
    # is an explicit decision: terraform apply -replace=...aws_instance.nat[0]
    ignore_changes = [ami]
  }
}

resource "aws_route" "private_nat_instance" {
  count = local.use_nat_instance ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat[0].primary_network_interface_id
}

# Auto-recover the NAT on host failure (keeps its ENI/private IP).
resource "aws_cloudwatch_metric_alarm" "nat_recover" {
  count = local.use_nat_instance ? 1 : 0

  alarm_name          = "${var.name}-nat-instance-system-check"
  alarm_description   = "Recover the NAT instance when the underlying host fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.nat[0].id }
  alarm_actions       = ["arn:aws:automate:${data.aws_region.current.region}:ec2:recover"]
}
