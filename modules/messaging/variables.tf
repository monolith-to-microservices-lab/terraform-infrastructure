variable "name" {
  description = "Name prefix, e.g. mtm-dev."
  type        = string
}

variable "environment" {
  description = "Environment name (secret paths)."
  type        = string
}

variable "name_prefix" {
  description = "Project prefix (secret paths), e.g. mtm."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster the platform host joins."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster ARN."
  type        = string
}

variable "namespace_id" {
  description = "Cloud Map namespace ID."
  type        = string
}

variable "namespace_name" {
  description = "Cloud Map namespace DNS name."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the platform host (fixes its AZ, and therefore the data volume's AZ)."
  type        = string
}

variable "security_group_id" {
  description = "Platform host security group."
  type        = string
}

variable "instance_type" {
  description = "Platform host instance type. Kafka + Connect + OTel need ~3 GiB."
  type        = string
  default     = "t3.medium"
}

variable "data_volume_size_gb" {
  description = "Persistent gp3 volume for Kafka logs."
  type        = number
  default     = 20
}

variable "extra_dns_names" {
  description = "Additional Cloud Map names pointing at the platform host (e.g. otel-collector)."
  type        = list(string)
  default     = []
}

variable "placement_attribute" {
  description = "ECS instance attribute that identifies the platform host."
  type        = object({ name = string, value = string })
  default     = { name = "mtm.role", value = "platform" }
}

variable "kafka_image" {
  description = "Kafka image (same as the local lab)."
  type        = string
  default     = "apache/kafka:3.9.1"
}

variable "kafka_cluster_id" {
  description = "Fixed KRaft cluster id. Must stay stable for the data volume to remain valid."
  type        = string
}

variable "kafka_default_partitions" {
  description = "Partitions for auto-created topics. Caps CDC consumer parallelism (see ADR 0002)."
  type        = number
  default     = 1
}

variable "connect_image" {
  description = "Kafka Connect image with Debezium (same as the local lab)."
  type        = string
  default     = "quay.io/debezium/connect:3.1"
}

variable "legacy_db_address" {
  description = "Legacy PostgreSQL hostname, exposed to Connect as an env var for connector configs."
  type        = string
}

variable "legacy_db_name" {
  description = "Legacy database name."
  type        = string
}

variable "debezium_password_version" {
  description = "Bump to generate a new Debezium DB password (then re-run the CDC runbook ALTER ROLE)."
  type        = number
  default     = 1
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

variable "alarm_topic_arn" {
  description = "SNS topic for host alarms (null = no notification)."
  type        = string
  default     = null
}
