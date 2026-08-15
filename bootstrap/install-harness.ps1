<#
.SYNOPSIS
    Dry-run or apply the managed global agent harness.

.DESCRIPTION
    -DryRun validates the manifest and prints the managed actions. It copies
    nothing, backs up nothing, changes no configuration, and makes no network,
    git, or agent-CLI call.

    -Apply performs the rollback-safe install described in HarnessInstaller.psm1.
    Applying to a live home is a user-approved gate, not a routine step.

.EXAMPLE
    powershell -File bootstrap/install-harness.ps1 -DryRun `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude -CodexHome C:\codex

.EXAMPLE
    powershell -File bootstrap/install-harness.ps1 -Apply `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude -CodexHome C:\codex
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$HermesHome,
    [Parameter(Mandatory = $true)][string]$ClaudeHome,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [string]$ManifestPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($DryRun -and $Apply) {
    Write-Error 'Specify exactly one of -DryRun or -Apply.'
    exit 2
}
if (-not $DryRun -and -not $Apply) {
    Write-Error 'Specify exactly one of -DryRun or -Apply.'
    exit 2
}

Import-Module (Join-Path $PSScriptRoot 'HarnessInstaller.psm1') -Force

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $RepositoryRoot 'manifest\harness-manifest.json'
}

try {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found at '$ManifestPath'. Build it first: python scripts/build-harness-manifest.py --root <repo> --output manifest/harness-manifest.json"
    }

    $manifest = Test-HarnessManifest -Path $ManifestPath

    if ($DryRun) {
        $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $RepositoryRoot `
            -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome
        Write-Output "DRY RUN - no file was copied, backed up, or modified."
        Write-Output "Manifest: $ManifestPath"
        foreach ($action in $plan) {
            Write-Output ("{0,-7} {1,-10} {2}" -f $action.Action, $action.TargetRoot, $action.Destination)
        }
        Write-Output ("Managed actions: {0} (create {1}, replace {2})" -f `
                $plan.Count, `
            @($plan | Where-Object { $_.Action -eq 'Create' }).Count, `
            @($plan | Where-Object { $_.Action -eq 'Replace' }).Count)
        exit 0
    }

    $result = Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $RepositoryRoot `
        -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome
    Write-Output ("APPLIED {0} managed file(s) (create {1}, replace {2})." -f `
            $result.Applied, $result.Created, $result.Replaced)
    Write-Output ("Backup root: {0}" -f $result.BackupRoot)
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
