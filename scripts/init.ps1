<#
.SYNOPSIS
  terraform init against the S3 remote backend (native S3 locking).
.EXAMPLE
  ./scripts/init.ps1 -Environment dev
  ./scripts/init.ps1 -Environment dev -Upgrade   # newer providers within constraints
#>
[CmdletBinding()]
param(
    [string]$Environment = 'dev',
    [switch]$Upgrade
)

. "$PSScriptRoot/_common.ps1"
$dir = Get-EnvDir $Environment
Assert-BackendConfig $dir | Out-Null

Write-Step "terraform init ($Environment, remote S3 backend)"
$tfArgs = @('init', '-input=false', '-backend-config=backend.hcl')
if ($Upgrade) { $tfArgs += '-upgrade' }
if ((Invoke-Terraform -WorkDir $dir -Arguments $tfArgs) -ne 0) { throw 'init failed' }

Write-Step 'Backend in use'
Get-Content (Join-Path $dir 'backend.hcl') | ForEach-Object { "  $_" }
Write-Host "  key    = $Environment/terraform.tfstate"
Write-Host '  lock   = S3 native lockfile (<key>.tflock), no DynamoDB'
