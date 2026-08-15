<#
.SYNOPSIS
    Restore a runtime-contract snapshot exactly.

.DESCRIPTION
    Consumes one snapshot directory written by bootstrap/apply-runtime-contract.ps1
    and restores exactly what that snapshot recorded:

      * every managed target, deleting the targets that were previously absent;
      * the byte-exact previous config.yaml;
      * the byte-exact previous Vault index, including its dirty user content;
      * the previous user HONG_VAULT_ROOT value, or its absence.

    Restoring the previous config.yaml also restores the previous plugin
    enablement state and the previous values of the three model keys, because
    those live in that file.

    The snapshot is refused when its schema is unknown, when it was taken for
    different destination roots, when a recorded destination is unsafe, or when
    a recorded hash no longer matches. Routing and cost logs are never read or
    deleted, no unowned file is enumerated, no credential is read, no network
    call is made, and the snapshot is retained as evidence.

    Running it twice in a row is a no-op the second time.

    Targets Windows PowerShell 5.1.

.EXAMPLE
    powershell -File bootstrap/rollback-runtime-contract.ps1 `
        -BackupRoot C:\hermes\backups\hongs-runtime-contract\20260814T101500Z `
        -HermesHome C:\hermes -ClaudeHome C:\claude -CodexHome C:\codex -VaultRoot D:\vault
#>
[CmdletBinding()]
param(
    [string]$BackupRoot,
    [string]$HermesHome,
    [string]$ClaudeHome,
    [string]$CodexHome,
    [string]$VaultRoot,

    # Disposable-test seam, identical to the apply script: when supplied, the
    # user-scope environment variable lives in this JSON store instead of the
    # user registry. A live run omits it.
    [string]$UserEnvironmentStorePath,

    # Load the restore function without running it. The apply script uses this
    # so one implementation serves both the automatic and the explicit path.
    [switch]$LoadOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RollbackSchemaVersion = 2
$script:RollbackKind = 'hongs-runtime-contract-snapshot'
$script:RollbackVaultVariable = 'HONG_VAULT_ROOT'
$script:RollbackTargetRoots = @('HermesHome', 'ClaudeHome', 'CodexHome')
$script:RollbackModelKeys = @('model.default', 'model.provider', 'agent.reasoning_effort')


function ConvertTo-RollbackFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'runtime contract rollback: an empty path was supplied.'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char]'\', [char]'/') }
    return $full
}

function Get-RollbackFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RollbackContainment {
    <# Resolve a root-relative destination and refuse anything that escapes. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Relative)) {
        throw "runtime contract rollback: $Label has an empty destination."
    }
    if ($Relative -match '^[\\/]' -or $Relative -match ':') {
        throw "runtime contract rollback: $Label is not a root-relative destination."
    }
    foreach ($segment in ($Relative -split '[\\/]')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') {
            throw "runtime contract rollback: $Label uses relative traversal."
        }
    }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root ($Relative -replace '/', '\')))
    $prefix = $Root
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "runtime contract rollback: $Label resolves outside its root."
    }
    return $candidate
}

function Assert-RollbackInsideBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = $BackupDirectory
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "runtime contract rollback: $Label resolves outside the snapshot."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "runtime contract rollback: $Label is missing from the snapshot."
    }
    return $full
}

function Get-RollbackUserEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$StorePath
    )

    if ($StorePath) {
        if (Test-Path -LiteralPath $StorePath -PathType Leaf) {
            $store = Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json
            if ($store -and $store.PSObject.Properties[$Name]) {
                return [pscustomobject]@{ IsSet = [bool]$store.$Name.set; Value = $store.$Name.value }
            }
        }
        return [pscustomobject]@{ IsSet = $false; Value = $null }
    }
    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    return [pscustomobject]@{ IsSet = ($null -ne $value); Value = $value }
}

function Set-RollbackUserEnvironment {
    <# Restore a recorded value. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [AllowEmptyString()][string]$StorePath
    )

    if ($StorePath) {
        $store = $null
        if (Test-Path -LiteralPath $StorePath -PathType Leaf) {
            $store = Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json
        }
        if (-not $store) { $store = [pscustomobject]@{} }
        $store | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{ set = $true; value = $Value }) -Force
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($StorePath, (($store | ConvertTo-Json -Depth 6) + "`n"), $encoding)
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Remove-RollbackUserEnvironment {
    <# Remove the variable, because the snapshot recorded it as unset. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$StorePath
    )

    if ($StorePath) {
        if (Test-Path -LiteralPath $StorePath -PathType Leaf) {
            $store = Get-Content -LiteralPath $StorePath -Raw | ConvertFrom-Json
            if ($store -and $store.PSObject.Properties[$Name]) {
                $store.PSObject.Properties.Remove($Name)
            }
            if (-not $store -or @($store.PSObject.Properties).Count -eq 0) {
                Remove-Item -LiteralPath $StorePath -Force -Confirm:$false
            }
            else {
                $encoding = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($StorePath, (($store | ConvertTo-Json -Depth 6) + "`n"), $encoding)
            }
        }
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    }
    [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
}

function Assert-RollbackProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not $Object.PSObject.Properties[$Name]) {
        throw "runtime contract rollback: the snapshot $Label has no '$Name'."
    }
    return $Object.$Name
}

function Get-RuntimeContractSnapshotPlan {
    <#
    .SYNOPSIS
        Validate one snapshot and return the exact restore plan. Pure: reads,
        resolves, and hashes only. It writes nothing and mutates nothing, so the
        apply script can prove a snapshot is restorable before it mutates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][string]$HermesHomePath,
        [Parameter(Mandatory = $true)][string]$ClaudeHomePath,
        [Parameter(Mandatory = $true)][string]$CodexHomePath,
        [Parameter(Mandatory = $true)][string]$VaultRootPath
    )

    $backup = ConvertTo-RollbackFullPath -Path $BackupDirectory
    if (-not (Test-Path -LiteralPath $backup -PathType Container)) {
        throw 'runtime contract rollback: the snapshot directory does not exist.'
    }
    $statePath = Join-Path $backup 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'runtime contract rollback: the snapshot has no state.json.'
    }
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { throw 'runtime contract rollback: state.json is not valid JSON.' }
    if ($null -eq $state) { throw 'runtime contract rollback: state.json is empty.' }
    if ([string](Assert-RollbackProperty -Object $state -Name 'kind' -Label 'state') -ne $script:RollbackKind) {
        throw 'runtime contract rollback: state.json is not a runtime-contract snapshot.'
    }
    if ([int](Assert-RollbackProperty -Object $state -Name 'schemaVersion' -Label 'state') -ne $script:RollbackSchemaVersion) {
        throw 'runtime contract rollback: the snapshot schema version is not supported.'
    }
    foreach ($required in @('roots', 'environment', 'config', 'vaultIndex', 'managed', 'modelKeys')) {
        [void](Assert-RollbackProperty -Object $state -Name $required -Label 'state')
    }

    $roots = @{
        'HermesHome' = ConvertTo-RollbackFullPath -Path $HermesHomePath
        'ClaudeHome' = ConvertTo-RollbackFullPath -Path $ClaudeHomePath
        'CodexHome'  = ConvertTo-RollbackFullPath -Path $CodexHomePath
    }
    $vaultReal = ConvertTo-RollbackFullPath -Path $VaultRootPath
    $recorded = @{
        'HermesHome' = [string](Assert-RollbackProperty -Object $state.roots -Name 'hermesHome' -Label 'roots')
        'ClaudeHome' = [string](Assert-RollbackProperty -Object $state.roots -Name 'claudeHome' -Label 'roots')
        'CodexHome'  = [string](Assert-RollbackProperty -Object $state.roots -Name 'codexHome' -Label 'roots')
    }
    foreach ($name in $script:RollbackTargetRoots) {
        if (-not [string]::Equals($roots[$name], (ConvertTo-RollbackFullPath -Path $recorded[$name]), [StringComparison]::OrdinalIgnoreCase)) {
            throw "runtime contract rollback: the snapshot was taken for a different $name."
        }
    }
    $recordedVault = ConvertTo-RollbackFullPath -Path ([string](Assert-RollbackProperty -Object $state.roots -Name 'vaultRoot' -Label 'roots'))
    if (-not [string]::Equals($vaultReal, $recordedVault, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'runtime contract rollback: the snapshot was taken for a different Vault root.'
    }

    $managed = New-Object System.Collections.ArrayList
    foreach ($record in @($state.managed)) {
        $targetRoot = [string](Assert-RollbackProperty -Object $record -Name 'targetRoot' -Label 'managed record')
        if ($script:RollbackTargetRoots -notcontains $targetRoot) {
            throw "runtime contract rollback: the snapshot names unknown target root '$targetRoot'."
        }
        $destination = [string](Assert-RollbackProperty -Object $record -Name 'destination' -Label 'managed record')
        $existed = [bool](Assert-RollbackProperty -Object $record -Name 'existed' -Label 'managed record')
        $targetPath = Assert-RollbackContainment -Root $roots[$targetRoot] -Relative $destination -Label "destination '$destination'"
        $sourcePath = $null
        if ($existed) {
            $candidate = Join-Path (Join-Path (Join-Path $backup 'files') $targetRoot) ($destination -replace '/', '\')
            $sourcePath = Assert-RollbackInsideBackup -BackupDirectory $backup -Path $candidate -Label "backup of '$destination'"
            $expected = [string](Assert-RollbackProperty -Object $record -Name 'sha256' -Label 'managed record')
            if ((Get-RollbackFileSha256 -Path $sourcePath) -ne $expected.ToLowerInvariant()) {
                throw "runtime contract rollback: the backup of '$destination' does not match its recorded hash."
            }
        }
        [void]$managed.Add([pscustomobject]@{ Existed = $existed; SourcePath = $sourcePath; TargetPath = $targetPath })
    }

    $configRelative = [string](Assert-RollbackProperty -Object $state.config -Name 'relative' -Label 'config record')
    $configTarget = Assert-RollbackContainment -Root $roots['HermesHome'] -Relative $configRelative -Label 'the configuration file'
    $configSource = Assert-RollbackInsideBackup -BackupDirectory $backup `
        -Path (Join-Path (Join-Path $backup 'config') ($configRelative -replace '/', '\')) -Label 'the configuration backup'
    $configHash = ([string](Assert-RollbackProperty -Object $state.config -Name 'sha256' -Label 'config record')).ToLowerInvariant()
    if ((Get-RollbackFileSha256 -Path $configSource) -ne $configHash) {
        throw 'runtime contract rollback: the configuration backup does not match its recorded hash.'
    }

    $indexRelative = [string](Assert-RollbackProperty -Object $state.vaultIndex -Name 'relative' -Label 'Vault index record')
    $indexTarget = Assert-RollbackContainment -Root $vaultReal -Relative $indexRelative -Label 'the Vault index'
    $indexSource = Assert-RollbackInsideBackup -BackupDirectory $backup `
        -Path (Join-Path (Join-Path $backup 'vault') ($indexRelative -replace '/', '\')) -Label 'the Vault index backup'
    $indexHash = ([string](Assert-RollbackProperty -Object $state.vaultIndex -Name 'sha256' -Label 'Vault index record')).ToLowerInvariant()
    if ((Get-RollbackFileSha256 -Path $indexSource) -ne $indexHash) {
        throw 'runtime contract rollback: the Vault index backup does not match its recorded hash.'
    }

    $modelKeys = New-Object System.Collections.ArrayList
    $recordedKeys = @($state.modelKeys)
    if ($recordedKeys.Count -ne $script:RollbackModelKeys.Count) {
        throw 'runtime contract rollback: the snapshot does not record exactly the three approved model keys.'
    }
    for ($index = 0; $index -lt $script:RollbackModelKeys.Count; $index++) {
        $record = $recordedKeys[$index]
        $key = [string](Assert-RollbackProperty -Object $record -Name 'key' -Label 'model key record')
        if ($key -cne $script:RollbackModelKeys[$index]) {
            throw 'runtime contract rollback: the snapshot records the model keys in an unapproved order.'
        }
        [void]$modelKeys.Add([pscustomobject]@{
                Key     = $key
                Existed = [bool](Assert-RollbackProperty -Object $record -Name 'existed' -Label 'model key record')
                Value   = [string](Assert-RollbackProperty -Object $record -Name 'value' -Label 'model key record')
            })
    }

    return [pscustomobject]@{
        BackupRoot        = $backup
        Managed           = @($managed.ToArray())
        ConfigSource      = $configSource
        ConfigTarget      = $configTarget
        ConfigSha256      = $configHash
        IndexSource       = $indexSource
        IndexTarget       = $indexTarget
        IndexSha256       = $indexHash
        ModelKeys         = @($modelKeys.ToArray())
        EnvironmentWasSet = [bool](Assert-RollbackProperty -Object $state.environment -Name 'wasSet' -Label 'environment record')
        EnvironmentValue  = [string](Assert-RollbackProperty -Object $state.environment -Name 'value' -Label 'environment record')
    }
}

function Invoke-RuntimeContractRollback {
    <#
    .SYNOPSIS
        Restore one snapshot exactly and return a categorical summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BackupDirectory,
        [Parameter(Mandatory = $true)][string]$HermesHomePath,
        [Parameter(Mandatory = $true)][string]$ClaudeHomePath,
        [Parameter(Mandatory = $true)][string]$CodexHomePath,
        [Parameter(Mandatory = $true)][string]$VaultRootPath,
        [AllowEmptyString()][string]$EnvironmentStorePath
    )

    $plan = Get-RuntimeContractSnapshotPlan -BackupDirectory $BackupDirectory -HermesHomePath $HermesHomePath `
        -ClaudeHomePath $ClaudeHomePath -CodexHomePath $CodexHomePath -VaultRootPath $VaultRootPath

    # Restore. Every write is a recorded artifact; nothing else is touched.
    $restored = 0
    $removed = 0
    foreach ($item in $plan.Managed) {
        if ($item.Existed) {
            $parent = Split-Path -Parent $item.TargetPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $parent -Force)
            }
            Copy-Item -LiteralPath $item.SourcePath -Destination $item.TargetPath -Force
            if ((Get-RollbackFileSha256 -Path $item.TargetPath) -ne (Get-RollbackFileSha256 -Path $item.SourcePath)) {
                throw 'runtime contract rollback: a restored managed file does not match its backup.'
            }
            $restored++
        }
        elseif (Test-Path -LiteralPath $item.TargetPath -PathType Leaf) {
            Remove-Item -LiteralPath $item.TargetPath -Force -Confirm:$false
            $removed++
        }
    }

    Copy-Item -LiteralPath $plan.ConfigSource -Destination $plan.ConfigTarget -Force
    if ((Get-RollbackFileSha256 -Path $plan.ConfigTarget) -ne $plan.ConfigSha256) {
        throw 'runtime contract rollback: the restored configuration does not match its recorded hash.'
    }
    Copy-Item -LiteralPath $plan.IndexSource -Destination $plan.IndexTarget -Force
    if ((Get-RollbackFileSha256 -Path $plan.IndexTarget) -ne $plan.IndexSha256) {
        throw 'runtime contract rollback: the restored Vault index does not match its recorded hash.'
    }

    if ($plan.EnvironmentWasSet) {
        Set-RollbackUserEnvironment -Name $script:RollbackVaultVariable -Value $plan.EnvironmentValue -StorePath $EnvironmentStorePath
    }
    else {
        Remove-RollbackUserEnvironment -Name $script:RollbackVaultVariable -StorePath $EnvironmentStorePath
    }

    return [pscustomobject]@{
        Restored        = $restored
        Removed         = $removed
        EnvironmentKept = $plan.EnvironmentWasSet
        BackupRoot      = $plan.BackupRoot
    }
}


if ($LoadOnly) { return }

try {
    foreach ($pair in @(
            @{ Name = '-BackupRoot'; Value = $BackupRoot },
            @{ Name = '-HermesHome'; Value = $HermesHome },
            @{ Name = '-ClaudeHome'; Value = $ClaudeHome },
            @{ Name = '-CodexHome'; Value = $CodexHome },
            @{ Name = '-VaultRoot'; Value = $VaultRoot })) {
        if ([string]::IsNullOrWhiteSpace($pair.Value)) {
            Write-Error ('runtime contract rollback: {0} is required.' -f $pair.Name) -ErrorAction Continue
            exit 2
        }
    }

    $result = Invoke-RuntimeContractRollback -BackupDirectory $BackupRoot -HermesHomePath $HermesHome `
        -ClaudeHomePath $ClaudeHome -CodexHomePath $CodexHome -VaultRootPath $VaultRoot `
        -EnvironmentStorePath $UserEnvironmentStorePath

    Write-Output ('ROLLED BACK the runtime contract: {0} managed file(s) restored, {1} removed, configuration and Vault index restored.' -f `
            $result.Restored, $result.Removed)
    Write-Output ('{0} restored to its previous state (value redacted).' -f $script:RollbackVaultVariable)
    Write-Output ('Snapshot retained as evidence: {0}' -f $result.BackupRoot)
    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
