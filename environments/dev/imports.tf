# -----------------------------------------------------------------------------
# Import blocks for resources that already exist in AWS.
#
# Workflow (docs/import-strategy.md):
#   1. discover   scripts/discover-aws.ps1 -> docs/existing-resources.md
#   2. map        decide IMPORT / KEEP UNMANAGED / CREATE NEW / IGNORE
#   3. plan       add an import block below, run scripts/plan.ps1
#                 -> must say "1 to import, 0 to add, 0 to change, 0 to destroy"
#   4. review     any change/destroy on an imported resource = config mismatch
#   5. import     scripts/apply.ps1 (applies the reviewed saved plan)
#   6. clean up   remove the block afterwards (it is a one-time operation)
#
# Nothing is imported today: the AWS discovery found no project resources
# (see docs/existing-resources.md).
#
# Example - adopt an ECR repository created by hand:
#
# import {
#   to = module.registry.aws_ecr_repository.this["user-service"]
#   id = "mtm/user-service"
# }
# -----------------------------------------------------------------------------
