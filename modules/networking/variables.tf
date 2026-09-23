variable "name" {
  description = "Name prefix, e.g. mtm-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Subnets are carved as /24s: public 0-9, private app 10-19, data 20-29."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR of size /20 or larger."
  }
}

variable "az_count" {
  description = "Number of AZs. ALB and RDS subnet groups require at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "egress_mode" {
  description = "Internet egress for private subnets: nat_instance (cheap, single point of failure) or nat_gateway (managed, ~10x cost)."
  type        = string
  default     = "nat_instance"

  validation {
    condition     = contains(["nat_instance", "nat_gateway"], var.egress_mode)
    error_message = "egress_mode must be nat_instance or nat_gateway."
  }
}

variable "nat_instance_type" {
  description = "Instance type for the NAT instance (arm64)."
  type        = string
  default     = "t4g.nano"
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs (REJECT only) to CloudWatch Logs."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 7
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for IAM roles created here."
  type        = string
  default     = null
}
