output "account_id" {
  description = "AWS account the bootstrap was applied to."
  value       = local.account_id
}

output "aws_region" {
  description = "Region of the state bucket."
  value       = var.aws_region
}

output "state_bucket_name" {
  description = "S3 bucket holding every environment's Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "backend_config" {
  description = "Content for environments/<env>/backend.hcl (partial backend configuration)."
  value       = <<-EOT
    bucket = "${aws_s3_bucket.state.bucket}"
    region = "${var.aws_region}"
  EOT
}

output "workload_permissions_boundary_arn" {
  description = "Pass to environments as permissions_boundary_arn."
  value       = aws_iam_policy.workload_boundary.arn
}

output "github_plan_role_arn" {
  description = "Set as GitHub variable AWS_PLAN_ROLE_ARN."
  value       = try(aws_iam_role.plan[0].arn, null)
}

output "github_apply_role_arn" {
  description = "Set as GitHub variable AWS_APPLY_ROLE_ARN (environment-scoped)."
  value       = try(aws_iam_role.apply[0].arn, null)
}
