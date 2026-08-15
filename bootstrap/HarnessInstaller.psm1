<#
.SYNOPSIS
    Rollback-safe installer for the managed global agent harness.

.DESCRIPTION
    The module copies an explicit, manifest-declared set of managed files from
    the repository baseline into three destination roots: HermesHome (SOUL.md,
    skills/, and the three hongs-vault-router plugin files), ClaudeHome
    (CLAUDE.md), and CodexHome (AGENTS.md).

    Design rules enforced here:

      * Sources are always repository-relative paths under baseline/.
      * Destinations are always root-relative and restricted to the approved
        managed set; traversal, absolute, UNC, device, and reparse-traversal
        destinations are rejected before any write.
      * A dry run validates and prints; it copies nothing, backs up nothing,
        changes no configuration, and touches no network, git, or agent CLI.
      * An apply hashes every source, stages every source, backs up every
        existing managed target, copies only managed files, verifies the
        written hashes, and rolls every write back if any step fails.
      * Unowned files inside the destination roots are never enumerated,
        modified, or removed. Credentials and runtime databases are never read.

    Targets Windows PowerShell 5.1.
#>

Set-StrictMode -Version 2.0

$script:HarnessSchemaVersion = 1

$script:HarnessTargetRoots = @('HermesHome', 'ClaudeHome', 'CodexHome')

# The managed skill packages: the twenty approved public-snapshot skills plus
# the preserved software-development/plan adapter. A package that is not spelled
# out here is not an approved destination, whatever a manifest claims.
$script:HarnessApprovedSkills = @(
    'superpowers/using-superpowers',
    'superpowers/brainstorming',
    'superpowers/writing-plans',
    'superpowers/executing-plans',
    'superpowers/subagent-driven-development',
    'superpowers/dispatching-parallel-agents',
    'superpowers/verification-before-completion',
    'superpowers/finishing-a-development-branch',
    'superpowers/receiving-code-review',
    'superpowers/using-git-worktrees',
    'software-development/plan',
    'autonomous-ai-agents/supervised-agent-workflow',
    'autonomous-ai-agents/mixed-model-agent-orchestration',
    'autonomous-ai-agents/subagent-coding-context',
    'autonomous-ai-agents/agent-context-efficiency',
    'autonomous-ai-agents/agent-context-governance',
    'autonomous-ai-agents/review-gated-config-distribution',
    'note-taking/obsidian-vault-ingest',
    'note-taking/obsidian-vault-lint',
    'note-taking/obsidian-vault-query',
    'automation/execution-continuity'
)

# The only plugin destinations the harness may install, spelled out in full.
# A sibling plugin, an extra file inside this plugin's directory, and the
# directory itself are all outside the managed set.
$script:HarnessApprovedPluginFiles = @(
    'plugins/hongs-vault-router/__init__.py',
    'plugins/hongs-vault-router/plugin.yaml',
    'plugins/hongs-vault-router/router.py'
)

$script:HarnessRecordKeys = @('source', 'targetRoot', 'destination', 'sha256')

$script:HarnessBackupSegment = 'backups\hongs-global-harness'


# --------------------------------------------------------------------------
# Path helpers
# --------------------------------------------------------------------------

function ConvertTo-HarnessFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'HarnessInstaller: an empty path was supplied.'
    }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) {
        $full = $full.TrimEnd([char]'\', [char]'/')
    }
    return $full
}

function Resolve-HarnessRootIdentity {
    <#
        Returns the real path of a destination root. If the root itself is a
        reparse point it is resolved once, so the root's own identity is
        preserved rather than treated as a traversal violation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = ConvertTo-HarnessFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $full)) {
        return $full
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        $target = $null
        if ($item.PSObject.Properties['Target'] -and $item.Target) {
            $target = @($item.Target)[0]
        }
        if ($target) {
            return ConvertTo-HarnessFullPath -Path $target
        }
    }
    return ConvertTo-HarnessFullPath -Path $item.FullName
}

function Test-HarnessRelativeDestination {
    <#
        Static destination shape check. Throws with an explicit reason for
        traversal, absolute, UNC, device, and alternate-data-stream forms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        throw "HarnessInstaller: $Label has an empty destination."
    }
    if ($Destination -match '^\\\\') {
        throw "HarnessInstaller: $Label uses a UNC destination."
    }
    if ($Destination -match '^[\\/]{1,2}[\?\.][\\/]') {
        throw "HarnessInstaller: $Label uses a device-namespace destination."
    }
    if ($Destination -match '^[A-Za-z]:') {
        throw "HarnessInstaller: $Label uses an absolute destination."
    }
    if ($Destination -match '^[\\/]') {
        throw "HarnessInstaller: $Label uses a root-anchored destination."
    }
    if ($Destination -match ':') {
        throw "HarnessInstaller: $Label destination contains a drive or stream separator."
    }
    foreach ($segment in ($Destination -split '[\\/]')) {
        if ($segment -eq '') {
            throw "HarnessInstaller: $Label destination has an empty path segment."
        }
        if ($segment -eq '.' -or $segment -eq '..') {
            throw "HarnessInstaller: $Label destination uses relative traversal."
        }
    }
    return $true
}

function Test-HarnessApprovedDestination {
    <#
        Destinations are limited to SOUL.md, the three managed plugin files,
        the twenty-one approved skill trees, CLAUDE.md, and AGENTS.md.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $normalized = $Destination -replace '\\', '/'
    switch ($TargetRoot) {
        'ClaudeHome' {
            if ($normalized -ne 'CLAUDE.md') {
                throw "HarnessInstaller: $Label destination is not managed under ClaudeHome."
            }
            return $true
        }
        'CodexHome' {
            if ($normalized -ne 'AGENTS.md') {
                throw "HarnessInstaller: $Label destination is not managed under CodexHome."
            }
            return $true
        }
        'HermesHome' {
            if ($normalized -eq 'SOUL.md') { return $true }
            foreach ($plugin in $script:HarnessApprovedPluginFiles) {
                if ([string]::Equals($normalized, $plugin, [StringComparison]::Ordinal)) {
                    return $true
                }
            }
            foreach ($skill in $script:HarnessApprovedSkills) {
                if ($normalized.StartsWith("skills/$skill/", [StringComparison]::Ordinal)) {
                    return $true
                }
            }
            throw "HarnessInstaller: $Label destination is not an approved managed path."
        }
        default {
            throw "HarnessInstaller: $Label uses unknown target root '$TargetRoot'."
        }
    }
}

function Assert-HarnessContainment {
    <#
        Resolves a root-relative destination against a real root and rejects any
        path that escapes the root or traverses an existing reparse point.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootReal,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $RootReal $Destination))
    $prefix = $RootReal
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $prefix = $prefix + [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HarnessInstaller: $Label resolves outside its target root."
    }

    $current = Split-Path -Parent $candidate
    while ($current -and $current.Length -ge $RootReal.Length) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "HarnessInstaller: $Label traverses a reparse point."
            }
        }
        if ($current -eq $RootReal) { break }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }

    if (Test-Path -LiteralPath $candidate) {
        $leaf = Get-Item -LiteralPath $candidate -Force
        if ($leaf.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "HarnessInstaller: $Label is an existing reparse point."
        }
        if ($leaf.PSIsContainer) {
            throw "HarnessInstaller: $Label already exists as a directory."
        }
    }

    return $candidate
}

function Get-HarnessFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}


# --------------------------------------------------------------------------
# Manifest validation
# --------------------------------------------------------------------------

function Test-HarnessManifest {
    <#
    .SYNOPSIS
        Validate a harness manifest and return its normalised records.

    .DESCRIPTION
        Rejects an unknown schema version, unknown or missing record keys,
        unknown target roots, non-baseline sources, malformed hashes, unmanaged
        or unsafe destinations, and duplicate (targetRoot, destination) pairs.
        Throws on the first violation. Returns the normalised manifest object.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'Object')]
        [object]$Manifest
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "HarnessInstaller: manifest not found at '$Path'."
        }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        try {
            $Manifest = $raw | ConvertFrom-Json
        }
        catch {
            throw "HarnessInstaller: manifest at '$Path' is not valid JSON."
        }
    }

    if ($null -eq $Manifest) {
        throw 'HarnessInstaller: manifest is empty.'
    }
    if (-not $Manifest.PSObject.Properties['schemaVersion']) {
        throw 'HarnessInstaller: manifest has no schemaVersion.'
    }
    if ([int]$Manifest.schemaVersion -ne $script:HarnessSchemaVersion) {
        throw "HarnessInstaller: unsupported manifest schemaVersion '$($Manifest.schemaVersion)'."
    }
    if (-not $Manifest.PSObject.Properties['files']) {
        throw 'HarnessInstaller: manifest has no files array.'
    }
    $records = @($Manifest.files)
    if ($records.Count -eq 0) {
        throw 'HarnessInstaller: manifest declares no managed files.'
    }

    $seen = @{}
    $index = 0
    foreach ($record in $records) {
        $label = "record $index"
        $index++

        $presentKeys = @($record.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($key in $presentKeys) {
            if ($script:HarnessRecordKeys -notcontains $key) {
                throw "HarnessInstaller: $label has unknown key '$key'."
            }
        }
        foreach ($key in $script:HarnessRecordKeys) {
            if ($presentKeys -notcontains $key) {
                throw "HarnessInstaller: $label is missing key '$key'."
            }
        }

        if ($script:HarnessTargetRoots -notcontains $record.targetRoot) {
            throw "HarnessInstaller: $label uses unknown target root '$($record.targetRoot)'."
        }

        $source = [string]$record.source
        if ([string]::IsNullOrWhiteSpace($source)) {
            throw "HarnessInstaller: $label has an empty source."
        }
        $normalizedSource = $source -replace '\\', '/'
        if (-not $normalizedSource.StartsWith('baseline/', [StringComparison]::Ordinal)) {
            throw "HarnessInstaller: $label source is outside baseline/."
        }
        foreach ($segment in ($normalizedSource -split '/')) {
            if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') {
                throw "HarnessInstaller: $label source uses relative traversal."
            }
        }
        if ($normalizedSource -match ':') {
            throw "HarnessInstaller: $label source is not repository-relative."
        }

        if ([string]$record.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "HarnessInstaller: $label has a malformed sha256."
        }

        [void](Test-HarnessRelativeDestination -Destination ([string]$record.destination) -Label $label)
        [void](Test-HarnessApprovedDestination -TargetRoot ([string]$record.targetRoot) `
                -Destination ([string]$record.destination) -Label $label)

        $key = '{0}::{1}' -f $record.targetRoot, (([string]$record.destination) -replace '\\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw "HarnessInstaller: duplicate destination '$($record.destination)' under $($record.targetRoot)."
        }
        $seen[$key] = $true
    }

    return $Manifest
}


# --------------------------------------------------------------------------
# Plan construction
# --------------------------------------------------------------------------

function New-HarnessInstallPlan {
    <#
    .SYNOPSIS
        Build the managed action list for a manifest without touching targets.

    .DESCRIPTION
        Validates the manifest, resolves every source under the repository root,
        resolves every destination inside its target root with containment and
        reparse checks, and classifies each action as Create or Replace. No file
        is written, copied, or backed up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$ClaudeHome,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    $validated = Test-HarnessManifest -Manifest $Manifest

    $repoReal = ConvertTo-HarnessFullPath -Path $RepositoryRoot
    if (-not (Test-Path -LiteralPath $repoReal -PathType Container)) {
        throw "HarnessInstaller: repository root '$RepositoryRoot' does not exist."
    }

    $roots = @{
        'HermesHome' = Resolve-HarnessRootIdentity -Path $HermesHome
        'ClaudeHome' = Resolve-HarnessRootIdentity -Path $ClaudeHome
        'CodexHome'  = Resolve-HarnessRootIdentity -Path $CodexHome
    }

    $actions = New-Object System.Collections.ArrayList
    foreach ($record in @($validated.files)) {
        $sourceRelative = ([string]$record.source) -replace '/', '\'
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $repoReal $sourceRelative))
        $repoPrefix = $repoReal
        if (-not $repoPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
            $repoPrefix += [System.IO.Path]::DirectorySeparatorChar
        }
        if (-not $sourcePath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "HarnessInstaller: source '$($record.source)' resolves outside the repository root."
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "HarnessInstaller: source '$($record.source)' does not exist."
        }

        $rootReal = $roots[[string]$record.targetRoot]
        $destinationRelative = ([string]$record.destination) -replace '/', '\'
        $targetPath = Assert-HarnessContainment -RootReal $rootReal `
            -Destination $destinationRelative -Label "destination '$($record.destination)'"

        $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
        [void]$actions.Add([pscustomobject]@{
                TargetRoot          = [string]$record.targetRoot
                TargetRootPath      = $rootReal
                Source              = [string]$record.source
                SourcePath          = $sourcePath
                Destination         = [string]$record.destination
                TargetPath          = $targetPath
                ExpectedSha256      = ([string]$record.sha256).ToLowerInvariant()
                Action              = if ($exists) { 'Replace' } else { 'Create' }
                BackupRequired      = [bool]$exists
            })
    }

    return $actions.ToArray()
}


# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------

function New-HarnessDirectory {
    <#
        Creates a directory chain and records only the directories this call
        actually created, so rollback removes nothing that pre-existed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$CreatedDirectories
    )

    if (Test-Path -LiteralPath $Path -PathType Container) { return }

    $missing = New-Object System.Collections.ArrayList
    $current = $Path
    while ($current -and -not (Test-Path -LiteralPath $current)) {
        [void]$missing.Insert(0, $current)
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
    foreach ($directory in $missing) {
        [void](New-Item -ItemType Directory -Path $directory -Force:$false)
        [void]$CreatedDirectories.Add($directory)
    }
}

function Invoke-HarnessRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$WriteLog,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.ArrayList]$CreatedDirectories
    )

    $problems = New-Object System.Collections.ArrayList
    for ($i = $WriteLog.Count - 1; $i -ge 0; $i--) {
        $entry = $WriteLog[$i]
        try {
            if ($entry.Kind -eq 'Replace') {
                Copy-Item -LiteralPath $entry.BackupPath -Destination $entry.TargetPath -Force
            }
            else {
                if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
                    Remove-Item -LiteralPath $entry.TargetPath -Force -Confirm:$false
                }
            }
        }
        catch {
            [void]$problems.Add("$($entry.TargetPath): $($_.Exception.Message)")
        }
    }
    for ($i = $CreatedDirectories.Count - 1; $i -ge 0; $i--) {
        $directory = $CreatedDirectories[$i]
        try {
            if (Test-Path -LiteralPath $directory -PathType Container) {
                $remaining = @(Get-ChildItem -LiteralPath $directory -Force)
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $directory -Force -Confirm:$false
                }
            }
        }
        catch {
            [void]$problems.Add("$directory : $($_.Exception.Message)")
        }
    }
    return $problems.ToArray()
}

function Invoke-HarnessApply {
    <#
    .SYNOPSIS
        Apply the managed harness files with backup, hash verification, and
        full rollback on any failure.

    .DESCRIPTION
        Order of operations:
          1. Validate the manifest and build the action plan (no writes).
          2. Hash every source in place and compare it to the manifest. A single
             mismatch aborts before any write.
          3. Stage every source under HermesHome\backups\hongs-global-harness\<UTC>\.staging
             and re-hash the staged copies.
          4. Back up every existing managed target under that same timestamped
             directory.
          5. Copy managed files only, from the staging copy.
          6. Verify every written destination hash.
        Any failure from step 3 onward restores every backed-up file, removes
        every file this call created, and removes only the directories this call
        created. The timestamped backup directory is deliberately retained.

    .PARAMETER FailAfterDestination
        Test hook. Raises a synthetic failure immediately after the named
        destination has been written, to exercise the rollback path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$ClaudeHome,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [string]$BackupTimestamp,
        [string]$FailAfterDestination
    )

    $plan = New-HarnessInstallPlan -Manifest $Manifest -RepositoryRoot $RepositoryRoot `
        -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome

    # Step 2: hash sources in place. No write has happened yet.
    foreach ($action in $plan) {
        $actual = Get-HarnessFileSha256 -Path $action.SourcePath
        if ($actual -ne $action.ExpectedSha256) {
            throw "HarnessInstaller: source hash mismatch for '$($action.Source)'; no files were written."
        }
    }

    if ([string]::IsNullOrWhiteSpace($BackupTimestamp)) {
        $BackupTimestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    }

    $hermesReal = Resolve-HarnessRootIdentity -Path $HermesHome
    $backupRoot = Join-Path (Join-Path $hermesReal $script:HarnessBackupSegment) $BackupTimestamp
    $stagingRoot = Join-Path $backupRoot '.staging'
    $backupFilesRoot = Join-Path $backupRoot 'files'

    $writeLog = New-Object System.Collections.ArrayList
    $createdDirectories = New-Object System.Collections.ArrayList
    $stagedPaths = @{}

    try {
        # Step 3: stage and re-hash.
        foreach ($action in $plan) {
            $stagedPath = Join-Path (Join-Path $stagingRoot $action.TargetRoot) ($action.Destination -replace '/', '\')
            New-HarnessDirectory -Path (Split-Path -Parent $stagedPath) -CreatedDirectories $createdDirectories
            Copy-Item -LiteralPath $action.SourcePath -Destination $stagedPath -Force
            $stagedHash = Get-HarnessFileSha256 -Path $stagedPath
            if ($stagedHash -ne $action.ExpectedSha256) {
                throw "HarnessInstaller: staged hash mismatch for '$($action.Source)'."
            }
            $stagedPaths[$action.TargetPath] = $stagedPath
        }

        # Steps 4 and 5: back up, then copy managed files only.
        foreach ($action in $plan) {
            if ($action.BackupRequired) {
                $backupPath = Join-Path (Join-Path $backupFilesRoot $action.TargetRoot) ($action.Destination -replace '/', '\')
                New-HarnessDirectory -Path (Split-Path -Parent $backupPath) -CreatedDirectories $createdDirectories
                Copy-Item -LiteralPath $action.TargetPath -Destination $backupPath -Force
            }
            else {
                $backupPath = $null
            }

            New-HarnessDirectory -Path (Split-Path -Parent $action.TargetPath) -CreatedDirectories $createdDirectories
            Copy-Item -LiteralPath $stagedPaths[$action.TargetPath] -Destination $action.TargetPath -Force
            [void]$writeLog.Add([pscustomobject]@{
                    Kind       = if ($action.BackupRequired) { 'Replace' } else { 'Create' }
                    TargetPath = $action.TargetPath
                    BackupPath = $backupPath
                })

            if ($FailAfterDestination -and $action.Destination -eq $FailAfterDestination) {
                throw "HarnessInstaller: induced failure after writing '$($action.Destination)'."
            }
        }

        # Step 6: verify every written destination.
        foreach ($action in $plan) {
            $written = Get-HarnessFileSha256 -Path $action.TargetPath
            if ($written -ne $action.ExpectedSha256) {
                throw "HarnessInstaller: written hash mismatch for '$($action.Destination)'."
            }
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackProblems = Invoke-HarnessRollback -WriteLog $writeLog -CreatedDirectories $createdDirectories
        if ($rollbackProblems.Count -gt 0) {
            throw "HarnessInstaller: apply failed ($failure) and rollback was incomplete: $($rollbackProblems -join '; ')"
        }
        throw "HarnessInstaller: apply failed and was rolled back. $failure"
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -Confirm:$false
        }
    }

    return [pscustomobject]@{
        Applied     = $plan.Count
        Created     = @($plan | Where-Object { $_.Action -eq 'Create' }).Count
        Replaced    = @($plan | Where-Object { $_.Action -eq 'Replace' }).Count
        BackupRoot  = $backupRoot
        Timestamp   = $BackupTimestamp
    }
}


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

function Test-HarnessInstall {
    <#
    .SYNOPSIS
        Verify that every managed destination exists with the manifest hash.

    .DESCRIPTION
        Read-only. Inspects only the manifest's managed destinations; it never
        enumerates unowned files, credentials, or runtime state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$ClaudeHome,
        [Parameter(Mandatory = $true)][string]$CodexHome
    )

    $plan = New-HarnessInstallPlan -Manifest $Manifest -RepositoryRoot $RepositoryRoot `
        -HermesHome $HermesHome -ClaudeHome $ClaudeHome -CodexHome $CodexHome

    $missing = New-Object System.Collections.ArrayList
    $mismatched = New-Object System.Collections.ArrayList
    foreach ($action in $plan) {
        if (-not (Test-Path -LiteralPath $action.TargetPath -PathType Leaf)) {
            [void]$missing.Add($action.Destination)
            continue
        }
        $actual = Get-HarnessFileSha256 -Path $action.TargetPath
        if ($actual -ne $action.ExpectedSha256) {
            [void]$mismatched.Add($action.Destination)
        }
    }

    return [pscustomobject]@{
        Ok         = (($missing.Count -eq 0) -and ($mismatched.Count -eq 0))
        Checked    = $plan.Count
        Missing    = $missing.ToArray()
        Mismatched = $mismatched.ToArray()
    }
}


Export-ModuleMember -Function Test-HarnessManifest, New-HarnessInstallPlan, Invoke-HarnessApply, Test-HarnessInstall
