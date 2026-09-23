variable "name" {
  description = "Name prefix, e.g. mtm-dev."
  type        = string
}

variable "environment" {
  description = "Environment name (resource attribute on spans)."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "placement_attribute" {
  description = "ECS attribute of the platform host."
  type        = object({ name = string, value = string })
}

variable "enable_otel_collector" {
  description = "Run the OTel Collector on the platform host (apps export OTLP to it)."
  type        = bool
  default     = true
}

variable "otel_collector_image" {
  description = "Collector image (same distribution/version as the local lab)."
  type        = string
  default     = "otel/opentelemetry-collector-contrib:0.108.0"
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

variable "alarm_emails" {
  description = "E-mail subscriptions for the alarm topic (each must confirm the subscription)."
  type        = list(string)
  default     = []
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for CloudWatch dimensions."
  type        = string
}

variable "target_group_arn_suffixes" {
  description = "Target group ARN suffixes per HTTP service."
  type        = map(string)
}

variable "databases" {
  description = "RDS instance identifiers to alarm on: logical name => instance id."
  type        = map(string)
}

variable "cdc_source_database" {
  description = "Logical name (key of var.databases) of the database with the Debezium replication slot."
  type        = string
}

variable "replication_slot_lag_alarm_bytes" {
  description = "Alarm when the oldest replication slot retains more WAL than this."
  type        = number
  default     = 1073741824 # 1 GiB
}

variable "free_storage_alarm_bytes" {
  description = "Alarm when free RDS storage drops below this."
  type        = number
  default     = 2147483648 # 2 GiB
}
