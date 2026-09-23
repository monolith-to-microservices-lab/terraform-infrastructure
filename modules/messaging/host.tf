# -----------------------------------------------------------------------------
# Platform host: one ECS container instance for stateful/JVM workloads that do
# not fit Fargate (Kafka needs a persistent disk that survives task restarts).
# See docs/adr/0001-compute-platform.md and 0002-kafka-platform.md.
# -----------------------------------------------------------------------------

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_subnet" "host" {
  id = var.subnet_id
}

data "aws_region" "current" {}

# Kafka data lives here, NOT on the instance: the instance can be replaced
# (new AMI, new user_data) without losing topics, offsets or Connect state.
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.host.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = { Name = "${var.name}-platform-data" }

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name                 = "${var.name}-platform-host"
  description          = "ECS agent + SSM on the platform host"
  assume_role_policy   = data.aws_iam_policy_document.ec2_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "host_ecs" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.name}-platform-host"
  role = aws_iam_role.host.name
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.ecs_ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = false
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/platform-host.sh.tftpl", {
    cluster_name    = var.cluster_name
    attribute_name  = var.placement_attribute.name
    attribute_value = var.placement_attribute.value
    volume_id       = replace(aws_ebs_volume.data.id, "-", "")
  })

  # Avoid surprise T3 "unlimited" CPU credit charges in a lab.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "${var.name}-platform-host" }

  lifecycle {
    # AMI updates are applied deliberately with -replace, not on every plan.
    ignore_changes = [ami]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id
}

# --- Stable DNS names for everything the host serves ------------------------------
resource "aws_service_discovery_service" "host" {
  for_each = toset(concat(["kafka", "connect"], var.extra_dns_names))

  name = each.key

  dns_config {
    namespace_id   = var.namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

resource "aws_service_discovery_instance" "host" {
  for_each = aws_service_discovery_service.host

  instance_id = "platform-host"
  service_id  = each.value.id

  attributes = {
    AWS_INSTANCE_IPV4 = aws_instance.host.private_ip
  }
}

# Recover on hardware failure: same instance id, private IP and EBS volumes.
resource "aws_cloudwatch_metric_alarm" "host_recover" {
  alarm_name          = "${var.name}-platform-host-system-check"
  alarm_description   = "Recover the platform host (Kafka/Connect) when the underlying hardware fails."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.host.id }
  alarm_actions       = compact(["arn:aws:automate:${data.aws_region.current.region}:ec2:recover", var.alarm_topic_arn])
}
