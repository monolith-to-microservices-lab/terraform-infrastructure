variable "name" {
  description = "Full identifier, e.g. mtm-dev-legacy-pg."
  type        = string
}

variable "secret_name" {
  description = "Secrets Manager name for the connection secret, e.g. mtm/dev/legacy-db."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Isolated data subnets (at least 2 AZs)."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Workload security groups allowed to connect on 5432, name => SG ID."
  type        = map(string)
}

variable "db_name" {
  description = "Initial database name."
  type        = string
}

variable "username" {
  description = "Master username (the apps currently connect as the owner, as in the local lab)."
  type        = string
}

variable "sqlalchemy_driver" {
  description = "SQLAlchemy dialect+driver used to build DATABASE_URL, e.g. postgresql+psycopg."
  type        = string
  default     = "postgresql+psycopg"
}

variable "engine_version" {
  description = "Major PostgreSQL version (minor upgrades are automatic). Local lab runs 16."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage (GiB)."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "gp3 storage for RDS PostgreSQL starts at 20 GiB."
  }
}

variable "max_allocated_storage" {
  description = "Storage autoscaling ceiling (GiB). Caps cost of a runaway replication slot."
  type        = number
  default     = 50
}

variable "multi_az" {
  description = "Multi-AZ doubles the instance cost. Off for dev."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention (days). Backup storage up to the DB size is free."
  type        = number
  default     = 3

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "Keep at least 1 day of automated backups (0 disables backups and PITR)."
  }
}

variable "deletion_protection" {
  description = "RDS-level deletion protection (in addition to Terraform prevent_destroy)."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of in the maintenance window."
  type        = bool
  default     = true
}

variable "logical_replication" {
  description = "Enable logical decoding (wal_level=logical) for Debezium. Only the legacy DB needs it."
  type        = bool
  default     = false
}

variable "max_slot_wal_keep_size_mb" {
  description = "Upper bound of WAL a replication slot may retain. Protects the disk if Debezium stops consuming; the slot is invalidated instead of filling storage."
  type        = number
  default     = 4096
}

variable "password_version" {
  description = "Bump to rotate the master password (write-only: never stored in state)."
  type        = number
  default     = 1
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret can still be restored."
  type        = number
  default     = 7
}
