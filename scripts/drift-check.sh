#!/usr/bin/env bash
# Drift detection (Linux/macOS/Git Bash/CI). Same contract as drift-check.ps1:
#   exit 0 = no drift, 1 = error, 2 = drift detected (nothing is changed).
# Uses `terraform plan -refresh-only`, never the deprecated `terraform refresh`.
set -uo pipefail

ENVIRONMENT="${1:-dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${ROOT}/environments/${ENVIRONMENT}"

[[ -d "${DIR}" ]] || { echo "unknown environment: ${ENVIRONMENT}" >&2; exit 1; }
cd "${DIR}"

if [[ -f backend.hcl ]]; then
  terraform init -input=false -backend-config=backend.hcl >/dev/null || exit 1
else
  # CI passes -backend-config flags itself and has already run init.
  [[ -d .terraform ]] || { echo "missing backend.hcl and not initialised" >&2; exit 1; }
fi

mkdir -p plans
PLAN="plans/${ENVIRONMENT}-drift-$(date +%Y%m%d-%H%M%S).tfplan"

terraform plan -refresh-only -input=false -detailed-exitcode -out="${PLAN}"
code=$?

case "${code}" in
  0) echo "NO DRIFT: real infrastructure matches the Terraform state."; rm -f "${PLAN}" ;;
  2) echo "DRIFT DETECTED: resources changed outside Terraform. Nothing was modified."
     echo "Decide: revert (plan + apply), adopt (edit config, plan + apply) or record in state (terraform apply ${PLAN})." ;;
  *) echo "drift check failed" >&2 ;;
esac
exit "${code}"
