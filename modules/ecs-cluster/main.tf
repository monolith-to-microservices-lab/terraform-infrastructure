variable "name" {
  description = "Cluster name, e.g. mtm-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC for the private DNS namespace."
  type        = string
}

variable "namespace" {
  description = "Private DNS namespace for service discovery, e.g. mtm-dev.internal."
  type        = string
}

variable "container_insights" {
  description = "CloudWatch Container Insights (extra per-metric cost). disabled | enabled | enhanced."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be disabled, enabled or enhanced."
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.namespace
  description = "Service discovery for ${var.name}"
  vpc         = var.vpc_id
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "namespace_id" {
  description = "Cloud Map namespace ID."
  value       = aws_service_discovery_private_dns_namespace.this.id
}

output "namespace_name" {
  description = "Cloud Map namespace (DNS suffix)."
  value       = aws_service_discovery_private_dns_namespace.this.name
}
