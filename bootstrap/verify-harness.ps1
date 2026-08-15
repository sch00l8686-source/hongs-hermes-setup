<#
.SYNOPSIS
    Verify that the installed harness matches the manifest.

.DESCRIPTION
    Read-only. Compares the SHA-256 of every managed destination against the
    manifest. Unowned files are never enumerated; credentials and runtime state
    are never read. Exits 0 when every managed file matches, 1 otherwise.

.EXAMPLE
    powershell -File bootstrap/verify-harness.ps1 `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude -CodexHome C:\codex
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$HermesHome,
    [Parameter(Mandatory = $true)][string]$ClaudeHome,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [string]$ManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'HarnessInstaller.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $RepositoryRoot 'manifest\harness-manifest.json'
}

try {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found at '$ManifestPath'. Build it first: python scripts/build-harness-manifest.py --root <repo> --output manifest/harness-manifest.json"
    }

    $manifest = Test-HarnessManifest -Path $ManifestPath
    $result = Test-HarnessInstall -Manifest $manifest -RepositoryRoot $RepositoryRoot `
        -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome

    Write-Output ("Checked {0} managed file(s)." -f $result.Checked)
    foreach ($destination in $result.Missing) {
        Write-Output ("MISSING    {0}" -f $destination)
    }
    foreach ($destination in $result.Mismatched) {
        Write-Output ("MISMATCH   {0}" -f $destination)
    }
    if ($result.Ok) {
        Write-Output 'VERIFY OK'
        exit 0
    }
    Write-Output 'VERIFY FAILED'
    exit 1
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
