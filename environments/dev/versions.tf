terraform {
  # 1.11+: S3 native locking (use_lockfile) and write-only arguments
  # (password_wo / secret_string_wo). Verified with 1.16.4.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
