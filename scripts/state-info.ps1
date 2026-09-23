<#
.SYNOPSIS
  Read-only state inspection. Never modifies state (no mv/rm/push).

.EXAMPLE
  ./scripts/state-info.ps1                                   # terraform state list
  ./scripts/state-info.ps1 -Address module.db_legacy.aws_db_instance.this
  ./scripts/state-info.ps1 -Outputs                          # terraform output -json
  ./scripts/state-info.ps1 -Versions                         # S3 versions of the state file
#>
[CmdletBinding()]
param(
    [string]$Environment = 'dev',
    [string]$Address,
    [switch]$Outputs,
    [switch]$Versions
)

. "$PSScriptRoot/_common.ps1"
$dir = Get-EnvDir $Environment
$backendFile = Assert-BackendConfig $dir

if (-not (Test-Path (Join-Path $dir '.terraform'))) {
    if ((Invoke-Terraform -WorkDir $dir -Arguments @('init', '-input=false', '-backend-config=backend.hcl')) -ne 0) { throw 'init failed' }
}

if ($Versions) {
    if (-not (Test-Command 'aws')) { throw 'AWS CLI required for -Versions.' }
    $bucket = (Select-String -Path $backendFile -Pattern 'bucket\s*=\s*"([^"]+)"').Matches[0].Groups[1].Value
    Write-Step "State versions: s3://$bucket/$Environment/terraform.tfstate"
    & aws s3api list-object-versions --bucket $bucket --prefix "$Environment/terraform.tfstate" `
        --query 'Versions[].{VersionId:VersionId,LastModified:LastModified,Size:Size,IsLatest:IsLatest}' --output table
    Write-Host 'Recovery procedure: docs/state-management.md'
    exit $LASTEXITCODE
}

if ($Outputs) {
    Write-Step 'terraform output -json'
    exit (Invoke-Terraform -WorkDir $dir -Arguments @('output', '-json'))
}

if ($Address) {
    Write-Step "terraform state show $Address"
    exit (Invoke-Terraform -WorkDir $dir -Arguments @('state', 'show', $Address))
}

Write-Step "terraform state list ($Environment)"
exit (Invoke-Terraform -WorkDir $dir -Arguments @('state', 'list'))
