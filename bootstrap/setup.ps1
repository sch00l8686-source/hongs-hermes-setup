<#
.SYNOPSIS
    One-command install of the global agent harness on a fresh PC.

.DESCRIPTION
    Resolves everything install-harness.ps1 needs, so no path has to be typed:

      * RepositoryRoot -- the repository this script sits in when run from an
        extracted ZIP or clone; otherwise the current main.zip is downloaded
        from GitHub and extracted to a temporary directory.
      * HermesHome     -- %LOCALAPPDATA%\hermes
      * ClaudeHome     -- %USERPROFILE%\.claude
      * CodexHome      -- %USERPROFILE%\.codex

    Every path can still be overridden with the matching parameter.

    The script then shows the installer's dry-run plan and asks for one
    confirmation before applying. -Apply skips the prompt; -DryRunOnly stops
    after the plan. All copy, backup, and rollback behaviour is the existing
    install-harness.ps1 / HarnessInstaller.psm1 -- this wrapper adds no install
    logic of its own.

    Targets Windows PowerShell 5.1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap\setup.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File bootstrap\setup.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$HermesHome,
    [string]$ClaudeHome,
    [string]$CodexHome,
    [switch]$Apply,
    [switch]$DryRunOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ArchiveUrl = 'https://github.com/sch00l8686-source/hongs-hermes-setup/archive/refs/heads/main.zip'

if ([string]::IsNullOrWhiteSpace($HermesHome)) { $HermesHome = Join-Path $env:LOCALAPPDATA 'hermes' }
if ([string]::IsNullOrWhiteSpace($ClaudeHome)) { $ClaudeHome = Join-Path $env:USERPROFILE '.claude' }
if ([string]::IsNullOrWhiteSpace($CodexHome)) { $CodexHome = Join-Path $env:USERPROFILE '.codex' }

# Resolve the repository root: prefer the tree this script was extracted into.
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $localRoot = Split-Path -Parent $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $localRoot 'manifest\harness-manifest.json') -PathType Leaf) {
        $RepositoryRoot = $localRoot
    }
    else {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        $downloadRoot = Join-Path $env:TEMP ("hongs-hermes-setup-" + $stamp)
        $zipPath = Join-Path $downloadRoot 'main.zip'
        New-Item -ItemType Directory -Path $downloadRoot | Out-Null
        Write-Output "Downloading $ArchiveUrl"
        Invoke-WebRequest -Uri $ArchiveUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $downloadRoot
        $extracted = Get-ChildItem -LiteralPath $downloadRoot -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest\harness-manifest.json') -PathType Leaf } |
            Select-Object -First 1
        if ($null -eq $extracted) {
            Write-Error 'The downloaded archive does not contain a harness manifest.'
            exit 2
        }
        $RepositoryRoot = $extracted.FullName
        Write-Output "Extracted to $RepositoryRoot"
    }
}

$installer = Join-Path $RepositoryRoot 'bootstrap\install-harness.ps1'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    Write-Error "Installer not found at '$installer'."
    exit 2
}

Write-Output "Repository root: $RepositoryRoot"
Write-Output "Hermes home:     $HermesHome"
Write-Output "Claude home:     $ClaudeHome"
Write-Output "Codex home:      $CodexHome"
Write-Output ''

& powershell -NoProfile -ExecutionPolicy Bypass -File $installer -DryRun `
    -RepositoryRoot $RepositoryRoot -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome
if ($LASTEXITCODE -ne 0) {
    Write-Error "Dry run failed (exit $LASTEXITCODE); nothing was installed."
    exit $LASTEXITCODE
}

if ($DryRunOnly) {
    Write-Output 'Dry run only: nothing was installed.'
    exit 0
}

if (-not $Apply) {
    $answer = Read-Host 'Apply these managed files to this PC? (y/N)'
    if ($answer -notmatch '^[Yy]') {
        Write-Output 'Cancelled: nothing was installed.'
        exit 0
    }
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Apply `
    -RepositoryRoot $RepositoryRoot -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome
exit $LASTEXITCODE
