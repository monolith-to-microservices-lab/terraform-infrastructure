<#
.SYNOPSIS
  Creates the remote-state bucket (+ GitHub OIDC roles, permissions boundary,
  optional budget) with LOCAL state, then writes environments/<env>/backend.hcl.

.DESCRIPTION
  Chicken-and-egg: the bucket that stores every state file cannot store its own
  creation. bootstrap/ therefore uses a local terraform.tfstate (git-ignored).
  Flow: init -> plan (saved) -> you review -> type 'yes' -> apply saved plan.

.EXAMPLE
  $env:AWS_PROFILE = 'mtm-admin'; ./scripts/bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Environments = @('dev')
)

. "$PSScriptRoot/_common.ps1"
$dir = Join-Path $script:RepoRoot 'bootstrap'

if (-not (Test-Path (Join-Path $dir 'terraform.tfvars'))) {
    throw "Create bootstrap/terraform.tfvars from terraform.tfvars.example first (aws_region is required)."
}

Write-Step 'AWS identity'
Show-AwsIdentity | Out-Null

Write-Step 'terraform init (local state)'
if ((Invoke-Terraform -WorkDir $dir -Arguments @('init', '-input=false')) -ne 0) { throw 'init failed' }

Write-Step 'terraform plan'
$planFile = New-PlanPath $dir 'bootstrap'
$code = Invoke-Terraform -WorkDir $dir -Arguments @('plan', '-input=false', '-detailed-exitcode', "-out=$planFile")
if ($code -eq 1) { throw 'plan failed' }

if ($code -eq 2) {
    $summary = Show-PlanSummary -WorkDir $dir -PlanFile $planFile
    if ($summary.Destroy -gt 0) { throw 'Bootstrap plan wants to destroy resources. Stop and investigate.' }
    $answer = Read-Host "Apply this bootstrap plan? Type 'yes' to continue"
    if ($answer -ne 'yes') { Write-Host 'Aborted. Nothing was applied.'; exit 0 }

    Write-Step 'terraform apply (saved plan)'
    if ((Invoke-Terraform -WorkDir $dir -Arguments @('apply', '-input=false', $planFile)) -ne 0) { throw 'apply failed' }
} else {
    Write-Host 'Bootstrap already up to date.'
}

Write-Step 'Writing backend.hcl for each environment'
$backend = Get-TerraformOutput -WorkDir $dir -Arguments @('output', '-raw', 'backend_config')
foreach ($envName in $Environments) {
    $target = Join-Path (Get-EnvDir $envName) 'backend.hcl'
    Set-Content -Path $target -Value $backend -Encoding utf8
    Write-Host "  wrote $target (git-ignored)"
}

Write-Step 'Values for GitHub (Settings > Secrets and variables > Actions > Variables)'
foreach ($o in 'state_bucket_name', 'aws_region', 'github_plan_role_arn', 'github_apply_role_arn', 'workload_permissions_boundary_arn') {
    $value = Get-TerraformOutput -WorkDir $dir -Arguments @('output', '-raw', $o)
    Write-Host ("  {0,-36} {1}" -f $o, $value)
}
Write-Host ''
Write-Host 'Next: ./scripts/init.ps1 -Environment dev'
