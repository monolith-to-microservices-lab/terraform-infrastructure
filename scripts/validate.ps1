<#
.SYNOPSIS
  Static checks, no AWS credentials needed:
  terraform fmt -check, init -backend=false + validate, terraform test (mocked
  plan), and tflint + trivy when available (natively or through Docker).
.EXAMPLE
  ./scripts/validate.ps1
  ./scripts/validate.ps1 -SkipTests -SkipScanners
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipScanners
)

. "$PSScriptRoot/_common.ps1"
$failed = @()
$roots = @('bootstrap', 'environments/dev')

Write-Step 'terraform fmt -check -recursive'
if ((Invoke-Terraform -WorkDir $script:RepoRoot -Arguments @('fmt', '-check', '-recursive', '-diff')) -ne 0) {
    $failed += 'fmt (run: terraform fmt -recursive)'
} else { Write-Host 'fmt PASS' -ForegroundColor Green }

foreach ($root in $roots) {
    $dir = Join-Path $script:RepoRoot $root
    Write-Step "validate $root"
    if ((Invoke-Terraform -WorkDir $dir -Arguments @('init', '-backend=false', '-input=false')) -ne 0) { $failed += "init $root"; continue }
    if ((Invoke-Terraform -WorkDir $dir -Arguments @('validate')) -ne 0) { $failed += "validate $root" } else { Write-Host "validate $root PASS" -ForegroundColor Green }

    if (-not $SkipTests) {
        Write-Step "terraform test $root (mocked provider, offline plan)"
        if ((Invoke-Terraform -WorkDir $dir -Arguments @('test')) -ne 0) { $failed += "test $root" } else { Write-Host "test $root PASS" -ForegroundColor Green }
    }
}

if (-not $SkipScanners) {
    if (Test-Command 'docker') {
        Write-Step 'tflint'
        foreach ($root in $roots) {
            & docker run --rm -v "$($script:RepoRoot):/ws" -v mtm-tflint-plugins:/root/.tflint.d -w "/ws/$root" --entrypoint sh `
                ghcr.io/terraform-linters/tflint:v0.64.0 -c 'tflint --init --config /ws/.tflint.hcl >/dev/null && tflint --config /ws/.tflint.hcl --format compact'
            if ($LASTEXITCODE -ne 0) { $failed += "tflint $root" } else { Write-Host "tflint $root PASS" -ForegroundColor Green }
        }

        Write-Step 'trivy config (IaC misconfigurations, MEDIUM+)'
        & docker run --rm -v "$($script:RepoRoot):/ws" -v mtm-trivy-cache:/root/.cache aquasec/trivy:0.74.0 config `
            --severity MEDIUM,HIGH,CRITICAL --skip-dirs '**/.terraform' --exit-code 1 /ws
        if ($LASTEXITCODE -ne 0) { $failed += 'trivy' } else { Write-Host 'trivy PASS' -ForegroundColor Green }
    } else {
        Write-Warning 'Docker not available: skipping tflint and trivy.'
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("FAILED: {0}" -f ($failed -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
