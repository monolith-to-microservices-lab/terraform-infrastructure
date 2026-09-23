# Consumed by humans, by CI and later by the E2E suite:
#   terraform output -json > outputs.json

output "aws_region" {
  description = "Region of this environment."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.networking.vpc_id
}

output "subnet_ids" {
  description = "Subnets per tier."
  value = {
    public  = module.networking.public_subnet_ids
    private = module.networking.private_subnet_ids
    data    = module.networking.data_subnet_ids
  }
}

output "nat_public_ip" {
  description = "Egress IP of the private subnets."
  value       = module.networking.nat_public_ip
}

output "load_balancer_dns" {
  description = "Public ALB DNS name."
  value       = module.compute.alb_dns_name
}

output "service_endpoints" {
  description = "Base URL per HTTP service (monolith :80, user :8001, sales :8080)."
  value       = module.compute.endpoints
}

output "ecr_repository_urls" {
  description = "Where to push images."
  value       = module.registry.repository_urls
}

output "ecs_cluster_name" {
  description = "ECS cluster."
  value       = module.ecs_cluster.cluster_name
}

output "ecs_service_names" {
  description = "ECS service per workload."
  value = merge(module.compute.service_names, module.messaging.service_names, {
    otel-collector = module.observability.otel_collector_service_name
  })
}

output "log_groups" {
  description = "CloudWatch log group per application workload."
  value       = module.compute.log_groups
}

output "service_discovery_namespace" {
  description = "Private DNS suffix used inside the VPC."
  value       = module.ecs_cluster.namespace_name
}

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap (inside the VPC only)."
  value       = module.messaging.kafka_bootstrap_servers
}

output "kafka_connect_url" {
  description = "Kafka Connect REST (reach it through SSM port forwarding)."
  value       = module.messaging.connect_url
}

output "platform_host_instance_id" {
  description = "SSM target for port forwarding / sessions."
  value       = module.messaging.platform_host_instance_id
}

output "database_endpoints" {
  description = "Private endpoints of the databases."
  value = {
    legacy = { address = module.db_legacy.address, port = module.db_legacy.port, db_name = module.db_legacy.db_name }
    user   = { address = module.db_user.address, port = module.db_user.port, db_name = module.db_user.db_name }
    sales  = { address = module.db_sales.address, port = module.db_sales.port, db_name = module.db_sales.db_name }
  }
}

# ARNs are not secret, but they map the credential inventory of the account;
# marked sensitive so they are not echoed in CI logs.
output "secret_arns" {
  description = "Secrets Manager ARNs (values are never in state)."
  sensitive   = true
  value = {
    legacy_db       = module.db_legacy.secret_arn
    user_db         = module.db_user.secret_arn
    sales_db        = module.db_sales.secret_arn
    legacy_debezium = module.messaging.debezium_secret_arn
  }
}

output "alarm_topic_arn" {
  description = "SNS topic with every alarm."
  value       = module.observability.alarm_topic_arn
}

output "workload_desired_counts" {
  description = "Tasks each ECS service should run (0 while services_enabled = false)."
  value       = module.compute.desired_counts
}
