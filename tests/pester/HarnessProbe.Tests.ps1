<#
    Behavioural tests for the read-only harness behaviour probe runner.

    These tests never launch a real Hermes, Claude, or Codex session. The probe
    script is parsed, and only its function definitions are dot-sourced, so the
    live apply gate, the API-key gate, and the probe loop at the bottom of the
    file are never executed. The invocation seam itself is exercised for real
    against a disposable child script that records the argument vector it was
    given, inside one GUID temp root.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

# $PSScriptRoot stays correct when this file is dot-sourced from the canonical
# entry point tests/Test-HarnessProbe.ps1; $MyInvocation is the 5.1 fallback.
$script:TestsDirectory = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:RepositoryRoot = (Resolve-Path (Join-Path $script:TestsDirectory '..\..')).ProviderPath
$script:ProbeScriptPath = Join-Path $script:RepositoryRoot 'scripts\run-harness-probes.ps1'

. (Join-Path $script:TestsDirectory 'HarnessTestHelpers.ps1')

function Get-ProbeScriptAst {
    <# Parse the probe script once. Parsing executes nothing. #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:ProbeAst) {
        $tokens = $null
        $errors = $null
        $script:ProbeAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ProbeScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors -and @($errors).Count -gt 0) {
            throw "HarnessProbe.Tests: '$script:ProbeScriptPath' failed to parse."
        }
    }
    return $script:ProbeAst
}

function Get-ProbeFunctionDefinition {
    <#
        Return one function of the probe script as a script block, taken
        verbatim from the production file. Dot-sourcing the result defines the
        real function without running the script's gates or probe loop.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $ast = Get-ProbeScriptAst
    $found = @($ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($node.Name -eq $Name)
            }, $false))
    if ($found.Count -ne 1) {
        throw "HarnessProbe.Tests: expected exactly one definition of '$Name', found $($found.Count)."
    }
    return [scriptblock]::Create($found[0].Extent.Text)
}

function Get-ProbeScriptParameterDefault {
    <# Read a script parameter's literal default straight from the source. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $ast = Get-ProbeScriptAst
    $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name })
    if ($parameter.Count -ne 1) {
        throw "HarnessProbe.Tests: script parameter '$Name' not found."
    }
    return $parameter[0].DefaultValue.Value
}

function Get-ArgumentIndex {
    <# First index of a literal argument, or -1. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Value
    )

    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        if ($ArgumentList[$i] -ceq $Value) { return $i }
    }
    return -1
}

$script:ProbeSuiteRoot = New-HarnessSuiteRoot


Describe 'Invoke-ProbeProcess argument binding' {

    . (Get-ProbeFunctionDefinition -Name 'Invoke-ProbeProcess')

    $case = Join-Path $script:ProbeSuiteRoot 'invoke-probe-process'
    $childTemp = Join-Path $case 'child-temp'
    [void](New-Item -ItemType Directory -Path $case -Force)
    [void](New-Item -ItemType Directory -Path $childTemp -Force)

    $capturePath = Join-Path $case 'received-args.json'
    $childScript = Join-Path $case 'capture-args.ps1'
    Set-HarnessFileText -Path $childScript -Text (
        "[Environment]::GetCommandLineArgs() | ConvertTo-Json |" +
        " Set-Content -LiteralPath '$capturePath' -Encoding utf8`n")

    It 'accepts an argument list that carries an empty element' {
        # Claude disables its whole tool set with an empty --tools value, so the
        # seam must bind the empty element instead of rejecting it before launch.
        $arguments = @('-NoProfile', '-NonInteractive', '-File', $childScript, '--tools', '', '--max-turns', '1')
        $run = Invoke-ProbeProcess -FilePath 'powershell.exe' -ArgumentList $arguments `
            -WorkingDirectory $case -TempDirectory $childTemp -TimeoutSeconds 120
        $run.Status | Should Be 'ran'
        $run.ExitCode | Should Be 0
    }

    It 'preserves the empty value in the argument vector the child receives' {
        # The cast is deliberate: ConvertFrom-Json emits the array as one object
        # on Windows PowerShell 5.1, so @() alone would not flatten it.
        $received = [string[]]((Get-Content -LiteralPath $capturePath -Raw) | ConvertFrom-Json)
        $index = Get-ArgumentIndex -ArgumentList $received -Value '--tools'
        $index | Should Not Be -1
        # An element really sits between --tools and --max-turns, and it is empty.
        $received[$index + 2] | Should Be '--max-turns'
        $received[$index + 1].Length | Should Be 0
    }
}


Describe 'New-ProbeArgumentList' {

    . (Get-ProbeFunctionDefinition -Name 'New-ProbeArgumentList')

    $prompt = 'probe prompt'

    It 'keeps the Claude route on an empty tool set, one turn, JSON, no session' {
        $arguments = @(New-ProbeArgumentList -Harness 'Claude' -Prompt $prompt)

        $tools = Get-ArgumentIndex -ArgumentList $arguments -Value '--tools'
        $tools | Should Not Be -1
        $arguments[$tools + 1].Length | Should Be 0

        $turns = Get-ArgumentIndex -ArgumentList $arguments -Value '--max-turns'
        $turns | Should Not Be -1
        $arguments[$turns + 1] | Should Be '1'

        $format = Get-ArgumentIndex -ArgumentList $arguments -Value '--output-format'
        $format | Should Not Be -1
        $arguments[$format + 1] | Should Be 'json'

        (Get-ArgumentIndex -ArgumentList $arguments -Value '--no-session-persistence') | Should Not Be -1
        (Get-ArgumentIndex -ArgumentList $arguments -Value $prompt) | Should Not Be -1
    }

    It 'keeps the Codex route read-only and ephemeral' {
        $arguments = @(New-ProbeArgumentList -Harness 'Codex' -Prompt $prompt)
        $arguments[0] | Should Be 'exec'

        $sandbox = Get-ArgumentIndex -ArgumentList $arguments -Value '--sandbox'
        $sandbox | Should Not Be -1
        $arguments[$sandbox + 1] | Should Be 'read-only'

        (Get-ArgumentIndex -ArgumentList $arguments -Value '--ephemeral') | Should Not Be -1
    }

    It 'lets the Codex route run from the non-Git probe working directory' {
        # The runner works in a disposable TEMP directory that is not a Git
        # repository, and Codex refuses to start there unless the check is
        # skipped. The flag only waives the repository requirement: the
        # read-only sandbox, the ephemeral session, and the stdin prompt form
        # all stay exactly as they were.
        $arguments = @(New-ProbeArgumentList -Harness 'Codex' -Prompt $prompt)
        (Get-ArgumentIndex -ArgumentList $arguments -Value '--skip-git-repo-check') | Should Not Be -1

        $arguments[0] | Should Be 'exec'
        $sandbox = Get-ArgumentIndex -ArgumentList $arguments -Value '--sandbox'
        $sandbox | Should Not Be -1
        $arguments[$sandbox + 1] | Should Be 'read-only'
        (Get-ArgumentIndex -ArgumentList $arguments -Value '--ephemeral') | Should Not Be -1
        $arguments[$arguments.Count - 1] | Should Be '-'
    }

    It 'reads the Codex prompt from standard input instead of the command line' {
        # Codex takes a prompt on stdin when the positional argument is '-'. A
        # multi-line prompt passed on the command line reaches the model in a
        # form it does not answer, so the prompt must not appear in the vector.
        $arguments = @(New-ProbeArgumentList -Harness 'Codex' -Prompt $prompt)
        $arguments[$arguments.Count - 1] | Should Be '-'
        (Get-ArgumentIndex -ArgumentList $arguments -Value $prompt) | Should Be -1
    }

    It 'keeps the Hermes route on the one-shot interface' {
        $HermesArgumentTemplate = Get-ProbeScriptParameterDefault -Name 'HermesArgumentTemplate'
        $arguments = @(New-ProbeArgumentList -Harness 'Hermes' -Prompt $prompt)
        (Get-ArgumentIndex -ArgumentList $arguments -Value '--oneshot') | Should Not Be -1
        (Get-ArgumentIndex -ArgumentList $arguments -Value $prompt) | Should Not Be -1
    }

    It 'refuses an unknown harness' {
        { New-ProbeArgumentList -Harness 'Vault' -Prompt $prompt } | Should Throw
    }
}


Describe 'Probe launcher resolution' {

    . (Get-ProbeFunctionDefinition -Name 'Resolve-ProbeCommand')

    # A synthetic npm-on-Windows layout. The real npm path of this machine is
    # never consulted, so the test states the rule rather than the local install.
    $case = Join-Path $script:ProbeSuiteRoot 'launcher-resolution'
    $npmStyle = Join-Path $case 'npm-style'
    $shimOnly = Join-Path $case 'shim-only'
    foreach ($directory in @($case, $npmStyle, $shimOnly)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    # npm lays down three siblings: a POSIX shell script with no extension, a
    # PowerShell shim, and the only file a no-shell ProcessStartInfo can start.
    Set-HarnessFileText -Path (Join-Path $npmStyle 'codex') -Text "#!/bin/sh`nexit 0`n"
    Set-HarnessFileText -Path (Join-Path $npmStyle 'codex.ps1') -Text "exit 0`n"
    Set-HarnessFileText -Path (Join-Path $npmStyle 'codex.cmd') -Text "@echo off`r`nexit /b 0`r`n"
    Set-HarnessFileText -Path (Join-Path $shimOnly 'codex') -Text "#!/bin/sh`nexit 0`n"
    Set-HarnessFileText -Path (Join-Path $shimOnly 'codex.ps1') -Text "exit 0`n"

    It 'chooses the directly launchable .cmd over the bare shim and the .ps1' {
        $originalPath = $env:PATH
        try {
            $env:PATH = $npmStyle
            $resolved = Resolve-ProbeCommand -Name 'codex'
        }
        finally { $env:PATH = $originalPath }
        $resolved | Should Be (Join-Path $npmStyle 'codex.cmd')
    }

    It 'reports no launcher when nothing on PATH is directly executable' {
        $originalPath = $env:PATH
        try {
            $env:PATH = $shimOnly
            $resolved = Resolve-ProbeCommand -Name 'codex'
        }
        finally { $env:PATH = $originalPath }
        $resolved | Should BeNullOrEmpty
    }

    It 'preserves an explicit caller-provided launcher path' {
        $explicit = Join-Path $npmStyle 'codex.cmd'
        Resolve-ProbeCommand -Name $explicit | Should Be $explicit
    }

    It 'refuses an explicit .ps1 path that no shell-free start can launch' {
        # The file exists, so existence alone must not qualify it: a .ps1 needs an
        # interpreter, and UseShellExecute=$false would fail to start it.
        $explicit = Join-Path $npmStyle 'codex.ps1'
        Resolve-ProbeCommand -Name $explicit | Should BeNullOrEmpty
    }

    It 'refuses an explicit extensionless shell script path' {
        # The npm POSIX shim: an existing leaf with no Windows launchable
        # extension is categorically unavailable, never a fallback launcher.
        $explicit = Join-Path $npmStyle 'codex'
        Resolve-ProbeCommand -Name $explicit | Should BeNullOrEmpty
    }
}


Describe 'Probe standard input routing' {

    . (Get-ProbeFunctionDefinition -Name 'Get-ProbeStandardInput')

    $prompt = "first line`nsecond line`n`nVERDICT: FULL_GATE`n"

    It 'hands the Codex prompt to standard input unchanged' {
        $text = Get-ProbeStandardInput -Harness 'Codex' -Prompt $prompt
        ($text -ceq $prompt) | Should Be $true
    }

    It 'leaves Claude on its argument path with no standard input' {
        Get-ProbeStandardInput -Harness 'Claude' -Prompt $prompt | Should BeNullOrEmpty
    }

    It 'leaves Hermes on its argument path with no standard input' {
        Get-ProbeStandardInput -Harness 'Hermes' -Prompt $prompt | Should BeNullOrEmpty
    }
}


Describe 'Invoke-ProbeProcess standard input' {

    . (Get-ProbeFunctionDefinition -Name 'Invoke-ProbeProcess')

    $case = Join-Path $script:ProbeSuiteRoot 'invoke-probe-stdin'
    $childTemp = Join-Path $case 'child-temp'
    [void](New-Item -ItemType Directory -Path $case -Force)
    [void](New-Item -ItemType Directory -Path $childTemp -Force)

    # A disposable .cmd, the same shape of launcher the Codex route resolves to.
    # It records its standard input verbatim, so the assertion is on the bytes
    # the child really received, not on the seam's own bookkeeping.
    $capturePath = Join-Path $case 'stdin-capture.txt'
    $captureCmd = Join-Path $case 'capture-stdin.cmd'
    Set-HarnessFileText -Path $captureCmd -Text (
        "@echo off`r`n" +
        "powershell -NoProfile -NonInteractive -Command " +
        "`"[System.IO.File]::WriteAllText((Join-Path (Get-Location).Path 'stdin-capture.txt')," +
        " [Console]::In.ReadToEnd())`"`r`n")

    $silentCmd = Join-Path $case 'no-stdin.cmd'
    Set-HarnessFileText -Path $silentCmd -Text "@echo off`r`nexit /b 0`r`n"

    $multiline = "first line`nsecond line`n`nVERDICT: FULL_GATE`n"

    It 'starts the child, writes the text, and closes the stream' {
        # Without the close the child blocks on ReadToEnd and the probe times out.
        $run = Invoke-ProbeProcess -FilePath $captureCmd `
            -ArgumentList @('exec', '--sandbox', 'read-only', '--ephemeral', '-') `
            -WorkingDirectory $case -TempDirectory $childTemp `
            -StandardInput $multiline -TimeoutSeconds 120
        $run.Status | Should Be 'ran'
        $run.ExitCode | Should Be 0
    }

    It 'delivers the prompt to the child with every line break intact' {
        $captured = [System.IO.File]::ReadAllText($capturePath)
        ($captured -ceq $multiline) | Should Be $true
        ([regex]::Matches($captured, "`n")).Count | Should Be 4
        ($captured.Contains("`n`n")) | Should Be $true
    }

    It 'runs a route that supplies no standard input without redirecting it' {
        $run = Invoke-ProbeProcess -FilePath $silentCmd -ArgumentList @('--oneshot', 'probe prompt') `
            -WorkingDirectory $case -TempDirectory $childTemp -TimeoutSeconds 120
        $run.Status | Should Be 'ran'
        $run.ExitCode | Should Be 0
    }
}


Describe 'Probe output reduction and gates' {

    . (Get-ProbeFunctionDefinition -Name 'Get-ProbeVerdict')

    $tokens = @('FULL_GATE', 'ONE_LINE_EXCEPTION')

    It 'collapses free-form model text to a bounded token' {
        Get-ProbeVerdict -Text 'here is a long explanation with secrets in it' -Tokens $tokens |
            Should Be 'UNPARSED'
    }

    It 'collapses an out-of-set declared verdict to a bounded token' {
        Get-ProbeVerdict -Text "VERDICT: SOMETHING_ELSE" -Tokens $tokens | Should Be 'UNPARSED'
    }

    It 'reports absent output rather than storing it' {
        Get-ProbeVerdict -Text '' -Tokens $tokens | Should Be 'NO_OUTPUT'
    }

    It 'keeps the API-key gate in the probe script' {
        $text = [System.IO.File]::ReadAllText($script:ProbeScriptPath)
        $text.Contains('ANTHROPIC_API_KEY') | Should Be $true
    }

    It 'keeps the live-apply confirmation gate in the probe script' {
        $text = [System.IO.File]::ReadAllText($script:ProbeScriptPath)
        $text.Contains('ConfirmLiveApplyComplete') | Should Be $true
    }
}
