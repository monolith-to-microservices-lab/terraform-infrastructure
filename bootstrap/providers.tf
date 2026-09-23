provider "aws" {
  region = var.aws_region

  # Credentials come from the standard AWS chain (AWS_PROFILE / SSO / env).
  # Never hardcode keys here.

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Repository  = "${var.github_org}/${var.github_repo}"
      Stack       = "bootstrap"
    }
  }
}
