terraform {
  # 1.11+ is required for S3 native state locking (use_lockfile) and for
  # write-only arguments used in environments/. Verified with 1.16.4.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60"
    }
  }

  # Bootstrap intentionally uses LOCAL state: the S3 bucket that will hold every
  # other state file does not exist yet. The local terraform.tfstate is
  # git-ignored. After the first apply it can optionally be migrated into the
  # bucket it created (see docs/state-management.md).
}
