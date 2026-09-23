variable "aws_region" {
  description = "AWS region for the state bucket and account-level resources. No default on purpose: choose it explicitly."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS region code, e.g. us-east-1."
  }
}

variable "project" {
  description = "Project tag value applied to every resource."
  type        = string
  default     = "monolith-to-microservices-lab"
}

variable "name_prefix" {
  description = "Short prefix for resource names (see docs/naming.md)."
  type        = string
  default     = "mtm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,10}$", var.name_prefix))
    error_message = "name_prefix must be 2-11 lowercase alphanumeric/hyphen characters."
  }
}

variable "state_bucket_name" {
  description = "Override for the state bucket name. Default: <prefix>-tfstate-<account_id>-<region> (globally unique)."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "How long old state versions are kept for recovery."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 30
    error_message = "Keep old state versions for at least 30 days so a bad apply can be rolled back."
  }
}

# --- GitHub Actions OIDC ------------------------------------------------------

variable "github_org" {
  description = "GitHub organization that owns the repository allowed to assume the CI roles."
  type        = string
  default     = "monolith-to-microservices-lab"
}

variable "github_repo" {
  description = "Repository allowed to assume the CI roles."
  type        = string
  default     = "terraform-infrastructure"
}

variable "enable_github_oidc" {
  description = "Create the GitHub OIDC trust and the plan/apply roles for CI."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  description = "If the account already has the token.actions.githubusercontent.com provider, pass its ARN to reuse it (or import it) instead of creating a duplicate."
  type        = string
  default     = null
}

variable "ci_environments" {
  description = "GitHub Environments whose jobs may assume the APPLY role (each should require reviewers)."
  type        = list(string)
  default     = ["dev"]
}

# --- Cost guardrail -----------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget for the account (alerting only, never blocks spend)."
  type        = number
  default     = 150
}

variable "budget_alert_emails" {
  description = "E-mails notified at 80% actual / 100% forecasted spend. Empty = no budget is created."
  type        = list(string)
  default     = []
}
