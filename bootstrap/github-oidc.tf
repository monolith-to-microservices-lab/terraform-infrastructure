# -----------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC (no long-lived access keys in GitHub).
#
#   mtm-gha-terraform-plan   PRs + main (plan, refresh-only drift check)
#   mtm-gha-terraform-apply  only jobs running in a protected GitHub Environment
#
# Workload roles created by environments/* must carry the permissions boundary
# below; the apply role is only allowed to create roles that have it. This
# stops CI from escalating to admin by minting a new role.
# -----------------------------------------------------------------------------

locals {
  repo_full     = "${var.github_org}/${var.github_repo}"
  oidc_host     = "token.actions.githubusercontent.com"
  create_oidc   = var.enable_github_oidc && var.existing_github_oidc_provider_arn == null
  oidc_provider = var.enable_github_oidc ? coalesce(var.existing_github_oidc_provider_arn, try(aws_iam_openid_connect_provider.github[0].arn, null)) : null

  role_prefix     = "${var.name_prefix}-"
  role_arn_prefix = "arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-"
  boundary_name   = "${var.name_prefix}-workload-boundary"
  boundary_arn    = "arn:${local.partition}:iam::${local.account_id}:policy/${local.boundary_name}"
  secrets_arn     = "arn:${local.partition}:secretsmanager:*:${local.account_id}:secret:${var.name_prefix}/*"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_oidc ? 1 : 0

  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# --- Permissions boundary for every workload role ----------------------------
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid    = "WorkloadRuntime"
    effect = "Allow"
    actions = [
      "ecs:*",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "ssm:*",
      "ssmmessages:*",
      "ec2messages:*",
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeNetworkInterfaces",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "xray:GetSamplingStatisticSummaries",
      "cloudwatch:PutMetricData",
      "kms:Decrypt",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadOwnSecretsOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.secrets_arn]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = local.boundary_name
  description = "Maximum permissions any ${var.name_prefix} workload role can ever have."
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

# --- Trust policies ------------------------------------------------------------
data "aws_iam_policy_document" "trust_plan" {
  count = var.enable_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${local.repo_full}:pull_request",
        "repo:${local.repo_full}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "trust_apply" {
  count = var.enable_github_oidc ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs bound to a (reviewer-protected) GitHub Environment.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [for env in var.ci_environments : "repo:${local.repo_full}:environment:${env}"]
    }
  }
}

# --- State access shared by both roles ----------------------------------------
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ReadWriteStateAndLock"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "ReleaseLockAndCleanCiPlans"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock", "${aws_s3_bucket.state.arn}/ci-plans/*"]
  }
}

# --- Plan role: read-only on AWS + state/lock access ---------------------------
resource "aws_iam_role" "plan" {
  count = var.enable_github_oidc ? 1 : 0

  name                 = "${local.role_prefix}gha-terraform-plan"
  description          = "GitHub Actions: terraform plan / refresh-only drift detection."
  assume_role_policy   = data.aws_iam_policy_document.trust_plan[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  count = var.enable_github_oidc ? 1 : 0

  role       = aws_iam_role.plan[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan_extra" {
  source_policy_documents = [data.aws_iam_policy_document.state_access.json]

  # Refreshing aws_secretsmanager_secret_version reads the secret value.
  statement {
    sid       = "RefreshProjectSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secrets_arn]
  }
}

resource "aws_iam_role_policy" "plan_extra" {
  count = var.enable_github_oidc ? 1 : 0

  name   = "state-and-refresh"
  role   = aws_iam_role.plan[0].id
  policy = data.aws_iam_policy_document.plan_extra.json
}

# --- Apply role: service-scoped, IAM limited by name prefix + boundary ---------
# PassRole is limited to mtm-* roles and to ECS/EC2 via iam:PassedToService.
#trivy:ignore:AWS-0342
data "aws_iam_policy_document" "apply" {
  source_policy_documents = [data.aws_iam_policy_document.state_access.json]

  statement {
    sid = "ManageLabServices"
    actions = [
      "ec2:*",
      "ecs:*",
      "ecr:*",
      "rds:*",
      "elasticloadbalancing:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "application-autoscaling:*",
      "autoscaling:Describe*",
      "servicediscovery:*",
      "route53:*",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "kms:DescribeKey",
      "kms:ListAliases",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ManageProjectSecrets"
    actions   = ["secretsmanager:*"]
    resources = [local.secrets_arn]
  }

  statement {
    sid       = "SecretsManagerAccountLevel"
    actions   = ["secretsmanager:ListSecrets", "secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadIam"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }

  statement {
    sid = "CreateRolesOnlyWithBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = ["${local.role_arn_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["${local.role_arn_prefix}*"]
  }

  statement {
    sid = "ManageProjectInstanceProfiles"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/${var.name_prefix}-*"]
  }

  # Scoped to mtm-* roles and to the ECS/EC2 services via iam:PassedToService.
  statement {
    sid       = "PassProjectRolesToAwsServices"
    actions   = ["iam:PassRole"]
    resources = ["${local.role_arn_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ec2.amazonaws.com"]
    }
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
        "ecs.application-autoscaling.amazonaws.com",
        "servicediscovery.amazonaws.com",
      ]
    }
  }

  # CI must never be able to widen its own permissions.
  statement {
    sid    = "ProtectCiRolesAndBoundary"
    effect = "Deny"
    actions = [
      "iam:Create*",
      "iam:Delete*",
      "iam:Put*",
      "iam:Attach*",
      "iam:Detach*",
      "iam:Update*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:SetDefaultPolicyVersion",
    ]
    resources = [
      "${local.role_arn_prefix}gha-*",
      local.boundary_arn,
    ]
  }

  statement {
    sid       = "ProtectStateBucket"
    effect    = "Deny"
    actions   = ["s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }
}

resource "aws_iam_policy" "apply" {
  count = var.enable_github_oidc ? 1 : 0

  name        = "${local.role_prefix}gha-terraform-apply"
  description = "Service-scoped permissions for applying the ${var.name_prefix} environments."
  policy      = data.aws_iam_policy_document.apply.json
}

resource "aws_iam_role" "apply" {
  count = var.enable_github_oidc ? 1 : 0

  name                 = "${local.role_prefix}gha-terraform-apply"
  description          = "GitHub Actions: terraform apply, only from protected GitHub Environments."
  assume_role_policy   = data.aws_iam_policy_document.trust_apply[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply" {
  count = var.enable_github_oidc ? 1 : 0

  role       = aws_iam_role.apply[0].name
  policy_arn = aws_iam_policy.apply[0].arn
}
