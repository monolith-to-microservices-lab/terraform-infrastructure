locals {
  # Naming convention (docs/naming.md): <prefix>-<env>-<component>, e.g. mtm-dev-legacy-pg
  name      = "${var.name_prefix}-${var.environment}"
  namespace = "${local.name}.internal"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "monolith-to-microservices-lab/terraform-infrastructure"
    Stack       = "environments/${var.environment}"
    CostCenter  = "lab"
  }

  platform_attribute = { name = "${var.name_prefix}.role", value = "platform" }

  otlp_endpoint = "http://otel-collector.${local.namespace}:4317"

  images = {
    for repo, tag in var.image_tags : repo => "${module.registry.repository_urls[repo]}:${tag}"
  }

  # Workload inventory (docs/current-state.md). Ports are the containers' own.
  http_workloads = {
    "monolith-api"      = { port = 8000, listener_port = 80 }
    "user-service-api"  = { port = 8000, listener_port = 8001 }
    "sales-service-api" = { port = 8000, listener_port = 8080 }
  }

  worker_workloads = {
    "user-service-cdc"  = { metrics_port = 9200 }
    "sales-service-cdc" = { metrics_port = 9201 }
  }

  desired = {
    for k, v in merge(var.api_sizing, var.cdc_sizing) :
    k => var.services_enabled ? v.desired_count : 0
  }
}
