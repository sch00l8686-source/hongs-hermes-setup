<#
    Support functions for the harness installer Pester suite.

    Every test artifact lives under a single GUID-named directory inside the
    system temp folder. Nothing here reads or writes a live Hermes, Claude, or
    Codex home, and no test ever points a destination root at a real home.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

function New-HarnessSuiteRoot {
    <# One GUID temp root for the whole suite. #>
    [CmdletBinding()]
    param()

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-pester-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $root)
    return $root
}

function New-HarnessTestCase {
    <#
        Create one disposable case: a synthetic source repository plus three
        explicitly disposable destination roots and a child-process temp
        directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SuiteRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$SkipSourceTree
    )

    $case = Join-Path $SuiteRoot $Name
    $repo = Join-Path $case 'repo'
    $hermes = Join-Path $case 'hermes-home'
    $claude = Join-Path $case 'claude-home'
    $codex = Join-Path $case 'codex-home'
    $temp = Join-Path $case 'child-temp'

    foreach ($directory in @($case, $repo, $hermes, $claude, $codex, $temp)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    if (-not $SkipSourceTree) {
        New-HarnessSourceTree -RepositoryRoot $repo
    }

    return [pscustomobject]@{
        CaseRoot       = $case
        RepositoryRoot = $repo
        HermesHome     = $hermes
        ClaudeHome     = $claude
        CodexHome      = $codex
        ChildTemp      = $temp
    }
}

function New-HarnessSourceTree {
    <# Write the synthetic baseline used by the behavioural tests. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $files = @{
        'baseline\hermes\SOUL.md'                                      = "# SOUL fixture`n"
        'baseline\agents\claude\CLAUDE.md'                             = "# CLAUDE fixture`n"
        'baseline\agents\codex\AGENTS.md'                              = "# AGENTS fixture`n"
        'baseline\skills\superpowers\brainstorming\SKILL.md'           = "# brainstorming fixture`n"
        'baseline\skills\superpowers\brainstorming\references\notes.md' = "# reference fixture`n"
    }
    foreach ($relative in $files.Keys) {
        $path = Join-Path $RepositoryRoot $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-HarnessFileText -Path $path -Text $files[$relative]
    }
}

function Set-HarnessFileText {
    <# Deterministic UTF-8 (no BOM) writer so fixture hashes are stable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-HarnessTestHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-HarnessTestManifest {
    <# Build a valid manifest object for the synthetic source tree. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $map = @(
        @{ source = 'baseline/agents/claude/CLAUDE.md'; targetRoot = 'ClaudeHome'; destination = 'CLAUDE.md' },
        @{ source = 'baseline/agents/codex/AGENTS.md'; targetRoot = 'CodexHome'; destination = 'AGENTS.md' },
        @{ source = 'baseline/hermes/SOUL.md'; targetRoot = 'HermesHome'; destination = 'SOUL.md' },
        @{ source = 'baseline/skills/superpowers/brainstorming/SKILL.md'; targetRoot = 'HermesHome'; destination = 'skills/superpowers/brainstorming/SKILL.md' },
        @{ source = 'baseline/skills/superpowers/brainstorming/references/notes.md'; targetRoot = 'HermesHome'; destination = 'skills/superpowers/brainstorming/references/notes.md' }
    )

    $records = @()
    foreach ($entry in $map) {
        $path = Join-Path $RepositoryRoot ($entry.source -replace '/', '\')
        $records += [pscustomobject]@{
            source      = $entry.source
            targetRoot  = $entry.targetRoot
            destination = $entry.destination
            sha256      = Get-HarnessTestHash -Path $path
        }
    }

    return [pscustomobject]@{
        schemaVersion = 1
        files         = $records
    }
}

function Copy-HarnessManifest {
    <# Deep copy a manifest object so a mutation cannot leak between tests. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Manifest)

    return ($Manifest | ConvertTo-Json -Depth 8) | ConvertFrom-Json
}

function Get-HarnessFileInventory {
    <#
        Snapshot every file under a root as 'relative=hash'. Used to prove that
        a dry run writes nothing and that unowned files survive an apply.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $prefix = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\') + '\'
    $inventory = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($prefix.Length)
        $inventory += ('{0}={1}' -f $relative, (Get-HarnessTestHash -Path $file.FullName))
    }
    return @($inventory | Sort-Object)
}

function Invoke-HarnessChildProcess {
    <#
        Run a child process with its own TEMP/TMP and working directory, reading
        stdout and stderr asynchronously so a chatty child cannot deadlock the
        test run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [int]$TimeoutSeconds = 300
    )

    $quoted = @()
    foreach ($argument in $ArgumentList) {
        if ($argument -match '[\s"]') { $quoted += ('"' + ($argument -replace '"', '\"') + '"') }
        else { $quoted += $argument }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($quoted -join ' ')
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['TEMP'] = $TempDirectory
    $startInfo.EnvironmentVariables['TMP'] = $TempDirectory

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "HarnessTestHelpers: child process '$FilePath' timed out after $TimeoutSeconds s."
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function New-HarnessJunction {
    <#
        Best-effort junction creation. Returns $true when the link exists, so a
        reparse test can degrade to a plain traversal assertion on a host where
        junction creation is unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    try {
        [void](New-Item -ItemType Junction -Path $LinkPath -Value $TargetPath -ErrorAction Stop)
        return (Test-Path -LiteralPath $LinkPath)
    }
    catch {
        return $false
    }
}
