#Requires -Version 5.1
<#
.SYNOPSIS
  Import the G3 / staging TLS inspection CA (ca.crt) into Windows trusted roots.

.DESCRIPTION
  When the proxy terminates HTTPS (e.g. ntp.msn.com), Edge shows NET::ERR_CERT_AUTHORITY_INVALID
  until the *issuer* CA is trusted — not the per-site leaf. That issuer must match ca.crt here
  (Subject CN stage.gfox.ai for your environment).

.PARAMETER Machine
  Install into Local Machine\Root instead of Current User\Root. Requires an elevated PowerShell.

.EXAMPLE
  .\trust-ca-windows.ps1

.EXAMPLE
  # All users on this PC (run PowerShell as Administrator)
  .\trust-ca-windows.ps1 -Machine
#>
param(
    [switch] $Machine
)

$ErrorActionPreference = "Stop"
$caPath = Join-Path $PSScriptRoot "ca.crt"

if (-not (Test-Path -LiteralPath $caPath)) {
    Write-Error "Missing $caPath"
    exit 1
}

if ($Machine) {
    Write-Host "Installing CA into machine store (requires Administrator)..."
    & certutil.exe @("-addstore", "Root", $caPath)
} else {
    Write-Host "Installing CA into current user Trusted Root Certification Authorities..."
    & certutil.exe -user @("-addstore", "Root", $caPath)
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "certutil failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Done. Fully quit Edge (all windows), then reopen via edge-local.ps1."
Write-Host "If warnings persist, reboot once so the store is flushed."
