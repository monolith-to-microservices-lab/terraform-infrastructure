# Shared helpers for the operational scripts. Dot-sourced, not executed.
#
# Terraform resolution:
#   1. `terraform` on PATH (recommended: winget install Hashicorp.Terraform)
#   2. otherwise Docker image hashicorp/terraform:$TerraformVersion, with the
#      repository and ~/.aws mounted and AWS_* / TF_VAR_* env vars passed through.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TerraformVersion = '1.16.4'
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-EnvDir {
    param([Parameter(Mandatory)][string]$Environment)
    $dir = Join-Path $script:RepoRoot "environments\$Environment"
    if (-not (Test-Path $dir)) { throw "Environment '$Environment' not found at $dir" }
    return $dir
}

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-TerraformCommand {
    param([Parameter(Mandatory)][string]$WorkDir)

    if (Test-Command 'terraform') { return @{ Exe = 'terraform'; Prefix = @() } }
    if (-not (Test-Command 'docker')) {
        throw "Neither terraform nor docker found. Install Terraform $script:TerraformVersion (winget install Hashicorp.Terraform)."
    }

    # Windows PowerShell 5.1 has no [IO.Path]::GetRelativePath.
    $full = (Resolve-Path $WorkDir).Path.TrimEnd('\')
    $rel = $full.Substring($script:RepoRoot.TrimEnd('\').Length).TrimStart('\') -replace '\\', '/'
    $awsDir = Join-Path $env:USERPROFILE '.aws'
    $prefix = @('run', '--rm', '-v', "$($script:RepoRoot):/ws", '-w', "/ws/$rel",
        '-v', 'mtm-tf-plugin-cache:/plugin-cache', '-e', 'TF_PLUGIN_CACHE_DIR=/plugin-cache')
    if (Test-Path $awsDir) { $prefix += @('-v', "$($awsDir):/root/.aws") }
    $passThrough = Get-ChildItem env: | Where-Object { $_.Name -like 'AWS_*' -or $_.Name -like 'TF_VAR_*' -or $_.Name -eq 'TF_LOG' }
    foreach ($var in $passThrough) { $prefix += @('-e', $var.Name) }
    $prefix += "hashicorp/terraform:$script:TerraformVersion"
    return @{ Exe = 'docker'; Prefix = $prefix }
}

# Runs terraform in $WorkDir, streaming output to the console. Returns ONLY the
# exit code, so callers can interpret -detailed-exitcode
# (0 = no changes, 1 = error, 2 = changes).
function Invoke-Terraform {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $cmd = Get-TerraformCommand -WorkDir $WorkDir
    Push-Location $WorkDir
    try {
        & $cmd.Exe @($cmd.Prefix + $Arguments) | Out-Host
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# Runs terraform and returns its stdout as a single string (throws on error).
function Get-TerraformOutput {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $cmd = Get-TerraformCommand -WorkDir $WorkDir
    Push-Location $WorkDir
    try {
        $out = & $cmd.Exe @($cmd.Prefix + $Arguments)
        if ($LASTEXITCODE -ne 0) { throw "terraform $($Arguments -join ' ') failed" }
        return ($out -join "`n")
    } finally {
        Pop-Location
    }
}

# Prints who we are about to act as. Never prints keys or tokens.
function Show-AwsIdentity {
    if (-not (Test-Command 'aws')) {
        Write-Warning "AWS CLI not installed: cannot confirm the AWS identity before running (winget install Amazon.AWSCLI)."
        return $null
    }
    $json = & aws sts get-caller-identity --output json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "No valid AWS credentials. Run 'aws sso login --profile <profile>' or set AWS_PROFILE." }
    $id = $json | ConvertFrom-Json
    $region = if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { (& aws configure get region 2>$null) }
    $awsProfile = if ($env:AWS_PROFILE) { $env:AWS_PROFILE } else { 'default' }
    Write-Host ("AWS account : {0}" -f $id.Account)
    Write-Host ("Principal   : {0}" -f $id.Arn)
    Write-Host ("Profile     : {0}" -f $awsProfile)
    Write-Host ("CLI region  : {0}" -f ($(if ($region) { $region } else { '<not set>' })))
    return $id
}

function Assert-BackendConfig([string]$EnvDir) {
    $hcl = Join-Path $EnvDir 'backend.hcl'
    if (-not (Test-Path $hcl)) {
        throw "Missing $hcl. Run scripts/bootstrap.ps1 first (it writes this file) or copy backend.hcl.example."
    }
    return $hcl
}

function New-PlanPath([string]$EnvDir, [string]$Prefix) {
    $plans = Join-Path $EnvDir 'plans'
    New-Item -ItemType Directory -Force $plans | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return "plans/$Prefix-$stamp.tfplan"
}

# Summarises a saved plan and lists every delete/replace explicitly.
function Show-PlanSummary {
    param([string]$WorkDir, [string]$PlanFile)

    $raw = Get-TerraformOutput -WorkDir $WorkDir -Arguments @('show', '-json', $PlanFile)
    $plan = $raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json
    $changes = @($plan.resource_changes | Where-Object { $_.change.actions -notcontains 'no-op' -and $_.change.actions -notcontains 'read' })

    $add = @($changes | Where-Object { $_.change.actions -contains 'create' }).Count
    $chg = @($changes | Where-Object { $_.change.actions -contains 'update' }).Count
    $del = @($changes | Where-Object { $_.change.actions -contains 'delete' })
    $imp = @($plan.resource_changes | Where-Object { $_.change.PSObject.Properties.Name -contains 'importing' -and $_.change.importing }).Count

    Write-Host ""
    Write-Host ("PLAN SUMMARY: {0} to add, {1} to change, {2} to destroy, {3} to import" -f $add, $chg, $del.Count, $imp) -ForegroundColor Yellow
    if ($del.Count -gt 0) {
        Write-Host "DESTROY / REPLACE (review each one):" -ForegroundColor Red
        foreach ($d in $del) { Write-Host ("  - {0}  [{1}]" -f $d.address, ($d.change.actions -join ',')) -ForegroundColor Red }
    }
    return [pscustomobject]@{ Add = $add; Change = $chg; Destroy = $del.Count; Import = $imp }
}
