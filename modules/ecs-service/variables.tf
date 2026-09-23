variable "name" {
  description = "Full service name, e.g. mtm-dev-user-service-api."
  type        = string
}

variable "container_name" {
  description = "Container name inside the task (short workload name)."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "launch" {
  description = "fargate (awsvpc, serverless) or ec2_host (host network on the platform host)."
  type        = string
  default     = "fargate"

  validation {
    condition     = contains(["fargate", "ec2_host"], var.launch)
    error_message = "launch must be fargate or ec2_host."
  }
}

variable "fargate_capacity_provider" {
  description = "FARGATE or FARGATE_SPOT (Spot is ~70% cheaper and may be interrupted)."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.fargate_capacity_provider)
    error_message = "fargate_capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "subnet_ids" {
  description = "Subnets for awsvpc tasks (ignored for ec2_host)."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "Security groups for awsvpc tasks (ignored for ec2_host: the host SG applies)."
  type        = list(string)
  default     = []
}

variable "image" {
  description = "Container image reference."
  type        = string
}

variable "command" {
  description = "Override of the image CMD (null keeps the image default)."
  type        = list(string)
  default     = null
}

variable "cpu" {
  description = "Task CPU units (Fargate valid combinations apply)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Task memory (MiB). For ec2_host this is the hard container limit."
  type        = number
  default     = 512
}

variable "memory_reservation" {
  description = "Soft memory reservation (MiB) used for ec2_host placement."
  type        = number
  default     = null
}

variable "desired_count" {
  description = "Number of tasks."
  type        = number

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count cannot be negative."
  }
}

variable "port_mappings" {
  description = "Container ports to expose."
  type        = list(number)
  default     = []
}

variable "environment" {
  description = "Plain environment variables (no secrets!)."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Env vars injected from Secrets Manager JSON keys: VAR => { secret_arn, key }."
  type        = map(object({ secret_arn = string, key = string }))
  default     = {}
}

variable "health_check_command" {
  description = "Container health check command (CMD-SHELL string), or null."
  type        = string
  default     = null
}

variable "health_check_start_period" {
  description = "Grace period before failed health checks count (seconds)."
  type        = number
  default     = 30
}

variable "stop_timeout" {
  description = "Seconds between SIGTERM and SIGKILL (graceful shutdown)."
  type        = number
  default     = 30
}

variable "mount_points" {
  description = "Host bind mounts for ec2_host: container_path => host_path."
  type        = map(string)
  default     = {}
}

variable "ulimits_nofile" {
  description = "nofile ulimit (Kafka needs a high value)."
  type        = number
  default     = null
}

variable "placement_attribute" {
  description = "For ec2_host: ECS instance attribute (name=value) that pins the task to the platform host."
  type        = object({ name = string, value = string })
  default     = null
}

variable "target_group_arn" {
  description = "ALB target group to register tasks in (used when target_port is set)."
  type        = string
  default     = null
}

variable "target_port" {
  description = "Container port registered in the target group."
  type        = number
  default     = null
}

variable "health_check_grace_period" {
  description = "Seconds ECS ignores ALB health checks after a task starts."
  type        = number
  default     = 60
}

variable "enable_service_discovery" {
  description = "Register the tasks in Cloud Map (awsvpc only). A flag, because the namespace id is unknown at plan time."
  type        = bool
  default     = false
}

variable "service_discovery_namespace_id" {
  description = "Cloud Map namespace to register an A record in (awsvpc only)."
  type        = string
  default     = null
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` into containers (debugging)."
  type        = bool
  default     = true
}

variable "task_role_policy_json" {
  description = "Extra IAM policy for the application itself (task role)."
  type        = string
  default     = null
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the roles created here."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for this workload."
  type        = number
  default     = 7
}

variable "autoscaling" {
  description = <<-EOT
    Target-tracking autoscaling for stateless HTTP services. null = fixed desired_count.
    min_capacity is always desired_count so Terraform and autoscaling never fight below it.
  EOT
  type = object({
    max_capacity       = number
    cpu_target         = optional(number)
    memory_target      = optional(number)
    requests_target    = optional(number)
    alb_resource_label = optional(string)
  })
  default = null
}
