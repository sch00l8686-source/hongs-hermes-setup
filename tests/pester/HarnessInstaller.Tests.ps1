<#
    Behavioural tests for the harness installer.

    Everything runs inside one GUID temp root with explicitly disposable
    Hermes/Claude/Codex homes. No live home, credential store, or runtime
    database is read or written.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

# $PSScriptRoot stays correct when this file is dot-sourced from the canonical
# entry point tests/Test-HarnessInstaller.ps1; $MyInvocation is the 5.1 fallback.
$script:TestsDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepositoryRoot = (Resolve-Path (Join-Path $script:TestsDirectory '..\..')).ProviderPath
$script:BootstrapDirectory = Join-Path $script:RepositoryRoot 'bootstrap'

. (Join-Path $script:TestsDirectory 'HarnessTestHelpers.ps1')

Import-Module (Join-Path $script:BootstrapDirectory 'HarnessInstaller.psm1') -Force

$script:SuiteRoot = New-HarnessSuiteRoot
$script:CaseIndex = 0

function New-Case {
    param([string]$Label)
    $script:CaseIndex++
    return New-HarnessTestCase -SuiteRoot $script:SuiteRoot -Name ('{0:d2}-{1}' -f $script:CaseIndex, $Label)
}

# The three -- and only three -- plugin files the harness manages, as
# HermesHome-relative destinations.
$script:PluginDestinations = @(
    'plugins/hongs-vault-router/__init__.py',
    'plugins/hongs-vault-router/plugin.yaml',
    'plugins/hongs-vault-router/router.py'
)

function New-HarnessPluginSourceTree {
    <# Add the three managed plugin sources to a synthetic case repository. #>
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    foreach ($destination in $script:PluginDestinations) {
        $path = Join-Path $RepositoryRoot (('baseline/hermes/' + $destination) -replace '/', '\')
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-HarnessFileText -Path $path -Text ("# fixture " + $destination + "`n")
    }
}

function New-HarnessPluginManifest {
    <# The synthetic five-file manifest plus the three managed plugin records. #>
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    New-HarnessPluginSourceTree -RepositoryRoot $RepositoryRoot
    $manifest = New-HarnessTestManifest -RepositoryRoot $RepositoryRoot
    $records = @($manifest.files)
    foreach ($destination in $script:PluginDestinations) {
        $source = 'baseline/hermes/' + $destination
        $records += [pscustomobject]@{
            source      = $source
            targetRoot  = 'HermesHome'
            destination = $destination
            sha256      = Get-HarnessTestHash -Path (Join-Path $RepositoryRoot ($source -replace '/', '\'))
        }
    }
    $manifest.files = $records
    return $manifest
}

function New-HarnessUnownedRuntimeState {
    <#
        Write the unowned state a real Hermes home carries next to the managed
        plugin: a sibling plugin, this plugin's own data, config, logs, and the
        routing key. Returns 'relative=hash' for each so an apply can be proven
        not to have touched any of them.
    #>
    param([Parameter(Mandatory = $true)][string]$HermesHome)

    $unowned = @{
        'plugins\other-plugin\plugin.yaml'          = "name: other-plugin`n"
        'plugins\hongs-vault-router\data\state.json' = "{`"turns`":3}`n"
        'config.yaml'                                = "model.default: local-only`n"
        'logs\vault-routing.jsonl'                   = "{`"decision`":`"skipped`"}`n"
        'runtime\vault-router\qhash.key'             = "not-a-real-key`n"
        'unowned.txt'                                = "keep me`n"
    }
    $inventory = @()
    foreach ($relative in $unowned.Keys) {
        $path = Join-Path $HermesHome $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-HarnessFileText -Path $path -Text $unowned[$relative]
        $inventory += ('{0}={1}' -f $relative, (Get-HarnessTestHash -Path $path))
    }
    return @($inventory | Sort-Object)
}

function Get-HarnessUnownedState {
    <# Re-read the same unowned paths as 'relative=hash', or 'relative=MISSING'. #>
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Inventory
    )

    $current = @()
    foreach ($entry in $Inventory) {
        $relative = $entry.Substring(0, $entry.LastIndexOf('='))
        $path = Join-Path $HermesHome $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $current += ('{0}={1}' -f $relative, (Get-HarnessTestHash -Path $path))
        }
        else {
            $current += ('{0}=MISSING' -f $relative)
        }
    }
    return @($current | Sort-Object)
}


Describe 'Test-HarnessManifest' {

    $case = New-Case 'manifest'
    $valid = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot

    It 'accepts a well-formed manifest' {
        $result = Test-HarnessManifest -Manifest (Copy-HarnessManifest -Manifest $valid)
        @($result.files).Count | Should Be 5
    }

    It 'rejects an unsupported schema version' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.schemaVersion = 2
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an empty file list' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files = @()
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an unknown record key' {
        $bad = Copy-HarnessManifest -Manifest $valid
        Add-Member -InputObject $bad.files[0] -MemberType NoteProperty -Name 'mode' -Value '0777'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a missing record key' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[0].PSObject.Properties.Remove('sha256')
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an unknown target root' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[0].targetRoot = 'VaultHome'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a source outside baseline/' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[0].source = 'scripts/validate-harness.py'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a source that uses traversal' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[0].source = 'baseline/../../secrets.env'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a traversal destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = '..\..\SOUL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an absolute destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = 'C:\SOUL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a UNC destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = '\\server\share\SOUL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a device-namespace destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = '\\?\C:\SOUL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a root-anchored destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = '\SOUL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an alternate data stream destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = 'SOUL.md:hidden'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an unmanaged destination under HermesHome' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].destination = 'notes/scratch.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a skill outside the approved twenty-one' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[3].destination = 'skills/experimental/new-thing/SKILL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'accepts every newly approved skill package destination' {
        $added = @(
            'skills/superpowers/finishing-a-development-branch/SKILL.md',
            'skills/superpowers/receiving-code-review/SKILL.md',
            'skills/superpowers/using-git-worktrees/SKILL.md',
            'skills/autonomous-ai-agents/agent-context-efficiency/references/caveman-evaluation.md',
            'skills/autonomous-ai-agents/agent-context-governance/SKILL.md',
            'skills/autonomous-ai-agents/review-gated-config-distribution/SKILL.md',
            'skills/note-taking/obsidian-vault-ingest/SKILL.md',
            'skills/note-taking/obsidian-vault-lint/SKILL.md',
            'skills/note-taking/obsidian-vault-query/SKILL.md'
        )
        foreach ($destination in $added) {
            $candidate = Copy-HarnessManifest -Manifest $valid
            $candidate.files[3].destination = $destination
            $result = Test-HarnessManifest -Manifest $candidate
            @($result.files)[3].destination | Should Be $destination
        }
    }

    It 'still rejects a note-taking skill that was never approved' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[3].destination = 'skills/note-taking/obsidian-vault-publish/SKILL.md'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a non-CLAUDE.md destination under ClaudeHome' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[0].destination = 'settings.json'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a duplicate destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[4].destination = $bad.files[3].destination
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a malformed sha256' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[2].sha256 = 'not-a-hash'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }
}


Describe 'New-HarnessInstallPlan' {

    It 'produces one Create action per record for empty homes' {
        $case = New-Case 'plan-create'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        @($plan).Count | Should Be 5
        @($plan | Where-Object { $_.Action -eq 'Create' }).Count | Should Be 5
    }

    It 'marks an existing managed target as Replace' {
        $case = New-Case 'plan-replace'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Set-HarnessFileText -Path (Join-Path $case.ClaudeHome 'CLAUDE.md') -Text "old`n"
        $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        @($plan | Where-Object { $_.Action -eq 'Replace' }).Count | Should Be 1
    }

    It 'throws when a declared source does not exist' {
        $case = New-Case 'plan-missing-source'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Remove-Item -LiteralPath (Join-Path $case.RepositoryRoot 'baseline\hermes\SOUL.md') -Force
        {
            New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        } | Should Throw
    }

    It 'rejects a destination that traverses a reparse point' {
        $case = New-Case 'plan-reparse'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        $outside = Join-Path $case.CaseRoot 'outside-skills'
        [void](New-Item -ItemType Directory -Path $outside -Force)
        $linked = New-HarnessJunction -LinkPath (Join-Path $case.HermesHome 'skills') -TargetPath $outside

        if ($linked) {
            {
                New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                    -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
            } | Should Throw
        }
        else {
            Write-Warning 'Junction creation unavailable; asserting the static traversal rejection instead.'
            $bad = Copy-HarnessManifest -Manifest $manifest
            $bad.files[3].destination = 'skills/superpowers/brainstorming/../../../../escape.md'
            { Test-HarnessManifest -Manifest $bad } | Should Throw
        }
    }

    It 'preserves root identity when a destination root is itself a junction' {
        $case = New-Case 'plan-root-identity'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        $realHome = Join-Path $case.CaseRoot 'real-hermes'
        [void](New-Item -ItemType Directory -Path $realHome -Force)
        $linkHome = Join-Path $case.CaseRoot 'linked-hermes'
        $linked = New-HarnessJunction -LinkPath $linkHome -TargetPath $realHome

        if ($linked) {
            $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $linkHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
            @($plan | Where-Object { $_.TargetRoot -eq 'HermesHome' }).Count | Should Be 3
        }
        else {
            Write-Warning 'Junction creation unavailable; root-identity assertion skipped.'
            $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $realHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
            @($plan | Where-Object { $_.TargetRoot -eq 'HermesHome' }).Count | Should Be 3
        }
    }
}


Describe 'install-harness.ps1 -DryRun' {

    It 'prints the managed actions and writes nothing' {
        $case = New-Case 'dry-run'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        $manifestPath = Join-Path $case.CaseRoot 'harness-manifest.json'
        Set-HarnessFileText -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 8) + "`n")

        Set-HarnessFileText -Path (Join-Path $case.HermesHome 'unowned.txt') -Text "keep me`n"
        $before = @(
            (Get-HarnessFileInventory -Root $case.HermesHome),
            (Get-HarnessFileInventory -Root $case.ClaudeHome),
            (Get-HarnessFileInventory -Root $case.CodexHome)
        )

        $result = Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:BootstrapDirectory 'install-harness.ps1'),
            '-DryRun',
            '-RepositoryRoot', $case.RepositoryRoot,
            '-HermesHome', $case.HermesHome,
            '-ClaudeHome', $case.ClaudeHome,
            '-CodexHome', $case.CodexHome,
            '-ManifestPath', $manifestPath
        ) -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp

        $result.ExitCode | Should Be 0
        ($result.StdOut -match 'DRY RUN') | Should Be $true
        ($result.StdOut -match 'Managed actions: 5') | Should Be $true

        $after = @(
            (Get-HarnessFileInventory -Root $case.HermesHome),
            (Get-HarnessFileInventory -Root $case.ClaudeHome),
            (Get-HarnessFileInventory -Root $case.CodexHome)
        )
        (($after | ForEach-Object { $_ }) -join '|') | Should Be (($before | ForEach-Object { $_ }) -join '|')
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'backups')) | Should Be $false
    }
}


Describe 'Invoke-HarnessApply' {

    It 'copies exactly the managed set with verified hashes' {
        $case = New-Case 'apply-exact'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        $result = Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome

        $result.Applied | Should Be 5
        $result.Created | Should Be 5

        foreach ($record in @($manifest.files)) {
            $root = switch ($record.targetRoot) {
                'HermesHome' { $case.HermesHome }
                'ClaudeHome' { $case.ClaudeHome }
                'CodexHome' { $case.CodexHome }
            }
            $target = Join-Path $root ($record.destination -replace '/', '\')
            (Test-Path -LiteralPath $target -PathType Leaf) | Should Be $true
            (Get-HarnessTestHash -Path $target) | Should Be $record.sha256
        }

        $verify = Test-HarnessInstall -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        $verify.Ok | Should Be $true
        $verify.Checked | Should Be 5
    }

    It 'preserves unowned files inside the destination roots' {
        $case = New-Case 'apply-unowned'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Set-HarnessFileText -Path (Join-Path $case.HermesHome 'settings.json') -Text "{`"keep`":true}`n"
        [void](New-Item -ItemType Directory -Path (Join-Path $case.HermesHome 'skills\local-only') -Force)
        Set-HarnessFileText -Path (Join-Path $case.HermesHome 'skills\local-only\SKILL.md') -Text "local`n"
        $unownedHash = Get-HarnessTestHash -Path (Join-Path $case.HermesHome 'skills\local-only\SKILL.md')

        [void](Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome)

        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'settings.json')) | Should Be $true
        (Get-HarnessTestHash -Path (Join-Path $case.HermesHome 'skills\local-only\SKILL.md')) | Should Be $unownedHash
    }

    It 'backs up an existing managed target under the timestamped backup root' {
        $case = New-Case 'apply-backup'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Set-HarnessFileText -Path (Join-Path $case.ClaudeHome 'CLAUDE.md') -Text "previous`n"

        $result = Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome `
            -BackupTimestamp '20260814T000000Z'

        $result.Replaced | Should Be 1
        $expectedBackup = Join-Path $case.HermesHome 'backups\hongs-global-harness\20260814T000000Z\files\ClaudeHome\CLAUDE.md'
        (Test-Path -LiteralPath $expectedBackup -PathType Leaf) | Should Be $true
        ([System.IO.File]::ReadAllText($expectedBackup)) | Should Be "previous`n"
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'backups\hongs-global-harness\20260814T000000Z\.staging')) | Should Be $false
    }

    It 'rejects a source hash mismatch before writing anything' {
        $case = New-Case 'apply-hash-mismatch'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Set-HarnessFileText -Path (Join-Path $case.RepositoryRoot 'baseline\hermes\SOUL.md') -Text "tampered`n"

        {
            Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        } | Should Throw

        (Test-Path -LiteralPath (Join-Path $case.ClaudeHome 'CLAUDE.md')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $case.CodexHome 'AGENTS.md')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'SOUL.md')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'backups')) | Should Be $false
    }

    It 'rolls every write back when a later step fails' {
        $case = New-Case 'apply-rollback'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        Set-HarnessFileText -Path (Join-Path $case.ClaudeHome 'CLAUDE.md') -Text "previous`n"
        Set-HarnessFileText -Path (Join-Path $case.HermesHome 'unowned.txt') -Text "keep me`n"

        {
            Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome `
                -BackupTimestamp '20260814T010000Z' -FailAfterDestination 'SOUL.md'
        } | Should Throw

        # Replaced target restored from backup.
        ([System.IO.File]::ReadAllText((Join-Path $case.ClaudeHome 'CLAUDE.md'))) | Should Be "previous`n"
        # Created targets removed.
        (Test-Path -LiteralPath (Join-Path $case.CodexHome 'AGENTS.md')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'SOUL.md')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills\superpowers\brainstorming\SKILL.md')) | Should Be $false
        # Directories this apply created are gone; unowned content survives.
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills')) | Should Be $false
        ([System.IO.File]::ReadAllText((Join-Path $case.HermesHome 'unowned.txt'))) | Should Be "keep me`n"
    }
}


Describe 'Test-HarnessInstall' {

    It 'reports a mismatch when an installed managed file drifts' {
        $case = New-Case 'verify-drift'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        [void](Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome)

        Set-HarnessFileText -Path (Join-Path $case.HermesHome 'SOUL.md') -Text "drifted`n"
        $verify = Test-HarnessInstall -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        $verify.Ok | Should Be $false
        @($verify.Mismatched).Count | Should Be 1
    }

    It 'reports a missing managed file' {
        $case = New-Case 'verify-missing'
        $manifest = New-HarnessTestManifest -RepositoryRoot $case.RepositoryRoot
        [void](Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome)

        Remove-Item -LiteralPath (Join-Path $case.CodexHome 'AGENTS.md') -Force
        $verify = Test-HarnessInstall -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome
        $verify.Ok | Should Be $false
        @($verify.Missing).Count | Should Be 1
    }
}


Describe 'Managed plugin destinations' {

    $case = New-Case 'plugin-manifest'
    $valid = New-HarnessPluginManifest -RepositoryRoot $case.RepositoryRoot

    It 'accepts exactly the three managed plugin destinations' {
        $result = Test-HarnessManifest -Manifest (Copy-HarnessManifest -Manifest $valid)
        @($result.files).Count | Should Be 8
        @(@($result.files) | Where-Object { $_.destination -like 'plugins/*' }).Count | Should Be 3
    }

    It 'rejects a sibling plugin destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[7].destination = 'plugins/other-plugin/router.py'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects an unlisted file inside the managed plugin directory' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[7].destination = 'plugins/hongs-vault-router/settings.json'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects the plugin directory itself as a destination' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[7].destination = 'plugins/hongs-vault-router'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'rejects a plugin destination under ClaudeHome' {
        $bad = Copy-HarnessManifest -Manifest $valid
        $bad.files[7].targetRoot = 'ClaudeHome'
        { Test-HarnessManifest -Manifest $bad } | Should Throw
    }

    It 'installs all three plugin files and touches no unowned runtime state' {
        $case = New-Case 'plugin-apply'
        $manifest = New-HarnessPluginManifest -RepositoryRoot $case.RepositoryRoot
        $before = New-HarnessUnownedRuntimeState -HermesHome $case.HermesHome

        $result = Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome

        $result.Applied | Should Be 8
        foreach ($destination in $script:PluginDestinations) {
            $target = Join-Path $case.HermesHome ($destination -replace '/', '\')
            (Test-Path -LiteralPath $target -PathType Leaf) | Should Be $true
            $record = @($manifest.files) | Where-Object { $_.destination -eq $destination }
            (Get-HarnessTestHash -Path $target) | Should Be $record.sha256
        }

        ((Get-HarnessUnownedState -HermesHome $case.HermesHome -Inventory $before) -join '|') |
            Should Be ($before -join '|')
    }

    It 'backs up an existing managed plugin file before replacing it' {
        $case = New-Case 'plugin-backup'
        $manifest = New-HarnessPluginManifest -RepositoryRoot $case.RepositoryRoot
        $existing = Join-Path $case.HermesHome 'plugins\hongs-vault-router\router.py'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $existing) -Force)
        Set-HarnessFileText -Path $existing -Text "previous`n"

        $result = Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
            -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome `
            -BackupTimestamp '20260814T020000Z'

        $result.Replaced | Should Be 1
        $expectedBackup = Join-Path $case.HermesHome 'backups\hongs-global-harness\20260814T020000Z\files\HermesHome\plugins\hongs-vault-router\router.py'
        (Test-Path -LiteralPath $expectedBackup -PathType Leaf) | Should Be $true
        ([System.IO.File]::ReadAllText($expectedBackup)) | Should Be "previous`n"
    }

    It 'rolls every plugin write back when a later step fails' {
        $case = New-Case 'plugin-rollback'
        $manifest = New-HarnessPluginManifest -RepositoryRoot $case.RepositoryRoot
        $before = New-HarnessUnownedRuntimeState -HermesHome $case.HermesHome

        {
            Invoke-HarnessApply -Manifest $manifest -RepositoryRoot $case.RepositoryRoot `
                -HermesHome $case.HermesHome -ClaudeHome $case.ClaudeHome -CodexHome $case.CodexHome `
                -BackupTimestamp '20260814T030000Z' `
                -FailAfterDestination 'plugins/hongs-vault-router/router.py'
        } | Should Throw

        foreach ($destination in $script:PluginDestinations) {
            (Test-Path -LiteralPath (Join-Path $case.HermesHome ($destination -replace '/', '\'))) |
                Should Be $false
        }
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'SOUL.md')) | Should Be $false
        # The sibling plugin and this plugin's own data pre-existed, so their
        # directories survive the rollback with their contents intact.
        ((Get-HarnessUnownedState -HermesHome $case.HermesHome -Inventory $before) -join '|') |
            Should Be ($before -join '|')
    }
}


Describe 'End-to-end with the real repository baseline' {

    It 'builds the manifest, dry-runs, applies, and verifies into disposable homes' {
        $case = New-Case 'end-to-end'
        $manifestPath = Join-Path $case.CaseRoot 'harness-manifest.json'

        $build = Invoke-HarnessChildProcess -FilePath 'python' -ArgumentList @(
            (Join-Path $script:RepositoryRoot 'scripts\build-harness-manifest.py'),
            '--root', $script:RepositoryRoot,
            '--output', $manifestPath
        ) -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp
        $build.ExitCode | Should Be 0

        $dryRun = Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:BootstrapDirectory 'install-harness.ps1'),
            '-DryRun',
            '-RepositoryRoot', $script:RepositoryRoot,
            '-HermesHome', $case.HermesHome,
            '-ClaudeHome', $case.ClaudeHome,
            '-CodexHome', $case.CodexHome,
            '-ManifestPath', $manifestPath
        ) -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp
        $dryRun.ExitCode | Should Be 0
        @(Get-HarnessFileInventory -Root $case.HermesHome).Count | Should Be 0

        $apply = Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:BootstrapDirectory 'install-harness.ps1'),
            '-Apply',
            '-RepositoryRoot', $script:RepositoryRoot,
            '-HermesHome', $case.HermesHome,
            '-ClaudeHome', $case.ClaudeHome,
            '-CodexHome', $case.CodexHome,
            '-ManifestPath', $manifestPath
        ) -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp
        $apply.ExitCode | Should Be 0
        ($apply.StdOut -match 'APPLIED 46 managed file') | Should Be $true

        $verify = Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $script:BootstrapDirectory 'verify-harness.ps1'),
            '-RepositoryRoot', $script:RepositoryRoot,
            '-HermesHome', $case.HermesHome,
            '-ClaudeHome', $case.ClaudeHome,
            '-CodexHome', $case.CodexHome,
            '-ManifestPath', $manifestPath
        ) -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp
        $verify.ExitCode | Should Be 0
        ($verify.StdOut -match 'VERIFY OK') | Should Be $true

        (Test-Path -LiteralPath (Join-Path $case.ClaudeHome 'CLAUDE.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.CodexHome 'AGENTS.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills\superpowers\writing-plans\SKILL.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills\superpowers\using-git-worktrees\SKILL.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills\note-taking\obsidian-vault-query\SKILL.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'skills\autonomous-ai-agents\agent-context-governance\references\verified-governance-patterns.md')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'plugins\hongs-vault-router\router.py')) | Should Be $true
    }
}
