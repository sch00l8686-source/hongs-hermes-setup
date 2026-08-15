<#
    Canonical Pester entry point for the runtime contract probe suite.

    Run it exactly like this:

        powershell.exe -NoProfile -NonInteractive -Command "$ProgressPreference='SilentlyContinue'; Invoke-Pester .\tests\Test-RuntimeContractProbe.ps1 -EnableExit"

    This file defines no test of its own. It dot-sources the single suite in
    tests/pester/ so the Describe blocks are declared once, in this container,
    and executed once. It deliberately does not call Invoke-Pester itself and is
    deliberately not named *.Tests.ps1, mirroring tests/Test-HarnessProbe.ps1.

    No test here starts a real Hermes, Claude, or Codex session and none touches
    a live home, a live Vault, or the network: the runner is parsed, its
    functions are dot-sourced, and its end-to-end behaviour is exercised against
    a disposable fake launcher under the system temp directory.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

. (Join-Path $PSScriptRoot 'pester\RuntimeContractProbe.Tests.ps1')
