<#
.SYNOPSIS
    Dry-run or apply the Phase 2 runtime contract as one transaction.

.DESCRIPTION
    The runtime contract is exactly five things:

      * the managed files the harness manifest declares;
      * the one marked routing-contract section inside the Vault index;
      * the user environment variable HONG_VAULT_ROOT;
      * the enablement of the hongs-vault-router plugin with
        allow_tool_override disabled;
      * the three shared model keys model.default, model.provider, and
        agent.reasoning_effort.

    Nothing else is applied, distributed, or published. The script makes no
    network call, reads no credential, enumerates no unowned file, and never
    prints a configuration value, an environment value, or Vault content.

    -DryRun runs the read-only preflight, including the read-only reasoning-seam
    verification, and prints the planned actions and hashes. It writes nothing:
    no file, no backup, no configuration, no environment variable, and no
    inference request.

    -Apply additionally requires -ConfirmLiveRuntimeMutation. It snapshots the
    exact prior state under $HermesHome\backups\hongs-runtime-contract\<UTC>\,
    verifies that snapshot, applies exactly the three model keys as the first
    mutation stage, and proves them in a fresh process with exactly
    `hermes chat --cli -Q -q <contract prompt>` and no override. Any failure
    before that proof restores exactly the three keys with zero later mutation
    and reports MODEL_CONTRACT_UNAVAILABLE; any failure after it rolls the whole
    transaction back to the snapshot. Both exit non-zero with the backup path.

    Targets Windows PowerShell 5.1.

.EXAMPLE
    powershell -File bootstrap/apply-runtime-contract.ps1 -DryRun `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude `
        -CodexHome C:\codex -VaultRoot D:\vault -HermesSourceRoot C:\hermes-source

.EXAMPLE
    powershell -File bootstrap/apply-runtime-contract.ps1 -Apply -ConfirmLiveRuntimeMutation `
        -RepositoryRoot C:\repo -HermesHome C:\hermes -ClaudeHome C:\claude `
        -CodexHome C:\codex -VaultRoot D:\vault -HermesSourceRoot C:\hermes-source
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$ConfirmLiveRuntimeMutation,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$HermesHome,
    [Parameter(Mandatory = $true)][string]$ClaudeHome,
    [Parameter(Mandatory = $true)][string]$CodexHome,
    [Parameter(Mandatory = $true)][string]$VaultRoot,
    [Parameter(Mandatory = $true)][string]$HermesSourceRoot,
    [string]$BackupTimestamp,
    [string]$ManifestPath,
    [string]$HermesCommand = 'hermes',
    [string]$PythonCommand = 'python',
    [string]$StateDatabasePath,

    # Disposable-test seam. When supplied, the read-only reasoning-seam verifier
    # is taken from this path instead of the repository default. A live run omits
    # it and the repository script is used.
    [string]$SeamVerifierPath,

    # Disposable-test seam. When supplied, the user-scope environment variable
    # is read from and written to this JSON store instead of the user registry.
    # A live run omits it.
    [string]$UserEnvironmentStorePath,

    # Test hook. Raises a synthetic failure immediately after the named stage so
    # the rollback path can be exercised without a real fault.
    [string]$FailAfterStage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The rollback script is dot-sourced below so its restore logic is shared
# rather than duplicated. Dot-sourcing brings that script's parameter names
# into this scope, so every parameter of this script is copied to a distinct
# name first and only the copies are used afterwards.
$script:ContractDryRun = [bool]$DryRun
$script:ContractApply = [bool]$Apply
$script:ContractConfirmed = [bool]$ConfirmLiveRuntimeMutation
$script:ContractRepositoryRoot = $RepositoryRoot
$script:ContractHermesHome = $HermesHome
$script:ContractClaudeHome = $ClaudeHome
$script:ContractCodexHome = $CodexHome
$script:ContractVaultRoot = $VaultRoot
$script:ContractBackupTimestamp = $BackupTimestamp
$script:ContractManifestPath = $ManifestPath
$script:ContractHermesCommand = $HermesCommand
$script:ContractPythonCommand = $PythonCommand
$script:ContractStateDatabase = $StateDatabasePath
$script:ContractEnvironmentStore = $UserEnvironmentStorePath
$script:ContractFailAfterStage = $FailAfterStage
$script:ContractHermesSource = $HermesSourceRoot
$script:ContractSeamVerifier = $SeamVerifierPath

$script:VaultVariableName = 'HONG_VAULT_ROOT'
$script:PluginName = 'hongs-vault-router'
$script:VaultIndexRelative = 'wiki\index.md'
$script:BackupSegment = 'backups\hongs-runtime-contract'
$script:ConfigRelative = 'config.yaml'

$script:ProbeProvider = 'openai-codex'
$script:ProbePrompt = 'Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools.'
$script:ProbeExpectedAnswer = 'MODEL_CONTRACT_PROBE_OK'

# The approved production proof caller, and the facts the correlated session
# must report for it.
$script:ProofArguments = @('chat', '--cli', '-Q', '-q')
$script:ProofModel = 'gpt-5.6-sol'
$script:ProofBillingProvider = 'openai-codex'
$script:ProofEffort = 'high'

$script:SeamKind = 'hongs-hermes-reasoning-seam'
$script:SeamSchemaVersion = 1
$script:SeamVerifierRelative = 'scripts\verify-hermes-reasoning-seam.py'
$script:SeamRouterRelative = 'baseline\hermes\plugins\hongs-vault-router\router.py'
$script:SeamRoutingContractRelative = 'contracts\vault-query-routing-contract.md'

# The complete, ordered set of shared model keys. Nothing else is distributed.
$script:ModelContract = @(
    [pscustomobject]@{ Key = 'model.default'; Value = 'gpt-5.6-sol'; Stage = 'ModelDefault' },
    [pscustomobject]@{ Key = 'model.provider'; Value = 'openai-codex'; Stage = 'ModelProvider' },
    [pscustomobject]@{ Key = 'agent.reasoning_effort'; Value = 'high'; Stage = 'ModelEffort' }
)

# The model stage runs before every other mutation, so nothing outside these
# three leaves may differ while it holds.
$script:ModelStageAllowedLeaves = @('model.default', 'model.provider', 'agent.reasoning_effort')

$script:AllowedConfigLeaves = @(
    'model.default',
    'model.provider',
    'agent.reasoning_effort',
    ('plugins.entries.' + $script:PluginName + '.allow_tool_override')
)

$script:AllowedConfigPrefixes = @('plugins.enabled', 'plugins.disabled')


# --------------------------------------------------------------------------
# Process helpers
# --------------------------------------------------------------------------

function ConvertTo-ContractArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Invoke-ContractProcess {
    <#
        Run one local process and return its exit code and streams. Batch
        launchers are executed through cmd.exe /s /c because CreateProcess
        cannot start them directly. Nothing here reaches the network.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [int]$TimeoutSeconds = 900
    )

    $quoted = @()
    foreach ($argument in $Arguments) { $quoted += (ConvertTo-ContractArgument -Value $argument) }

    $fileName = $FilePath
    $argumentLine = ($quoted -join ' ')
    if ($FilePath -match '\.(cmd|bat)$') {
        $commandLine = (ConvertTo-ContractArgument -Value $FilePath)
        if ($argumentLine) { $commandLine = $commandLine + ' ' + $argumentLine }
        $fileName = 'cmd.exe'
        $argumentLine = '/s /c "' + $commandLine + '"'
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $fileName
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "runtime contract: '$FilePath' timed out after $TimeoutSeconds s."
    }
    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout.Result
        StdErr   = $stderr.Result
    }
    $process.Dispose()
    return $result
}

function Invoke-ContractHermes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)

    return Invoke-ContractProcess -FilePath $script:ContractHermesCommand -Arguments $Arguments
}

function Invoke-ContractPython {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)

    return Invoke-ContractProcess -FilePath $script:ContractPythonCommand -Arguments $Arguments
}


# --------------------------------------------------------------------------
# Path and hash helpers
# --------------------------------------------------------------------------

function ConvertTo-ContractFullPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd([char]'\', [char]'/') }
    return $full
}

function Get-ContractFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-ContractDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Protect-ContractDirectory {
    <#
        Restrict a snapshot directory to the current user. The snapshot holds
        machine-local paths and prior configuration bytes, so it is never world
        readable, never printed, and never committed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}


# --------------------------------------------------------------------------
# Minimal YAML reader
# --------------------------------------------------------------------------
#
# The configuration file is machine-local and is never distributed. This reader
# exists only to compare the parsed leaves before and after the transaction, so
# that exactly the approved keys may change and every unrelated key stays
# semantically equal across a reformat. Anything it cannot parse unambiguously
# is refused rather than silently accepted.

function Read-ContractYamlLines {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $lines = New-Object System.Collections.ArrayList
    foreach ($raw in ($Text -split "`r?`n")) {
        if ($raw -match '^\s*$') { continue }
        if ($raw -match '^\s*#') { continue }
        $trimmed = $raw.TrimStart(' ')
        $indent = $raw.Length - $trimmed.Length
        if ($raw.Substring(0, $indent) -match "`t") {
            throw 'runtime contract: the configuration uses tab indentation, which cannot be compared safely.'
        }
        $content = $trimmed.TrimEnd()
        if ($content -eq '---' -or $content -eq '...') { continue }
        [void]$lines.Add([pscustomobject]@{ Indent = $indent; Text = $content })
    }
    return $lines
}

function Add-ContractLeaf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Leaves,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Leaves.ContainsKey($Path)) {
        throw "runtime contract: the configuration declares '$Path' more than once."
    }
    $Leaves[$Path] = $Value
}

function ConvertTo-ContractScalar {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $value = $Value.Trim()
    if ($value.StartsWith('&') -or $value.StartsWith('*') -or $value.StartsWith('!')) {
        throw 'runtime contract: the configuration uses an anchor, alias, or tag, which cannot be compared safely.'
    }
    if (-not ($value.StartsWith('"') -or $value.StartsWith(''''))) {
        $value = ($value -replace '\s+#.*$', '').Trim()
    }
    if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq '''' -and $last -eq '''')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }
    if ($value.StartsWith('{') -and -not $value.EndsWith('}')) {
        throw 'runtime contract: the configuration uses a multi-line flow mapping, which cannot be compared safely.'
    }
    if ($value.StartsWith('[') -and -not $value.EndsWith(']')) {
        throw 'runtime contract: the configuration uses a multi-line flow sequence, which cannot be compared safely.'
    }
    return $value
}

function Read-ContractBlockScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Indent
    )

    $parts = @()
    while ($State.Index -lt $State.Lines.Count) {
        $line = $State.Lines[$State.Index]
        if ($line.Indent -le $Indent) { break }
        $parts += $line.Text
        $State.Index++
    }
    return ($parts -join "`n")
}

function Convert-ContractYamlBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Indent,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prefix
    )

    $sequenceIndex = 0
    while ($State.Index -lt $State.Lines.Count) {
        $line = $State.Lines[$State.Index]
        if ($line.Indent -lt $Indent) { return }
        if ($line.Indent -gt $Indent) {
            throw "runtime contract: the configuration has unexpected indentation at '$($line.Text)'."
        }

        $text = $line.Text
        if ($text -eq '-' -or $text.StartsWith('- ')) {
            $itemPath = '{0}[{1}]' -f $Prefix, $sequenceIndex
            $sequenceIndex++
            $rest = if ($text -eq '-') { '' } else { $text.Substring(2).TrimStart(' ') }
            if ($rest -eq '') {
                $State.Index++
                if ($State.Index -lt $State.Lines.Count -and $State.Lines[$State.Index].Indent -gt $Indent) {
                    Convert-ContractYamlBlock -State $State -Indent $State.Lines[$State.Index].Indent -Prefix $itemPath
                }
                else {
                    Add-ContractLeaf -Leaves $State.Leaves -Path $itemPath -Value ''
                }
                continue
            }
            if ($rest -match '^(?<key>"[^"]*"|''[^'']*''|[^:#]+?)\s*:(?:\s+(?<value>\S.*))?$') {
                $keyIndent = $Indent + ($text.Length - $rest.Length)
                $State.Lines[$State.Index] = [pscustomobject]@{ Indent = $keyIndent; Text = $rest }
                Convert-ContractYamlBlock -State $State -Indent $keyIndent -Prefix $itemPath
                continue
            }
            Add-ContractLeaf -Leaves $State.Leaves -Path $itemPath -Value (ConvertTo-ContractScalar -Value $rest)
            $State.Index++
            continue
        }

        if ($text -notmatch '^(?<key>"[^"]*"|''[^'']*''|[^:#]+?)\s*:(?:\s+(?<value>\S.*))?$') {
            throw "runtime contract: a configuration line could not be parsed safely."
        }
        $key = $Matches['key'].Trim()
        if ($key.StartsWith('"') -or $key.StartsWith('''')) { $key = $key.Substring(1, $key.Length - 2) }
        if ($key -eq '<<') {
            throw 'runtime contract: the configuration uses a merge key, which cannot be compared safely.'
        }
        $path = if ($Prefix -eq '') { $key } else { $Prefix + '.' + $key }
        $rawValue = ''
        if ($Matches.ContainsKey('value')) { $rawValue = ([string]$Matches['value']).Trim() }
        $State.Index++

        if ($rawValue -ne '') {
            if ($rawValue -match '^[|>][-+0-9]*$') {
                $block = Read-ContractBlockScalar -State $State -Indent $Indent
                Add-ContractLeaf -Leaves $State.Leaves -Path $path -Value $block
                continue
            }
            Add-ContractLeaf -Leaves $State.Leaves -Path $path -Value (ConvertTo-ContractScalar -Value $rawValue)
            continue
        }

        if ($State.Index -lt $State.Lines.Count -and $State.Lines[$State.Index].Indent -gt $Indent) {
            Convert-ContractYamlBlock -State $State -Indent $State.Lines[$State.Index].Indent -Prefix $path
        }
        else {
            Add-ContractLeaf -Leaves $State.Leaves -Path $path -Value ''
        }
    }
}

function Get-ContractConfigLeaves {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'runtime contract: the Hermes configuration file was not found.'
    }
    $text = [System.IO.File]::ReadAllText($Path)
    $lines = Read-ContractYamlLines -Text $text
    $state = [pscustomobject]@{ Lines = $lines; Index = 0; Leaves = @{} }
    if ($lines.Count -gt 0) {
        Convert-ContractYamlBlock -State $state -Indent $lines[0].Indent -Prefix ''
    }
    if ($state.Index -lt $lines.Count) {
        throw 'runtime contract: the configuration could not be parsed to the end.'
    }
    return $state.Leaves
}

function Test-ContractAllowedConfigPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedLeaves,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedPrefixes
    )

    if ($AllowedLeaves -contains $Path) { return $true }
    foreach ($prefix in $AllowedPrefixes) {
        if ($Path -eq $prefix -or $Path.StartsWith($prefix + '[', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-ContractConfigViolations {
    <#
        Paths whose value changed, appeared, or disappeared outside the supplied
        allowlist. The allowlist is a parameter so the same comparison serves
        both the strict model stage and the final full-transaction stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Before,
        [Parameter(Mandatory = $true)][hashtable]$After,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedLeaves,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$AllowedPrefixes
    )

    $violations = New-Object System.Collections.ArrayList
    foreach ($path in @($Before.Keys)) {
        if (Test-ContractAllowedConfigPath -Path $path -AllowedLeaves $AllowedLeaves -AllowedPrefixes $AllowedPrefixes) { continue }
        if (-not $After.ContainsKey($path)) {
            [void]$violations.Add("removed $path")
            continue
        }
        if ($After[$path] -cne $Before[$path]) {
            [void]$violations.Add("changed $path")
        }
    }
    foreach ($path in @($After.Keys)) {
        if (Test-ContractAllowedConfigPath -Path $path -AllowedLeaves $AllowedLeaves -AllowedPrefixes $AllowedPrefixes) { continue }
        if (-not $Before.ContainsKey($path)) {
            [void]$violations.Add("added $path")
        }
    }
    return $violations.ToArray()
}

function Get-ContractFallbackFindings {
    <# Configured fallback providers. A silent model fallback is forbidden. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Leaves)

    $findings = New-Object System.Collections.ArrayList
    foreach ($path in @($Leaves.Keys)) {
        if ($path -notmatch '(?i)fallback') { continue }
        $value = $Leaves[$path]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (@('[]', '{}', 'null', 'none', 'false', '~') -contains $value) { continue }
        [void]$findings.Add($path)
    }
    return $findings.ToArray()
}


# --------------------------------------------------------------------------
# User environment abstraction
# --------------------------------------------------------------------------

function Get-ContractUserEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    if ($script:ContractEnvironmentStore) {
        if (Test-Path -LiteralPath $script:ContractEnvironmentStore -PathType Leaf) {
            $store = Get-Content -LiteralPath $script:ContractEnvironmentStore -Raw | ConvertFrom-Json
            if ($store -and $store.PSObject.Properties[$Name]) {
                $entry = $store.$Name
                return [pscustomobject]@{ IsSet = [bool]$entry.set; Value = $entry.value }
            }
        }
        return [pscustomobject]@{ IsSet = $false; Value = $null }
    }

    $value = [Environment]::GetEnvironmentVariable($Name, 'User')
    return [pscustomobject]@{ IsSet = ($null -ne $value); Value = $value }
}

function Set-ContractUserEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ($script:ContractEnvironmentStore) {
        $store = $null
        if (Test-Path -LiteralPath $script:ContractEnvironmentStore -PathType Leaf) {
            $store = Get-Content -LiteralPath $script:ContractEnvironmentStore -Raw | ConvertFrom-Json
        }
        if (-not $store) { $store = [pscustomobject]@{} }
        $entry = [pscustomobject]@{ set = ($null -ne $Value); value = $Value }
        $store | Add-Member -NotePropertyName $Name -NotePropertyValue $entry -Force
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:ContractEnvironmentStore, (($store | ConvertTo-Json -Depth 6) + "`n"), $encoding)
    }
    else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}


# --------------------------------------------------------------------------
# Read-only reasoning-seam preflight
# --------------------------------------------------------------------------

function Get-ContractReportValue {
    <# Read one property from a parsed report, or fail categorically. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the seam report is missing a required field.'
    }
    return $Object.$Name
}

function Invoke-ContractSeamVerification {
    <#
        Run the read-only seam verifier. It performs no inference and no
        mutation. Its report is categorical, so the summary below carries no
        path, prompt, session identifier, or configuration value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $verifier = $script:ContractSeamVerifier
    if ([string]::IsNullOrWhiteSpace($verifier)) {
        $verifier = Join-Path $RepositoryRoot $script:SeamVerifierRelative
    }
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the read-only seam verifier was not found.'
    }
    if ([string]::IsNullOrWhiteSpace($script:ContractHermesSource)) {
        throw 'runtime contract: SEAM_UNAVAILABLE - no installed Hermes source root was supplied.'
    }
    $source = ConvertTo-ContractFullPath -Path $script:ContractHermesSource
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the installed Hermes source root does not exist.'
    }
    $router = Join-Path $RepositoryRoot $script:SeamRouterRelative
    $routingContract = Join-Path $RepositoryRoot $script:SeamRoutingContractRelative
    foreach ($required in @($router, $routingContract)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw 'runtime contract: SEAM_UNAVAILABLE - the routing seam source is incomplete.'
        }
    }

    $run = Invoke-ContractPython -Arguments @($verifier,
        '--hermes-source', $source,
        '--router', $router,
        '--routing-contract', $routingContract,
        '--prompt', $script:ProbePrompt)

    $lines = @((($run.StdOut -replace "`r", '') -split "`n") | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -ne 1) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the seam verifier did not print exactly one report line.'
    }
    try { $report = $lines[0] | ConvertFrom-Json }
    catch { throw 'runtime contract: SEAM_UNAVAILABLE - the seam report is not valid JSON.' }

    if ([string](Get-ContractReportValue -Object $report -Name 'kind') -cne $script:SeamKind) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the seam report is not a reasoning-seam report.'
    }
    if ([int](Get-ContractReportValue -Object $report -Name 'schemaVersion') -ne $script:SeamSchemaVersion) {
        throw 'runtime contract: SEAM_UNAVAILABLE - the seam report schema version is not supported.'
    }

    $dispatcher = Get-ContractReportValue -Object $report -Name 'dispatcher'
    $payload = Get-ContractReportValue -Object $report -Name 'payload'
    $routing = Get-ContractReportValue -Object $report -Name 'routing'
    $summary = 'dispatcher {0}; payload {1}; routing {2}/{3} matched {4}' -f `
        [string](Get-ContractReportValue -Object $dispatcher -Name 'clauses'),
    [string](Get-ContractReportValue -Object $payload -Name 'checks'),
    [string](Get-ContractReportValue -Object $routing -Name 'decision'),
    [string](Get-ContractReportValue -Object $routing -Name 'trigger'),
    [int](Get-ContractReportValue -Object $routing -Name 'matched')

    $result = [string](Get-ContractReportValue -Object $report -Name 'result')
    if ($run.ExitCode -eq 2 -or $result -ceq 'UNAVAILABLE') {
        throw ('runtime contract: SEAM_UNAVAILABLE - the read-only reasoning seam could not be measured ({0}). This is not a pass.' -f $summary)
    }
    if ($run.ExitCode -ne 0 -or $result -cne 'PASS') {
        throw ('runtime contract: SEAM_FAILED - the read-only reasoning seam did not pass; activation is blocked ({0}).' -f $summary)
    }
    if ([string](Get-ContractReportValue -Object $dispatcher -Name 'clauses') -cne '8/8' -or
        [string](Get-ContractReportValue -Object $payload -Name 'checks') -cne '4/4' -or
        [string](Get-ContractReportValue -Object $routing -Name 'status') -cne 'PASS') {
        throw ('runtime contract: SEAM_FAILED - the read-only reasoning seam did not pass; activation is blocked ({0}).' -f $summary)
    }
    if ([int](Get-ContractReportValue -Object $report -Name 'externalInference') -ne 0 -or
        [int](Get-ContractReportValue -Object $report -Name 'liveMutation') -ne 0) {
        throw 'runtime contract: SEAM_FAILED - the seam verifier reported an external inference call or a live mutation; that is a hard defect, not an acceptable result.'
    }

    return [pscustomobject]@{ Status = 'PASS'; Summary = $summary }
}


# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

function Invoke-ContractPreflight {
    <#
        Read-only. Validates the source, the Vault target, the contract section
        status, provider readiness, and the current contract keys. Writes
        nothing and executes no inference.
    #>
    [CmdletBinding()]
    param()

    $repositoryReal = ConvertTo-ContractFullPath -Path $script:ContractRepositoryRoot
    if (-not (Test-Path -LiteralPath $repositoryReal -PathType Container)) {
        throw 'runtime contract: the repository root does not exist.'
    }

    $manifestFile = $script:ContractManifestPath
    if ([string]::IsNullOrWhiteSpace($manifestFile)) {
        $manifestFile = Join-Path $repositoryReal 'manifest\harness-manifest.json'
    }
    if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
        throw "runtime contract: manifest not found at '$manifestFile'."
    }

    $validator = Join-Path $repositoryReal 'scripts\validate-harness.py'
    if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
        throw 'runtime contract: the source validator was not found.'
    }
    $validation = Invoke-ContractPython -Arguments @($validator, '--root', $repositoryReal)
    if ($validation.ExitCode -ne 0) {
        throw 'runtime contract: the source validator failed; the source is not applyable.'
    }

    $manifest = Test-HarnessManifest -Path $manifestFile
    $plan = New-HarnessInstallPlan -Manifest $manifest -RepositoryRoot $repositoryReal `
        -HermesHome $script:ContractHermesHome -ClaudeHome $script:ContractClaudeHome -CodexHome $script:ContractCodexHome
    foreach ($action in $plan) {
        $actual = Get-ContractFileSha256 -Path $action.SourcePath
        if ($actual -ne $action.ExpectedSha256) {
            throw "runtime contract: source hash mismatch for '$($action.Source)'."
        }
    }

    $vaultReal = ConvertTo-ContractFullPath -Path $script:ContractVaultRoot
    if (-not (Test-Path -LiteralPath $vaultReal -PathType Container)) {
        throw 'runtime contract: VAULT_UNAVAILABLE - the Vault root directory does not exist.'
    }
    $indexPath = Join-Path $vaultReal $script:VaultIndexRelative
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw 'runtime contract: VAULT_UNAVAILABLE - the Vault index file does not exist.'
    }

    $patcher = Join-Path $repositoryReal 'scripts\patch-vault-routing-contract.py'
    $contract = Join-Path $repositoryReal 'contracts\vault-query-routing-contract.md'
    foreach ($required in @($patcher, $contract)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw 'runtime contract: the routing-contract source is incomplete.'
        }
    }
    $check = Invoke-ContractPython -Arguments @($patcher, '--index', $indexPath, '--contract', $contract, '--check')
    if ($check.ExitCode -eq 0) { $sectionStatus = 'in sync' }
    elseif ($check.ExitCode -eq 1) { $sectionStatus = 'absent or stale' }
    else { throw 'runtime contract: the routing-contract patcher refused the Vault index.' }

    # `hermes auth status` requires the provider positional; without it the CLI
    # exits on a usage error before reporting anything.
    $auth = Invoke-ContractHermes -Arguments @('auth', 'status', $script:ProbeProvider)
    if ($auth.ExitCode -ne 0) {
        throw "runtime contract: the $($script:ProbeProvider) auth status check failed; no apply is possible."
    }
    if ($auth.StdOut -notmatch [regex]::Escape($script:ProbeProvider)) {
        throw "runtime contract: the auth status output does not name $($script:ProbeProvider)."
    }

    $configPath = Join-Path (ConvertTo-ContractFullPath -Path $script:ContractHermesHome) $script:ConfigRelative
    $leaves = Get-ContractConfigLeaves -Path $configPath
    $fallbacks = @(Get-ContractFallbackFindings -Leaves $leaves)
    if ($fallbacks.Count -gt 0) {
        throw ('runtime contract: a fallback provider is configured at ' + ($fallbacks -join ', ') + '; silent fallback is forbidden.')
    }

    # The read-only seam runs after the cheap checks and before any plan is
    # built, so a broken dispatcher blocks activation while nothing is staged.
    $seam = Invoke-ContractSeamVerification -RepositoryRoot $repositoryReal

    $keyReport = @()
    foreach ($entry in $script:ModelContract) {
        $current = if ($leaves.ContainsKey($entry.Key)) { $leaves[$entry.Key] } else { $null }
        $keyReport += [pscustomobject]@{
            Key            = $entry.Key
            Target         = $entry.Value
            ChangeRequired = ($current -cne $entry.Value)
        }
    }

    $enabledLeaves = @()
    foreach ($path in @($leaves.Keys)) {
        if ($path.StartsWith('plugins.enabled', [StringComparison]::Ordinal)) { $enabledLeaves += $leaves[$path] }
    }
    $pluginEnabled = ($enabledLeaves -contains $script:PluginName)

    return [pscustomobject]@{
        RepositoryRoot = $repositoryReal
        ManifestPath   = $manifestFile
        Manifest       = $manifest
        Plan           = $plan
        VaultRoot      = $vaultReal
        VaultIndex     = $indexPath
        Patcher        = $patcher
        Contract       = $contract
        SectionStatus  = $sectionStatus
        ConfigPath     = $configPath
        ConfigLeaves   = $leaves
        KeyReport      = $keyReport
        PluginEnabled  = $pluginEnabled
        Seam           = $seam
    }
}


# --------------------------------------------------------------------------
# Snapshot
# --------------------------------------------------------------------------

function New-ContractSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Preflight,
        [Parameter(Mandatory = $true)][string]$BackupDirectory
    )

    New-ContractDirectory -Path $BackupDirectory
    Protect-ContractDirectory -Path $BackupDirectory

    $managed = @()
    foreach ($action in $Preflight.Plan) {
        $existed = Test-Path -LiteralPath $action.TargetPath -PathType Leaf
        $sha256 = $null
        if ($existed) {
            $backupPath = Join-Path (Join-Path (Join-Path $BackupDirectory 'files') $action.TargetRoot) ($action.Destination -replace '/', '\')
            New-ContractDirectory -Path (Split-Path -Parent $backupPath)
            Copy-Item -LiteralPath $action.TargetPath -Destination $backupPath -Force
            $sha256 = Get-ContractFileSha256 -Path $backupPath
        }
        $managed += [pscustomobject]@{
            targetRoot  = $action.TargetRoot
            destination = $action.Destination
            existed     = $existed
            sha256      = $sha256
        }
    }

    $configBackup = Join-Path (Join-Path $BackupDirectory 'config') $script:ConfigRelative
    New-ContractDirectory -Path (Split-Path -Parent $configBackup)
    Copy-Item -LiteralPath $Preflight.ConfigPath -Destination $configBackup -Force

    $indexBackup = Join-Path (Join-Path $BackupDirectory 'vault') $script:VaultIndexRelative
    New-ContractDirectory -Path (Split-Path -Parent $indexBackup)
    Copy-Item -LiteralPath $Preflight.VaultIndex -Destination $indexBackup -Force

    $environment = Get-ContractUserEnvironment -Name $script:VaultVariableName

    # The prior value of each approved key, in the approved order, so a failed
    # model stage can be proved restored rather than merely overwritten.
    $modelKeys = @()
    foreach ($entry in $script:ModelContract) {
        $existed = $Preflight.ConfigLeaves.ContainsKey($entry.Key)
        $modelKeys += [pscustomobject]@{
            key     = $entry.Key
            existed = $existed
            value   = if ($existed) { [string]$Preflight.ConfigLeaves[$entry.Key] } else { '' }
        }
    }

    $state = [pscustomobject]@{
        schemaVersion = 2
        kind          = 'hongs-runtime-contract-snapshot'
        timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        roots         = [pscustomobject]@{
            hermesHome = ConvertTo-ContractFullPath -Path $script:ContractHermesHome
            claudeHome = ConvertTo-ContractFullPath -Path $script:ContractClaudeHome
            codexHome  = ConvertTo-ContractFullPath -Path $script:ContractCodexHome
            vaultRoot  = $Preflight.VaultRoot
        }
        environment   = [pscustomobject]@{
            name   = $script:VaultVariableName
            wasSet = [bool]$environment.IsSet
            value  = $environment.Value
        }
        config        = [pscustomobject]@{
            relative = $script:ConfigRelative
            existed  = $true
            sha256   = (Get-ContractFileSha256 -Path $configBackup)
        }
        vaultIndex    = [pscustomobject]@{
            relative = ($script:VaultIndexRelative -replace '\\', '/')
            existed  = $true
            sha256   = (Get-ContractFileSha256 -Path $indexBackup)
        }
        managed       = $managed
        modelKeys     = $modelKeys
    }

    $statePath = Join-Path $BackupDirectory 'state.json'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($statePath, (($state | ConvertTo-Json -Depth 8) + "`n"), $encoding)
    return $statePath
}


# --------------------------------------------------------------------------
# Model contract proof
# --------------------------------------------------------------------------
#
# The installed `sessions` row carries both `model` and `model_config`, inserted
# together and preserved together, so the session's model and its reasoning
# config are read from one row of one table. The billing provider is read from
# that same session's `session_model_usage` row. Both statements bind the one
# session identifier parsed from the proof's stderr, so all three facts are
# correlated to one session and none is inferred from a different session, a
# different table, or the response text.

$script:SessionProofReader = @'
"""Correlate one session read-only. Prints one compact JSON object, or one
categorical token and exit 3. It never prints the session identifier, a path,
or any other database value."""
import json
import sqlite3
import sys
import urllib.parse

REQUIRED = (
    ("sessions", ("id", "model", "model_config")),
    ("session_model_usage", ("session_id", "billing_provider")),
)


def fail(token):
    sys.stdout.write(token + "\n")
    raise SystemExit(3)


absolute = sys.argv[1]
session = sys.argv[2]
uri = "file:" + urllib.parse.quote(absolute.replace("\\", "/"), safe="/:") + "?mode=ro"
try:
    connection = sqlite3.connect(uri, uri=True)
except sqlite3.Error:
    fail("STATE_UNAVAILABLE")

try:
    for table, columns in REQUIRED:
        try:
            present = {row[1] for row in connection.execute("PRAGMA table_info(%s)" % table)}
        except sqlite3.Error:
            fail("STATE_UNAVAILABLE")
        for name in columns:
            if name not in present:
                fail("STATE_UNAVAILABLE")
    try:
        row = connection.execute(
            "SELECT model, model_config FROM sessions WHERE id = ?", (session,)
        ).fetchone()
        usage = connection.execute(
            "SELECT billing_provider FROM session_model_usage WHERE session_id = ?",
            (session,),
        ).fetchone()
    except sqlite3.Error:
        fail("STATE_UNAVAILABLE")
finally:
    connection.close()

if row is None or usage is None:
    fail("SESSION_NOT_CORRELATED")

enabled = False
effort = ""
if isinstance(row[1], str):
    try:
        parsed = json.loads(row[1])
    except ValueError:
        parsed = {}
    reasoning = parsed.get("reasoning_config") if isinstance(parsed, dict) else None
    if isinstance(reasoning, dict):
        enabled = bool(reasoning.get("enabled"))
        effort = reasoning.get("effort") or ""

sys.stdout.write(
    json.dumps(
        {
            "enabled": enabled,
            "effort": effort,
            "model": row[0] or "",
            "billingProvider": usage[0] or "",
        },
        separators=(",", ":"),
    )
    + "\n"
)
'@

function Test-ContractModelProof {
    <#
        The approved post-apply proof. One fresh process, exactly
        `hermes chat --cli -Q -q <contract prompt>`, no model, provider,
        reasoning, or usage-file override. The session identifier is parsed from
        stderr, used only to correlate the state read, and never printed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$BackupDirectory)

    $proof = Invoke-ContractHermes -Arguments ($script:ProofArguments + @($script:ProbePrompt))
    if ($proof.ExitCode -ne 0) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the post-apply proof did not complete.'
    }
    $answer = ($proof.StdOut -replace "`r", '').Trim()
    if ($answer -cne $script:ProbeExpectedAnswer) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the post-apply proof answer did not match the contract.'
    }

    $match = [regex]::Match(($proof.StdErr -replace "`r", ''), '(?m)^\s*session_id:\s*(?<id>\S+)\s*$')
    if (-not $match.Success) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the post-apply proof emitted no parseable session identifier.'
    }
    $session = $match.Groups['id'].Value

    $database = $script:ContractStateDatabase
    if ([string]::IsNullOrWhiteSpace($database)) {
        $database = Join-Path (ConvertTo-ContractFullPath -Path $script:ContractHermesHome) 'state.db'
    }
    if (-not (Test-Path -LiteralPath $database -PathType Leaf)) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the runtime state database was not found.'
    }

    $toolsDirectory = Join-Path $BackupDirectory '.tools'
    New-ContractDirectory -Path $toolsDirectory
    $readerPath = Join-Path $toolsDirectory 'read-session-proof.py'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($readerPath, $script:SessionProofReader, $encoding)
    try { $read = Invoke-ContractPython -Arguments @($readerPath, $database, $session) }
    finally { Remove-Item -LiteralPath $toolsDirectory -Recurse -Force -Confirm:$false }

    $stdout = ($read.StdOut -replace "`r", '').Trim()
    if ($read.ExitCode -ne 0) {
        throw ('MODEL_CONTRACT_UNAVAILABLE: the correlated state read failed ({0}).' -f $stdout)
    }
    try { $evidence = $stdout | ConvertFrom-Json }
    catch { throw 'MODEL_CONTRACT_UNAVAILABLE: the correlated state read produced no readable evidence.' }

    if (-not [bool](Get-ContractReportValue -Object $evidence -Name 'enabled')) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the proof session did not record an enabled reasoning config.'
    }
    if ([string](Get-ContractReportValue -Object $evidence -Name 'effort') -cne $script:ProofEffort) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the proof session did not run at the contract reasoning effort.'
    }
    if ([string](Get-ContractReportValue -Object $evidence -Name 'model') -cne $script:ProofModel) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the correlated session reports a different model.'
    }
    if ([string](Get-ContractReportValue -Object $evidence -Name 'billingProvider') -cne $script:ProofBillingProvider) {
        throw 'MODEL_CONTRACT_UNAVAILABLE: the correlated session reports a different billing provider.'
    }
}


# --------------------------------------------------------------------------
# Transaction
# --------------------------------------------------------------------------

function Assert-ContractStage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Stage)

    if ($script:ContractFailAfterStage -and $script:ContractFailAfterStage -eq $Stage) {
        throw "runtime contract: induced failure after the $Stage stage."
    }
}

function Invoke-ContractModelStage {
    <# Stage one: exactly the three approved keys, in the approved order. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Preflight)

    foreach ($entry in $script:ModelContract) {
        $set = Invoke-ContractHermes -Arguments @('config', 'set', $entry.Key, $entry.Value)
        if ($set.ExitCode -ne 0) {
            throw "runtime contract: '$($entry.Key)' could not be set."
        }
        Assert-ContractStage -Stage $entry.Stage
    }

    $after = Get-ContractConfigLeaves -Path $Preflight.ConfigPath
    $violations = @(Get-ContractConfigViolations -Before $Preflight.ConfigLeaves -After $after `
            -AllowedLeaves $script:ModelStageAllowedLeaves -AllowedPrefixes @())
    if ($violations.Count -gt 0) {
        throw ('runtime contract: the model stage changed something outside the three approved keys: ' + ($violations -join ', ') + '.')
    }
    foreach ($entry in $script:ModelContract) {
        if (-not $after.ContainsKey($entry.Key) -or $after[$entry.Key] -cne $entry.Value) {
            throw "runtime contract: '$($entry.Key)' does not hold the contract value."
        }
    }
    Assert-ContractStage -Stage 'ModelStageDiff'
}

function Restore-ContractModelStage {
    <#
        The exact three-key restore. The snapshot's byte-exact configuration is
        the only write, so the managed files, the Vault index, the environment
        variable, and the plugin state are not touched at all. The restore is
        then proved against the pre-apply leaves and the recorded prior values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$Preflight
    )

    Copy-Item -LiteralPath $Plan.ConfigSource -Destination $Plan.ConfigTarget -Force
    if ((Get-ContractFileSha256 -Path $Plan.ConfigTarget) -ne $Plan.ConfigSha256) {
        throw 'runtime contract: the restored configuration does not match the snapshot hash.'
    }

    $after = Get-ContractConfigLeaves -Path $Preflight.ConfigPath
    foreach ($path in @($Preflight.ConfigLeaves.Keys)) {
        if (-not $after.ContainsKey($path) -or $after[$path] -cne $Preflight.ConfigLeaves[$path]) {
            throw 'runtime contract: the model-stage restore did not reproduce the pre-apply configuration.'
        }
    }
    foreach ($path in @($after.Keys)) {
        if (-not $Preflight.ConfigLeaves.ContainsKey($path)) {
            throw 'runtime contract: the model-stage restore left an unapproved configuration key behind.'
        }
    }
    foreach ($record in $Plan.ModelKeys) {
        $present = $after.ContainsKey($record.Key)
        if ($record.Existed) {
            if (-not $present -or $after[$record.Key] -cne $record.Value) {
                throw 'runtime contract: the model-stage restore did not reproduce a recorded prior key value.'
            }
        }
        elseif ($present) {
            throw 'runtime contract: the model-stage restore left a key that did not exist before the apply.'
        }
    }
}

function Invoke-ContractTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Preflight)

    # 2. Managed files, through the existing installer.
    [void](Invoke-HarnessApply -Manifest $Preflight.Manifest -RepositoryRoot $Preflight.RepositoryRoot `
            -HermesHome $script:ContractHermesHome -ClaudeHome $script:ContractClaudeHome -CodexHome $script:ContractCodexHome)
    Assert-ContractStage -Stage 'Installer'

    # 3. Exactly the marked Vault contract section.
    $patch = Invoke-ContractPython -Arguments @($Preflight.Patcher, '--index', $Preflight.VaultIndex,
        '--contract', $Preflight.Contract, '--apply')
    if ($patch.ExitCode -ne 0) {
        throw 'runtime contract: the routing-contract section could not be applied.'
    }
    Assert-ContractStage -Stage 'VaultSection'

    # 4. The machine-local Vault environment variable.
    Set-ContractUserEnvironment -Name $script:VaultVariableName -Value $Preflight.VaultRoot
    Assert-ContractStage -Stage 'Environment'

    # 5. Plugin enablement without tool override.
    $enable = Invoke-ContractHermes -Arguments @('plugins', 'enable', $script:PluginName, '--no-allow-tool-override')
    if ($enable.ExitCode -ne 0) {
        throw 'runtime contract: the plugin could not be enabled.'
    }
    Assert-ContractStage -Stage 'PluginEnable'

    # 6. Only the approved leaves may differ. The three model keys were applied
    #    and proved before this transaction began.
    $after = Get-ContractConfigLeaves -Path $Preflight.ConfigPath
    $violations = @(Get-ContractConfigViolations -Before $Preflight.ConfigLeaves -After $after `
            -AllowedLeaves $script:AllowedConfigLeaves -AllowedPrefixes $script:AllowedConfigPrefixes)
    if ($violations.Count -gt 0) {
        throw ('runtime contract: unapproved configuration change: ' + ($violations -join ', ') + '.')
    }
    foreach ($entry in $script:ModelContract) {
        if (-not $after.ContainsKey($entry.Key) -or $after[$entry.Key] -cne $entry.Value) {
            throw "runtime contract: '$($entry.Key)' does not hold the contract value."
        }
    }
    $overridePath = 'plugins.entries.' + $script:PluginName + '.allow_tool_override'
    if (-not $after.ContainsKey($overridePath) -or $after[$overridePath] -cne 'false') {
        throw 'runtime contract: the plugin does not have allow_tool_override disabled.'
    }
    $enabledValues = @()
    $disabledValues = @()
    foreach ($path in @($after.Keys)) {
        if ($path.StartsWith('plugins.enabled', [StringComparison]::Ordinal)) { $enabledValues += $after[$path] }
        if ($path.StartsWith('plugins.disabled', [StringComparison]::Ordinal)) { $disabledValues += $after[$path] }
    }
    if ($enabledValues -notcontains $script:PluginName) {
        throw 'runtime contract: the plugin is not enabled after the transaction.'
    }
    if ($disabledValues -contains $script:PluginName) {
        throw 'runtime contract: the plugin is still listed as disabled.'
    }
    Assert-ContractStage -Stage 'ConfigDiff'

    # 7. Managed hashes and the exact Vault section.
    $verification = Test-HarnessInstall -Manifest $Preflight.Manifest -RepositoryRoot $Preflight.RepositoryRoot `
        -HermesHome $script:ContractHermesHome -ClaudeHome $script:ContractClaudeHome -CodexHome $script:ContractCodexHome
    if (-not $verification.Ok) {
        throw 'runtime contract: the managed files do not match the manifest after the transaction.'
    }
    $sectionCheck = Invoke-ContractPython -Arguments @($Preflight.Patcher, '--index', $Preflight.VaultIndex,
        '--contract', $Preflight.Contract, '--check')
    if ($sectionCheck.ExitCode -ne 0) {
        throw 'runtime contract: the Vault routing-contract section is not exact after the transaction.'
    }
    Assert-ContractStage -Stage 'Verify'

    return $verification.Checked
}


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

if ($script:ContractDryRun -and $script:ContractApply) {
    Write-Error 'Specify exactly one of -DryRun or -Apply.' -ErrorAction Continue
    exit 2
}
if (-not $script:ContractDryRun -and -not $script:ContractApply) {
    Write-Error 'Specify exactly one of -DryRun or -Apply.' -ErrorAction Continue
    exit 2
}

Import-Module (Join-Path $PSScriptRoot 'HarnessInstaller.psm1') -Force
. (Join-Path $PSScriptRoot 'rollback-runtime-contract.ps1') -LoadOnly

try {
    if ($script:ContractApply -and -not $script:ContractConfirmed) {
        throw 'runtime contract: -Apply mutates live runtime state and requires -ConfirmLiveRuntimeMutation.'
    }

    $preflight = Invoke-ContractPreflight

    if ($script:ContractDryRun) {
        Write-Output 'DRY RUN - no file, configuration, environment variable, plugin state, or inference request was made.'
        Write-Output 'Manifest: verified current'
        foreach ($action in $preflight.Plan) {
            Write-Output ('{0,-7} {1,-10} {2} {3}' -f $action.Action, $action.TargetRoot, $action.Destination, $action.ExpectedSha256)
        }
        Write-Output ('Managed actions: {0} (create {1}, replace {2})' -f `
                @($preflight.Plan).Count, `
            @($preflight.Plan | Where-Object { $_.Action -eq 'Create' }).Count, `
            @($preflight.Plan | Where-Object { $_.Action -eq 'Replace' }).Count)
        Write-Output ('Vault index: present; routing-contract section {0} (path and content redacted)' -f $preflight.SectionStatus)
        Write-Output ('Auth: {0} ready' -f $script:ProbeProvider)
        Write-Output ('{0}: will be set to the supplied Vault root (value redacted)' -f $script:VaultVariableName)
        Write-Output ('Plugin {0}: currently enabled={1}; allow_tool_override will be false' -f $script:PluginName, $preflight.PluginEnabled)
        foreach ($entry in $preflight.KeyReport) {
            Write-Output ('Model key {0} -> {1} (change required: {2}; current value redacted)' -f `
                    $entry.Key, $entry.Target, $entry.ChangeRequired)
        }
        Write-Output ('Reasoning seam: PASS ({0})' -f $preflight.Seam.Summary)
        Write-Output 'Proof (not executed): hermes chat --cli -Q -q <contract prompt>; no model, provider, reasoning, or usage-file override'
        Write-Output 'Order (not executed): snapshot -> verified snapshot -> model.default -> model.provider -> agent.reasoning_effort -> proof -> installer -> Vault section -> HONG_VAULT_ROOT -> plugin -> verification'
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($script:ContractBackupTimestamp)) {
        $script:ContractBackupTimestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    }
    $backupDirectory = Join-Path (Join-Path (ConvertTo-ContractFullPath -Path $script:ContractHermesHome) $script:BackupSegment) $script:ContractBackupTimestamp

    # (a) Snapshot the exact prior state before anything else.
    [void](New-ContractSnapshot -Preflight $preflight -BackupDirectory $backupDirectory)
    Assert-ContractStage -Stage 'Snapshot'

    # (b) Prove the snapshot is restorable before entering the rollback boundary.
    #     Pure validation: it writes nothing, so a snapshot that cannot be
    #     restored stops the run while the mutation count is still zero.
    $snapshotPlan = Get-RuntimeContractSnapshotPlan -BackupDirectory $backupDirectory `
        -HermesHomePath $script:ContractHermesHome -ClaudeHomePath $script:ContractClaudeHome `
        -CodexHomePath $script:ContractCodexHome -VaultRootPath $script:ContractVaultRoot
    Assert-ContractStage -Stage 'SnapshotVerified'

    # (c)-(e) Three keys first, then the fresh override-free proof.
    try {
        Invoke-ContractModelStage -Preflight $preflight
        Test-ContractModelProof -BackupDirectory $backupDirectory
        Assert-ContractStage -Stage 'Proof'
    }
    catch {
        $failure = $_.Exception.Message
        Write-Output ('Backup retained: {0}' -f $backupDirectory)
        try { Restore-ContractModelStage -Plan $snapshotPlan -Preflight $preflight }
        catch {
            Write-Error ('{0} MODEL_CONTRACT_UNAVAILABLE: the three-key restore was incomplete: {1} Backup: {2}' -f `
                    $failure, $_.Exception.Message, $backupDirectory) -ErrorAction Continue
            exit 1
        }
        Write-Error ('{0} MODEL_CONTRACT_UNAVAILABLE: the three model keys were restored and no managed file, Vault section, environment variable, or plugin state was mutated. Backup: {1}' -f `
                $failure, $backupDirectory) -ErrorAction Continue
        exit 1
    }

    # (f)-(g) Only after the proof: the remaining mutations and gates.
    try {
        $checked = Invoke-ContractTransaction -Preflight $preflight
    }
    catch {
        $failure = $_.Exception.Message
        # An unwrapped line, so an operator and a test can read the exact path.
        Write-Output ('Backup retained: {0}' -f $backupDirectory)
        try {
            [void](Invoke-RuntimeContractRollback -BackupDirectory $backupDirectory `
                    -HermesHomePath $script:ContractHermesHome -ClaudeHomePath $script:ContractClaudeHome `
                    -CodexHomePath $script:ContractCodexHome -VaultRootPath $script:ContractVaultRoot `
                    -EnvironmentStorePath $script:ContractEnvironmentStore)
        }
        catch {
            Write-Error ('{0} Rollback was incomplete: {1} Backup: {2}' -f $failure, $_.Exception.Message, $backupDirectory) -ErrorAction Continue
            exit 1
        }
        Write-Error ('{0} The transaction was rolled back. Backup: {1}' -f $failure, $backupDirectory) -ErrorAction Continue
        exit 1
    }

    Write-Output ('APPLIED the runtime contract: {0} managed file(s), one Vault contract section, {1}, plugin {2}, and {3} model key(s).' -f `
            $checked, $script:VaultVariableName, $script:PluginName, $script:ModelContract.Count)
    Write-Output ('Backup: {0}' -f $backupDirectory)
    exit 0
}
catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
}
