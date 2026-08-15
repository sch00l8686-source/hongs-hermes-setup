<#
    Behavioural tests for the transactional runtime-contract apply and rollback
    scripts.

    Everything runs inside one GUID temp root: a synthetic source repository,
    explicitly disposable Hermes/Claude/Codex homes, a disposable Vault root, a
    fake `hermes.cmd`, a disposable user-environment store, and a disposable
    SQLite state database. No live home, live config, live environment
    variable, credential store, or live runtime database is read or written,
    and no test reaches the network.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

# $PSScriptRoot stays correct when this file is dot-sourced from the canonical
# entry point tests/Test-RuntimeContractApply.ps1; $MyInvocation is the 5.1
# fallback.
$script:TestsDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepositoryRoot = (Resolve-Path (Join-Path $script:TestsDirectory '..\..')).ProviderPath
$script:BootstrapDirectory = Join-Path $script:RepositoryRoot 'bootstrap'
$script:ApplyScript = Join-Path $script:BootstrapDirectory 'apply-runtime-contract.ps1'
$script:RollbackScript = Join-Path $script:BootstrapDirectory 'rollback-runtime-contract.ps1'

. (Join-Path $script:TestsDirectory 'HarnessTestHelpers.ps1')

$script:SuiteRoot = New-HarnessSuiteRoot
$script:CaseIndex = 0

# A distinctive marker inside the disposable Vault path. Apply and rollback
# output must never contain it: the Vault root is the machine-local value of
# HONG_VAULT_ROOT.
$script:VaultMarker = 'PRIVATE-7c1d9'

# A distinctive unrelated config value. No script output may contain it.
$script:ConfigSecret = 'SECRET-DO-NOT-PRINT-9f3a'

$script:PluginName = 'hongs-vault-router'

$script:ManagedDestinations = @(
    @{ Source = 'baseline/hermes/SOUL.md'; TargetRoot = 'HermesHome'; Destination = 'SOUL.md' },
    @{ Source = 'baseline/agents/claude/CLAUDE.md'; TargetRoot = 'ClaudeHome'; Destination = 'CLAUDE.md' },
    @{ Source = 'baseline/agents/codex/AGENTS.md'; TargetRoot = 'CodexHome'; Destination = 'AGENTS.md' },
    @{ Source = 'baseline/hermes/plugins/hongs-vault-router/__init__.py'; TargetRoot = 'HermesHome'; Destination = 'plugins/hongs-vault-router/__init__.py' },
    @{ Source = 'baseline/hermes/plugins/hongs-vault-router/plugin.yaml'; TargetRoot = 'HermesHome'; Destination = 'plugins/hongs-vault-router/plugin.yaml' },
    @{ Source = 'baseline/hermes/plugins/hongs-vault-router/router.py'; TargetRoot = 'HermesHome'; Destination = 'plugins/hongs-vault-router/router.py' }
)

# --------------------------------------------------------------------------
# Fixture sources
# --------------------------------------------------------------------------

# A fake Hermes CLI. It implements exactly the four command shapes the apply
# script is allowed to use, records every invocation, and can be forced to fail
# or to answer wrongly through environment variables. It reaches no network and
# knows nothing outside its case directory.
#
# The remaining-argument parameter is deliberately named so that no frozen CLI
# flag can prefix-match it. Windows PowerShell resolves `--cli` to the parameter
# name `-cli`, which prefix-matches a parameter called `CliArguments`; the
# binder then consumes the frozen proof vector as a parameter name instead of
# passing it through, and the fixture body never runs. `FakeHermesArguments`
# shares no prefix with `--cli`, `-Q`, `-q`, `-z`, `--oneshot`, `--model`,
# `--provider`, `--reasoning`, `--usage-file`, or `--no-allow-tool-override`, so
# every argument reaches the body verbatim and each assertion below still tests
# the exact caller.
$script:FakeHermesSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FakeHermesArguments)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$storePath = $env:FAKE_HERMES_STORE
$configPath = $env:FAKE_HERMES_CONFIG
$logPath = $env:FAKE_HERMES_LOG

function Write-FakeText {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Add-FakeLog {
    param([string]$Line)
    if ($logPath) {
        Add-Content -LiteralPath $logPath -Value $Line -Encoding UTF8
    }
}

function Get-FakeEntries {
    if (Test-Path -LiteralPath $storePath -PathType Leaf) {
        $json = Get-Content -LiteralPath $storePath -Raw | ConvertFrom-Json
        return @($json.entries)
    }
    return @()
}

function Save-FakeEntries {
    param($Entries)
    $payload = [pscustomobject]@{ entries = @($Entries) }
    Write-FakeText -Path $storePath -Text (($payload | ConvertTo-Json -Depth 6) + "`n")
}

function Set-FakeEntry {
    param([string]$Path, [string]$Value)
    $entries = @(Get-FakeEntries)
    $found = $false
    foreach ($entry in $entries) {
        if ($entry.path -eq $Path) {
            $entry.value = $Value
            if ($entry.PSObject.Properties['values']) { $entry.PSObject.Properties.Remove('values') }
            $found = $true
        }
    }
    if (-not $found) {
        $entries += [pscustomobject]@{ path = $Path; value = $Value }
    }
    Save-FakeEntries -Entries $entries
}

function Set-FakeListEntry {
    param([string]$Path, [string[]]$Values)
    $entries = @(Get-FakeEntries)
    $found = $false
    foreach ($entry in $entries) {
        if ($entry.path -eq $Path) {
            if ($entry.PSObject.Properties['value']) { $entry.PSObject.Properties.Remove('value') }
            $entry | Add-Member -NotePropertyName 'values' -NotePropertyValue @($Values) -Force
            $found = $true
        }
    }
    if (-not $found) {
        $entries += [pscustomobject]@{ path = $Path; values = @($Values) }
    }
    Save-FakeEntries -Entries $entries
}

function Get-FakeListEntry {
    param([string]$Path)
    foreach ($entry in @(Get-FakeEntries)) {
        if ($entry.path -eq $Path -and $entry.PSObject.Properties['values']) {
            return @($entry.values)
        }
    }
    return @()
}

function Add-FakeTreeLeaf {
    param($Tree, [string]$Path, $Value)
    $parts = $Path.Split('.')
    $node = $Tree
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $node.Contains($parts[$i])) {
            $node[$parts[$i]] = New-Object System.Collections.Specialized.OrderedDictionary
        }
        $node = $node[$parts[$i]]
    }
    $node[$parts[$parts.Count - 1]] = $Value
}

function Format-FakeNode {
    param($Node, [int]$Indent, [int]$Step)
    $pad = ' ' * $Indent
    $lines = @()
    foreach ($key in @($Node.Keys)) {
        $value = $Node[$key]
        if ($value -is [System.Collections.Specialized.OrderedDictionary]) {
            $lines += ($pad + $key + ':')
            $lines += Format-FakeNode -Node $value -Indent ($Indent + $Step) -Step $Step
        }
        elseif ($value -is [System.Array]) {
            if (@($value).Count -eq 0) {
                $lines += ($pad + $key + ': []')
            }
            else {
                $lines += ($pad + $key + ':')
                foreach ($item in @($value)) {
                    $lines += ($pad + (' ' * $Step) + '- ' + $item)
                }
            }
        }
        else {
            $lines += ($pad + $key + ': ' + $value)
        }
    }
    return $lines
}

function Write-FakeConfig {
    $entries = @(Get-FakeEntries)
    $step = 2
    if ($env:FAKE_HERMES_REFORMAT -eq '1') {
        $reversed = @()
        for ($i = $entries.Count - 1; $i -ge 0; $i--) { $reversed += $entries[$i] }
        $entries = $reversed
        $step = 4
    }
    $tree = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($entry in $entries) {
        if ($entry.PSObject.Properties['values']) {
            Add-FakeTreeLeaf -Tree $tree -Path $entry.path -Value @($entry.values)
        }
        else {
            Add-FakeTreeLeaf -Tree $tree -Path $entry.path -Value $entry.value
        }
    }
    $lines = @('# fake hermes configuration', '# machine-local, never distributed')
    $lines += Format-FakeNode -Node $tree -Indent 0 -Step $step
    Write-FakeText -Path $configPath -Text (($lines -join "`n") + "`n")
}

function Test-FakeFailure {
    param([string]$Command)
    if ($env:FAKE_HERMES_FAIL_COMMAND -and $env:FAKE_HERMES_FAIL_COMMAND -eq $Command) {
        Write-Error ("fake hermes: refusing '" + $Command + "'")
        exit 4
    }
}

$arguments = @()
if ($FakeHermesArguments) { $arguments = @($FakeHermesArguments) }
Add-FakeLog -Line ($arguments -join ' ')

if ($arguments.Count -eq 0) {
    Write-Error 'fake hermes: no command'
    exit 9
}

if ($arguments[0] -eq '__fixture-render') {
    Write-FakeConfig
    exit 0
}

if ($arguments[0] -eq 'auth' -and $arguments.Count -ge 2 -and $arguments[1] -eq 'status') {
    # The installed CLI is `hermes auth status [-h] provider`: the provider
    # positional is required and argparse exits 2 on a usage error.
    if ($arguments.Count -ne 3) {
        [Console]::Error.WriteLine('usage: hermes auth status [-h] provider')
        [Console]::Error.WriteLine('hermes auth status: error: wrong number of positional arguments')
        exit 2
    }
    if ($arguments[2] -cne 'openai-codex') {
        [Console]::Error.WriteLine(('hermes auth status: error: unknown provider ' + $arguments[2]))
        exit 3
    }
    if ($env:FAKE_HERMES_AUTH_EXIT -and $env:FAKE_HERMES_AUTH_EXIT -ne '0') {
        Write-Error 'fake hermes: openai-codex is not authenticated'
        exit ([int]$env:FAKE_HERMES_AUTH_EXIT)
    }
    if ($env:FAKE_HERMES_AUTH_TEXT) { Write-Output $env:FAKE_HERMES_AUTH_TEXT }
    else { Write-Output 'openai-codex: authenticated (subscription)' }
    exit 0
}

if ($arguments[0] -eq 'plugins' -and $arguments.Count -ge 3 -and $arguments[1] -eq 'enable') {
    Test-FakeFailure -Command 'plugins.enable'
    if ($arguments -notcontains '--no-allow-tool-override') {
        Write-Error 'fake hermes: plugins enable requires --no-allow-tool-override'
        exit 5
    }
    $name = $arguments[2]
    $enabled = @(Get-FakeListEntry -Path 'plugins.enabled')
    if ($enabled -notcontains $name) { $enabled += $name }
    Set-FakeListEntry -Path 'plugins.enabled' -Values $enabled
    $disabled = @(Get-FakeListEntry -Path 'plugins.disabled') | Where-Object { $_ -ne $name }
    Set-FakeListEntry -Path 'plugins.disabled' -Values @($disabled)
    Set-FakeEntry -Path ('plugins.entries.' + $name + '.allow_tool_override') -Value 'false'
    Write-FakeConfig
    Write-Output ('enabled plugin ' + $name)
    exit 0
}

if ($arguments[0] -eq 'config' -and $arguments.Count -ge 4 -and $arguments[1] -eq 'set') {
    $key = $arguments[2]
    $value = $arguments[3]
    Test-FakeFailure -Command ('config.set:' + $key)
    Set-FakeEntry -Path $key -Value $value
    if ($env:FAKE_HERMES_EXTRA_PATH) {
        Set-FakeEntry -Path $env:FAKE_HERMES_EXTRA_PATH -Value $env:FAKE_HERMES_EXTRA_VALUE
    }
    Write-FakeConfig
    Write-Output ('set ' + $key)
    exit 0
}

if ($arguments -contains '-z' -or $arguments -contains '--oneshot') {
    [Console]::Error.WriteLine('fake hermes: the -z/--oneshot caller is not an approved model-contract proof')
    exit 7
}

if ($arguments[0] -eq 'chat') {
    Test-FakeFailure -Command 'chat'
    foreach ($forbidden in @('--model', '--provider', '--reasoning', '--usage-file')) {
        if ($arguments -contains $forbidden) {
            [Console]::Error.WriteLine('fake hermes: chat proof must pass no ' + $forbidden + ' override')
            exit 8
        }
    }
    if ($arguments -notcontains '--cli' -or $arguments -notcontains '-Q' -or $arguments -notcontains '-q') {
        [Console]::Error.WriteLine('fake hermes: chat proof requires --cli -Q -q')
        exit 8
    }
    $queryIndex = [array]::IndexOf($arguments, '-q')
    $prompt = ''
    if ($queryIndex -ge 0 -and $queryIndex -lt $arguments.Count - 1) { $prompt = $arguments[$queryIndex + 1] }
    if ($prompt -cne 'Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools.') {
        [Console]::Error.WriteLine('fake hermes: chat proof did not receive the frozen contract prompt')
        exit 8
    }
    $session = if ($env:FAKE_HERMES_CHAT_SESSION) { $env:FAKE_HERMES_CHAT_SESSION } else { 'proof-session-high' }
    if ($env:FAKE_HERMES_CHAT_NO_SESSION_LINE -ne '1') {
        [Console]::Error.WriteLine('session_id: ' + $session)
    }
    $text = if ($env:FAKE_HERMES_CHAT_TEXT) { $env:FAKE_HERMES_CHAT_TEXT } else { 'MODEL_CONTRACT_PROBE_OK' }
    Write-Output $text
    if ($env:FAKE_HERMES_CHAT_EXIT -and $env:FAKE_HERMES_CHAT_EXIT -ne '0') {
        exit ([int]$env:FAKE_HERMES_CHAT_EXIT)
    }
    exit 0
}

Write-Error ('fake hermes: unsupported command ' + ($arguments -join ' '))
exit 9
'@

# A stub source validator. The real validator is proved by its own Python
# suite; this fixture only proves that the apply script honours its exit code.
$script:ValidatorStubSource = @'
import os
import sys

print("validator stub: %s" % " ".join(sys.argv[1:]))
sys.exit(int(os.environ.get("FIXTURE_VALIDATOR_EXIT", "0")))
'@

# Seeds a disposable SQLite state database with the verified two-table shape:
# `sessions` carries the model beside its reasoning config, exactly as the
# installed source inserts and preserves them, and `session_model_usage` carries
# the billing provider for the same session identifier. Each correlated row
# differs from `proof-session-high` in exactly one dimension, so every
# correlation assertion can fail on its own. `proof-session-absent` is
# deliberately not inserted.
$script:SeedStateSource = @'
import json
import sqlite3
import sys

path = sys.argv[1]
connection = sqlite3.connect(path)
try:
    with connection:
        connection.execute("CREATE TABLE sessions (id TEXT, model TEXT, model_config TEXT)")
        connection.execute(
            "CREATE TABLE session_model_usage ("
            "session_id TEXT, billing_provider TEXT, task TEXT,"
            " api_call_count INTEGER, first_seen REAL)"
        )
        rows = (
            ("proof-session-high", True, "high", "gpt-5.6-sol", "openai-codex"),
            ("proof-session-medium", True, "medium", "gpt-5.6-sol", "openai-codex"),
            ("proof-session-disabled", False, "high", "gpt-5.6-sol", "openai-codex"),
            ("proof-session-terra", True, "high", "gpt-5.6-terra", "openai-codex"),
            ("proof-session-anthropic", True, "high", "gpt-5.6-sol", "anthropic"),
        )
        for session_id, enabled, effort, model, provider in rows:
            connection.execute(
                "INSERT INTO sessions (id, model, model_config) VALUES (?, ?, ?)",
                (
                    session_id,
                    model,
                    json.dumps(
                        {
                            "model": model,
                            "provider": provider,
                            "reasoning_config": {"enabled": enabled, "effort": effort},
                        }
                    ),
                ),
            )
            connection.execute(
                "INSERT INTO session_model_usage"
                " (session_id, billing_provider, task, api_call_count, first_seen)"
                " VALUES (?, ?, '', 1, 0.0)",
                (session_id, provider),
            )
finally:
    connection.close()
'@

# A stub reasoning-seam verifier. The real verifier is proved by its own suite;
# this fixture asserts the four flags and the frozen prompt, so a case can only
# pass if the apply script really passes them, and no case reaches the installed
# Hermes source.
$script:SeamVerifierStubSource = @'
import json
import os
import sys

expected = "Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools."
arguments = dict(zip(sys.argv[1::2], sys.argv[2::2]))
for flag in ("--hermes-source", "--router", "--routing-contract", "--prompt"):
    if flag not in arguments:
        sys.stdout.write('{"kind":"hongs-hermes-reasoning-seam","schemaVersion":1,'
                         '"result":"UNAVAILABLE","dispatcher":{"status":"UNAVAILABLE","clauses":"0/8",'
                         '"failed":["SOURCE_ROOT_MISSING"]},"payload":{"status":"UNAVAILABLE","checks":"0/4",'
                         '"failed":["SOURCE_ROOT_MISSING"]},"routing":{"status":"UNAVAILABLE",'
                         '"decision":"UNAVAILABLE","trigger":"UNAVAILABLE","matched":0},'
                         '"externalInference":0,"liveMutation":0}\n')
        raise SystemExit(2)
if arguments["--prompt"] != expected:
    result = "FAIL"
else:
    result = os.environ.get("FIXTURE_SEAM_RESULT", "PASS")

passing = result == "PASS"
report = {
    "kind": "hongs-hermes-reasoning-seam",
    "schemaVersion": 1,
    "result": result,
    "dispatcher": {
        "status": result,
        "clauses": "8/8" if passing else "6/8",
        "failed": [] if passing else ["NOT_ONESHOT", "NO_REASONING_OVERRIDE"],
    },
    "payload": {
        "status": result,
        "checks": "4/4" if passing else "3/4",
        "failed": [] if passing else ["PAYLOAD_EFFORT_HIGH"],
    },
    "routing": {"status": result, "decision": "SKIPPED", "trigger": "NO_DOMAIN", "matched": 0},
    "externalInference": 0,
    "liveMutation": 0,
}
sys.stdout.write(json.dumps(report, separators=(",", ":")) + "\n")
raise SystemExit({"PASS": 0, "FAIL": 1}.get(result, 2))
'@

# Re-reads the disposable configuration and state from a brand new process, so
# requirement 6 proves the post-rollback state on disk rather than a value the
# parent session already holds in memory.
$script:FreshReaderSource = @'
param([string]$ConfigPath, [string]$EnvStorePath, [string]$HermesHome, [string]$ClaudeHome, [string]$CodexHome)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$reading = [ordered]@{
    config      = [System.IO.File]::ReadAllText($ConfigPath)
    environment = if (Test-Path -LiteralPath $EnvStorePath -PathType Leaf) { Get-Content -LiteralPath $EnvStorePath -Raw } else { '<absent>' }
    soul        = Test-Path -LiteralPath (Join-Path $HermesHome 'SOUL.md') -PathType Leaf
    claude      = Test-Path -LiteralPath (Join-Path $ClaudeHome 'CLAUDE.md') -PathType Leaf
    codex       = Test-Path -LiteralPath (Join-Path $CodexHome 'AGENTS.md') -PathType Leaf
    router      = Test-Path -LiteralPath (Join-Path $HermesHome 'plugins\hongs-vault-router\router.py') -PathType Leaf
}
Write-Output (([pscustomobject]$reading) | ConvertTo-Json -Depth 4)
'@

# The patcher owns exactly the marked section and inserts it directly after the
# frontmatter, so the fixture separates the frontmatter it appends to from the
# user body that must survive unchanged.
$script:DirtyIndexFrontmatter = @'
---
title: Hong Vault Index
---
'@

$script:DirtyIndexBody = @'

# Index

Local, dirty, user-owned notes that must survive the patch byte for byte.

'@

$script:DirtyIndexPrefix = $script:DirtyIndexFrontmatter + $script:DirtyIndexBody

$script:DirtyIndexSuffix = @'

## Personal links

- [Niagara notes](wiki/niagara.md)
- [Beam notes](wiki/beam.md)
'@

# --------------------------------------------------------------------------
# Fixture construction
# --------------------------------------------------------------------------

function New-RuntimeCase {
    <# One disposable case: synthetic repo, four disposable roots, fake CLI. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Label)

    $script:CaseIndex++
    $case = Join-Path $script:SuiteRoot ('{0:d2}-{1}' -f $script:CaseIndex, $Label)
    $repo = Join-Path $case 'repo'
    $hermes = Join-Path $case 'hermes-home'
    $claude = Join-Path $case 'claude-home'
    $codex = Join-Path $case 'codex-home'
    $vault = Join-Path $case ('vault-' + $script:VaultMarker)
    $fake = Join-Path $case 'fake'
    $runtime = Join-Path $case 'runtime'
    $temp = Join-Path $case 'child-temp'
    # A disposable stand-in for the installed Hermes source tree. The stub
    # verifier only has to find it, so no case reaches the real installation.
    $hermesSource = Join-Path $case 'hermes-source'

    foreach ($directory in @($case, $repo, $hermes, $claude, $codex, $vault, $fake, $runtime, $temp, $hermesSource)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    # Synthetic managed sources.
    foreach ($entry in $script:ManagedDestinations) {
        $path = Join-Path $repo ($entry.Source -replace '/', '\')
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-HarnessFileText -Path $path -Text ("# fixture " + $entry.Source + "`n")
    }

    # Manifest for exactly those sources.
    $records = @()
    foreach ($entry in $script:ManagedDestinations) {
        $path = Join-Path $repo ($entry.Source -replace '/', '\')
        $records += [pscustomobject]@{
            source      = $entry.Source
            targetRoot  = $entry.TargetRoot
            destination = $entry.Destination
            sha256      = Get-HarnessTestHash -Path $path
        }
    }
    $manifestPath = Join-Path $repo 'manifest\harness-manifest.json'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force)
    Set-HarnessFileText -Path $manifestPath -Text ((([pscustomobject]@{ schemaVersion = 1; files = $records }) | ConvertTo-Json -Depth 6) + "`n")

    # The real contract source and the real patcher, so contract preservation
    # is tested against production behaviour rather than a mock.
    $scriptsDirectory = Join-Path $repo 'scripts'
    $contractsDirectory = Join-Path $repo 'contracts'
    [void](New-Item -ItemType Directory -Path $scriptsDirectory -Force)
    [void](New-Item -ItemType Directory -Path $contractsDirectory -Force)
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'scripts\patch-vault-routing-contract.py') `
        -Destination (Join-Path $scriptsDirectory 'patch-vault-routing-contract.py') -Force
    Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'contracts\vault-query-routing-contract.md') `
        -Destination (Join-Path $contractsDirectory 'vault-query-routing-contract.md') -Force
    Set-HarnessFileText -Path (Join-Path $scriptsDirectory 'validate-harness.py') -Text $script:ValidatorStubSource

    # Disposable Vault with a dirty, user-owned index.
    $indexPath = Join-Path $vault 'wiki\index.md'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force)
    Set-HarnessFileText -Path $indexPath -Text ($script:DirtyIndexPrefix + $script:DirtyIndexSuffix)

    # Machine-local logs that rollback must never delete.
    $logsDirectory = Join-Path $hermes 'logs'
    [void](New-Item -ItemType Directory -Path $logsDirectory -Force)
    Set-HarnessFileText -Path (Join-Path $logsDirectory 'vault-routing.jsonl') -Text ('{"event":"fixture"}' + "`n")
    Set-HarnessFileText -Path (Join-Path $logsDirectory 'supervisor-cost-monthly.jsonl') -Text ('{"month":"2026-08"}' + "`n")

    # Fake CLI plus its machine-local store.
    $fakeScript = Join-Path $fake 'fake-hermes.ps1'
    Set-HarnessFileText -Path $fakeScript -Text $script:FakeHermesSource
    $fakeCmd = Join-Path $fake 'hermes.cmd'
    Set-HarnessFileText -Path $fakeCmd -Text "@echo off`r`npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%~dp0fake-hermes.ps1`" %*`r`n"

    $storePath = Join-Path $fake 'config-store.json'
    $configPath = Join-Path $hermes 'config.yaml'
    $logPath = Join-Path $fake 'command-log.txt'
    $entries = @(
        [pscustomobject]@{ path = 'model.default'; value = 'gpt-5.6-terra' },
        [pscustomobject]@{ path = 'model.provider'; value = 'openai-codex' },
        [pscustomobject]@{ path = 'agent.reasoning_effort'; value = 'medium' },
        [pscustomobject]@{ path = 'terminal.theme'; value = 'dark' },
        [pscustomobject]@{ path = 'stt.language'; value = 'ko' },
        [pscustomobject]@{ path = 'secrets.api_key'; value = $script:ConfigSecret },
        [pscustomobject]@{ path = 'plugins.enabled'; values = @('unrelated-plugin') }
    )
    Set-HarnessFileText -Path $storePath -Text ((([pscustomobject]@{ entries = $entries }) | ConvertTo-Json -Depth 6) + "`n")

    $stateDatabase = Join-Path $runtime 'state.db'
    $seedScript = Join-Path $fake 'seed-state.py'
    Set-HarnessFileText -Path $seedScript -Text $script:SeedStateSource

    $seamVerifier = Join-Path $fake 'seam-verifier.py'
    Set-HarnessFileText -Path $seamVerifier -Text $script:SeamVerifierStubSource
    $freshReader = Join-Path $fake 'fresh-reader.ps1'
    Set-HarnessFileText -Path $freshReader -Text $script:FreshReaderSource

    $result = [pscustomobject]@{
        CaseRoot       = $case
        RepositoryRoot = $repo
        HermesHome     = $hermes
        ClaudeHome     = $claude
        CodexHome      = $codex
        VaultRoot      = $vault
        VaultIndex     = $indexPath
        ChildTemp      = $temp
        HermesCommand  = $fakeCmd
        ConfigPath     = $configPath
        StorePath      = $storePath
        LogPath        = $logPath
        StateDatabase  = $stateDatabase
        HermesSource   = $hermesSource
        SeamVerifier   = $seamVerifier
        FreshReader    = $freshReader
        EnvStore       = (Join-Path $case 'user-environment.json')
        Environment    = @{
            FAKE_HERMES_STORE  = $storePath
            FAKE_HERMES_CONFIG = $configPath
            FAKE_HERMES_LOG    = $logPath
        }
    }

    $seed = Invoke-HarnessChildProcess -FilePath 'python' -ArgumentList @($seedScript, $stateDatabase) `
        -WorkingDirectory $case -TempDirectory $temp
    if ($seed.ExitCode -ne 0) {
        throw "RuntimeContractApply.Tests: state database fixture failed: $($seed.StdErr)"
    }

    $render = Invoke-RuntimeFake -Case $result -Arguments @('__fixture-render')
    if ($render.ExitCode -ne 0) {
        throw "RuntimeContractApply.Tests: config fixture failed: $($render.StdErr)"
    }

    return $result
}

function Invoke-WithCaseEnvironment {
    <# Run a scriptblock with the case (and extra) environment applied. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [hashtable]$Environment,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $merged = @{}
    foreach ($key in $Case.Environment.Keys) { $merged[$key] = $Case.Environment[$key] }
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $merged[$key] = $Environment[$key] }
    }

    $previous = @{}
    foreach ($key in $merged.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $merged[$key], 'Process')
    }
    try {
        return & $Body
    }
    finally {
        foreach ($key in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process')
        }
    }
}

function Invoke-RuntimeFake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment
    )

    return Invoke-WithCaseEnvironment -Case $Case -Environment $Environment -Body {
        Invoke-HarnessChildProcess -FilePath $Case.HermesCommand -ArgumentList $Arguments `
            -WorkingDirectory $Case.CaseRoot -TempDirectory $Case.ChildTemp
    }
}

function Get-RuntimeApplyArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [string[]]$Extra
    )

    $arguments = @(
        '-RepositoryRoot', $Case.RepositoryRoot,
        '-HermesHome', $Case.HermesHome,
        '-ClaudeHome', $Case.ClaudeHome,
        '-CodexHome', $Case.CodexHome,
        '-VaultRoot', $Case.VaultRoot,
        '-HermesCommand', $Case.HermesCommand,
        '-StateDatabasePath', $Case.StateDatabase,
        '-UserEnvironmentStorePath', $Case.EnvStore,
        '-HermesSourceRoot', $Case.HermesSource,
        '-SeamVerifierPath', $Case.SeamVerifier
    )
    if ($Extra) { $arguments += $Extra }
    return $arguments
}

function Invoke-RuntimeApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [string[]]$Extra,
        [hashtable]$Environment
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:ApplyScript)
    $arguments += Get-RuntimeApplyArguments -Case $Case -Extra $Extra
    return Invoke-WithCaseEnvironment -Case $Case -Environment $Environment -Body {
        Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList $arguments `
            -WorkingDirectory $Case.CaseRoot -TempDirectory $Case.ChildTemp
    }
}

function Invoke-RuntimeRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string[]]$Extra,
        [hashtable]$Environment
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script:RollbackScript,
        '-BackupRoot', $BackupRoot,
        '-HermesHome', $Case.HermesHome,
        '-ClaudeHome', $Case.ClaudeHome,
        '-CodexHome', $Case.CodexHome,
        '-VaultRoot', $Case.VaultRoot,
        '-UserEnvironmentStorePath', $Case.EnvStore)
    if ($Extra) { $arguments += $Extra }
    return Invoke-WithCaseEnvironment -Case $Case -Environment $Environment -Body {
        Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList $arguments `
            -WorkingDirectory $Case.CaseRoot -TempDirectory $Case.ChildTemp
    }
}

function Get-RuntimeInventory {
    <#
        Every disposable destination as 'root\relative=hash', plus the user
        environment store. Backup directories are excluded: a retained backup is
        evidence, not restored state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    $items = @()
    foreach ($root in @($Case.HermesHome, $Case.ClaudeHome, $Case.CodexHome, $Case.VaultRoot)) {
        $label = Split-Path -Leaf $root
        foreach ($entry in @(Get-HarnessFileInventory -Root $root)) {
            if ($entry -like 'backups\*') { continue }
            $items += ('{0}\{1}' -f $label, $entry)
        }
    }
    if (Test-Path -LiteralPath $Case.EnvStore -PathType Leaf) {
        $items += ('environment=' + (Get-Content -LiteralPath $Case.EnvStore -Raw))
    }
    else {
        $items += 'environment=<absent>'
    }
    return @($items | Sort-Object)
}

function Get-RuntimeCommandLog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    if (-not (Test-Path -LiteralPath $Case.LogPath -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Case.LogPath | Where-Object { $_ -notmatch '^__fixture-render' })
}

function Get-RuntimeBackupRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    $root = Join-Path $Case.HermesHome 'backups\hongs-runtime-contract'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $children = @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)
    if ($children.Count -eq 0) { return $null }
    return $children[$children.Count - 1].FullName
}

function Get-RuntimeConfigText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    return [System.IO.File]::ReadAllText($Case.ConfigPath)
}

function Get-RuntimeIndexText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    return [System.IO.File]::ReadAllText($Case.VaultIndex)
}

function Get-RuntimeOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Result)

    return ($Result.StdOut + "`n" + $Result.StdErr)
}

function Get-RuntimeUnwrappedOutput {
    <#
        Combined child output with every whitespace character removed.

        The apply script reports a failed model contract by throwing, and the
        Windows PowerShell host renders that error record through the format
        engine, which hard-wraps at the host width. A categorical token can
        therefore arrive split across lines, which makes a raw match depend on
        console width rather than on product behaviour. The tokens asserted
        against this text contain no whitespace of their own, so removing
        rendering whitespace keeps the check an exact literal comparison.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Result)

    return ((Get-RuntimeOutput -Result $Result) -replace '\s', '')
}

function New-RuntimeContractErrorRecord {
    <# The error record the apply script raises when the model contract fails. #>
    [CmdletBinding()]
    param()

    try { throw 'MODEL_CONTRACT_UNAVAILABLE: the runtime probe answer did not match the contract.' }
    catch { return $_ }
}

function New-RuntimeResultFromRendering {
    <# A child-process result whose stderr carries an already rendered error. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rendering)

    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = $Rendering }
}

function Get-RuntimeFreshReading {
    <# Re-read config and state from a brand new process. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Case)

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Case.FreshReader,
        '-ConfigPath', $Case.ConfigPath, '-EnvStorePath', $Case.EnvStore,
        '-HermesHome', $Case.HermesHome, '-ClaudeHome', $Case.ClaudeHome, '-CodexHome', $Case.CodexHome)
    $result = Invoke-HarnessChildProcess -FilePath 'powershell.exe' -ArgumentList $arguments `
        -WorkingDirectory $Case.CaseRoot -TempDirectory $Case.ChildTemp
    if ($result.ExitCode -ne 0) {
        throw "RuntimeContractApply.Tests: the fresh reading failed: $($result.StdErr)"
    }
    return ($result.StdOut | ConvertFrom-Json)
}

# Only these stages can fail after the proof; the pre-proof stages restore
# exactly the three model keys instead of the full snapshot.
$script:PreProofFailureStages = @('ModelDefault', 'ModelProvider', 'ModelEffort', 'ModelStageDiff', 'Proof')
$script:FailureStages = @('Installer', 'VaultSection', 'Environment', 'PluginEnable', 'ConfigDiff', 'Verify')

function Invoke-RuntimeApplied {
    <# Apply once against a fresh case and return the case plus the result. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [string[]]$Extra,
        [hashtable]$Environment
    )

    $case = New-RuntimeCase -Label $Label
    $before = Get-RuntimeInventory -Case $case
    $arguments = @('-Apply', '-ConfirmLiveRuntimeMutation')
    if ($Extra) { $arguments += $Extra }
    $result = Invoke-RuntimeApply -Case $case -Extra $arguments -Environment $Environment
    return [pscustomobject]@{
        Case   = $case
        Before = $before
        Result = $result
    }
}

# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

Describe 'runtime contract apply: command contract' {

    It 'refuses when neither -DryRun nor -Apply is given' {
        $case = New-RuntimeCase -Label 'no-mode'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case
        $result.ExitCode | Should Be 2
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }

    It 'refuses when both -DryRun and -Apply are given' {
        $case = New-RuntimeCase -Label 'both-modes'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun', '-Apply', '-ConfirmLiveRuntimeMutation')
        $result.ExitCode | Should Be 2
    }

    It 'refuses -Apply without -ConfirmLiveRuntimeMutation and mutates nothing' {
        $case = New-RuntimeCase -Label 'unconfirmed'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply')
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
        (Get-RuntimeCommandLog -Case $case).Count | Should Be 0
    }
}

Describe 'runtime contract apply: dry run' {

    It 'writes nothing under any destination root' {
        $case = New-RuntimeCase -Label 'dry-run-clean'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Be 0
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
        (Get-RuntimeBackupRoot -Case $case) | Should BeNullOrEmpty
    }

    It 'runs no inference and no mutating Hermes command' {
        $case = New-RuntimeCase -Label 'dry-run-commands'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Be 0
        $log = Get-RuntimeCommandLog -Case $case
        ($log | Where-Object { $_ -match '(^|\s)-z(\s|$)' }).Count | Should Be 0
        ($log | Where-Object { $_ -match 'config set' }).Count | Should Be 0
        ($log | Where-Object { $_ -match 'plugins enable' }).Count | Should Be 0
    }

    It 'names the managed actions and their hashes' {
        $case = New-RuntimeCase -Label 'dry-run-report'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $output = Get-RuntimeOutput -Result $result
        $output | Should Match 'DRY RUN'
        $output | Should Match 'SOUL\.md'
        $output | Should Match 'plugins/hongs-vault-router/router\.py'
        $output | Should Match '[0-9a-f]{64}'
        $output | Should Match 'model\.default'
    }

    It 'prints no config value, environment value, or secret' {
        $case = New-RuntimeCase -Label 'dry-run-redaction'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $output = Get-RuntimeOutput -Result $result
        $output.Contains($script:ConfigSecret) | Should Be $false
        $output.Contains($script:VaultMarker) | Should Be $false
        $output.Contains('gpt-5.6-terra') | Should Be $false
    }

    It 'prints no supplied root path and reports the manifest categorically' {
        $case = New-RuntimeCase -Label 'dry-run-path-redaction'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Be 0
        $unwrapped = Get-RuntimeUnwrappedOutput -Result $result
        foreach ($supplied in @($case.RepositoryRoot, $case.HermesHome, $case.ClaudeHome,
                $case.CodexHome, $case.VaultRoot, $case.HermesSource)) {
            $unwrapped.Contains(($supplied -replace '\s', '')) | Should Be $false
        }
        (Get-RuntimeOutput -Result $result) | Should Match '(?m)^Manifest: verified current\r?$'
    }

    It 'fails preflight when the source validator fails' {
        $case = New-RuntimeCase -Label 'validator-red'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun') -Environment @{ FIXTURE_VALIDATOR_EXIT = '1' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }

    It 'fails preflight when the Vault index is missing' {
        $case = New-RuntimeCase -Label 'index-missing'
        Remove-Item -LiteralPath $case.VaultIndex -Force
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeOutput -Result $result) | Should Match 'VAULT_UNAVAILABLE'
    }

    It 'fails preflight when a fallback provider is configured' {
        $case = New-RuntimeCase -Label 'fallback-configured'
        $result = Invoke-RuntimeFake -Case $case -Arguments @('config', 'set', 'model.fallback_provider', 'anthropic')
        $result.ExitCode | Should Be 0
        $dryRun = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $dryRun.ExitCode | Should Not Be 0
        (Get-RuntimeOutput -Result $dryRun) | Should Match 'fallback'
    }

    It 'fails preflight when openai-codex is not authenticated' {
        $case = New-RuntimeCase -Label 'auth-red'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun') -Environment @{ FAKE_HERMES_AUTH_EXIT = '3' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeOutput -Result $result) | Should Match 'auth'
    }

    It 'calls auth status with the required openai-codex provider positional' {
        $case = New-RuntimeCase -Label 'auth-provider-argument'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Be 0
        $log = Get-RuntimeCommandLog -Case $case
        ($log | Where-Object { $_ -eq 'auth status openai-codex' }).Count | Should Be 1
        ($log | Where-Object { $_ -eq 'auth status' }).Count | Should Be 0
    }
}

Describe 'runtime contract apply: read-only seam preflight' {

    It 'runs the seam verifier during DryRun and still writes nothing' {
        $case = New-RuntimeCase -Label 'seam-dry-run'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-DryRun')
        $result.ExitCode | Should Be 0
        (Get-RuntimeOutput -Result $result) | Should Match 'Reasoning seam: PASS'
        (Get-RuntimeOutput -Result $result) | Should Match 'dispatcher 8/8'
        (Get-RuntimeOutput -Result $result) | Should Match 'payload 4/4'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }

    It 'blocks Apply and mutates nothing when the seam reports FAIL' {
        $case = New-RuntimeCase -Label 'seam-fail'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FIXTURE_SEAM_RESULT = 'FAIL' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'SEAM_FAILED'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
        (Get-RuntimeBackupRoot -Case $case) | Should BeNullOrEmpty
    }

    It 'treats an UNAVAILABLE seam as blocked, never as a pass or an entitlement result' {
        $case = New-RuntimeCase -Label 'seam-unavailable'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FIXTURE_SEAM_RESULT = 'UNAVAILABLE' }
        $result.ExitCode | Should Not Be 0
        $unwrapped = Get-RuntimeUnwrappedOutput -Result $result
        $unwrapped | Should Match 'SEAM_UNAVAILABLE'
        $unwrapped | Should Not Match 'entitlement'
        (Get-RuntimeBackupRoot -Case $case) | Should BeNullOrEmpty
    }
}

Describe 'runtime contract fixture: fake Hermes auth contract' {
    <#
        The installed CLI declares `hermes auth status [-h] provider`, so the
        fixture refuses any other shape. These cases keep the fixture honest:
        if the apply script ever drops or changes the provider positional, the
        preflight cases above fail instead of passing against a lenient fake.
    #>

    It 'rejects auth status without the provider positional' {
        $case = New-RuntimeCase -Label 'fake-auth-no-provider'
        $result = Invoke-RuntimeFake -Case $case -Arguments @('auth', 'status')
        $result.ExitCode | Should Be 2
        (Get-RuntimeOutput -Result $result) | Should Match 'usage: hermes auth status'
    }

    It 'rejects auth status for a provider other than openai-codex' {
        $case = New-RuntimeCase -Label 'fake-auth-other-provider'
        $result = Invoke-RuntimeFake -Case $case -Arguments @('auth', 'status', 'anthropic')
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeOutput -Result $result) | Should Match 'provider'
    }

    It 'rejects auth status with an extra positional argument' {
        $case = New-RuntimeCase -Label 'fake-auth-extra-positional'
        $result = Invoke-RuntimeFake -Case $case -Arguments @('auth', 'status', 'openai-codex', 'extra')
        $result.ExitCode | Should Be 2
    }

    It 'accepts exactly auth status openai-codex' {
        $case = New-RuntimeCase -Label 'fake-auth-exact'
        $result = Invoke-RuntimeFake -Case $case -Arguments @('auth', 'status', 'openai-codex')
        $result.ExitCode | Should Be 0
        $result.StdOut | Should Match 'openai-codex'
    }
}

Describe 'runtime contract fixture: categorical token rendering' {
    <#
        The apply script reports a failed model contract by throwing, and the
        Windows PowerShell host renders that error record through the format
        engine, which hard-wraps at the host width. The categorical token can
        therefore reach a test split across lines on a narrow host and intact on
        a wide one. These cases pin that both renderings prove exactly
        MODEL_CONTRACT_UNAVAILABLE once rendering whitespace is removed, so the
        probe assertions below stay host-independent without being weakened.
    #>

    It 'proves the exact token from host-wrapped rendering that defeats a raw match' {
        $record = New-RuntimeContractErrorRecord
        $wrapped = New-RuntimeResultFromRendering -Rendering ($record | Out-String -Width 20)
        (Get-RuntimeOutput -Result $wrapped) | Should Not Match 'MODEL_CONTRACT_UNAVAILABLE'
        (Get-RuntimeUnwrappedOutput -Result $wrapped) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
    }

    It 'proves the exact token from unwrapped rendering' {
        $record = New-RuntimeContractErrorRecord
        $plain = New-RuntimeResultFromRendering -Rendering ($record | Out-String -Width 200)
        (Get-RuntimeOutput -Result $plain) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
        (Get-RuntimeUnwrappedOutput -Result $plain) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
    }

    It 'still rejects a rendering that carries no categorical token' {
        $other = New-RuntimeResultFromRendering -Rendering "MODEL_CONTRACT_UN`nSOMETHING_ELSE_AVAILABLE"
        (Get-RuntimeUnwrappedOutput -Result $other) | Should Not Match 'MODEL_CONTRACT_UNAVAILABLE'
    }
}

Describe 'runtime contract rollback requirement 1: a verified snapshot precedes every mutation' {

    It 'writes and verifies the snapshot before the first model key is set' {
        $applied = Invoke-RuntimeApplied -Label 'req1-order'
        $applied.Result.ExitCode | Should Be 0
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $backup | Should Not BeNullOrEmpty
        $state = Get-Content -LiteralPath (Join-Path $backup 'state.json') -Raw | ConvertFrom-Json
        $state.schemaVersion | Should Be 2
        @($state.modelKeys).Count | Should Be 3
        $state.modelKeys[0].key | Should Be 'model.default'
        $state.modelKeys[1].key | Should Be 'model.provider'
        $state.modelKeys[2].key | Should Be 'agent.reasoning_effort'
        $state.modelKeys[2].value | Should Be 'medium'
        (Test-Path -LiteralPath (Join-Path $backup 'config\config.yaml')) | Should Be $true
        (Get-RuntimeCommandLog -Case $applied.Case | Where-Object { $_ -match 'config set' }).Count | Should Be 3
    }

    It 'stops with the mutation count at zero when the snapshot cannot be verified' {
        $case = New-RuntimeCase -Label 'req1-unverifiable'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation', '-FailAfterStage', 'Snapshot')
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match 'config set' }).Count | Should Be 0
        (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match '^chat ' }).Count | Should Be 0
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }
}

Describe 'runtime contract rollback requirement 2: only the three approved keys change before the probe' {

    It 'sets exactly model.default, model.provider, agent.reasoning_effort in that order before the proof' {
        $applied = Invoke-RuntimeApplied -Label 'req2-order'
        $applied.Result.ExitCode | Should Be 0
        $log = Get-RuntimeCommandLog -Case $applied.Case
        $sets = @($log | Where-Object { $_ -match '^config set ' })
        $sets.Count | Should Be 3
        $sets[0] | Should Be 'config set model.default gpt-5.6-sol'
        $sets[1] | Should Be 'config set model.provider openai-codex'
        $sets[2] | Should Be 'config set agent.reasoning_effort high'
        $proofIndex = [array]::IndexOf($log, ($log | Where-Object { $_ -match '^chat ' } | Select-Object -First 1))
        $lastSetIndex = [array]::IndexOf($log, $sets[2])
        ($lastSetIndex -lt $proofIndex) | Should Be $true
    }

    It 'runs no installer, Vault, environment, or plugin mutation before the proof' {
        $case = New-RuntimeCase -Label 'req2-no-early-mutation'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation', '-FailAfterStage', 'ModelStageDiff')
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match 'plugins enable' }).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'SOUL.md')) | Should Be $false
        (Test-Path -LiteralPath $case.EnvStore) | Should Be $false
        (Get-RuntimeIndexText -Case $case) | Should Not Match 'hongs-vault-routing-contract:start'
    }

    It 'refuses a model stage that changed anything outside the three approved keys' {
        $case = New-RuntimeCase -Label 'req2-extra-key'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_EXTRA_PATH = 'terminal.theme'; FAKE_HERMES_EXTRA_VALUE = 'solarized' }
        $result.ExitCode | Should Not Be 0
        # The refusal names the offending key inside a long thrown message, and
        # the host format engine hard-wraps that message at the console width,
        # so the key itself can arrive split across two lines. The token carries
        # no whitespace of its own, so the unwrapped reading below stays an
        # exact literal check rather than a host-width-dependent one.
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'terminal\.theme'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }
}

Describe 'runtime contract rollback requirement 3: exact explicit-classic fresh probe with correlated evidence' {

    It 'proves the contract through exactly hermes chat --cli -Q -q with the frozen prompt and no override' {
        $applied = Invoke-RuntimeApplied -Label 'req3-caller'
        $applied.Result.ExitCode | Should Be 0
        $proofs = @(Get-RuntimeCommandLog -Case $applied.Case | Where-Object { $_ -match '^chat ' })
        $proofs.Count | Should Be 1
        $proofs[0] | Should Be 'chat --cli -Q -q Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools.'
    }

    It 'never uses the -z/--oneshot caller or any model, provider, reasoning, or usage-file override' {
        $applied = Invoke-RuntimeApplied -Label 'req3-no-override'
        $applied.Result.ExitCode | Should Be 0
        $log = Get-RuntimeCommandLog -Case $applied.Case
        ($log | Where-Object { $_ -match '(^|\s)(-z|--oneshot)(\s|$)' }).Count | Should Be 0
        ($log | Where-Object { $_ -match '--model|--provider|--reasoning|--usage-file' }).Count | Should Be 0
        [System.IO.File]::ReadAllText($script:ApplyScript) | Should Not Match "'-z'"
    }

    It 'fails when the correlated session reports a different model' {
        $case = New-RuntimeCase -Label 'req3-wrong-model'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_SESSION = 'proof-session-terra' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }

    It 'fails when the correlated billing provider is not openai-codex' {
        $case = New-RuntimeCase -Label 'req3-wrong-provider'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_SESSION = 'proof-session-anthropic' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
    }

    It 'fails when the correlated session effort is not high or its reasoning config is disabled' {
        foreach ($session in @('proof-session-medium', 'proof-session-disabled')) {
            $case = New-RuntimeCase -Label ('req3-effort-' + $session)
            $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
                -Environment @{ FAKE_HERMES_CHAT_SESSION = $session }
            $result.ExitCode | Should Not Be 0
            (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
        }
    }

    It 'fails when the session cannot be correlated and when no session line is emitted' {
        $absent = New-RuntimeCase -Label 'req3-absent-session'
        $result = Invoke-RuntimeApply -Case $absent -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_SESSION = 'proof-session-absent' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'

        $silent = New-RuntimeCase -Label 'req3-no-session-line'
        $result2 = Invoke-RuntimeApply -Case $silent -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_NO_SESSION_LINE = '1' }
        $result2.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result2) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'
    }

    It 'never prints the session identifier, the contract prompt, or a config value' {
        $applied = Invoke-RuntimeApplied -Label 'req3-redaction'
        $applied.Result.ExitCode | Should Be 0
        $output = Get-RuntimeOutput -Result $applied.Result
        $output.Contains('proof-session-high') | Should Be $false
        $output.Contains('MODEL_CONTRACT_PROBE_OK') | Should Be $false
        $output.Contains($script:ConfigSecret) | Should Be $false
        $output.Contains($script:VaultMarker) | Should Be $false
    }
}

Describe 'runtime contract rollback requirement 4: probe failure restores exactly the three keys' {

    It 'restores all three keys, keeps later mutation at zero, retains the snapshot, and reports MODEL_CONTRACT_UNAVAILABLE' {
        $case = New-RuntimeCase -Label 'req4-probe-failure'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_TEXT = 'sure, here is your answer' }

        $result.ExitCode | Should Not Be 0
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'MODEL_CONTRACT_UNAVAILABLE'

        $config = Get-RuntimeConfigText -Case $case
        $config | Should Match 'default: gpt-5\.6-terra'
        $config | Should Match 'reasoning_effort: medium'
        $config | Should Not Match 'reasoning_effort: high'

        (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match 'plugins enable' }).Count | Should Be 0
        (Test-Path -LiteralPath (Join-Path $case.HermesHome 'SOUL.md')) | Should Be $false
        (Test-Path -LiteralPath $case.EnvStore) | Should Be $false
        (Get-RuntimeIndexText -Case $case) | Should Not Match 'hongs-vault-routing-contract:start'

        $backup = Get-RuntimeBackupRoot -Case $case
        $backup | Should Not BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $backup 'state.json')) | Should Be $true
        (Get-RuntimeOutput -Result $result) | Should Match 'Backup retained'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }
}

Describe 'runtime contract apply: transaction' {

    It 'installs managed files, enables the plugin, and sets exactly three model keys' {
        $applied = Invoke-RuntimeApplied -Label 'apply-happy'
        $applied.Result.ExitCode | Should Be 0

        Test-Path -LiteralPath (Join-Path $applied.Case.HermesHome 'SOUL.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $applied.Case.ClaudeHome 'CLAUDE.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $applied.Case.CodexHome 'AGENTS.md') | Should Be $true
        Test-Path -LiteralPath (Join-Path $applied.Case.HermesHome 'plugins\hongs-vault-router\router.py') | Should Be $true

        $config = Get-RuntimeConfigText -Case $applied.Case
        $config | Should Match 'default: gpt-5\.6-sol'
        $config | Should Match 'provider: openai-codex'
        $config | Should Match 'reasoning_effort: high'
        $config | Should Match 'allow_tool_override: false'
        $config | Should Match ('- ' + $script:PluginName)
        $config | Should Match 'theme: dark'
    }

    It 'sets the user HONG_VAULT_ROOT through the disposable environment store' {
        $applied = Invoke-RuntimeApplied -Label 'apply-environment'
        $applied.Result.ExitCode | Should Be 0
        $store = Get-Content -LiteralPath $applied.Case.EnvStore -Raw | ConvertFrom-Json
        $store.HONG_VAULT_ROOT.set | Should Be $true
        $store.HONG_VAULT_ROOT.value | Should Be $applied.Case.VaultRoot
    }

    It 'patches only the marked section and preserves the dirty index bytes' {
        $applied = Invoke-RuntimeApplied -Label 'apply-index'
        $applied.Result.ExitCode | Should Be 0
        $index = Get-RuntimeIndexText -Case $applied.Case
        $index.StartsWith($script:DirtyIndexFrontmatter) | Should Be $true
        $index.Contains($script:DirtyIndexBody) | Should Be $true
        $index.EndsWith($script:DirtyIndexSuffix) | Should Be $true
        $index | Should Match '<!-- hongs-vault-routing-contract:start -->'
        $index | Should Match '<!-- hongs-vault-routing-contract:end -->'
    }

    It 'accepts an unrelated config rewrite that is semantically equal' {
        $applied = Invoke-RuntimeApplied -Label 'apply-reformat' -Environment @{ FAKE_HERMES_REFORMAT = '1' }
        $applied.Result.ExitCode | Should Be 0
        $config = Get-RuntimeConfigText -Case $applied.Case
        $config | Should Match 'theme: dark'
        $config | Should Match 'reasoning_effort: high'
    }

    It 'rolls back when an unapproved config key changes' {
        $case = New-RuntimeCase -Label 'apply-extra-key'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_EXTRA_PATH = 'terminal.theme'; FAKE_HERMES_EXTRA_VALUE = 'solarized' }
        $result.ExitCode | Should Not Be 0
        # Host-wrapped for the same reason as the requirement 2 case above.
        (Get-RuntimeUnwrappedOutput -Result $result) | Should Match 'terminal\.theme'
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }

    It 'keeps the snapshot machine-local and prints no snapshot content' {
        $applied = Invoke-RuntimeApplied -Label 'apply-snapshot'
        $applied.Result.ExitCode | Should Be 0
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $backup | Should Not BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $backup 'state.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $backup 'config\config.yaml') | Should Be $true
        Test-Path -LiteralPath (Join-Path $backup 'vault\wiki\index.md') | Should Be $true

        $output = Get-RuntimeOutput -Result $applied.Result
        $output.Contains($script:ConfigSecret) | Should Be $false
        $output.Contains($script:VaultMarker) | Should Be $false
    }
}

Describe 'runtime contract rollback requirement 5: each later injected failure restores every approved target' {

    foreach ($stage in $script:FailureStages) {
        It ('restores every approved target when the ' + $stage + ' stage fails after the proof') {
            $case = New-RuntimeCase -Label ('req5-' + $stage.ToLowerInvariant())
            $before = Get-RuntimeInventory -Case $case
            $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation', '-FailAfterStage', $stage)
            $result.ExitCode | Should Not Be 0
            (Get-RuntimeOutput -Result $result) | Should Match 'Backup retained'
            (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match '^chat ' }).Count | Should Be 1
            (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
        }
    }

    foreach ($stage in $script:PreProofFailureStages) {
        It ('restores the three keys when the pre-proof ' + $stage + ' stage fails') {
            $case = New-RuntimeCase -Label ('req5-pre-' + $stage.ToLowerInvariant())
            $before = Get-RuntimeInventory -Case $case
            $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation', '-FailAfterStage', $stage)
            $result.ExitCode | Should Not Be 0
            (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
        }
    }

    It 'rolls back when the Hermes CLI refuses a model key' {
        $case = New-RuntimeCase -Label 'req5-cli-refusal'
        $before = Get-RuntimeInventory -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_FAIL_COMMAND = 'config.set:agent.reasoning_effort' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $case) -join "`n" | Should Be ($before -join "`n")
    }
}

Describe 'runtime contract rollback requirement 6: a fresh post-rollback read shows no partial activation' {

    It 'reads the pre-apply configuration and state from a new process after an explicit rollback' {
        $case = New-RuntimeCase -Label 'req6-fresh-read'
        $preApply = Get-RuntimeFreshReading -Case $case

        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation')
        $result.ExitCode | Should Be 0
        $rollback = Invoke-RuntimeRollback -Case $case -BackupRoot (Get-RuntimeBackupRoot -Case $case)
        $rollback.ExitCode | Should Be 0

        $fresh = Get-RuntimeFreshReading -Case $case
        $fresh.config | Should Be $preApply.config
        $fresh.environment | Should Be $preApply.environment
        $fresh.config | Should Match 'reasoning_effort: medium'
        $fresh.config | Should Not Match 'reasoning_effort: high'
        $fresh.config | Should Not Match ('- ' + $script:PluginName)
        $fresh.soul | Should Be $false
        $fresh.claude | Should Be $false
        $fresh.codex | Should Be $false
        $fresh.router | Should Be $false
    }

    It 'reads the pre-apply configuration and state from a new process after an automatic rollback' {
        $case = New-RuntimeCase -Label 'req6-fresh-read-auto'
        $preApply = Get-RuntimeFreshReading -Case $case
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation', '-FailAfterStage', 'Verify')
        $result.ExitCode | Should Not Be 0
        $fresh = Get-RuntimeFreshReading -Case $case
        $fresh.config | Should Be $preApply.config
        $fresh.environment | Should Be $preApply.environment
    }
}

Describe 'runtime contract rollback requirement 7: no automatic live retry exists in the source' {
    <#
        Requirement 7 itself — "the pre-gate live retry count stays at 0" — is
        process evidence held by the supervisor, not a unit test. A Pester case
        asserting a hard-coded 0 would prove nothing about the live runtime and
        is forbidden by this plan. The two cases here are the real, adjacent
        source facts that can be measured: the proof runs exactly once, and no
        retry loop exists around it.
    #>

    It 'runs the post-apply proof exactly once per Apply' {
        $applied = Invoke-RuntimeApplied -Label 'req7-single-proof'
        $applied.Result.ExitCode | Should Be 0
        (Get-RuntimeCommandLog -Case $applied.Case | Where-Object { $_ -match '^chat ' }).Count | Should Be 1
    }

    It 'does not retry the proof after a failure' {
        $case = New-RuntimeCase -Label 'req7-no-retry'
        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation') `
            -Environment @{ FAKE_HERMES_CHAT_EXIT = '4' }
        $result.ExitCode | Should Not Be 0
        (Get-RuntimeCommandLog -Case $case | Where-Object { $_ -match '^chat ' }).Count | Should Be 1
    }
}

Describe 'runtime contract rollback' {

    It 'restores the prior state and is idempotent' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-idempotent'
        $applied.Result.ExitCode | Should Be 0
        $backup = Get-RuntimeBackupRoot -Case $applied.Case

        $first = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $first.ExitCode | Should Be 0
        $afterFirst = Get-RuntimeInventory -Case $applied.Case
        $afterFirst -join "`n" | Should Be ($applied.Before -join "`n")

        $second = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $second.ExitCode | Should Be 0
        (Get-RuntimeInventory -Case $applied.Case) -join "`n" | Should Be ($afterFirst -join "`n")
    }

    It 'unsets HONG_VAULT_ROOT when it was previously unset' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-unset'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Be 0
        $isSet = $false
        if (Test-Path -LiteralPath $applied.Case.EnvStore -PathType Leaf) {
            $store = Get-Content -LiteralPath $applied.Case.EnvStore -Raw | ConvertFrom-Json
            if ($store -and $store.PSObject.Properties['HONG_VAULT_ROOT']) {
                $isSet = [bool]$store.HONG_VAULT_ROOT.set
            }
        }
        $isSet | Should Be $false
    }

    It 'restores a previous HONG_VAULT_ROOT value' {
        $case = New-RuntimeCase -Label 'rollback-previous-value'
        $previous = Join-Path $case.CaseRoot 'previous-vault'
        [void](New-Item -ItemType Directory -Path $previous -Force)
        Set-HarnessFileText -Path $case.EnvStore -Text (((
                    [pscustomobject]@{ HONG_VAULT_ROOT = [pscustomobject]@{ set = $true; value = $previous } }
                ) | ConvertTo-Json -Depth 4) + "`n")

        $result = Invoke-RuntimeApply -Case $case -Extra @('-Apply', '-ConfirmLiveRuntimeMutation')
        $result.ExitCode | Should Be 0
        $backup = Get-RuntimeBackupRoot -Case $case
        $rollback = Invoke-RuntimeRollback -Case $case -BackupRoot $backup
        $rollback.ExitCode | Should Be 0
        $store = Get-Content -LiteralPath $case.EnvStore -Raw | ConvertFrom-Json
        $store.HONG_VAULT_ROOT.set | Should Be $true
        $store.HONG_VAULT_ROOT.value | Should Be $previous
    }

    It 'never deletes routing or cost logs' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-logs'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path $applied.Case.HermesHome 'logs\vault-routing.jsonl') | Should Be $true
        Test-Path -LiteralPath (Join-Path $applied.Case.HermesHome 'logs\supervisor-cost-monthly.jsonl') | Should Be $true
    }

    It 'retains the backup as evidence and prints no secret or Vault value' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-evidence'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path $backup 'state.json') | Should Be $true
        $output = Get-RuntimeOutput -Result $rollback
        $output.Contains($script:ConfigSecret) | Should Be $false
        $output.Contains($script:VaultMarker) | Should Be $false
    }

    It 'refuses a snapshot with an unknown schema' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-bad-schema'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $statePath = Join-Path $backup 'state.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.schemaVersion = 99
        Set-HarnessFileText -Path $statePath -Text (($state | ConvertTo-Json -Depth 8) + "`n")

        $applied2 = Get-RuntimeInventory -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $applied.Case) -join "`n" | Should Be ($applied2 -join "`n")
    }

    It 'refuses a snapshot whose recorded hash no longer matches' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-bad-hash'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        Set-HarnessFileText -Path (Join-Path $backup 'config\config.yaml') -Text "tampered: true`n"

        $current = Get-RuntimeInventory -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $applied.Case) -join "`n" | Should Be ($current -join "`n")
    }

    It 'refuses a snapshot taken for different roots' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-wrong-roots'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $other = New-RuntimeCase -Label 'rollback-wrong-roots-other'
        $current = Get-RuntimeInventory -Case $other
        $rollback = Invoke-RuntimeRollback -Case $other -BackupRoot $backup
        $rollback.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $other) -join "`n" | Should Be ($current -join "`n")
    }
}

Describe 'runtime contract rollback: snapshot schema' {

    It 'refuses a version 1 snapshot rather than restoring it partially' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-old-schema'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $statePath = Join-Path $backup 'state.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.schemaVersion = 1
        Set-HarnessFileText -Path $statePath -Text (($state | ConvertTo-Json -Depth 8) + "`n")

        $current = Get-RuntimeInventory -Case $applied.Case
        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Not Be 0
        (Get-RuntimeInventory -Case $applied.Case) -join "`n" | Should Be ($current -join "`n")
    }

    It 'refuses a snapshot whose modelKeys record is absent or reordered' {
        $applied = Invoke-RuntimeApplied -Label 'rollback-bad-model-keys'
        $backup = Get-RuntimeBackupRoot -Case $applied.Case
        $statePath = Join-Path $backup 'state.json'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        $state.modelKeys = @($state.modelKeys[2], $state.modelKeys[1], $state.modelKeys[0])
        Set-HarnessFileText -Path $statePath -Text (($state | ConvertTo-Json -Depth 8) + "`n")

        $rollback = Invoke-RuntimeRollback -Case $applied.Case -BackupRoot $backup
        $rollback.ExitCode | Should Not Be 0
    }
}

Describe 'runtime contract scripts: no remote side effect' {

    It 'contains no network, publication, or git remote command' {
        $pattern = 'Invoke-WebRequest|Invoke-RestMethod|System\.Net\.WebClient|Start-BitsTransfer|Send-MailMessage|New-WebServiceProxy|git\s+push|curl\s|gh\s+(repo|pr|release)'
        foreach ($path in @($script:ApplyScript, $script:RollbackScript)) {
            $text = [System.IO.File]::ReadAllText($path)
            ($text -match $pattern) | Should Be $false
        }
    }

    It 'reads no credential store' {
        $pattern = 'auth\.json|\.env\b|ANTHROPIC_API_KEY|OPENAI_API_KEY|credentials'
        foreach ($path in @($script:ApplyScript, $script:RollbackScript)) {
            $text = [System.IO.File]::ReadAllText($path)
            ($text -match $pattern) | Should Be $false
        }
    }
}
