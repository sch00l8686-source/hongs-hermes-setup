<#
    Canonical Pester entry point for the harness behaviour probe suite.

    Run it exactly like this:

        powershell.exe -NoProfile -NonInteractive -Command "$ProgressPreference='SilentlyContinue'; Invoke-Pester .\tests\Test-HarnessProbe.ps1 -EnableExit"

    This file defines no test of its own. It dot-sources the single suite in
    tests/pester/ so the Describe blocks are declared once, in this container,
    and executed once. It deliberately does not call Invoke-Pester itself and is
    deliberately not named *.Tests.ps1, mirroring tests/Test-HarnessInstaller.ps1.

    No test here starts a real Hermes, Claude, or Codex session: the probe
    script is parsed, its functions are dot-sourced, and the process seam is
    exercised against a disposable child script under the system temp directory.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

. (Join-Path $PSScriptRoot 'pester\HarnessProbe.Tests.ps1')
