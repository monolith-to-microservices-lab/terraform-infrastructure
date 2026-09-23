<#
.SYNOPSIS
  init + terraform plan with a SAVED plan file. Never applies.

.DESCRIPTION
  Exit codes follow `terraform plan -detailed-exitcode`:
    0 = no changes, 1 = error, 2 = changes present (plan saved for apply.ps1)
  Any destroy/replace is listed explicitly ("zero surprise destroy").

.EXAMPLE
  ./scripts/plan.ps1 -Environment dev
  ./scripts/plan.ps1 -Environment dev -Target module.registry   # debugging only
#>
[CmdletBinding()]
param(
    [string]$Environment = 'dev',
    [string[]]$Target = @()
)

. "$PSScriptRoot/_common.ps1"
$dir = Get-EnvDir $Environment
Assert-BackendConfig $dir | Out-Null

Write-Step 'AWS identity'
Show-AwsIdentity | Out-Null

Write-Step "terraform init ($Environment)"
if ((Invoke-Terraform -WorkDir $dir -Arguments @('init', '-input=false', '-backend-config=backend.hcl')) -ne 0) { throw 'init failed' }

$planFile = New-PlanPath $dir $Environment
Write-Step "terraform plan -> $planFile"
$tfArgs = @('plan', '-input=false', '-detailed-exitcode', "-out=$planFile")
foreach ($t in $Target) { $tfArgs += "-target=$t" }
$code = Invoke-Terraform -WorkDir $dir -Arguments $tfArgs

switch ($code) {
    0 { Write-Host 'No changes. Infrastructure matches the configuration.' -ForegroundColor Green; Remove-Item (Join-Path $dir $planFile) -ErrorAction SilentlyContinue }
    2 {
        $summary = Show-PlanSummary -WorkDir $dir -PlanFile $planFile
        Write-Host ''
        Write-Host "Saved plan: environments/$Environment/$planFile"
        Write-Host "Review it, then: ./scripts/apply.ps1 -Environment $Environment -PlanFile $planFile"
        if ($summary.Destroy -gt 0) { Write-Warning 'This plan DESTROYS resources. apply.ps1 will refuse it unless -AllowDestroy is passed.' }
    }
    default { Write-Host 'terraform plan failed.' -ForegroundColor Red }
}
exit $code
