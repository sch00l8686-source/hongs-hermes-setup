<#
    Behavioural tests for the fresh-process runtime contract probe runner.

    No test here starts a real Hermes, Claude, or Codex session and no test
    touches a live home, a live Vault, a live configuration, or the network.
    The runner script is parsed, and only its function and table definitions are
    dot-sourced, so its confirmation gate and its probe loop never run by
    accident. Where behaviour can only be shown end to end, the runner is
    launched as a child process against a disposable fake `hermes.cmd`, four
    disposable roots, and a disposable state database inside one GUID temp root.

    The probe prompts are additionally routed through the real router module
    against the real routing contract, so a prompt that would accidentally
    trigger or suppress its own route fails here rather than during a live run.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

# $PSScriptRoot stays correct when this file is dot-sourced from the canonical
# entry point tests/Test-RuntimeContractProbe.ps1; $MyInvocation is the 5.1
# fallback.
$script:TestsDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepositoryRoot = (Resolve-Path (Join-Path $script:TestsDirectory '..\..')).ProviderPath
$script:RunnerPath = Join-Path $script:RepositoryRoot 'scripts\run-runtime-contract-probes.ps1'
$script:Phase1Path = Join-Path $script:RepositoryRoot 'scripts\run-harness-probes.ps1'
$script:RouterDirectory = Join-Path $script:RepositoryRoot 'baseline\hermes\plugins\hongs-vault-router'
$script:ContractSourcePath = Join-Path $script:RepositoryRoot 'contracts\vault-query-routing-contract.md'

. (Join-Path $script:TestsDirectory 'HarnessTestHelpers.ps1')

# A distinctive string the fake runtime prints on every turn. No persisted
# artefact of a run may contain it: raw model output is reduced in memory and
# dropped.
$script:ProbeSecret = 'RAW-MODEL-TEXT-DO-NOT-PERSIST-4b71e'

# The citation probe's expected source page name is caller-supplied fixture
# input, so it must not be written into the verdict-only envelope either.
$script:CitationPage = 'niagara-beam-page'

$script:ExpectedProbeIds = @(
    'explicit-entered',
    'heartbeat-skipped',
    'korean-domain-entered',
    'phase1-regression',
    'router-missing-fail-closed',
    'runtime-identity',
    'telemetry-denied-fail-open',
    'vault-answer-citations',
    'vault-unavailable'
)

$script:ExpectedMarkerTokens = @(
    'HEARTBEAT_SKIPPED',
    'HEARTBEAT_ENTERED_EXPLICIT',
    'HEARTBEAT_ENTERED_DOMAIN',
    'HEARTBEAT_UNAVAILABLE',
    'ROUTER_UNAVAILABLE'
)

# The frozen identity prompt. It is an independent literal here on purpose: a
# drift in the runner's copy must fail rather than be mirrored.
$script:ExpectedIdentityPrompt = 'Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools.'

# The classic Hermes caller. Every Hermes behaviour probe uses exactly this
# array, with its own behaviour prompt as the final element.
$script:ExpectedLauncherPrefix = @('chat', '--cli', '-Q', '-q')

# A distinctive string the fake runtime writes to standard error only. Stderr is
# read into memory to correlate one session id and must never be persisted.
$script:StdErrSecret = 'RAW-STDERR-TEXT-DO-NOT-PERSIST-9c02f'

$script:ProbeSessionId = 'probe-session-high'

# A distinctive string that only ever exists in the disposable applied home's
# own root material - its configuration, its OAuth file, its environment file.
# A disposable profile that carries it would prove the runner copied root
# material instead of generating a minimal synthetic configuration of its own.
$script:RootMaterialSecret = 'ROOT-MATERIAL-DO-NOT-COPY-1f5d8'

# A distinctive string inside the fake router plugin package. Every test plugin
# is a disposable fake: the tracked baseline router package is never copied,
# installed, or otherwise touched by these tests.
$script:FakePluginMarker = 'FAKE-DISPOSABLE-ROUTER-PACKAGE-7e31a'

# The exact minimal synthetic runtime configuration a disposable profile must
# carry. These are independent literals on purpose: a drift in the runner's own
# contract constants must fail here rather than be mirrored.
$script:ExpectedProfileConfigHead = @(
    'model:',
    '  default: gpt-5.6-sol',
    '  provider: openai-codex',
    'agent:',
    '  reasoning_effort: high',
    'plugins:'
) -join "`n"

$script:ExpectedTelemetryConfig = $script:ExpectedProfileConfigHead + "`n" + (@(
        '  enabled:',
        '    - hongs-vault-router',
        '  disabled: []'
    ) -join "`n") + "`n"

$script:ExpectedRouterDisabledConfig = $script:ExpectedProfileConfigHead + "`n" + (@(
        '  enabled: []',
        '  disabled:',
        '    - hongs-vault-router'
    ) -join "`n") + "`n"

# The fake router plugin package installed into each disposable applied home.
# It is nested on purpose, so a copy that only handled top-level files would
# fail rather than pass.
$script:FakePluginFiles = @{
    'plugin.yaml'             = "name: hongs-vault-router`nversion: 0.0.0-fake`nkind: standalone`n"
    'router.py'               = "# $script:FakePluginMarker`n"
    'hooks\pre_llm_call.py'   = "# $script:FakePluginMarker nested`n"
}

$script:ExpectedPluginRelativeFiles = @(
    'plugins\hongs-vault-router\hooks\pre_llm_call.py',
    'plugins\hongs-vault-router\plugin.yaml',
    'plugins\hongs-vault-router\router.py'
)


# --------------------------------------------------------------------------
# Source access: parse, never execute
# --------------------------------------------------------------------------

function Get-RunnerAst {
    <# Parse the runner script once. Parsing executes nothing. #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:RunnerAst) {
        $tokens = $null
        $errors = $null
        $script:RunnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:RunnerPath, [ref]$tokens, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) {
            throw "RuntimeContractProbe.Tests: '$script:RunnerPath' failed to parse."
        }
    }
    return $script:RunnerAst
}

function Get-RunnerFunctionDefinition {
    <#
        Return one function of the runner as a script block, taken verbatim from
        the production file. Dot-sourcing the result defines the real function
        without running the runner's gates or probe loop.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $ast = Get-RunnerAst
    $found = @($ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq $Name)
            }, $false))
    if ($found.Count -ne 1) {
        throw "RuntimeContractProbe.Tests: expected exactly one definition of '$Name', found $($found.Count)."
    }
    return [scriptblock]::Create($found[0].Extent.Text)
}

function Get-RunnerVariableDefinition {
    <#
        Return one script-scope assignment of the runner as a script block.
        Dot-sourcing it defines the real value in the test scope, so the tests
        assert on the production table rather than on a copy of it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $ast = Get-RunnerAst
    $target = '$script:' + $Name
    $found = @($ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
                ($node.Left.Extent.Text -eq $target)
            }, $false))
    if ($found.Count -ne 1) {
        throw "RuntimeContractProbe.Tests: expected exactly one assignment of '$target', found $($found.Count)."
    }
    return [scriptblock]::Create($found[0].Extent.Text)
}

function Get-RunnerSourceText {
    [CmdletBinding()]
    param()

    if ($null -eq $script:RunnerText) {
        $script:RunnerText = [System.IO.File]::ReadAllText($script:RunnerPath)
    }
    return $script:RunnerText
}

function Get-ProbeById {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)

    $found = @($script:ContractProbes | Where-Object { $_.Id -eq $Id })
    if ($found.Count -ne 1) {
        throw "RuntimeContractProbe.Tests: expected exactly one probe '$Id', found $($found.Count)."
    }
    return $found[0]
}


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

# Seeds a disposable SQLite state database shaped like the runtime state the
# runner correlates: sessions carry the model and the reasoning configuration,
# session_model_usage carries the billing provider. One session sits at the
# contract effort, one below it, one has no usage row at all, and one is
# deliberately billed by two providers so the reader's fail-closed path is real.
$script:SeedStateSource = @'
import json
import sqlite3
import sys


def model_config(effort):
    return json.dumps({"reasoning_config": {"enabled": True, "effort": effort}})


connection = sqlite3.connect(sys.argv[1])
try:
    with connection:
        connection.execute("CREATE TABLE sessions (id TEXT, model TEXT, model_config TEXT)")
        connection.execute(
            "CREATE TABLE session_model_usage (session_id TEXT, billing_provider TEXT)"
        )
        for session_id, effort in (
            ("probe-session-high", "high"),
            ("probe-session-medium", "medium"),
            ("probe-session-no-usage", "high"),
            ("probe-session-two-providers", "high"),
        ):
            connection.execute(
                "INSERT INTO sessions (id, model, model_config) VALUES (?, ?, ?)",
                (session_id, "gpt-5.6-sol", model_config(effort)),
            )
        for session_id, provider in (
            ("probe-session-high", "openai-codex"),
            ("probe-session-high", "openai-codex"),
            ("probe-session-medium", "openai-codex"),
            ("probe-session-two-providers", "openai-codex"),
            ("probe-session-two-providers", "anthropic"),
        ):
            connection.execute(
                "INSERT INTO session_model_usage (session_id, billing_provider) VALUES (?, ?)",
                (session_id, provider),
            )
finally:
    connection.close()
'@

# Routes each probe prompt through the real router module against the real
# routing contract, inside a disposable Vault. The routing home is an explicit
# disposable directory, so no live telemetry file is ever appended to, and the
# matched aliases are reduced to a count so the report stays ASCII on any
# console code page.
$script:RouteProbesSource = @'
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])

import router  # noqa: E402

with open(sys.argv[2], "r", encoding="utf-8") as handle:
    prompts = json.load(handle)

for entry in prompts:
    marker = router.route_turn(
        entry["prompt"], "", hermes_home=router.Path(sys.argv[4]), vault_root=sys.argv[3]
    )
    head, _, tail = marker.partition(" matched=")
    count = len([alias for alias in tail.split(",") if alias]) if tail else 0
    print("%s\t%s\tmatched=%d" % (entry["id"], head, count))
'@

# A fake Hermes CLI. It refuses anything that is not the classic caller, so an
# end-to-end run proves the launcher shape rather than only the unit assertion
# on the argument list. It answers with a chatty, secret-bearing body plus one
# bounded verdict line on stdout, and announces its session id together with a
# second secret on stderr. It reaches no network and knows nothing outside its
# case directory. There is no param block on purpose: a declared parameter would
# make Windows PowerShell bind '-Q' and '-q' instead of passing them through.
$script:FakeHermesSource = @'
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$arguments = @($args)
$expected = @('chat', '--cli', '-Q', '-q')

if ($arguments.Count -ne ($expected.Count + 1)) {
    [Console]::Error.WriteLine('fake-hermes: unexpected argument count')
    exit 3
}
for ($i = 0; $i -lt $expected.Count; $i++) {
    if ($arguments[$i] -cne $expected[$i]) {
        [Console]::Error.WriteLine('fake-hermes: unexpected argument shape')
        exit 3
    }
}

[Console]::Error.WriteLine('fake-hermes: ' + $env:FAKE_STDERR_SECRET)
[Console]::Error.WriteLine('session_id: ' + $env:FAKE_SESSION_ID)

Write-Output ('a long chatty answer carrying ' + $env:FAKE_PROBE_SECRET + ' in its body')
Write-Output ('SOURCES: ' + $env:FAKE_PROBE_PAGE)
Write-Output 'VERDICT: HEARTBEAT_SKIPPED'
exit 0
'@

function Install-FakeRouterPlugin {
    <#
        Install the disposable fake router package into a disposable applied
        home. Nothing here reads or copies the tracked baseline package.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$HermesHome)

    $package = Join-Path $HermesHome 'plugins\hongs-vault-router'
    foreach ($relative in @($script:FakePluginFiles.Keys)) {
        $target = Join-Path $package $relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        Set-HarnessFileText -Path $target -Text $script:FakePluginFiles[$relative]
    }
    return $package
}

function New-ProbeCase {
    <#
        One disposable case: four disposable roots, a disposable Vault, a fake
        Hermes launcher, a disposable state database, and an output directory.

        The disposable applied home carries the fake router package the runner
        must install into a profile, and root material - configuration, OAuth,
        and an environment file - the runner must never copy anywhere.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Label)

    $case = Join-Path $script:ProbeSuiteRoot $Label
    $hermes = Join-Path $case 'hermes-home'
    $claude = Join-Path $case 'claude-home'
    $codex = Join-Path $case 'codex-home'
    $vault = Join-Path $case 'vault'
    $fake = Join-Path $case 'fake'
    $runtime = Join-Path $case 'runtime'
    $output = Join-Path $case 'output'
    $temp = Join-Path $case 'child-temp'

    foreach ($directory in @($case, $hermes, $claude, $codex, $vault, $fake, $runtime, $output, $temp)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    [void](Install-FakeRouterPlugin -HermesHome $hermes)
    foreach ($rootFile in @('config.yaml', 'auth.json', '.env')) {
        Set-HarnessFileText -Path (Join-Path $hermes $rootFile) `
            -Text ("root-material: $script:RootMaterialSecret`n")
    }

    $indexPath = Join-Path $vault 'wiki\index.md'
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $indexPath) -Force)
    Set-HarnessFileText -Path $indexPath -Text ([System.IO.File]::ReadAllText($script:ContractSourcePath))

    $fakeScript = Join-Path $fake 'fake-hermes.ps1'
    Set-HarnessFileText -Path $fakeScript -Text $script:FakeHermesSource
    $fakeCmd = Join-Path $fake 'hermes.cmd'
    Set-HarnessFileText -Path $fakeCmd -Text (
        "@echo off`r`npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
        "`"%~dp0fake-hermes.ps1`" %*`r`n")

    $stateDatabase = Join-Path $runtime 'state.db'
    $seedScript = Join-Path $fake 'seed-state.py'
    Set-HarnessFileText -Path $seedScript -Text $script:SeedStateSource
    $seed = Invoke-HarnessChildProcess -FilePath 'python' -ArgumentList @($seedScript, $stateDatabase) `
        -WorkingDirectory $case -TempDirectory $temp
    if ($seed.ExitCode -ne 0) {
        throw "RuntimeContractProbe.Tests: state database fixture failed: $($seed.StdErr)"
    }

    return [pscustomobject]@{
        CaseRoot        = $case
        HermesHome      = $hermes
        ClaudeHome      = $claude
        CodexHome       = $codex
        VaultRoot       = $vault
        OutputDirectory = $output
        ChildTemp       = $temp
        FakeDirectory   = $fake
        HermesCommand   = $fakeCmd
        StateDatabase   = $stateDatabase
        ResultPath      = (Join-Path $output 'runtime-contract-probe-results.json')
    }
}

function Invoke-ProbeRunner {
    <# Launch the runner as a child process with a bounded environment. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExtraArguments,
        [hashtable]$Environment
    )

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:RunnerPath,
        '-RepositoryRoot', $script:RepositoryRoot,
        '-HermesHome', $Case.HermesHome,
        '-ClaudeHome', $Case.ClaudeHome,
        '-CodexHome', $Case.CodexHome,
        '-VaultRoot', $Case.VaultRoot,
        '-OutputDirectory', $Case.OutputDirectory,
        '-HermesCommand', $Case.HermesCommand,
        '-PythonCommand', $script:PythonLauncher,
        '-StateDatabasePath', $Case.StateDatabase
    ) + $ExtraArguments

    $saved = @{}
    $applied = @{}
    if ($Environment) { foreach ($key in $Environment.Keys) { $applied[$key] = $Environment[$key] } }
    try {
        foreach ($key in @($applied.Keys)) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $applied[$key], 'Process')
        }
        return Invoke-HarnessChildProcess -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList $arguments -WorkingDirectory $Case.CaseRoot `
            -TempDirectory $Case.ChildTemp -TimeoutSeconds 600
    }
    finally {
        foreach ($key in @($saved.Keys)) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
}

function Get-CaseFileTexts {
    <# Every persisted byte of a case output directory, as text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $texts = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $texts += [System.IO.File]::ReadAllText($file.FullName)
    }
    return $texts
}

function Get-ProfileRelativeFile {
    <# Every file below one disposable profile, as sorted profile-relative paths. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolved = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\')
    $names = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -File)) {
        $names += $file.FullName.Substring($resolved.Length + 1)
    }
    return @($names | Sort-Object)
}

$script:ProbeSuiteRoot = New-HarnessSuiteRoot

# The end-to-end case runs with a deliberately narrow PATH, so the interpreter
# the runner uses to read the disposable state database is passed explicitly.
$script:PythonLauncher = (Get-Command -Name 'python' -CommandType Application -ErrorAction Stop)[0].Source

# Dependency order: the probe table refers to the shared token set, the shared
# preamble, the shared domain question, and the identity prompt, so all four
# must be defined before it is evaluated. The runner's own contract constants
# are taken the same way, so the functions under test see the production values
# while the assertions below stay independent literals.
. (Get-RunnerVariableDefinition -Name 'ContractModel')
. (Get-RunnerVariableDefinition -Name 'ContractProvider')
. (Get-RunnerVariableDefinition -Name 'ContractEffort')
. (Get-RunnerVariableDefinition -Name 'Phase1Relative')
. (Get-RunnerVariableDefinition -Name 'Phase1Expected')
. (Get-RunnerVariableDefinition -Name 'MarkerTokens')
. (Get-RunnerVariableDefinition -Name 'MarkerPreamble')
. (Get-RunnerVariableDefinition -Name 'CitationPreamble')
. (Get-RunnerVariableDefinition -Name 'IdentityPrompt')
. (Get-RunnerVariableDefinition -Name 'DomainQuestion')
. (Get-RunnerVariableDefinition -Name 'ContractProbes')


# --------------------------------------------------------------------------
# Probe table
# --------------------------------------------------------------------------

Describe 'Runtime contract probe table' {

    It 'declares exactly the nine approved probe identifiers' {
        $ids = @($script:ContractProbes | ForEach-Object { $_.Id } | Sort-Object)
        ($ids -join ',') | Should Be ($script:ExpectedProbeIds -join ',')
    }

    It 'keeps every heartbeat probe on one bounded marker token set' {
        foreach ($probe in @($script:ContractProbes | Where-Object { $_.Kind -eq 'marker' })) {
            (@($probe.Tokens) -join ',') | Should Be ($script:ExpectedMarkerTokens -join ',')
            (@($probe.Tokens) -contains $probe.Expected) | Should Be $true
        }
    }

    It 'requests exactly one categorical verdict line' {
        $script:MarkerPreamble.Contains('VERDICT:') | Should Be $true
    }

    It 'expects the approved direction for each heartbeat probe' {
        (Get-ProbeById -Id 'heartbeat-skipped').Expected | Should Be 'HEARTBEAT_SKIPPED'
        (Get-ProbeById -Id 'explicit-entered').Expected | Should Be 'HEARTBEAT_ENTERED_EXPLICIT'
        (Get-ProbeById -Id 'korean-domain-entered').Expected | Should Be 'HEARTBEAT_ENTERED_DOMAIN'
        (Get-ProbeById -Id 'vault-unavailable').Expected | Should Be 'HEARTBEAT_UNAVAILABLE'
        (Get-ProbeById -Id 'telemetry-denied-fail-open').Expected | Should Be 'HEARTBEAT_ENTERED_DOMAIN'
        (Get-ProbeById -Id 'router-missing-fail-closed').Expected | Should Be 'ROUTER_UNAVAILABLE'
    }

    It 'carries a real prompt for every probe that launches a session' {
        # An empty prompt would make every routing assertion below pass
        # vacuously, so each launching probe must carry text of its own.
        foreach ($probe in @($script:ContractProbes | Where-Object { $_.Kind -eq 'marker' -or $_.Kind -eq 'identity' })) {
            [string]::IsNullOrWhiteSpace($probe.Prompt) | Should Be $false
        }
    }

    It 'uses the frozen identity literal for the identity probe alone' {
        ($script:IdentityPrompt -ceq $script:ExpectedIdentityPrompt) | Should Be $true
        ((Get-ProbeById -Id 'runtime-identity').Prompt -ceq $script:ExpectedIdentityPrompt) | Should Be $true

        foreach ($probe in @($script:ContractProbes | Where-Object { $_.Id -ne 'runtime-identity' })) {
            ($probe.Prompt -ceq $script:ExpectedIdentityPrompt) | Should Be $false
        }
    }

    It 'keeps every heartbeat and citation behaviour prompt at its own meaning' {
        # The identity correction may not repurpose a behaviour probe: the
        # heartbeat preamble still asks for one routing marker and the citation
        # preamble still asks for the pages used. This file is ASCII on purpose,
        # so the two Korean prompts are asserted structurally here and by their
        # real routing outcome in the router Describe below.
        $script:MarkerPreamble.Contains('Report the routing heartbeat this turn actually carries.') | Should Be $true
        foreach ($token in $script:ExpectedMarkerTokens) {
            $script:MarkerPreamble.Contains($token) | Should Be $true
        }
        $script:CitationPreamble.Contains('SOURCES:') | Should Be $true
        $script:CitationPreamble.Contains('from the knowledge base') | Should Be $true
        ((Get-ProbeById -Id 'heartbeat-skipped').Prompt -ceq 'Question: what is the sum of two and two?') | Should Be $true
        (Get-ProbeById -Id 'explicit-entered').Prompt.StartsWith('/query ') | Should Be $true
        $script:DomainQuestion.Contains('Niagara') | Should Be $true
        $script:DomainQuestion.StartsWith('/query ') | Should Be $false
    }

    It 'separates the two failure directions by environment, not by prompt' {
        # Readiness failure, telemetry denial, and a dead router must be shown by
        # the runtime state alone, so the three probes share one prompt.
        $domain = (Get-ProbeById -Id 'korean-domain-entered').Prompt
        [string]::IsNullOrWhiteSpace($domain) | Should Be $false
        ((Get-ProbeById -Id 'vault-unavailable').Prompt -ceq $domain) | Should Be $true
        ((Get-ProbeById -Id 'telemetry-denied-fail-open').Prompt -ceq $domain) | Should Be $true
        ((Get-ProbeById -Id 'router-missing-fail-closed').Prompt -ceq $domain) | Should Be $true

        (Get-ProbeById -Id 'vault-unavailable').Environment | Should Be 'broken-vault'
        (Get-ProbeById -Id 'telemetry-denied-fail-open').Environment | Should Be 'telemetry-denied'
        (Get-ProbeById -Id 'router-missing-fail-closed').Environment | Should Be 'router-disabled'
        (Get-ProbeById -Id 'korean-domain-entered').Environment | Should Be 'default'
    }

    It 'requires the Phase 1 matrix to be complete' {
        $phase1 = Get-ProbeById -Id 'phase1-regression'
        $phase1.Kind | Should Be 'phase1'
        $phase1.Expected | Should Be 'PHASE1_18_OF_18'
    }
}


Describe 'Probe prompts routed through the real router' {

    # The prompts are classified by the production router against the production
    # contract, so a wrapper word that silently changes a route fails here.
    $case = New-ProbeCase -Label '01-prompt-routing'

    $expected = @{
        'heartbeat-skipped'     = 'VAULT_ROUTING_CHECKED decision=skipped trigger=NO_DOMAIN_MATCH'
        'explicit-entered'      = 'VAULT_ROUTING_CHECKED decision=entered trigger=EXPLICIT'
        'korean-domain-entered' = 'VAULT_ROUTING_CHECKED decision=entered trigger=DOMAIN_MATCH'
    }

    $payload = @()
    foreach ($id in @($expected.Keys)) {
        $probe = Get-ProbeById -Id $id
        $payload += [pscustomobject]@{ id = $id; prompt = ($script:MarkerPreamble + "`n`n" + $probe.Prompt) }
    }
    $payloadPath = Join-Path $case.CaseRoot 'prompts.json'
    Set-HarnessFileText -Path $payloadPath -Text (($payload | ConvertTo-Json -Depth 4) + "`n")

    $routingHome = Join-Path $case.CaseRoot 'routing-home'
    [void](New-Item -ItemType Directory -Path $routingHome -Force)

    $routeScript = Join-Path $case.CaseRoot 'route-probes.py'
    Set-HarnessFileText -Path $routeScript -Text $script:RouteProbesSource
    $routed = Invoke-HarnessChildProcess -FilePath 'python' `
        -ArgumentList @($routeScript, $script:RouterDirectory, $payloadPath, $case.VaultRoot, $routingHome) `
        -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp

    $markers = @{}
    $matchCounts = @{}
    foreach ($line in ($routed.StdOut -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        $markers[$parts[0]] = $parts[1]
        $matchCounts[$parts[0]] = [int]($parts[2] -replace 'matched=', '')
    }

    It 'classifies every routed prompt' {
        $routed.ExitCode | Should Be 0
        $markers.Count | Should Be 3
    }

    It 'keeps the no-domain prompt on a skipped heartbeat' {
        $markers['heartbeat-skipped'] | Should Be $expected['heartbeat-skipped']
    }

    It 'keeps the explicit prompt on an explicit entry' {
        $markers['explicit-entered'] | Should Be $expected['explicit-entered']
    }

    It 'keeps the Korean domain prompt on a domain entry' {
        $markers['korean-domain-entered'] | Should Be $expected['korean-domain-entered']
    }

    It 'caps the Korean domain prompt at the two-item public match list' {
        $matchCounts['korean-domain-entered'] | Should Be 2
    }

    # Importing the production router must not write bytecode into the tracked
    # baseline, or the harness validator reports the generated cache as an
    # unexpected artefact on the next run.
    It 'leaves no Python bytecode in the production router directory' {
        @(Get-ChildItem -LiteralPath $script:RouterDirectory -Recurse -Force -Directory |
            Where-Object { $_.Name -eq '__pycache__' }).Count | Should Be 0
        @(Get-ChildItem -LiteralPath $script:RouterDirectory -Recurse -Force -File |
            Where-Object { $_.Extension -eq '.pyc' }).Count | Should Be 0
    }
}


# --------------------------------------------------------------------------
# Output reduction
# --------------------------------------------------------------------------

Describe 'Probe output reduction' {

    . (Get-RunnerFunctionDefinition -Name 'Get-ContractVerdict')

    It 'collapses free-form model text to a bounded token' {
        Get-ContractVerdict -Text 'a long explanation carrying private Vault content' -Tokens $script:ExpectedMarkerTokens |
            Should Be 'UNPARSED'
    }

    It 'collapses an out-of-set declared verdict to a bounded token' {
        Get-ContractVerdict -Text 'VERDICT: SOMETHING_ELSE' -Tokens $script:ExpectedMarkerTokens | Should Be 'UNPARSED'
    }

    It 'reports absent output rather than storing it' {
        Get-ContractVerdict -Text '' -Tokens $script:ExpectedMarkerTokens | Should Be 'NO_OUTPUT'
    }

    It 'returns the declared token when it is inside the allowed set' {
        Get-ContractVerdict -Text "chatty body`nVERDICT: HEARTBEAT_ENTERED_DOMAIN" -Tokens $script:ExpectedMarkerTokens |
            Should Be 'HEARTBEAT_ENTERED_DOMAIN'
    }

    It 'takes the last declared verdict when the model restates itself' {
        Get-ContractVerdict -Text "VERDICT: HEARTBEAT_SKIPPED`nVERDICT: ROUTER_UNAVAILABLE" -Tokens $script:ExpectedMarkerTokens |
            Should Be 'ROUTER_UNAVAILABLE'
    }
}


Describe 'Citation reduction' {

    . (Get-RunnerFunctionDefinition -Name 'Get-CitationVerdict')

    It 'reports a citation only when every required page is named' {
        Get-CitationVerdict -Text "answer body`nSOURCES: niagara-beam-page, shader-page" `
            -RequiredPages @('niagara-beam-page') | Should Be 'CITED'
    }

    It 'reports a missing citation when a required page is absent' {
        Get-CitationVerdict -Text "answer body`nSOURCES: shader-page" `
            -RequiredPages @('niagara-beam-page') | Should Be 'MISSING_CITATION'
    }

    It 'never returns model text or a page name of its own' {
        $verdict = Get-CitationVerdict -Text 'a long private answer with no source line' `
            -RequiredPages @('niagara-beam-page')
        $verdict | Should Be 'MISSING_CITATION'
        $verdict.Contains('private') | Should Be $false
    }

    It 'reports absent output rather than storing it' {
        Get-CitationVerdict -Text '' -RequiredPages @('niagara-beam-page') | Should Be 'NO_OUTPUT'
    }

    It 'refuses to pass without a caller-supplied source page' {
        Get-CitationVerdict -Text 'SOURCES: anything' -RequiredPages @() | Should Be 'MISSING_CITATION'
    }
}


Describe 'Runtime identity reduction' {

    . (Get-RunnerFunctionDefinition -Name 'Get-RuntimeIdentityVerdict')

    It 'confirms only the exact contract triple' {
        Get-RuntimeIdentityVerdict -Model 'gpt-5.6-sol' -Provider 'openai-codex' -Effort 'high' |
            Should Be 'RUNTIME_IDENTITY_CONFIRMED'
    }

    It 'rejects the current pre-activation effort' {
        Get-RuntimeIdentityVerdict -Model 'gpt-5.6-sol' -Provider 'openai-codex' -Effort 'medium' |
            Should Be 'RUNTIME_IDENTITY_MISMATCH'
    }

    It 'rejects a different model' {
        Get-RuntimeIdentityVerdict -Model 'gpt-5.6-terra' -Provider 'openai-codex' -Effort 'high' |
            Should Be 'RUNTIME_IDENTITY_MISMATCH'
    }

    It 'rejects a different provider' {
        Get-RuntimeIdentityVerdict -Model 'gpt-5.6-sol' -Provider 'anthropic' -Effort 'high' |
            Should Be 'RUNTIME_IDENTITY_MISMATCH'
    }

    It 'reports unverified evidence rather than assuming it' {
        Get-RuntimeIdentityVerdict -Model '' -Provider 'openai-codex' -Effort 'high' |
            Should Be 'RUNTIME_IDENTITY_UNVERIFIED'
    }

    It 'never accepts response text as identity evidence' {
        # The runner reduces the correlated runtime state only; the answer text
        # is not a parameter of the identity verdict at all.
        $definition = (Get-RunnerFunctionDefinition -Name 'Get-RuntimeIdentityVerdict').ToString()
        $definition.Contains('StdOut') | Should Be $false
        $definition.Contains('$Text') | Should Be $false
    }
}


Describe 'Session identity correlation' {

    # Get-ProbeSessionId reads the runner's own announcement pattern, so the
    # pattern is taken from production too rather than restated here.
    . (Get-RunnerVariableDefinition -Name 'SessionIdPattern')
    . (Get-RunnerFunctionDefinition -Name 'Get-ProbeSessionId')
    . (Get-RunnerVariableDefinition -Name 'SessionIdentityReader')

    It 'takes the one session id the classic caller announced on stderr' {
        Get-ProbeSessionId -StandardError "hermes: starting`nsession_id: probe-session-high`ndone" |
            Should Be 'probe-session-high'
    }

    It 'accepts the same id restated more than once' {
        Get-ProbeSessionId -StandardError "session_id: probe-session-high`nsession_id: probe-session-high" |
            Should Be 'probe-session-high'
    }

    It 'fails closed when stderr announced no session id' {
        Get-ProbeSessionId -StandardError 'hermes: nothing to report' | Should Be ''
        Get-ProbeSessionId -StandardError '' | Should Be ''
    }

    It 'fails closed when stderr announced more than one session id' {
        Get-ProbeSessionId -StandardError "session_id: probe-session-high`nsession_id: probe-session-medium" |
            Should Be ''
    }

    It 'reads the runtime state read-only and correlates both tables' {
        $script:SessionIdentityReader.Contains('mode=ro') | Should Be $true
        $script:SessionIdentityReader.Contains('FROM sessions') | Should Be $true
        $script:SessionIdentityReader.Contains('model_config') | Should Be $true
        $script:SessionIdentityReader.Contains('session_model_usage') | Should Be $true
        $script:SessionIdentityReader.Contains('billing_provider') | Should Be $true
    }

    # The reader is executed against the disposable state database, so the
    # correlation is measured rather than asserted from its source text.
    $case = New-ProbeCase -Label '06-identity-reader'
    $readerPath = Join-Path $case.CaseRoot 'read-session-identity.py'
    Set-HarnessFileText -Path $readerPath -Text $script:SessionIdentityReader

    function Invoke-IdentityReader {
        param([string]$SessionId)

        $run = Invoke-HarnessChildProcess -FilePath $script:PythonLauncher `
            -ArgumentList @($readerPath, $case.StateDatabase, $SessionId) `
            -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp
        if ($run.ExitCode -ne 0) { throw "identity reader failed: $($run.StdErr)" }
        return ($run.StdOut | ConvertFrom-Json)
    }

    It 'reports the exact contract triple for a correlated session' {
        $identity = Invoke-IdentityReader -SessionId $script:ProbeSessionId
        $identity.model | Should Be 'gpt-5.6-sol'
        $identity.provider | Should Be 'openai-codex'
        $identity.effort | Should Be 'high'
    }

    It 'reports the measured effort rather than the contract effort' {
        $identity = Invoke-IdentityReader -SessionId 'probe-session-medium'
        $identity.effort | Should Be 'medium'
    }

    It 'fails closed when the session has no billing provider row' {
        $identity = Invoke-IdentityReader -SessionId 'probe-session-no-usage'
        $identity.model | Should Be ''
        $identity.provider | Should Be ''
        $identity.effort | Should Be ''
    }

    It 'fails closed when the session is billed by more than one provider' {
        $identity = Invoke-IdentityReader -SessionId 'probe-session-two-providers'
        $identity.provider | Should Be ''
    }

    It 'fails closed when the session is absent from the state database' {
        $identity = Invoke-IdentityReader -SessionId 'probe-session-absent'
        $identity.model | Should Be ''
        $identity.provider | Should Be ''
        $identity.effort | Should Be ''
    }
}


# --------------------------------------------------------------------------
# Launcher shape
# --------------------------------------------------------------------------

Describe 'Hermes probe launcher shape' {

    . (Get-RunnerFunctionDefinition -Name 'New-ContractProbeArgumentList')

    It 'uses exactly the classic Hermes caller array for every behaviour probe' {
        foreach ($probe in @($script:ContractProbes | Where-Object { $_.Kind -eq 'marker' -or $_.Kind -eq 'identity' -or $_.Kind -eq 'citation' })) {
            $prompt = 'behaviour prompt for ' + $probe.Id
            $arguments = @(New-ContractProbeArgumentList -Prompt $prompt)
            $expected = @($script:ExpectedLauncherPrefix) + @($prompt)
            $separator = [string][char]1
            ($arguments -join $separator) | Should Be ($expected -join $separator)
        }
    }

    It 'never passes -z, a usage file, or a runtime override' {
        # The identity evidence is only meaningful when the session runs on the
        # applied defaults, so no probe may pass a model, provider, or effort,
        # and the superseded one-shot switch may not come back.
        $arguments = @(New-ContractProbeArgumentList -Prompt 'probe prompt')
        ($arguments -contains '-z') | Should Be $false
        ($arguments -contains '--usage-file') | Should Be $false
        ($arguments -contains '--model') | Should Be $false
        ($arguments -contains '--provider') | Should Be $false
        ($arguments -contains '--reasoning') | Should Be $false
    }

    It 'takes no usage-file parameter at all' {
        $definition = (Get-RunnerFunctionDefinition -Name 'New-ContractProbeArgumentList').ToString()
        $definition.Contains('UsageFilePath') | Should Be $false
    }

    It 'leaves no usage-file or -z evidence path in the runner source' {
        $text = Get-RunnerSourceText
        $text.Contains('--usage-file') | Should Be $false
        $text.Contains('Find-ContractUsageValue') | Should Be $false
        [regex]::IsMatch($text, "'-z'") | Should Be $false
    }
}


Describe 'Probe process seam' {

    . (Get-RunnerFunctionDefinition -Name 'Invoke-ContractProbeProcess')

    It 'returns standard error in memory so one session id can be correlated' {
        $definition = (Get-RunnerFunctionDefinition -Name 'Invoke-ContractProbeProcess').ToString()
        [regex]::IsMatch($definition, 'StdErr\s*=') | Should Be $true
    }

    It 'reads both streams asynchronously and keeps neither on disk' {
        $case = New-ProbeCase -Label '07-process-seam'
        $script = Join-Path $case.CaseRoot 'both-streams.ps1'
        Set-HarnessFileText -Path $script -Text (
            "[Console]::Error.WriteLine('session_id: probe-session-high')`r`n" +
            "Write-Output 'VERDICT: HEARTBEAT_SKIPPED'`r`n")

        $run = Invoke-ContractProbeProcess -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script) `
            -WorkingDirectory $case.CaseRoot -TempDirectory $case.ChildTemp

        $run.Status | Should Be 'ran'
        $run.ExitCode | Should Be 0
        $run.StdOut.Contains('HEARTBEAT_SKIPPED') | Should Be $true
        $run.StdErr.Contains('probe-session-high') | Should Be $true
        @(Get-ChildItem -LiteralPath $case.OutputDirectory -Recurse -File -Force).Count | Should Be 0
    }
}


Describe 'Probe environment isolation' {

    . (Get-RunnerFunctionDefinition -Name 'New-ProbeEnvironment')

    $roots = @{
        HermesHome       = 'C:\live\hermes'
        VaultRoot        = 'C:\live\vault'
        TelemetryProfile = 'C:\live\hermes\profiles\probe-telemetry'
        RouterProfile    = 'C:\live\hermes\profiles\probe-router'
        BrokenVaultPath  = 'C:\disposable\absent-vault'
    }

    It 'runs a default probe against the applied home and Vault' {
        $environment = New-ProbeEnvironment -Environment 'default' @roots
        $environment['HERMES_HOME'] | Should Be 'C:\live\hermes'
        $environment['HONG_VAULT_ROOT'] | Should Be 'C:\live\vault'
    }

    It 'points only the readiness probe at an absent Vault root' {
        $environment = New-ProbeEnvironment -Environment 'broken-vault' @roots
        $environment['HONG_VAULT_ROOT'] | Should Be 'C:\disposable\absent-vault'
        $environment['HERMES_HOME'] | Should Be 'C:\live\hermes'
    }

    It 'redirects the telemetry probe to the disposable profile' {
        $environment = New-ProbeEnvironment -Environment 'telemetry-denied' @roots
        $environment['HERMES_HOME'] | Should Be 'C:\live\hermes\profiles\probe-telemetry'
        $environment['HONG_VAULT_ROOT'] | Should Be 'C:\live\vault'
    }

    It 'redirects the dead-router probe to the disposable profile' {
        $environment = New-ProbeEnvironment -Environment 'router-disabled' @roots
        $environment['HERMES_HOME'] | Should Be 'C:\live\hermes\profiles\probe-router'
    }

    It 'refuses an unknown environment rather than silently using the live one' {
        { New-ProbeEnvironment -Environment 'production' @roots } | Should Throw
    }
}


Describe 'Disposable probe profiles' {

    # The three fixture functions are driven entirely by the runner's own naming
    # constants, so all five are taken from production rather than restated.
    . (Get-RunnerVariableDefinition -Name 'ProfilePrefix')
    . (Get-RunnerVariableDefinition -Name 'ProfilesDirectory')
    . (Get-RunnerVariableDefinition -Name 'PluginsDirectory')
    . (Get-RunnerVariableDefinition -Name 'RouterPluginId')
    . (Get-RunnerVariableDefinition -Name 'ProfileConfigRelative')
    . (Get-RunnerVariableDefinition -Name 'ProfileTelemetryRelative')
    . (Get-RunnerFunctionDefinition -Name 'Copy-ProbeRouterPlugin')
    . (Get-RunnerFunctionDefinition -Name 'New-DisposableProbeProfile')
    . (Get-RunnerFunctionDefinition -Name 'Test-DisposableProbeProfile')
    . (Get-RunnerFunctionDefinition -Name 'Remove-DisposableProbeProfile')

    $case = New-ProbeCase -Label '02-failure-fixture'
    $profilesRoot = Join-Path $case.HermesHome 'profiles'

    $telemetry = New-DisposableProbeProfile -HermesHome $case.HermesHome -Kind 'telemetry-denied'
    $router = New-DisposableProbeProfile -HermesHome $case.HermesHome -Kind 'router-disabled'

    It 'creates each fixture only under the applied home profiles directory' {
        (Split-Path -Parent $telemetry) | Should Be $profilesRoot
        (Split-Path -Parent $router) | Should Be $profilesRoot
        (Test-Path -LiteralPath $telemetry -PathType Container) | Should Be $true
        (Test-Path -LiteralPath $router -PathType Container) | Should Be $true
    }

    It 'isolates each fixture behind its own UUID' {
        foreach ($path in @($telemetry, $router)) {
            $leaf = Split-Path -Leaf $path
            $leaf.StartsWith($script:ProfilePrefix) | Should Be $true
            [regex]::IsMatch($leaf.Substring($script:ProfilePrefix.Length), '^[0-9a-f]{32}$') | Should Be $true
        }
        ($telemetry -eq $router) | Should Be $false
        $again = New-DisposableProbeProfile -HermesHome $case.HermesHome -Kind 'router-disabled'
        ($again -eq $router) | Should Be $false
        [void](Remove-DisposableProbeProfile -Path $again -HermesHome $case.HermesHome)
    }

    It 'copies no credential, token, or environment material into a fixture' {
        foreach ($path in @($telemetry, $router)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -Force -File)) {
                [regex]::IsMatch($file.Name, '(?i)auth|token|credential|secret|\.env') | Should Be $false
            }
        }
    }

    It 'copies no byte of the applied home root material into a fixture' {
        # The applied home carries its own configuration, its OAuth file, and an
        # environment file, all bearing one marker. Root OAuth must be reached
        # through the Hermes profile fallback, so no fixture may carry it.
        foreach ($path in @($telemetry, $router)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -Force -File)) {
                ([System.IO.File]::ReadAllText($file.FullName)).Contains($script:RootMaterialSecret) |
                    Should Be $false
            }
        }
    }

    It 'copies exactly the router plugin package and nothing else' {
        $expectedRouter = @(@($script:ExpectedPluginRelativeFiles) + @($script:ProfileConfigRelative)) | Sort-Object
        $expectedTelemetry = @(@($expectedRouter) + @($script:ProfileTelemetryRelative)) | Sort-Object
        ((Get-ProfileRelativeFile -Root $router) -join '|') | Should Be (($expectedRouter) -join '|')
        ((Get-ProfileRelativeFile -Root $telemetry) -join '|') | Should Be (($expectedTelemetry) -join '|')
    }

    It 'installs the router package into the fixture own plugins directory' {
        foreach ($path in @($telemetry, $router)) {
            $package = Join-Path (Join-Path $path $script:PluginsDirectory) $script:RouterPluginId
            (Test-Path -LiteralPath $package -PathType Container) | Should Be $true
            ([System.IO.File]::ReadAllText((Join-Path $package 'router.py'))).Contains($script:FakePluginMarker) |
                Should Be $true
        }
    }

    It 'writes the profile configuration as config.yaml, never as config.json' {
        $script:ProfileConfigRelative | Should Be 'config.yaml'
        foreach ($path in @($telemetry, $router)) {
            (Test-Path -LiteralPath (Join-Path $path 'config.yaml') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $path 'config.json')) | Should Be $false
        }
    }

    It 'generates only the minimal synthetic runtime configuration for the dead-router fixture' {
        # Installed but not enabled, and explicitly denied: the plugin is present
        # on disk, so the probe measures a disabled router rather than an absent
        # package. The whole file is asserted, so no unrelated or secret root
        # value can be added to it unnoticed.
        $text = [System.IO.File]::ReadAllText((Join-Path $router $script:ProfileConfigRelative))
        ($text -replace "`r`n", "`n") | Should Be $script:ExpectedRouterDisabledConfig
    }

    It 'generates only the minimal synthetic runtime configuration for the telemetry fixture' {
        $text = [System.IO.File]::ReadAllText((Join-Path $telemetry $script:ProfileConfigRelative))
        ($text -replace "`r`n", "`n") | Should Be $script:ExpectedTelemetryConfig
    }

    It 'obstructs the telemetry log path with a file rather than a directory' {
        $logs = Join-Path $telemetry $script:ProfileTelemetryRelative
        (Test-Path -LiteralPath $logs -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $logs -PathType Container) | Should Be $false
    }

    It 'fails closed and leaves nothing behind when the router package is absent' {
        $bare = Join-Path $case.CaseRoot 'bare-home'
        [void](New-Item -ItemType Directory -Path $bare -Force)
        { New-DisposableProbeProfile -HermesHome $bare -Kind 'router-disabled' } | Should Throw
        $bareProfiles = Join-Path $bare $script:ProfilesDirectory
        if (Test-Path -LiteralPath $bareProfiles) {
            @(Get-ChildItem -LiteralPath $bareProfiles -Force).Count | Should Be 0
        }
    }

    It 'fails closed rather than writing outside the profile it owns' {
        # The profile's own plugins directory is pre-planted, as a junction where
        # the host allows one and as a plain directory otherwise. Either way the
        # copy must refuse rather than write through it.
        $manual = Join-Path $profilesRoot ($script:ProfilePrefix + 'escape')
        [void](New-Item -ItemType Directory -Path $manual -Force)
        $outside = Join-Path $case.CaseRoot 'escape-target'
        [void](New-Item -ItemType Directory -Path $outside -Force)

        $link = Join-Path $manual $script:PluginsDirectory
        if (-not (New-HarnessJunction -LinkPath $link -TargetPath $outside)) {
            [void](New-Item -ItemType Directory -Path $link -Force)
        }

        { Copy-ProbeRouterPlugin -HermesHome $case.HermesHome -ProfilePath $manual } | Should Throw
        @(Get-ChildItem -LiteralPath $outside -Recurse -Force).Count | Should Be 0
    }

    It 'states the exact copy boundary rather than claiming nothing is copied' {
        $text = Get-RunnerSourceText
        $text.Contains('Nothing is copied into it') | Should Be $false
        $text.Contains('No credential, token, or environment file is ever copied into a profile') |
            Should Be $true
    }

    It 'accepts only a fixture directly under the applied home profiles directory' {
        Test-DisposableProbeProfile -Path $telemetry -HermesHome $case.HermesHome | Should Be $true
    }

    It 'refuses the applied home itself' {
        Test-DisposableProbeProfile -Path $case.HermesHome -HermesHome $case.HermesHome | Should Be $false
    }

    It 'refuses a directory outside the profiles directory' {
        $outside = Join-Path $case.CaseRoot 'probe-outside'
        [void](New-Item -ItemType Directory -Path $outside -Force)
        Test-DisposableProbeProfile -Path $outside -HermesHome $case.HermesHome | Should Be $false
    }

    It 'refuses a profile the runner did not name' {
        $foreign = Join-Path $profilesRoot 'operator-profile'
        [void](New-Item -ItemType Directory -Path $foreign -Force)
        Test-DisposableProbeProfile -Path $foreign -HermesHome $case.HermesHome | Should Be $false
    }

    It 'refuses an empty or absent fixture path' {
        Test-DisposableProbeProfile -Path '' -HermesHome $case.HermesHome | Should Be $false
        Test-DisposableProbeProfile -Path (Join-Path $profilesRoot 'probe-absent') -HermesHome $case.HermesHome |
            Should Be $false
    }

    It 'deletes a fixture it owns and refuses one it does not' {
        Remove-DisposableProbeProfile -Path (Join-Path $profilesRoot 'operator-profile') `
            -HermesHome $case.HermesHome | Should Be $false
        (Test-Path -LiteralPath (Join-Path $profilesRoot 'operator-profile')) | Should Be $true

        Remove-DisposableProbeProfile -Path $telemetry -HermesHome $case.HermesHome | Should Be $true
        (Test-Path -LiteralPath $telemetry) | Should Be $false
        Remove-DisposableProbeProfile -Path $router -HermesHome $case.HermesHome | Should Be $true
        (Test-Path -LiteralPath $router) | Should Be $false
    }

    It 'owns fixture creation and cleanup instead of taking them from the caller' {
        $text = Get-RunnerSourceText
        $text.Contains('TelemetryDeniedHome') | Should Be $false
        $text.Contains('RouterDisabledHome') | Should Be $false
        $text.Contains('ConfirmDisposableFailureHomes') | Should Be $false
        [regex]::IsMatch($text, '(?s)finally\s*\{[^}]*Remove-DisposableProbeProfile') | Should Be $true
    }
}


# --------------------------------------------------------------------------
# Phase 1 chain
# --------------------------------------------------------------------------

Describe 'Phase 1 regression chain' {

    . (Get-RunnerFunctionDefinition -Name 'New-Phase1ArgumentList')
    . (Get-RunnerFunctionDefinition -Name 'ConvertTo-Phase1Record')

    It 'invokes the unchanged Phase 1 runner with its own confirmation flag' {
        $arguments = @(New-Phase1ArgumentList -RepositoryRoot 'C:\repo' -OutputRoot 'C:\out\phase1')
        ($arguments -contains '-ConfirmLiveApplyComplete') | Should Be $true
        ($arguments -contains (Join-Path 'C:\repo' 'scripts\run-harness-probes.ps1')) | Should Be $true
        $index = [array]::IndexOf($arguments, '-OutputRoot')
        $index | Should Not Be -1
        $arguments[$index + 1] | Should Be 'C:\out\phase1'
    }

    It 'passes no expectation, scenario, or prompt override to the Phase 1 runner' {
        $arguments = @(New-Phase1ArgumentList -RepositoryRoot 'C:\repo' -OutputRoot 'C:\out\phase1')
        foreach ($argument in $arguments) {
            ($argument -like '-Scenario*') | Should Be $false
            ($argument -like '-Expect*') | Should Be $false
            ($argument -like '-Prompt*') | Should Be $false
        }
    }

    It 'keeps only categorical fields from each Phase 1 record' {
        $raw = [pscustomobject]@{
            Harness  = 'Hermes'
            Scenario = 'probe-1-two-line-config'
            Expected = 'FULL_GATE'
            Verdict  = 'FULL_GATE'
            ExitCode = 0
            Pass     = $true
            Note     = ''
            StdOut   = 'raw model text that must never be copied forward'
        }
        $record = ConvertTo-Phase1Record -Record $raw
        $names = @($record.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        ($names -join ',') | Should Be 'Expected,Harness,Note,Pass,Scenario,Verdict'
        (($record | ConvertTo-Json -Depth 4).Contains('raw model text')) | Should Be $false
    }

    It 'leaves the Phase 1 runner and its expectations untouched' {
        # The chained script is production Phase 1 evidence: the runner may only
        # call it, never rewrite it.
        $text = Get-RunnerSourceText
        $text.Contains('run-harness-probes.ps1') | Should Be $true
        [System.IO.File]::Exists($script:Phase1Path) | Should Be $true
    }
}


# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------

Describe 'Runtime contract probe gates' {

    It 'refuses to run without the applied-contract confirmation' {
        $case = New-ProbeCase -Label '03-gate-unconfirmed'
        $run = Invoke-ProbeRunner -Case $case -ExtraArguments @()
        $run.ExitCode | Should Be 2
        (Test-Path -LiteralPath $case.ResultPath) | Should Be $false
        @(Get-ChildItem -LiteralPath $case.OutputDirectory -Recurse -File -Force).Count | Should Be 0
    }

    It 'refuses to run while an API key is present' {
        $case = New-ProbeCase -Label '04-gate-api-key'
        $run = Invoke-ProbeRunner -Case $case -ExtraArguments @('-ConfirmRuntimeContractApplied') `
            -Environment @{ ANTHROPIC_API_KEY = 'fixture-key-never-used' }
        $run.ExitCode | Should Be 2
        (Test-Path -LiteralPath $case.ResultPath) | Should Be $false
    }

    It 'keeps both gates in the runner source' {
        $text = Get-RunnerSourceText
        $text.Contains('ConfirmRuntimeContractApplied') | Should Be $true
        $text.Contains('ANTHROPIC_API_KEY') | Should Be $true
    }

    It 'states the exact network boundary instead of a blanket no-network claim' {
        # An explicitly approved live run does reach the network: each probe is a
        # real Hermes one-shot, so the provider performs inference remotely. A
        # blanket "no probe reaches the network" header would tell the live gate
        # the opposite, so the header must name the boundary per run mode and the
        # blanket claim must not come back.
        $text = Get-RunnerSourceText
        [regex]::IsMatch($text, 'No probe[^.]*reaches the network') | Should Be $false
        [regex]::IsMatch($text, 'Every probe[^.]*reaches the network') | Should Be $false
        [regex]::IsMatch($text, 'no probe reaches the network', 'IgnoreCase') | Should Be $false
        $text.Contains('disposable fake launcher only and reaches no network') | Should Be $true
        $text.Contains('intended Hermes provider inference network calls') | Should Be $true
        $text.Contains('no publication, no direct web or API command') | Should Be $true
        $text.Contains('no mutation of live state') | Should Be $true
    }
}


# --------------------------------------------------------------------------
# End-to-end: verdict-only persistence
# --------------------------------------------------------------------------

Describe 'Verdict-only persistence' {

    # One full run against the fake launcher. Claude and Codex are absent from
    # the child PATH, so the chained Phase 1 matrix is incomplete and the run
    # must report that rather than pass.
    $case = New-ProbeCase -Label '05-end-to-end'
    $originalPath = $env:PATH
    try {
        $env:PATH = $case.FakeDirectory + ';' + $PSHOME
        $run = Invoke-ProbeRunner -Case $case -ExtraArguments @(
            '-ConfirmRuntimeContractApplied',
            '-CitationQuestion', 'which page records the beam study?',
            '-CitationSourcePage', $script:CitationPage
        ) -Environment @{
            FAKE_PROBE_SECRET = $script:ProbeSecret
            FAKE_PROBE_PAGE   = $script:CitationPage
            FAKE_STDERR_SECRET = $script:StdErrSecret
            FAKE_SESSION_ID   = $script:ProbeSessionId
        }
    }
    finally { $env:PATH = $originalPath }

    $envelope = $null
    if (Test-Path -LiteralPath $case.ResultPath) {
        $envelope = (Get-Content -LiteralPath $case.ResultPath -Raw) | ConvertFrom-Json
    }

    It 'writes exactly one verdict-only envelope' {
        (Test-Path -LiteralPath $case.ResultPath) | Should Be $true
        $envelope | Should Not BeNullOrEmpty
        @($envelope.probes).Count | Should Be 9
    }

    It 'reports failure when the Phase 1 matrix is not complete' {
        $run.ExitCode | Should Be 1
        $phase1 = @($envelope.probes | Where-Object { $_.Id -eq 'phase1-regression' })[0]
        $phase1.Verdict | Should Be 'PHASE1_INCOMPLETE'
        $phase1.Pass | Should Be $false
    }

    It 'really runs the chained Phase 1 matrix and keeps its full record set' {
        # Claude and Codex are absent from the child PATH, so the 18 cases are
        # reached but not all passed. An empty record set would mean the chain
        # never ran and the failure above was reported for the wrong reason.
        $envelope.phase1.expected | Should Be 18
        @($envelope.phase1.records).Count | Should Be 18
        @($envelope.phase1.records | Where-Object { $_.Note -eq 'cli_not_found' }).Count | Should Be 12
    }

    It 'reduces every chained Phase 1 record to categorical fields only' {
        foreach ($record in @($envelope.phase1.records)) {
            $names = @($record.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
            ($names -join ',') | Should Be 'Expected,Harness,Note,Pass,Scenario,Verdict'
        }
    }

    It 'persists no raw model output anywhere under the output directory' {
        foreach ($text in Get-CaseFileTexts -Root $case.OutputDirectory) {
            $text.Contains($script:ProbeSecret) | Should Be $false
        }
    }

    It 'persists no standard error text' {
        # Stderr is read into memory only, to correlate one session id.
        foreach ($text in Get-CaseFileTexts -Root $case.OutputDirectory) {
            $text.Contains($script:StdErrSecret) | Should Be $false
        }
    }

    It 'persists no caller-supplied Vault page name' {
        foreach ($text in Get-CaseFileTexts -Root $case.OutputDirectory) {
            $text.Contains($script:CitationPage) | Should Be $false
        }
    }

    It 'keeps every probe verdict inside its declared token set' {
        foreach ($record in @($envelope.probes)) {
            $probe = Get-ProbeById -Id $record.Id
            $allowed = @($probe.Tokens) + @('UNPARSED', 'NO_OUTPUT', 'UNAVAILABLE')
            ($allowed -contains $record.Verdict) | Should Be $true
        }
    }

    It 'keeps every note inside the bounded categorical set' {
        $allowed = @(
            '', 'launch_failed', 'timeout', 'nonzero_exit', 'unparsed', 'unexpected_verdict',
            'cli_not_found', 'fixture_missing', 'session_unresolved',
            'state_unreadable', 'phase1_incomplete'
        )
        foreach ($record in @($envelope.probes)) {
            ($allowed -contains [string]$record.Note) | Should Be $true
        }
    }

    It 'really launches both failure-direction probes from its own fixtures' {
        # The fixtures are no longer caller-supplied, so neither probe may be
        # recorded as a missing fixture; both reached the launcher and were
        # judged on the verdict the fake runtime returned.
        foreach ($id in @('telemetry-denied-fail-open', 'router-missing-fail-closed')) {
            $record = @($envelope.probes | Where-Object { $_.Id -eq $id })[0]
            $record.ExitCode | Should Be 0
            $record.Note | Should Be 'unexpected_verdict'
        }
    }

    It 'leaves no child temporary artefact behind' {
        (Test-Path -LiteralPath (Join-Path $case.OutputDirectory 'child-temp')) | Should Be $false
    }

    It 'deletes every disposable profile it created' {
        # The profiles directory itself survives: in a real home it is not the
        # runner's to remove. Its emptiness is what proves the cleanup ran.
        $profilesRoot = Join-Path $case.HermesHome 'profiles'
        (Test-Path -LiteralPath $profilesRoot -PathType Container) | Should Be $true
        @(Get-ChildItem -LiteralPath $profilesRoot -Force).Count | Should Be 0
    }

    It 'confirms the runtime identity from the correlated runtime state' {
        $record = @($envelope.probes | Where-Object { $_.Id -eq 'runtime-identity' })[0]
        $record.Verdict | Should Be 'RUNTIME_IDENTITY_CONFIRMED'
        $record.Pass | Should Be $true
    }
}


Describe 'Disposable profile cleanup on induced failure' {

    # The launcher cannot be resolved, so every Hermes probe fails and the run
    # takes its failure path. The fixtures the runner created must still be gone.
    $case = New-ProbeCase -Label '08-induced-failure'
    $case.HermesCommand = Join-Path $case.FakeDirectory 'absent-hermes.cmd'
    $originalPath = $env:PATH
    try {
        $env:PATH = $PSHOME
        $run = Invoke-ProbeRunner -Case $case -ExtraArguments @('-ConfirmRuntimeContractApplied')
    }
    finally { $env:PATH = $originalPath }

    It 'reports the failure rather than passing' {
        $run.ExitCode | Should Be 1
    }

    It 'still deletes every disposable profile it created' {
        $profilesRoot = Join-Path $case.HermesHome 'profiles'
        (Test-Path -LiteralPath $profilesRoot -PathType Container) | Should Be $true
        @(Get-ChildItem -LiteralPath $profilesRoot -Force).Count | Should Be 0
    }
}
