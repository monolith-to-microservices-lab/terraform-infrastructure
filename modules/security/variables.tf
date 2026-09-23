variable "name" {
  description = "Name prefix, e.g. mtm-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (database egress is scoped to it; the DB security group enforces per-workload access)."
  type        = string
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the public ALB. Never 0.0.0.0/0 in dev by default."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry of allowed_ingress_cidrs must be a valid CIDR."
  }
}

variable "alb_listener_ports" {
  description = "Public ALB listener ports."
  type        = list(number)
}

variable "http_workloads" {
  description = "Workloads behind the ALB: name => container port."
  type        = map(object({ port = number }))
}

variable "worker_workloads" {
  description = "Non-HTTP workloads (CDC consumers): name => metrics port."
  type        = map(object({ metrics_port = number }))
}

variable "kafka_port" {
  description = "Kafka client listener port on the platform host."
  type        = number
  default     = 9092
}

variable "otlp_ports" {
  description = "OTLP gRPC/HTTP ports of the OTel Collector on the platform host."
  type        = list(number)
  default     = [4317, 4318]
}
