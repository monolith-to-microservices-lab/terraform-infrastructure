<#
.SYNOPSIS
  Detects changes made OUTSIDE Terraform (console, CLI, other tools).

.DESCRIPTION
  Runs `terraform plan -refresh-only -detailed-exitcode`: reads the real
  infrastructure, compares it with the STATE and shows what changed. It never
  proposes changes to real resources and never updates the state by itself.

  Exit codes: 0 = no drift, 1 = error, 2 = drift detected.

  After drift is found, decide explicitly:
    a) the manual change is wrong  -> ./scripts/plan.ps1 + apply.ps1 (restores the configuration)
    b) the manual change is right  -> edit the .tf/.tfvars to match, then plan/apply
    c) only record reality in state (rare) -> terraform apply <saved refresh-only plan>
  Never use `terraform refresh` (deprecated: updates state without review).

.EXAMPLE
  ./scripts/drift-check.ps1 -Environment dev
#>
[CmdletBinding()]
param(
    [string]$Environment = 'dev'
)

. "$PSScriptRoot/_common.ps1"
$dir = Get-EnvDir $Environment
Assert-BackendConfig $dir | Out-Null

Write-Step 'AWS identity'
Show-AwsIdentity | Out-Null

Write-Step "terraform init ($Environment)"
if ((Invoke-Terraform -WorkDir $dir -Arguments @('init', '-input=false', '-backend-config=backend.hcl')) -ne 0) { throw 'init failed' }

$planFile = New-PlanPath $dir "$Environment-drift"
Write-Step 'terraform plan -refresh-only'
$code = Invoke-Terraform -WorkDir $dir -Arguments @('plan', '-refresh-only', '-input=false', '-detailed-exitcode', "-out=$planFile")

switch ($code) {
    0 {
        Write-Host 'NO DRIFT: real infrastructure matches the Terraform state.' -ForegroundColor Green
        Remove-Item (Join-Path $dir $planFile) -ErrorAction SilentlyContinue
    }
    2 {
        Write-Host ''
        Write-Host 'DRIFT DETECTED: resources were changed outside Terraform (details above).' -ForegroundColor Red
        Write-Host 'Nothing was changed. Decide:'
        Write-Host '  a) revert the manual change : ./scripts/plan.ps1 then ./scripts/apply.ps1'
        Write-Host '  b) keep it                  : update the configuration, then plan/apply'
        Write-Host "  c) record it in state only  : terraform apply $planFile  (from environments/$Environment)"
    }
    default { Write-Host 'Drift check failed (error).' -ForegroundColor Red }
}
exit $code
