# Offline plan tests for the bootstrap stack (mocked AWS provider).
#   cd bootstrap && terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  aws_region = "us-east-1"
}

run "state_bucket_is_private_versioned_encrypted" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "mtm-tfstate-123456789012-us-east-1"
    error_message = "State bucket name must follow <prefix>-tfstate-<account>-<region>."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket must be versioned (state recovery)."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All four Block Public Access settings must be on."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm]) == "AES256"
    error_message = "State must be encrypted at rest."
  }

  assert {
    condition     = length(aws_budgets_budget.monthly) == 0
    error_message = "No budget without alert e-mails."
  }
}

run "reuses_existing_github_oidc_provider" {
  command = plan

  variables {
    existing_github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "Must not create a duplicate OIDC provider when one exists."
  }
}

run "state_versions_kept_at_least_30_days" {
  command = plan

  variables {
    noncurrent_version_retention_days = 7
  }

  expect_failures = [var.noncurrent_version_retention_days]
}
