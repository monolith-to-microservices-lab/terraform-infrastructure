# --- Identity / placement -------------------------------------------------------

variable "aws_region" {
  description = "AWS region. No default on purpose (see docs/cost-estimate.md)."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS region code, e.g. us-east-1."
  }
}

variable "environment" {
  description = "Environment name. Drives names, tags and the state key."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project" {
  description = "Project tag value."
  type        = string
  default     = "monolith-to-microservices-lab"
}

variable "name_prefix" {
  description = "Short prefix for resource names: <prefix>-<env>-<component>."
  type        = string
  default     = "mtm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,5}$", var.name_prefix))
    error_message = "name_prefix must be 2-6 lowercase alphanumeric characters (AWS name length limits)."
  }
}

variable "permissions_boundary_arn" {
  description = "Boundary for every IAM role (output workload_permissions_boundary_arn of bootstrap). null = none."
  type        = string
  default     = null
}

# --- Network ------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "az_count" {
  description = "Availability zones (2 minimum for ALB and RDS subnet groups)."
  type        = number
  default     = 2
}

variable "egress_mode" {
  description = "nat_instance (lab, ~USD 4/mo) or nat_gateway (~USD 33/mo + data)."
  type        = string
  default     = "nat_instance"
}

variable "enable_flow_logs" {
  description = "VPC flow logs (REJECT) to CloudWatch."
  type        = bool
  default     = false
}

variable "allowed_ingress_cidrs" {
  description = "Who may reach the public ALB. Typically your own IP as x.x.x.x/32."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_ingress_cidrs must contain at least one valid CIDR."
  }

  validation {
    condition     = !contains(var.allowed_ingress_cidrs, "0.0.0.0/0") || var.allow_public_ingress
    error_message = "0.0.0.0/0 exposes the lab to the internet. Set allow_public_ingress = true to do it on purpose."
  }
}

variable "allow_public_ingress" {
  description = "Explicit opt-in to accept 0.0.0.0/0 in allowed_ingress_cidrs."
  type        = bool
  default     = false
}

variable "internal_api_allowed_cidrs" {
  description = "Sources allowed to call /internal/* through the ALB (migration-tool). Empty = blocked."
  type        = list(string)
  default     = []
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS listeners (null = HTTP)."
  type        = string
  default     = null
}

# --- Workloads ----------------------------------------------------------------------

variable "services_enabled" {
  description = "false = ECS services exist with 0 tasks (images not pushed yet). true = run desired_count."
  type        = bool
  default     = false
}

variable "fargate_capacity_provider" {
  description = "FARGATE or FARGATE_SPOT for application workloads."
  type        = string
  default     = "FARGATE_SPOT"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.fargate_capacity_provider)
    error_message = "fargate_capacity_provider must be FARGATE or FARGATE_SPOT."
  }
}

variable "image_tags" {
  description = "Image tag per ECR repository (immutable tags: bump to deploy)."
  type        = map(string)

  validation {
    condition     = alltrue([for r in ["monolith-api", "user-service", "sales-service"] : contains(keys(var.image_tags), r)])
    error_message = "image_tags must define monolith-api, user-service and sales-service."
  }

  validation {
    condition     = !contains(values(var.image_tags), "latest")
    error_message = "Do not deploy :latest; ECR tags are immutable and plans must show what changes."
  }
}

variable "api_sizing" {
  description = "HTTP services: desired_count, Fargate cpu/memory and autoscaling ceiling."
  type = map(object({
    desired_count = number
    cpu           = number
    memory        = number
    max_capacity  = number
  }))

  validation {
    condition     = alltrue([for k in ["monolith-api", "user-service-api", "sales-service-api"] : contains(keys(var.api_sizing), k)])
    error_message = "api_sizing must define monolith-api, user-service-api and sales-service-api."
  }

  validation {
    condition     = alltrue([for s in values(var.api_sizing) : s.desired_count >= 1 && s.max_capacity >= s.desired_count])
    error_message = "Each API needs desired_count >= 1 and max_capacity >= desired_count."
  }

  validation {
    condition = alltrue([for s in values(var.api_sizing) : contains(
      lookup({ 256 = [512, 1024, 2048], 512 = [1024, 2048, 3072, 4096], 1024 = [2048, 3072, 4096, 5120, 6144, 7168, 8192] }, s.cpu, []),
      s.memory
    )])
    error_message = "Invalid Fargate cpu/memory combination (cpu 256: 512-2048, 512: 1024-4096, 1024: 2048-8192)."
  }
}

variable "cdc_sizing" {
  description = "CDC consumers: desired_count and Fargate cpu/memory. No autoscaling (ordering/partitions)."
  type = map(object({
    desired_count = number
    cpu           = number
    memory        = number
  }))

  validation {
    condition     = alltrue([for k in ["user-service-cdc", "sales-service-cdc"] : contains(keys(var.cdc_sizing), k)])
    error_message = "cdc_sizing must define user-service-cdc and sales-service-cdc."
  }

  validation {
    condition     = alltrue([for s in values(var.cdc_sizing) : s.desired_count >= 1 && s.desired_count <= var.kafka_default_partitions])
    error_message = "CDC desired_count must be between 1 and kafka_default_partitions: extra consumers in the group would sit idle (one partition = one active consumer)."
  }

  validation {
    condition = alltrue([for s in values(var.cdc_sizing) : contains(
      lookup({ 256 = [512, 1024, 2048], 512 = [1024, 2048, 3072, 4096] }, s.cpu, []),
      s.memory
    )])
    error_message = "Invalid Fargate cpu/memory combination for a CDC consumer."
  }
}

variable "monolith_cors_origins" {
  description = "CORS origins for the monolith API (the Vue frontend still runs locally)."
  type        = string
  default     = "http://localhost:5173"
}

# --- Data -----------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class for all three databases."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_deletion_protection" {
  description = "RDS deletion protection (Terraform prevent_destroy is always on)."
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  description = "Automated backup retention."
  type        = number
  default     = 3
}

variable "db_password_version" {
  description = "Bump to rotate every database master password (write-only, never in state)."
  type        = number
  default     = 1
}

# --- Messaging / platform host ------------------------------------------------------

variable "debezium_password_version" {
  description = "Bump to rotate the Debezium replication password (then follow docs/runbooks/cdc-bootstrap.md)."
  type        = number
  default     = 1
}

variable "platform_instance_type" {
  description = "Platform host (Kafka, Connect, OTel Collector)."
  type        = string
  default     = "t3.medium"
}

variable "platform_data_volume_gb" {
  description = "Persistent Kafka volume size."
  type        = number
  default     = 20
}

variable "kafka_cluster_id" {
  description = "KRaft cluster id (22-char base64 UUID). Keep stable."
  type        = string
  default     = "5Yr1SIgYQz-b-dgRabWx4g"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{22}$", var.kafka_cluster_id))
    error_message = "kafka_cluster_id must be a 22-character base64url UUID (kafka-storage.sh random-uuid)."
  }
}

variable "kafka_default_partitions" {
  description = "Partitions for auto-created topics."
  type        = number
  default     = 1

  validation {
    condition     = var.kafka_default_partitions >= 1
    error_message = "kafka_default_partitions must be >= 1."
  }
}

# --- Observability ------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for every workload."
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90], var.log_retention_days)
    error_message = "Use a supported CloudWatch retention up to 90 days."
  }
}

variable "container_insights" {
  description = "ECS Container Insights: disabled | enabled | enhanced (extra cost)."
  type        = string
  default     = "disabled"
}

variable "enable_otel_collector" {
  description = "Run the OTel Collector (traces -> X-Ray)."
  type        = bool
  default     = true
}

variable "alarm_emails" {
  description = "E-mails subscribed to the alarm SNS topic."
  type        = list(string)
  default     = []
}
