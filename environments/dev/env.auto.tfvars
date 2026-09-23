# -----------------------------------------------------------------------------
# dev desired state - VERSIONED. Change infrastructure by editing this file in a
# PR: CI shows the plan (e.g. desired_count 2 -> 3) before anything is applied.
#
# No secrets and nothing personal here. Personal/account-specific values
# (region, your IP) go in terraform.tfvars (git-ignored) or TF_VAR_* in CI.
# -----------------------------------------------------------------------------

environment = "dev"

# Workloads start with 0 tasks until images are pushed to ECR (docs/runbooks/first-deploy.md).
services_enabled          = false
fargate_capacity_provider = "FARGATE_SPOT"

image_tags = {
  "monolith-api"  = "0.1.0"
  "user-service"  = "0.1.0"
  "sales-service" = "0.1.0"
}

api_sizing = {
  "monolith-api"      = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
  "user-service-api"  = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
  "sales-service-api" = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
}

cdc_sizing = {
  "user-service-cdc"  = { desired_count = 1, cpu = 256, memory = 512 }
  "sales-service-cdc" = { desired_count = 1, cpu = 256, memory = 512 }
}

egress_mode              = "nat_instance"
db_instance_class        = "db.t4g.micro"
platform_instance_type   = "t3.medium"
kafka_default_partitions = 1
log_retention_days       = 7
container_insights       = "disabled"
enable_otel_collector    = true
