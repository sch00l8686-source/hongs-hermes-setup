<#
    Canonical Pester entry point for the harness installer suite.

    Run it exactly like this:

        powershell.exe -NoProfile -NonInteractive -Command "$ProgressPreference='SilentlyContinue'; Invoke-Pester .\tests\Test-HarnessInstaller.ps1 -EnableExit"

    This file defines no test of its own. It dot-sources the single suite in
    tests/pester/ so the Describe blocks are declared once, in this container,
    and executed once. It deliberately does not call Invoke-Pester itself and is
    deliberately not named *.Tests.ps1: a directory-wide Invoke-Pester discovers
    only tests/pester/HarnessInstaller.Tests.ps1, so neither entry path can run
    the suite twice or recurse into Pester.

    All disposable-home safety lives in the suite it loads: one GUID temp root,
    explicitly disposable Hermes/Claude/Codex homes, no live home, credential
    store, or runtime database read or written.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

. (Join-Path $PSScriptRoot 'pester\HarnessInstaller.Tests.ps1')
