# -----------------------------------------------------------------------------
# Phase 1 observability on AWS (docs/adr/0004-observability-strategy.md):
#   * container logs      -> CloudWatch Logs (log groups live with each service)
#   * AWS infra metrics   -> CloudWatch (ALB, RDS, EC2) + alarms below
#   * traces              -> OTel Collector on the platform host -> AWS X-Ray
# The apps keep exporting plain OTLP; swapping X-Ray for self-hosted Tempo in
# phase 2 is a collector config change, not an application change.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  otel_config = yamlencode({
    receivers = {
      otlp = {
        protocols = {
          grpc = { endpoint = "0.0.0.0:4317" }
          http = { endpoint = "0.0.0.0:4318" }
        }
      }
    }
    processors = {
      batch = { timeout = "2s" }
      resource = {
        attributes = [
          { key = "lab", value = "migration-lab", action = "upsert" },
          { key = "deployment.environment", value = var.environment, action = "upsert" },
        ]
      }
    }
    exporters = {
      awsxray = { region = data.aws_region.current.region }
      debug   = { verbosity = "basic" }
    }
    extensions = {
      health_check = { endpoint = "0.0.0.0:13133" }
    }
    service = {
      extensions = ["health_check"]
      telemetry  = { metrics = { address = "0.0.0.0:8888" } }
      pipelines = {
        traces = {
          receivers  = ["otlp"]
          processors = ["resource", "batch"]
          exporters  = ["awsxray", "debug"]
        }
      }
    }
  })
}

data "aws_iam_policy_document" "otel" {
  statement {
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

module "otel_collector" {
  source = "../ecs-service"
  count  = var.enable_otel_collector ? 1 : 0

  name                     = "${var.name}-otel-collector"
  container_name           = "otel-collector"
  cluster_arn              = var.cluster_arn
  launch                   = "ec2_host"
  image                    = var.otel_collector_image
  command                  = ["--config=env:OTEL_COLLECTOR_CONFIG"]
  memory                   = 512
  memory_reservation       = 256
  desired_count            = 1
  port_mappings            = [4317, 4318, 13133]
  placement_attribute      = var.placement_attribute
  enable_execute_command   = false # distroless image: nothing to exec into
  task_role_policy_json    = data.aws_iam_policy_document.otel.json
  permissions_boundary_arn = var.permissions_boundary_arn
  log_retention_days       = var.log_retention_days

  environment = {
    OTEL_COLLECTOR_CONFIG = local.otel_config
  }
}

# --- Alerting -----------------------------------------------------------------------
# Not encrypted with alias/aws/sns on purpose: CloudWatch alarms cannot publish
# to a topic encrypted with the AWS-managed key (its key policy cannot grant
# cloudwatch.amazonaws.com). Alarm payloads are not sensitive; a CMK would cost
# USD 1/month. Accepted in docs/security-scan.md.
#trivy:ignore:AWS-0095
#trivy:ignore:AWS-0136
resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "ALB returned 5xx (no healthy target or target error)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  for_each = var.target_group_arn_suffixes

  alarm_name          = "${var.name}-${each.key}-unhealthy"
  alarm_description   = "${each.key}: at least one target failing /health."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = var.alb_arn_suffix, TargetGroup = each.value }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_free_storage" {
  for_each = var.databases

  alarm_name          = "${var.name}-${each.key}-free-storage"
  alarm_description   = "${each.key}: low free storage."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = each.value }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.free_storage_alarm_bytes
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# The CDC-specific failure mode: Debezium stops consuming, the slot pins WAL
# and the legacy database disk fills up. Same signal as the local
# cdc-debezium-wal Grafana dashboard.
resource "aws_cloudwatch_metric_alarm" "replication_slot_lag" {
  alarm_name          = "${var.name}-${var.cdc_source_database}-replication-slot-lag"
  alarm_description   = "Debezium replication slot is retaining too much WAL (connector stopped or slow)."
  namespace           = "AWS/RDS"
  metric_name         = "OldestReplicationSlotLag"
  dimensions          = { DBInstanceIdentifier = var.databases[var.cdc_source_database] }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.replication_slot_lag_alarm_bytes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
