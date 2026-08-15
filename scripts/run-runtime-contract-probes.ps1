<#
.SYNOPSIS
    Fresh-process behaviour probes for the applied Phase 2 runtime contract.

.DESCRIPTION
    These probes answer one question: does a *new, independent* Hermes session
    on the applied runtime actually behave the way the approved contract says
    it should? They cover the routing heartbeat, both failure directions, the
    Vault-entered answer's citations, the real runtime identity, and the
    unchanged Phase 1 gate matrix.

    They are meaningful only against the applied runtime, so the script refuses
    to run until the caller confirms the runtime contract has already been
    applied. Source tests, router unit tests, and the apply/rollback transaction
    are covered elsewhere and need no live session.

    Every probe is read-only with respect to the applied runtime. No probe
    applies configuration, enables a plugin, writes the Vault, or writes the
    applied home's own configuration or state. The two failure directions are
    made observable by disposable profiles the runner creates under the applied
    home's profiles/ directory and deletes again before it exits, plus the
    environment of each child process. Exactly one thing is copied into such a
    profile - the non-secret routing plugin package, because Hermes scans user
    plugins per home - and its configuration is generated as the minimal
    synthetic runtime contract rather than copied from the applied home. No
    credential, token, or environment file is ever copied into a profile: a
    probe session reaches the root OAuth only through the Hermes profile
    fallback.

    The network boundary differs by run mode, so it is stated exactly rather
    than blanketed. Source and Pester verification of this file substitutes a
    disposable fake launcher only and reaches no network. An explicitly approved
    live run launches real Hermes one-shot sessions, so it does perform the
    intended Hermes provider inference network calls, and only those: the runner
    itself issues no publication, no direct web or API command of its own, and
    no mutation of live state.

    Recorded output is minimised on purpose. Raw stdout is read in memory,
    reduced to one bounded token, and dropped. Stderr is read in memory too, for
    one reason only: the classic caller announces the session id there, and the
    runtime identity is correlated from that session in the runtime state
    database rather than from anything the model said. Neither stream is
    persisted. The only artefact left behind is a verdict-only JSON envelope in
    which a failed probe carries a bounded categorical note rather than model
    text, a path, a configuration value, or Vault content.

    This file is UTF-8 with a byte-order mark on purpose: two probe prompts are
    Korean, and Windows PowerShell 5.1 decodes a BOM-less script with the ANSI
    code page, which would corrupt them and silently change what is being
    probed. The Pester suite routes the prompts through the real router, so a
    corrupted prompt fails there rather than during a live run.

.PARAMETER ConfirmRuntimeContractApplied
    Required acknowledgement that the Phase 2 runtime contract has already been
    applied. Without it the script exits 2 without launching anything.

.PARAMETER CitationQuestion
    A question whose answer lives in a page linked from the Vault index. The
    citation probe is recorded as failed, never as passed, when it is absent.

.PARAMETER CitationSourcePage
    The wiki page names the answer must cite. They are matched in memory and are
    never written to the envelope.

.EXAMPLE
    powershell -File scripts/run-runtime-contract-probes.ps1 `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude `
        -CodexHome C:\codex -VaultRoot D:\vault -OutputDirectory C:\out `
        -ConfirmRuntimeContractApplied
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$HermesHome,
    [Parameter(Mandatory = $true)][string]$ClaudeHome,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [switch]$ConfirmRuntimeContractApplied,
    [string]$HermesCommand = 'hermes',
    [string]$PythonCommand = 'python',
    [string]$StateDatabasePath,
    [string]$CitationQuestion,
    [string[]]$CitationSourcePage = @(),
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The contract runtime identity. Response text is never accepted as evidence
# for any of the three.
$script:ContractModel = 'gpt-5.6-sol'
$script:ContractProvider = 'openai-codex'
$script:ContractEffort = 'high'

$script:Phase1Relative = 'scripts\run-harness-probes.ps1'
$script:Phase1Expected = 18

# One bounded token set for every heartbeat probe, so no probe can widen what a
# model is allowed to say into the record.
$script:MarkerTokens = @(
    'HEARTBEAT_SKIPPED',
    'HEARTBEAT_ENTERED_EXPLICIT',
    'HEARTBEAT_ENTERED_DOMAIN',
    'HEARTBEAT_UNAVAILABLE',
    'ROUTER_UNAVAILABLE'
)

# The heartbeat probes ask the model to classify the marker the turn actually
# carries. Classifying it, rather than asking about routing policy, is what
# proves the plugin context reached the model without making an ordinary
# skipped turn expose routing noise. The preamble deliberately contains no
# explicit trigger and no domain alias, so it cannot change its own route.
$script:MarkerPreamble = @'
Verdict-only runtime contract probe. Do not call any tool. Do not change
anything on disk. Do not answer the question itself.

Report the routing heartbeat this turn actually carries. An absent marker is
ROUTER_UNAVAILABLE; never infer a skip from an absent marker.

Allowed tokens: HEARTBEAT_SKIPPED, HEARTBEAT_ENTERED_EXPLICIT,
HEARTBEAT_ENTERED_DOMAIN, HEARTBEAT_UNAVAILABLE, ROUTER_UNAVAILABLE

End your answer with exactly one final line of the form:
VERDICT: <token>
'@

$script:CitationPreamble = @'
Answer the question below from the knowledge base, following the approved
reading path. Do not call any tool that changes anything on disk.

End your answer with the exact page names you used, on one final line of the
form:
SOURCES: <page names>
'@

# Frozen by the approved correction. The identity probe is the only probe whose
# prompt is a literal of the runner's own: every other probe keeps the behaviour
# prompt it is measuring.
$script:IdentityPrompt = 'Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools.'

# The classic caller announces the session it started on standard error. Exactly
# one distinct id must be found there; none and more than one both fail closed,
# because a misattributed session would make the identity verdict meaningless.
$script:SessionIdPattern = '(?i)session(?:[ _-]?id)?\s*[:=]\s*([0-9A-Za-z][0-9A-Za-z_-]{7,})'

# Disposable profile fixtures. The runner names them itself so a caller can
# neither point a failure probe at a live home nor leave one behind.
$script:ProfilePrefix = 'probe-'
$script:ProfilesDirectory = 'profiles'
$script:RouterPluginId = 'hongs-vault-router'
$script:PluginsDirectory = 'plugins'
$script:ProfileConfigRelative = 'config.yaml'
$script:ProfileTelemetryRelative = 'logs'

# The Korean domain question is shared by four probes on purpose: the readiness
# failure, the telemetry denial, and the dead router must be visible from the
# runtime state alone, never from a differently worded prompt.
$script:DomainQuestion = '빔을 쏘는 Niagara 시스템은 어떻게 설계하는가?'

$script:ContractProbes = @(
    [pscustomobject]@{
        Id          = 'heartbeat-skipped'
        Kind        = 'marker'
        Environment = 'default'
        Expected    = 'HEARTBEAT_SKIPPED'
        Tokens      = $script:MarkerTokens
        Prompt      = 'Question: what is the sum of two and two?'
    },
    [pscustomobject]@{
        Id          = 'explicit-entered'
        Kind        = 'marker'
        Environment = 'default'
        Expected    = 'HEARTBEAT_ENTERED_EXPLICIT'
        Tokens      = $script:MarkerTokens
        Prompt      = '/query 이 인덱스는 어떤 주제를 다루는가?'
    },
    [pscustomobject]@{
        Id          = 'korean-domain-entered'
        Kind        = 'marker'
        Environment = 'default'
        Expected    = 'HEARTBEAT_ENTERED_DOMAIN'
        Tokens      = $script:MarkerTokens
        Prompt      = $script:DomainQuestion
    },
    [pscustomobject]@{
        Id          = 'vault-unavailable'
        Kind        = 'marker'
        Environment = 'broken-vault'
        Expected    = 'HEARTBEAT_UNAVAILABLE'
        Tokens      = $script:MarkerTokens
        Prompt      = $script:DomainQuestion
    },
    [pscustomobject]@{
        Id          = 'telemetry-denied-fail-open'
        Kind        = 'marker'
        Environment = 'telemetry-denied'
        Expected    = 'HEARTBEAT_ENTERED_DOMAIN'
        Tokens      = $script:MarkerTokens
        Prompt      = $script:DomainQuestion
    },
    [pscustomobject]@{
        Id          = 'router-missing-fail-closed'
        Kind        = 'marker'
        Environment = 'router-disabled'
        Expected    = 'ROUTER_UNAVAILABLE'
        Tokens      = $script:MarkerTokens
        Prompt      = $script:DomainQuestion
    },
    [pscustomobject]@{
        Id          = 'vault-answer-citations'
        Kind        = 'citation'
        Environment = 'default'
        Expected    = 'CITED'
        Tokens      = @('CITED', 'MISSING_CITATION')
        Prompt      = ''
    },
    [pscustomobject]@{
        Id          = 'runtime-identity'
        Kind        = 'identity'
        Environment = 'default'
        Expected    = 'RUNTIME_IDENTITY_CONFIRMED'
        Tokens      = @('RUNTIME_IDENTITY_CONFIRMED', 'RUNTIME_IDENTITY_MISMATCH', 'RUNTIME_IDENTITY_UNVERIFIED')
        Prompt      = $script:IdentityPrompt
    },
    [pscustomobject]@{
        Id          = 'phase1-regression'
        Kind        = 'phase1'
        Environment = 'default'
        Expected    = 'PHASE1_18_OF_18'
        Tokens      = @('PHASE1_18_OF_18', 'PHASE1_INCOMPLETE')
        Prompt      = ''
    }
)

# Reads the identity the probe session actually ran at, by correlating the one
# session id the caller announced across both state tables: sessions carries the
# model and the reasoning configuration, session_model_usage carries the billing
# provider. The database is opened read-only.
#
# Every ambiguity fails closed to empty strings, which the caller reduces to
# RUNTIME_IDENTITY_UNVERIFIED: a session that is absent, duplicated, or billed by
# more than one provider is not evidence of the applied runtime. No dimension is
# ever inferred from another one that did resolve.
$script:SessionIdentityReader = @'
import json
import sqlite3
import sys

identity = {"model": "", "provider": "", "effort": ""}

connection = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
try:
    sessions = connection.execute(
        "SELECT model, model_config FROM sessions WHERE id = ?", (sys.argv[2],)
    ).fetchall()
    providers = connection.execute(
        "SELECT DISTINCT billing_provider FROM session_model_usage WHERE session_id = ?",
        (sys.argv[2],),
    ).fetchall()
finally:
    connection.close()

if len(sessions) == 1 and len(providers) == 1:
    model, model_config = sessions[0]
    if isinstance(model, str):
        identity["model"] = model
    if isinstance(model_config, str):
        try:
            parsed = json.loads(model_config)
        except ValueError:
            parsed = {}
        reasoning = parsed.get("reasoning_config")
        if isinstance(reasoning, dict):
            identity["effort"] = reasoning.get("effort") or ""
    if isinstance(providers[0][0], str):
        identity["provider"] = providers[0][0]

print(json.dumps(identity))
'@


# --------------------------------------------------------------------------
# Process seam
# --------------------------------------------------------------------------

function Invoke-ContractProbeProcess {
    <#
        Run one probe child process with async stdout/stderr and a hard timeout.

        Returns the exit code, an in-memory copy of both streams for reduction,
        and a categorical Status. Stderr is returned rather than discarded
        because the classic caller announces its session id there; it may carry
        model or environment text, so it stays in memory and the recorded
        contract remains exit status plus one bounded verdict.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [hashtable]$EnvironmentOverrides,
        [int]$TimeoutSeconds = 300
    )

    $quoted = @()
    foreach ($argument in $ArgumentList) {
        if ($argument -eq '') { $quoted += '""' }
        elseif ($argument -match '[\s"]') { $quoted += ('"' + ($argument -replace '"', '\"') + '"') }
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
    if ($EnvironmentOverrides) {
        foreach ($name in $EnvironmentOverrides.Keys) {
            $startInfo.EnvironmentVariables[$name] = [string]$EnvironmentOverrides[$name]
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
    }
    catch {
        # The exception message is not recorded anywhere; only the category is.
        return [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; Status = 'launch_failed' }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = $null; StdOut = ''; StdErr = ''; Status = 'timeout' }
    }

    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
        Status   = 'ran'
    }
    $process.Dispose()
    return $result
}

function Resolve-ContractProbeCommand {
    <#
        Resolve a command to a file that can be started without a shell.

        On Windows an npm-installed CLI is a set of shims: the bare name is a
        POSIX shell script and the sibling .ps1 needs an interpreter, so neither
        is a launchable application for UseShellExecute=$false. $null means no
        safe launcher exists; the probe is then recorded as unavailable and no
        shell fallback is attempted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $executable = @('.com', '.exe', '.bat', '.cmd')

    if ($Name -match '[\\/]') {
        if (-not (Test-Path -LiteralPath $Name -PathType Leaf)) { return $null }
        if ($env:OS -ne 'Windows_NT') { return $Name }
        $explicitExtension = [System.IO.Path]::GetExtension($Name)
        if (-not $explicitExtension) { return $null }
        if ($executable -notcontains $explicitExtension.ToLowerInvariant()) { return $null }
        return $Name
    }

    if ($env:OS -ne 'Windows_NT') {
        $command = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
        if ($command.Count -gt 0) { return $command[0].Source }
        return $null
    }

    $extension = [System.IO.Path]::GetExtension($Name)
    if ($extension) {
        if ($executable -notcontains $extension.ToLowerInvariant()) { return $null }
        $candidates = @($Name)
    }
    else {
        $candidates = @($executable | ForEach-Object { $Name + $_ })
    }

    foreach ($directory in ($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($directory)) { continue }
        foreach ($candidate in $candidates) {
            try { $path = Join-Path $directory.Trim('"') $candidate }
            catch { continue }
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    return $null
}


# --------------------------------------------------------------------------
# Launcher shape and environment
# --------------------------------------------------------------------------

function New-ContractProbeArgumentList {
    <#
        One fresh Hermes session through the installed classic caller.

        The array is exactly the approved caller shape, with the probe's own
        behaviour prompt as its final element. No model, provider, or reasoning
        override is ever passed: the probes measure the applied runtime
        defaults, and an overridden session would prove nothing about what a
        real turn runs on. No evidence artefact is requested either; the
        identity is correlated from the runtime state instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Prompt)

    return @('chat', '--cli', '-Q', '-q', $Prompt)
}

function Get-ProbeSessionId {
    <#
        The one session id the classic caller announced on standard error.

        Zero ids and two different ids both return an empty string: the identity
        verdict may only be drawn from the session this probe actually started,
        so an unresolvable announcement fails closed rather than picking one.
        Standard error itself is never returned or persisted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$StandardError)

    if ([string]::IsNullOrWhiteSpace($StandardError)) { return '' }
    $found = [regex]::Matches($StandardError, $script:SessionIdPattern)
    if ($found.Count -eq 0) { return '' }
    $ids = @($found | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($ids.Count -ne 1) { return '' }
    return [string]$ids[0]
}

function New-ProbeEnvironment {
    <#
        The child environment for one probe. Only the child's environment is
        set; the user and machine environments are never written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Environment,
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$VaultRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TelemetryProfile,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RouterProfile,
        [Parameter(Mandatory = $true)][string]$BrokenVaultPath
    )

    switch ($Environment) {
        'default' { return @{ HERMES_HOME = $HermesHome; HONG_VAULT_ROOT = $VaultRoot } }
        'broken-vault' { return @{ HERMES_HOME = $HermesHome; HONG_VAULT_ROOT = $BrokenVaultPath } }
        'telemetry-denied' { return @{ HERMES_HOME = $TelemetryProfile; HONG_VAULT_ROOT = $VaultRoot } }
        'router-disabled' { return @{ HERMES_HOME = $RouterProfile; HONG_VAULT_ROOT = $VaultRoot } }
        default { throw "run-runtime-contract-probes: unknown probe environment '$Environment'." }
    }
}

function Copy-ProbeRouterPlugin {
    <#
        Install the routing plugin package into one disposable profile.

        Hermes scans user plugins at <home>/plugins only, so a profile used as a
        probe home sees no plugin at all unless the package is present in its
        own plugins directory. Without it, the telemetry probe could not load
        the router and the dead-router probe would prove an absent package
        rather than a disabled one.

        Only this one package is copied, and only file content below it: no
        configuration, credential, token, environment file, state database, or
        log of the applied home is ever duplicated. Every failure is closed - an
        absent or unreadable source, a reparse point anywhere in the package,
        and a destination that is not a fresh directory inside the profile the
        runner owns all throw rather than copy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $source = Join-Path (Join-Path $HermesHome $script:PluginsDirectory) $script:RouterPluginId
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "run-runtime-contract-probes: the routing plugin package was not found under the applied home."
    }
    $sourceRoot = (Resolve-Path -LiteralPath $source).ProviderPath.TrimEnd('\')
    if ((Get-Item -LiteralPath $sourceRoot -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw 'run-runtime-contract-probes: the routing plugin package is not an ordinary directory.'
    }

    $profileRoot = (Resolve-Path -LiteralPath $ProfilePath).ProviderPath.TrimEnd('\')
    $pluginsRoot = Join-Path $profileRoot $script:PluginsDirectory

    # The profile was created empty moments ago, so an existing plugins path is
    # not this runner's. Refusing it closes the junction case too: a pre-planted
    # link would otherwise make a lexically contained destination write outside
    # the profile.
    if (Test-Path -LiteralPath $pluginsRoot) {
        throw 'run-runtime-contract-probes: the disposable profile plugins directory already exists.'
    }

    $destination = [System.IO.Path]::GetFullPath((Join-Path $pluginsRoot $script:RouterPluginId)).TrimEnd('\')
    if (-not $destination.StartsWith($profileRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'run-runtime-contract-probes: the routing plugin destination escapes the disposable profile.'
    }

    [void](New-Item -ItemType Directory -Path $destination -Force)
    foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force)) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw 'run-runtime-contract-probes: the routing plugin package contains a reparse point.'
        }
        $target = Join-Path $destination $item.FullName.Substring($sourceRoot.Length).TrimStart('\')
        if ($item.PSIsContainer) { [void](New-Item -ItemType Directory -Path $target -Force) }
        else { [System.IO.File]::Copy($item.FullName, $target, $false) }
    }

    return $destination
}

function New-DisposableProbeProfile {
    <#
        One UUID-isolated disposable profile under the applied home's profiles/
        directory, carrying exactly one failure condition.

        Two things are written into it and nothing else. The routing plugin
        package is installed into the profile's own plugins directory, because
        Hermes scans user plugins per home. Its configuration is generated here
        rather than copied from the applied home, which could carry unrelated or
        secret values: it is the minimal synthetic runtime contract - the model,
        the provider, the reasoning effort - plus the plugin opt-in lists.

        No credential, token, or environment file is ever copied into a profile:
        a probe session reaches the root OAuth only through the Hermes profile
        fallback, and no root state is written.

        'router-disabled' installs the plugin but leaves it out of the opt-in
        list and denies it explicitly, so the probe measures a disabled router
        rather than an absent package. 'telemetry-denied' enables the plugin and
        occupies the log directory name with an ordinary file, so every routing
        telemetry write below it fails while the rest of the profile is intact.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HermesHome,
        [Parameter(Mandatory = $true)][ValidateSet('telemetry-denied', 'router-disabled')][string]$Kind
    )

    $profilesRoot = Join-Path $HermesHome $script:ProfilesDirectory
    [void](New-Item -ItemType Directory -Path $profilesRoot -Force)

    $path = Join-Path $profilesRoot ($script:ProfilePrefix + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path)

    try {
        [void](Copy-ProbeRouterPlugin -HermesHome $HermesHome -ProfilePath $path)

        if ($Kind -eq 'router-disabled') { $enabled = @(); $disabled = @($script:RouterPluginId) }
        else { $enabled = @($script:RouterPluginId); $disabled = @() }

        $lines = @(
            'model:',
            ('  default: ' + $script:ContractModel),
            ('  provider: ' + $script:ContractProvider),
            'agent:',
            ('  reasoning_effort: ' + $script:ContractEffort),
            'plugins:'
        )
        foreach ($list in @(
                [pscustomobject]@{ Name = 'enabled'; Value = $enabled },
                [pscustomobject]@{ Name = 'disabled'; Value = $disabled })) {
            if (@($list.Value).Count -eq 0) { $lines += ('  ' + $list.Name + ': []') }
            else {
                $lines += ('  ' + $list.Name + ':')
                foreach ($id in @($list.Value)) { $lines += ('    - ' + $id) }
            }
        }

        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            (Join-Path $path $script:ProfileConfigRelative), (($lines -join "`n") + "`n"), $encoding)

        if ($Kind -eq 'telemetry-denied') {
            [System.IO.File]::WriteAllText((Join-Path $path $script:ProfileTelemetryRelative), '', $encoding)
        }
    }
    catch {
        # A half-provisioned profile is never left behind, so a fail-closed
        # fixture cannot become an unowned directory in the applied home.
        Remove-Item -LiteralPath $path -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        throw
    }

    return $path
}

function Test-DisposableProbeProfile {
    <#
        A profile is the runner's to use and to delete only when it is a real
        directory named by this runner, directly under the applied home's
        profiles/ directory. Anything else - the applied home itself, a path
        outside profiles/, an operator's own profile, a reparse point - is
        refused rather than used or removed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$HermesHome
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath $HermesHome -PathType Container)) { return $false }

    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $applied = (Resolve-Path -LiteralPath $HermesHome).ProviderPath.TrimEnd('\')
    if ($resolved -ieq $applied) { return $false }

    $expectedParent = (Join-Path $applied $script:ProfilesDirectory).TrimEnd('\')
    if (-not ((Split-Path -Parent $resolved) -ieq $expectedParent)) { return $false }

    $leaf = Split-Path -Leaf $resolved
    if (-not $leaf.StartsWith($script:ProfilePrefix, [System.StringComparison]::Ordinal)) { return $false }

    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
    return $true
}

function Remove-DisposableProbeProfile {
    <#
        Delete one profile this runner created, after re-validating it. The
        profiles/ directory itself is left in place: in a real home it is not
        the runner's to remove.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$HermesHome
    )

    if (-not (Test-DisposableProbeProfile -Path $Path -HermesHome $HermesHome)) { return $false }
    Remove-Item -LiteralPath $Path -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    return (-not (Test-Path -LiteralPath $Path))
}


# --------------------------------------------------------------------------
# Reduction
# --------------------------------------------------------------------------

function Get-ContractVerdict {
    <#
        Reduce probe output to one token drawn from the probe's allowed set.

        Anything the model says that is not an allowed token collapses to
        UNPARSED, so no free-form model text can reach the envelope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Tokens
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'NO_OUTPUT' }
    $verdictMatches = [regex]::Matches($Text, 'VERDICT:\s*([A-Z_0-9]+)')
    if ($verdictMatches.Count -gt 0) {
        $declared = $verdictMatches[$verdictMatches.Count - 1].Groups[1].Value
        if ($Tokens -contains $declared) { return $declared }
        return 'UNPARSED'
    }
    foreach ($token in $Tokens) {
        if ($Text -match [regex]::Escape($token)) { return $token }
    }
    return 'UNPARSED'
}

function Get-CitationVerdict {
    <#
        Reduce an entered answer to whether it named every required source page.

        The page names are caller-supplied fixture input: they are matched here
        and never returned, so nothing derived from Vault content is persisted.
        An empty requirement is a missing fixture, never a pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$RequiredPages
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'NO_OUTPUT' }
    if (@($RequiredPages).Count -eq 0) { return 'MISSING_CITATION' }
    foreach ($page in $RequiredPages) {
        if ([string]::IsNullOrWhiteSpace($page)) { return 'MISSING_CITATION' }
        if ($Text.IndexOf($page, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            return 'MISSING_CITATION'
        }
    }
    return 'CITED'
}

function Get-RuntimeIdentityVerdict {
    <#
        Reduce the measured runtime identity to one token.

        The inputs are the correlated runtime state only. The session's answer is
        deliberately not a parameter: a model can say anything about its own
        configuration, so response text is never identity evidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Provider,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Effort
    )

    if ([string]::IsNullOrWhiteSpace($Model) -or
        [string]::IsNullOrWhiteSpace($Provider) -or
        [string]::IsNullOrWhiteSpace($Effort)) {
        return 'RUNTIME_IDENTITY_UNVERIFIED'
    }
    if (($Model -cne $script:ContractModel) -or
        ($Provider -cne $script:ContractProvider) -or
        ($Effort -cne $script:ContractEffort)) {
        return 'RUNTIME_IDENTITY_MISMATCH'
    }
    return 'RUNTIME_IDENTITY_CONFIRMED'
}

function Get-SessionIdentity {
    <#
        Correlate one announced session id with the runtime state database and
        return the three measured dimensions.

        Every failure - no interpreter, no database, a reader that did not exit
        cleanly, output that is not the expected object - returns three empty
        strings, which the identity verdict reduces to unverified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$StateDatabase,
        [Parameter(Mandatory = $true)][string]$PythonCommand,
        [Parameter(Mandatory = $true)][string]$ReaderPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$TempDirectory,
        [int]$TimeoutSeconds = 300
    )

    $empty = [pscustomobject]@{ Model = ''; Provider = ''; Effort = '' }

    $interpreter = Resolve-ContractProbeCommand -Name $PythonCommand
    if (-not $interpreter) { return $empty }
    if (-not (Test-Path -LiteralPath $StateDatabase -PathType Leaf)) { return $empty }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ReaderPath, $script:SessionIdentityReader, $encoding)

    $run = Invoke-ContractProbeProcess -FilePath $interpreter `
        -ArgumentList @($ReaderPath, $StateDatabase, $SessionId) `
        -WorkingDirectory $WorkingDirectory -TempDirectory $TempDirectory -TimeoutSeconds $TimeoutSeconds
    if ($run.Status -ne 'ran' -or $run.ExitCode -ne 0) { return $empty }

    try { $identity = $run.StdOut | ConvertFrom-Json }
    catch { return $empty }
    if ($null -eq $identity) { return $empty }

    return [pscustomobject]@{
        Model    = [string]$identity.model
        Provider = [string]$identity.provider
        Effort   = [string]$identity.effort
    }
}


# --------------------------------------------------------------------------
# Phase 1 chain
# --------------------------------------------------------------------------

function New-Phase1ArgumentList {
    <#
        Invoke the Phase 1 probe runner exactly as Phase 1 defines it: its own
        confirmation flag and an output root, and nothing that could change a
        scenario, an expectation, or a prompt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputRoot
    )

    return @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $RepositoryRoot $script:Phase1Relative),
        '-RepositoryRoot', $RepositoryRoot,
        '-ConfirmLiveApplyComplete',
        '-OutputRoot', $OutputRoot
    )
}

function ConvertTo-Phase1Record {
    <#
        Keep only the categorical fields of one Phase 1 record. Any other field
        the Phase 1 summary may carry is dropped rather than copied forward.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Record)

    return [pscustomobject]@{
        Harness  = [string]$Record.Harness
        Scenario = [string]$Record.Scenario
        Expected = [string]$Record.Expected
        Verdict  = [string]$Record.Verdict
        Pass     = [bool]$Record.Pass
        Note     = [string]$Record.Note
    }
}


# --------------------------------------------------------------------------
# Gates
# --------------------------------------------------------------------------

# A refused gate is reported on standard error and exits 2. Write-Error is not
# used: this script runs with $ErrorActionPreference = 'Stop', which would turn
# the message into a terminating error and exit 1 before the gate's own exit
# code could be returned.
if (-not $ConfirmRuntimeContractApplied) {
    [Console]::Error.WriteLine(@'
Runtime contract probes run against the applied runtime only.
Re-run with -ConfirmRuntimeContractApplied after the runtime contract has been
applied.
'@)
    exit 2
}

if ($env:ANTHROPIC_API_KEY) {
    [Console]::Error.WriteLine(@'
ANTHROPIC_API_KEY is set. The chained Phase 1 matrix must stay on the
subscription-backed first-party path; there is no API-key fallback. Clear the
variable and re-run.
'@)
    exit 2
}

foreach ($root in @($RepositoryRoot, $HermesHome, $ClaudeHome, $CodexHome, $VaultRoot)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        [Console]::Error.WriteLine("run-runtime-contract-probes: required root '$root' does not exist.")
        exit 2
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $script:Phase1Relative) -PathType Leaf)) {
    [Console]::Error.WriteLine('run-runtime-contract-probes: the Phase 1 probe runner was not found.')
    exit 2
}

[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
$childTemp = Join-Path $OutputDirectory 'child-temp'
[void](New-Item -ItemType Directory -Path $childTemp -Force)


# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

# A path that must not exist, so the readiness probe measures a real readiness
# failure instead of an unrelated one.
$brokenVaultPath = Join-Path $childTemp 'absent-vault-root'

$stateDatabase = $StateDatabasePath
if ([string]::IsNullOrWhiteSpace($stateDatabase)) {
    $stateDatabase = Join-Path $HermesHome 'state.db'
}

$launcher = Resolve-ContractProbeCommand -Name $HermesCommand
$results = @()
$phase1Records = @()

# The exit code is decided inside the try block and returned after the finally
# block, so the disposable fixtures are removed before the process ends on the
# success path and on every failure path alike.
$runExitCode = 0

# The two failure fixtures belong to the runner, not to the caller: they are
# created here and removed in the finally block below.
$telemetryProfile = ''
$routerProfile = ''

try {

$telemetryProfile = New-DisposableProbeProfile -HermesHome $HermesHome -Kind 'telemetry-denied'
$routerProfile = New-DisposableProbeProfile -HermesHome $HermesHome -Kind 'router-disabled'

foreach ($probe in $script:ContractProbes) {

    $verdict = 'UNAVAILABLE'
    $exitCode = $null
    $note = ''

    if ($probe.Kind -eq 'phase1') {
        $phase1Root = Join-Path $OutputDirectory 'phase1'
        [void](New-Item -ItemType Directory -Path $phase1Root -Force)
        $run = Invoke-ContractProbeProcess -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList (New-Phase1ArgumentList -RepositoryRoot $RepositoryRoot -OutputRoot $phase1Root) `
            -WorkingDirectory $OutputDirectory -TempDirectory $childTemp `
            -EnvironmentOverrides @{ HERMES_HOME = $HermesHome; HONG_VAULT_ROOT = $VaultRoot } `
            -TimeoutSeconds ($TimeoutSeconds * $script:Phase1Expected)
        $exitCode = $run.ExitCode

        $summaryPath = Join-Path $phase1Root 'probe-results.json'
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            # Assigned before it is iterated: on Windows PowerShell 5.1
            # ConvertFrom-Json writes a JSON array to the pipeline as one
            # object, so an inline @( ... | ConvertFrom-Json ) would yield a
            # single element holding all 18 records instead of 18 records.
            $parsed = (Get-Content -LiteralPath $summaryPath -Raw) | ConvertFrom-Json
            foreach ($record in $parsed) {
                $phase1Records += ConvertTo-Phase1Record -Record $record
            }
        }
        $passed = @($phase1Records | Where-Object { $_.Pass }).Count
        if (($phase1Records.Count -eq $script:Phase1Expected) -and ($passed -eq $script:Phase1Expected)) {
            $verdict = 'PHASE1_18_OF_18'
        }
        else {
            $verdict = 'PHASE1_INCOMPLETE'
            $note = 'phase1_incomplete'
        }
    }
    elseif (-not $launcher) {
        $note = 'cli_not_found'
    }
    elseif ($probe.Kind -eq 'citation' -and
        ([string]::IsNullOrWhiteSpace($CitationQuestion) -or @($CitationSourcePage).Count -eq 0)) {
        $note = 'fixture_missing'
    }
    else {
        $environment = New-ProbeEnvironment -Environment $probe.Environment -HermesHome $HermesHome `
            -VaultRoot $VaultRoot -TelemetryProfile $telemetryProfile -RouterProfile $routerProfile `
            -BrokenVaultPath $brokenVaultPath

        switch ($probe.Kind) {
            'marker' { $prompt = $script:MarkerPreamble + "`n`n" + $probe.Prompt }
            'citation' { $prompt = $script:CitationPreamble + "`n`n" + '/query ' + $CitationQuestion }
            'identity' { $prompt = $probe.Prompt }
            default { throw "run-runtime-contract-probes: unknown probe kind '$($probe.Kind)'." }
        }

        $arguments = New-ContractProbeArgumentList -Prompt $prompt
        $run = Invoke-ContractProbeProcess -FilePath $launcher -ArgumentList $arguments `
            -WorkingDirectory $OutputDirectory -TempDirectory $childTemp `
            -EnvironmentOverrides $environment -TimeoutSeconds $TimeoutSeconds
        $exitCode = $run.ExitCode

        # $run.StdOut is reduced here and never leaves this scope.
        if ($run.Status -ne 'ran') {
            $note = $run.Status
        }
        elseif ($probe.Kind -eq 'marker') {
            $verdict = Get-ContractVerdict -Text $run.StdOut -Tokens $probe.Tokens
        }
        elseif ($probe.Kind -eq 'citation') {
            $verdict = Get-CitationVerdict -Text $run.StdOut -RequiredPages $CitationSourcePage
        }
        else {
            # The identity is never taken from what the session answered. The
            # one session id the caller announced on standard error is
            # correlated with the runtime state instead.
            $sessionId = Get-ProbeSessionId -StandardError $run.StdErr
            if ([string]::IsNullOrWhiteSpace($sessionId)) {
                $verdict = 'RUNTIME_IDENTITY_UNVERIFIED'
                $note = 'session_unresolved'
            }
            else {
                $identity = Get-SessionIdentity -SessionId $sessionId -StateDatabase $stateDatabase `
                    -PythonCommand $PythonCommand `
                    -ReaderPath (Join-Path $childTemp 'read-session-identity.py') `
                    -WorkingDirectory $OutputDirectory -TempDirectory $childTemp `
                    -TimeoutSeconds $TimeoutSeconds
                $verdict = Get-RuntimeIdentityVerdict -Model $identity.Model `
                    -Provider $identity.Provider -Effort $identity.Effort
                if ($verdict -eq 'RUNTIME_IDENTITY_UNVERIFIED') { $note = 'state_unreadable' }
            }
        }
    }

    $pass = (($exitCode -eq 0) -and ($verdict -eq $probe.Expected))
    if ($note -eq '') {
        if ($exitCode -ne 0 -and $null -ne $exitCode) { $note = 'nonzero_exit' }
        elseif ($verdict -eq 'UNPARSED' -or $verdict -eq 'NO_OUTPUT') { $note = 'unparsed' }
        elseif (-not $pass) { $note = 'unexpected_verdict' }
    }

    $results += [pscustomobject]@{
        Id       = $probe.Id
        Expected = $probe.Expected
        Verdict  = $verdict
        ExitCode = $exitCode
        Pass     = $pass
        Note     = $note
    }
}

# The state reader and the absent-Vault placeholder are both disposable:
# nothing derived from a model turn survives the run.
Remove-Item -LiteralPath $childTemp -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue

$envelope = [pscustomobject]@{
    kind      = 'hongs-runtime-contract-probe-results'
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    probes    = $results
    phase1    = [pscustomobject]@{
        expected = $script:Phase1Expected
        passed   = @($phase1Records | Where-Object { $_.Pass }).Count
        records  = $phase1Records
    }
}

$summaryPath = Join-Path $OutputDirectory 'runtime-contract-probe-results.json'
$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($summaryPath, (($envelope | ConvertTo-Json -Depth 6) + "`n"), $encoding)

foreach ($result in $results) {
    Write-Output ('{0,-28} expected={1,-28} verdict={2,-28} exit={3} pass={4} note={5}' -f `
            $result.Id, $result.Expected, $result.Verdict, $result.ExitCode, $result.Pass, $result.Note)
}
Write-Output ('Phase 1 matrix: {0}/{1} PASS' -f $envelope.phase1.passed, $script:Phase1Expected)
Write-Output "Probe results: $summaryPath"

if (@($results | Where-Object { -not $_.Pass }).Count -gt 0) { $runExitCode = 1 }

}
finally {
    # Both fixtures are removed here, so a completed run, a failed run, and a
    # run that threw all leave the applied home's profiles/ directory as it was.
    [void](Remove-DisposableProbeProfile -Path $telemetryProfile -HermesHome $HermesHome)
    [void](Remove-DisposableProbeProfile -Path $routerProfile -HermesHome $HermesHome)
}

exit $runExitCode
