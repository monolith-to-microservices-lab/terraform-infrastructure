<#
.SYNOPSIS
  Applies a SAVED, reviewed plan. Never plans and applies in one step, never
  uses -auto-approve.

.DESCRIPTION
  * Refuses plans that destroy anything unless -AllowDestroy is given.
  * Asks you to type the environment name to confirm.
  * Terraform itself rejects a stale plan (state changed since it was made).

.EXAMPLE
  ./scripts/apply.ps1 -Environment dev -PlanFile plans/dev-20260923-101500.tfplan
  ./scripts/apply.ps1 -Environment dev     # uses the newest saved plan
#>
[CmdletBinding()]
param(
    [string]$Environment = 'dev',
    [string]$PlanFile,
    [switch]$AllowDestroy
)

. "$PSScriptRoot/_common.ps1"
$dir = Get-EnvDir $Environment

if (-not $PlanFile) {
    $latest = Get-ChildItem (Join-Path $dir 'plans') -Filter "$Environment-*.tfplan" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No saved plan found. Run ./scripts/plan.ps1 -Environment $Environment first." }
    $PlanFile = "plans/$($latest.Name)"
}
if (-not (Test-Path (Join-Path $dir $PlanFile))) { throw "Plan file not found: $PlanFile" }

Write-Step 'AWS identity'
Show-AwsIdentity | Out-Null

Write-Step "Reviewing $PlanFile"
$summary = Show-PlanSummary -WorkDir $dir -PlanFile $PlanFile
if ($summary.Destroy -gt 0 -and -not $AllowDestroy) {
    throw "Plan destroys $($summary.Destroy) resource(s). Explain each one before re-running with -AllowDestroy."
}

$answer = Read-Host "Type the environment name ('$Environment') to apply this plan"
if ($answer -ne $Environment) { Write-Host 'Aborted. Nothing was applied.'; exit 0 }

Write-Step 'terraform apply (saved plan)'
$code = Invoke-Terraform -WorkDir $dir -Arguments @('apply', '-input=false', $PlanFile)
if ($code -ne 0) { throw 'apply failed' }

Remove-Item (Join-Path $dir $PlanFile) -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Applied. Verify with: ./scripts/drift-check.ps1 (expect: no drift) and ./scripts/state-info.ps1 -Outputs'
