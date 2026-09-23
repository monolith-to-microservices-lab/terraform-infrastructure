# -----------------------------------------------------------------------------
# Network security: one security group per workload, least-privilege rules.
#
#   Internet (allowed CIDRs) -> ALB -> HTTP workloads :port
#   HTTP + worker workloads  -> platform host (OTLP)
#   worker workloads         -> platform host (Kafka)
#   workloads                -> PostgreSQL (enforced again by each DB's own SG)
#
# Nothing opens a database or Kafka to 0.0.0.0/0. The only 0.0.0.0/0 egress is
# HTTPS (ECR, Secrets Manager, CloudWatch, SSM through the NAT).
# -----------------------------------------------------------------------------

locals {
  all_workloads = setunion(keys(var.http_workloads), keys(var.worker_workloads))

  alb_ingress = {
    for pair in setproduct(var.alb_listener_ports, var.allowed_ingress_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  platform_otlp_ingress = {
    for pair in setproduct(local.all_workloads, var.otlp_ports) :
    "${pair[0]}-${pair[1]}" => { workload = pair[0], port = pair[1] }
  }

  workload_otlp_egress = local.platform_otlp_ingress
}

# --- ALB ------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB: listener ports from allowed CIDRs only"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_listeners" {
  for_each = local.alb_ingress

  security_group_id = aws_security_group.alb.id
  description       = "Listener ${each.value.port} from ${each.value.cidr}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_to_http" {
  for_each = var.http_workloads

  security_group_id            = aws_security_group.alb.id
  description                  = "To ${each.key} targets"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.workload[each.key].id
}

# --- Workloads ------------------------------------------------------------------
resource "aws_security_group" "workload" {
  for_each = local.all_workloads

  name        = "${var.name}-${each.key}"
  description = "Workload ${each.key}"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-${each.key}" }
}

resource "aws_vpc_security_group_ingress_rule" "http_from_alb" {
  for_each = var.http_workloads

  security_group_id            = aws_security_group.workload[each.key].id
  description                  = "HTTP from ALB"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.alb.id
}

# Prepared for self-hosted Prometheus on the platform host (phase 2).
resource "aws_vpc_security_group_ingress_rule" "http_metrics_from_platform" {
  for_each = var.http_workloads

  security_group_id            = aws_security_group.workload[each.key].id
  description                  = "Prometheus scrape of /metrics from platform host"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.platform.id
}

resource "aws_vpc_security_group_ingress_rule" "worker_metrics_from_platform" {
  for_each = var.worker_workloads

  security_group_id            = aws_security_group.workload[each.key].id
  description                  = "Prometheus scrape of CDC metrics from platform host"
  ip_protocol                  = "tcp"
  from_port                    = each.value.metrics_port
  to_port                      = each.value.metrics_port
  referenced_security_group_id = aws_security_group.platform.id
}

# Accepted (docs/security-scan.md): AWS public endpoints have no stable CIDR;
# the alternative is ~USD 7/month per interface endpoint per AZ.
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "workload_https" {
  for_each = local.all_workloads

  security_group_id = aws_security_group.workload[each.key].id
  description       = "HTTPS to AWS APIs (ECR, Secrets Manager, CloudWatch, SSM) via NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "workload_postgres" {
  for_each = local.all_workloads

  security_group_id = aws_security_group.workload[each.key].id
  description       = "PostgreSQL inside the VPC (each DB SG decides who is allowed)"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "workload_otlp" {
  for_each = local.workload_otlp_egress

  security_group_id            = aws_security_group.workload[each.value.workload].id
  description                  = "OTLP ${each.value.port} to OTel Collector"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.platform.id
}

resource "aws_vpc_security_group_egress_rule" "worker_kafka" {
  for_each = var.worker_workloads

  security_group_id            = aws_security_group.workload[each.key].id
  description                  = "Kafka on platform host"
  ip_protocol                  = "tcp"
  from_port                    = var.kafka_port
  to_port                      = var.kafka_port
  referenced_security_group_id = aws_security_group.platform.id
}

# --- Platform host (Kafka, Kafka Connect/Debezium, OTel Collector) --------------
resource "aws_security_group" "platform" {
  name        = "${var.name}-platform"
  description = "Platform host: Kafka, Kafka Connect, OTel Collector"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-platform" }
}

resource "aws_vpc_security_group_ingress_rule" "platform_kafka" {
  for_each = var.worker_workloads

  security_group_id            = aws_security_group.platform.id
  description                  = "Kafka from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = var.kafka_port
  to_port                      = var.kafka_port
  referenced_security_group_id = aws_security_group.workload[each.key].id
}

resource "aws_vpc_security_group_ingress_rule" "platform_otlp" {
  for_each = local.platform_otlp_ingress

  security_group_id            = aws_security_group.platform.id
  description                  = "OTLP ${each.value.port} from ${each.value.workload}"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.workload[each.value.workload].id
}

#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "platform_https" {
  security_group_id = aws_security_group.platform.id
  description       = "HTTPS: image pulls, ECS agent, SSM, CloudWatch, X-Ray"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "platform_postgres" {
  security_group_id = aws_security_group.platform.id
  description       = "Debezium to legacy PostgreSQL (legacy DB SG enforces it)"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "platform_scrape" {
  for_each = merge(
    { for k, v in var.http_workloads : k => v.port },
    { for k, v in var.worker_workloads : k => v.metrics_port },
  )

  security_group_id            = aws_security_group.platform.id
  description                  = "Metrics scrape of ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.workload[each.key].id
}
