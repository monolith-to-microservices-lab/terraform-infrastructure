provider "aws" {
  region = var.aws_region

  # Credentials: standard AWS chain only (AWS_PROFILE / SSO / OIDC in CI).

  default_tags {
    tags = local.common_tags
  }
}
