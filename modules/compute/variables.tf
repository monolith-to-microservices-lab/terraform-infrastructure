variable "name" {
  description = "Name prefix, e.g. mtm-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "public_subnet_ids" {
  description = "Subnets for the ALB."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets for Fargate tasks."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB security group."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "namespace_id" {
  description = "Cloud Map namespace for task discovery (Prometheus in phase 2)."
  type        = string
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS listeners. null = HTTP (lab without a domain)."
  type        = string
  default     = null
}

variable "internal_api_allowed_cidrs" {
  description = "Source CIDRs allowed to call /internal/* (migration-tool). Empty = always 403."
  type        = list(string)
  default     = []
}

variable "fargate_capacity_provider" {
  description = "FARGATE or FARGATE_SPOT for every workload in this module."
  type        = string
  default     = "FARGATE"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for IAM roles."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 7
}

variable "http_services" {
  description = "Stateless HTTP workloads behind the ALB."
  type = map(object({
    listener_port     = number
    container_port    = number
    image             = string
    command           = optional(list(string))
    cpu               = number
    memory            = number
    desired_count     = number
    security_group_id = string
    environment       = map(string)
    secrets           = map(object({ secret_arn = string, key = string }))
    autoscaling = optional(object({
      max_capacity    = number
      cpu_target      = optional(number)
      memory_target   = optional(number)
      requests_target = optional(number)
    }))
  }))
}

variable "workers" {
  description = "Non-HTTP workloads (CDC consumers)."
  type = map(object({
    image             = string
    command           = optional(list(string))
    cpu               = number
    memory            = number
    desired_count     = number
    security_group_id = string
    environment       = map(string)
    secrets           = map(object({ secret_arn = string, key = string }))
  }))
}
