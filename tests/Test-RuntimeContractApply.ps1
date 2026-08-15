<#
    Canonical Pester entry point for the runtime-contract apply and rollback
    suite.

    Run it exactly like this:

        powershell.exe -NoProfile -NonInteractive -Command "$ProgressPreference='SilentlyContinue'; Invoke-Pester .\tests\Test-RuntimeContractApply.ps1 -EnableExit"

    This file defines no test of its own. It dot-sources the single suite in
    tests/pester/ so the Describe blocks are declared once, in this container,
    and executed once. It deliberately does not call Invoke-Pester itself and is
    deliberately not named *.Tests.ps1, so neither entry path can run the suite
    twice or recurse into Pester.

    All disposable-state safety lives in the suite it loads: one GUID temp root,
    an explicitly disposable Hermes/Claude/Codex home, a disposable Vault root,
    a fake Hermes CLI, a disposable user-environment store, and a disposable
    state database. No live home, live config, live environment variable,
    credential store, or live runtime database is read or written.

    Windows PowerShell 5.1 / Pester 3.4 compatible.
#>

. (Join-Path $PSScriptRoot 'pester\RuntimeContractApply.Tests.ps1')
