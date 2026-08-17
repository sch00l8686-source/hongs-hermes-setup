# hongs-hermes-setup

Canonical, version-controlled source for the global agent harness: the Hermes
`SOUL.md` constitution, the global Claude and Codex instruction files, and the
managed skill set that carries the design, planning, and execution policy — the
twenty approved skill packages plus the preserved `software-development/plan`
adapter, twenty-one packages in total.

Design of record: [`docs/specs/global-agent-harness-design.md`](docs/specs/global-agent-harness-design.md).
Provenance rules: [`docs/provenance.md`](docs/provenance.md).
Version: [`VERSION.md`](VERSION.md) — 0.1.0.

## Source and runtime are different things

| | Source | Runtime |
| --- | --- | --- |
| Location | this repository, under `baseline/` | `HermesHome`, `ClaudeHome`, `CodexHome` |
| Role | authored, reviewed, version-controlled | applied, disposable, reconstructible |
| Edited by | a reviewed change here | the installer only |

Every intentional policy change is made **here first**. The live roots are the
destination of an install step, never an authoring location. Editing a live file
directly creates drift that has no review history and is silently reverted the
next time the baseline is applied. If a live file has drifted, the fix is to
reconcile the change back into `baseline/` under review.

The installer copies only the managed files the manifest declares. Unowned files
inside the destination roots — local settings, local-only skills, anything else
the user put there — are preserved untouched and are never enumerated.

## Line endings are part of the contract

`.gitattributes` pins `baseline/**` and `manifest/*.json` to `text eol=lf`. The
manifest identifies managed files by SHA-256, which is byte-sensitive, so a
checkout that rewrote LF to CRLF — the `core.autocrlf=true` default on Windows —
would invalidate all 46 recorded hashes. The pin makes the checkout, the Git
blob, and the manifest byte-identical on Windows, macOS, and Linux.

## No remote, no publish

Nothing in this repository publishes anything. Nothing here pushes to a
remote, creates a GitHub repository, uploads to Supabase, publishes a site, or
sends anything externally. The validator, the manifest builder, the installer,
and the verifier make no network call. The probe script is the only component
that launches another process, and it launches locally installed agent CLIs in
read-only mode.

The public-snapshot tooling below is local-only for the same reason: it builds a
disposable snapshot in a directory outside this repository, scans that copy, and
renders the download page in-process. It creates no repository, configures no
remote, deploys nothing, and opens no network connection. Publication remains a
separate, explicitly approved external gate.

## The public snapshot

```text
python scripts/build-public-snapshot.py --root <repo> --staging <empty dir outside the repo>
python scripts/verify-public-snapshot.py --staging <that same dir>
node scripts/test-download-function.mjs
```

The builder stages the tracked tree plus the untracked files the managed
allowlist and the approved-extras list already name, minus `docs/status/**` and
`docs/superpowers/**`. The staged skill set is the twenty approved packages plus
the preserved `software-development/plan` adapter, twenty-one in total. It then
creates a fresh staging repository: branch `main`, exactly one commit, no
configured remote, and a staging-local `noreply` author identity that is written
into the staging repository only.

Machine-local literals survive in three in-scope files — `docs/provenance.md`,
`docs/specs/global-agent-harness-design.md`, and
`provenance/upstream-lock.json`. They are rewritten to a portable placeholder
**in the staged copy only**; the canonical files keep their exact bytes. The
substitution is an allowlist, not a sweep: the staged tree is rescanned
afterwards and the build fails closed if any machine-local path remains outside
the classified synthetic test fixtures.

`verify-public-snapshot.py` proves the snapshot categorically. It reports counts
and classifications — never a matched value, never a secret, never a
machine-local path, never the author address — across the commit shape, the
identity, the package set, the exclusions, machine-local paths, forbidden files,
and credential-shaped assignments.

The download site is `Supabase 302 no-store -> GitHub Pages -> static
index.html`. The Edge Function hosts no HTML: it answers with a fixed 302 to the
Pages URL, a `Cache-Control: no-store` header, and no body, and
`supabase/config.toml` declares it `verify_jwt = false`, so it is a public
endpoint. GitHub Pages serves the repository-root `index.html` from the `main`
branch of the public repository.

`test-download-function.mjs` proves both halves locally. It reads `index.html`
from disk and checks its accessible static markup, the absence of client-side
JavaScript and external assets, and exactly the two approved links; it then runs
the function source in a Node `vm` context that supplies a `Deno.serve` stub
alongside the standard Web constructors and deliberately omits `fetch`, so the
real handler is invoked and its real response is checked for status
302, that exact `Location`, an empty body, and `no-store`. No port is opened and
`fetch` is deliberately absent from that context.

Those four artifacts — `index.html`, `supabase/config.toml`,
`supabase/functions/download/index.ts`, and `scripts/test-download-function.mjs`
— are required. The builder refuses to finish without them and the verifier
fails without them, each from its own list: the verifier imports nothing from
the builder, so relaxing a builder allowlist does not relax the proof.

Publication order of record: the canonical repository is the source; a fresh
snapshot is built and verified from it; its content is carried into the existing
public clone as a forward commit rather than a history rewrite; and the push and
any deploy remain a separate, explicitly approved gate. Nothing in this
repository automates that carry.

## One-command install on a fresh PC

`bootstrap/setup.ps1` wraps the installer below and resolves every path itself:
the repository root from the extracted ZIP or clone it sits in (downloading the
current `main.zip` from GitHub only when run outside one), and the three
destination homes from `%LOCALAPPDATA%\hermes`, `%USERPROFILE%\.claude`, and
`%USERPROFILE%\.codex`. It shows the dry-run plan and asks for one confirmation
before applying; every path can still be overridden with a parameter. It is the
one script here that may make a network call, and only to fetch that archive.

```text
powershell -ExecutionPolicy Bypass -File bootstrap\setup.ps1
```

## The apply gate

A dry run is free. An apply is a user-approved gate.

```text
python scripts/validate-harness.py --root <repo>
python scripts/build-harness-manifest.py --root <repo> --output manifest/harness-manifest.json
powershell -File bootstrap/install-harness.ps1 -DryRun  -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path>
powershell -File bootstrap/install-harness.ps1 -Apply   -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path>
powershell -File bootstrap/verify-harness.ps1           -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path>
powershell -File scripts/run-harness-probes.ps1 -RepositoryRoot <repo> -ConfirmLiveApplyComplete
```

`-DryRun` validates the manifest, resolves every destination, and prints the
managed actions. It copies nothing, backs up nothing, changes no configuration,
and makes no network, git, or agent-CLI call.

`-Apply` writes to the destination roots. Applying to a live home is a user
decision, not a routine step inside an approved plan.

`run-harness-probes.ps1` refuses to run without `-ConfirmLiveApplyComplete`,
because a probe against an unapplied runtime measures the old harness.

## Backup and rollback

`Invoke-HarnessApply` runs in this order:

1. Validate the manifest and build the action plan. No write.
2. Hash every source in place and compare it to the manifest. A single mismatch
   aborts **before any write**.
3. Stage every source under `HermesHome\backups\hongs-global-harness\<UTC>\.staging`
   and re-hash the staged copies.
4. Back up every existing managed target under
   `HermesHome\backups\hongs-global-harness\<UTC>\files\<TargetRoot>\<destination>`.
5. Copy managed files only, from the staged copy.
6. Verify the SHA-256 of every written destination.

Any failure from step 3 onward restores every backed-up file, deletes every file
this apply created, and removes only the directories this apply created. The
staging directory is always cleaned up; the timestamped backup directory is
deliberately retained as evidence.

Destinations are restricted before any write: only `SOUL.md`, the twenty-one
managed `skills/**` trees, `CLAUDE.md`, and `AGENTS.md`. Traversal, absolute,
UNC, device-namespace, alternate-data-stream, duplicate, and reparse-traversing
destinations are rejected, and the identity of a destination root that is itself
a junction is preserved rather than replaced.

## The runtime contract gate

The harness installer moves managed files. The runtime contract additionally
activates the Phase 2 runtime, and it is a separate, explicitly confirmed gate.
It covers exactly five things and nothing else:

| Part | Target |
| --- | --- |
| managed files | whatever `manifest/harness-manifest.json` declares |
| Vault index | the one marked `hongs-vault-routing-contract` section |
| environment | the user variable `HONG_VAULT_ROOT` |
| plugin | `hongs-vault-router` enabled with `allow_tool_override=false` |
| model keys | `model.default`, `model.provider`, `agent.reasoning_effort` |

```text
python scripts/validate-harness.py --root <repo>
powershell -File bootstrap/apply-runtime-contract.ps1 -DryRun -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path> -VaultRoot <vault>
powershell -File bootstrap/apply-runtime-contract.ps1 -Apply -ConfirmLiveRuntimeMutation -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path> -VaultRoot <vault>
powershell -File bootstrap/verify-harness.ps1 -RepositoryRoot <repo> -HermesHome <path> -ClaudeHome <path> -CodexHome <path>
powershell -File bootstrap/rollback-runtime-contract.ps1 -BackupRoot <hermes>\backups\hongs-runtime-contract\<UTC> -HermesHome <path> -ClaudeHome <path> -CodexHome <path> -VaultRoot <vault>
```

Every path above is a fixed local path. Nothing in this gate pushes, publishes,
uploads, or sends anything externally, and nothing reads a credential file.

`-DryRun` runs the read-only preflight only: source validation, manifest and
source hashes, Vault root and index presence, the routing-contract `--check`
status, the `hermes auth status openai-codex` check, the absence of configured
fallback providers, and the current state of the three model keys and of the
plugin. It then prints the planned actions and their hashes. It writes no file,
no backup, no configuration, and no environment variable, and it runs no
inference. Its output names actions, keys, and hashes — never a configuration
value, an environment value, a credential, or Vault content.

`-Apply` is refused without `-ConfirmLiveRuntimeMutation`. Approving a plan
authorises running the source checks and the dry run; it does not authorise
`-Apply`. That remains a separate user decision.

An `-Apply` run does this and only this, in this order:

1. Snapshot the exact prior state under
   `$HermesHome\backups\hongs-runtime-contract\<UTC>\`: the managed targets,
   `config.yaml`, `wiki/index.md`, the previous `HONG_VAULT_ROOT` set/unset
   state, the previous values of the three model keys in their approved order,
   and SHA-256 evidence, in a directory restricted to the current user. The
   snapshot is schema version 2. It is machine-local: never printed, never
   committed.
2. Prove that snapshot restorable before entering the rollback boundary. This
   step is pure validation and writes nothing, so an unrestorable snapshot stops
   the run while the mutation count is still zero.
3. `hermes config set model.default gpt-5.6-sol`.
4. `hermes config set model.provider openai-codex`.
5. `hermes config set agent.reasoning_effort high`.
6. Compare the parsed configuration against the pre-apply reading and refuse the
   run if anything outside those three leaves changed.
7. Prove the runtime in one fresh process with exactly
   `hermes chat --cli -Q -q '<contract prompt>'`. No `--model`, `--provider`,
   `--reasoning`, or `--usage-file` override is passed, and the superseded
   `-z`/`--oneshot` caller is not used: that branch drops `--reasoning` before
   the agent is constructed, so it cannot prove the effort key. The exit code and
   the exact answer must match, and the session identifier parsed from the
   proof's stderr is then bound to the correlated state read —
   `SELECT model, model_config FROM sessions WHERE id = ?` and
   `SELECT billing_provider FROM session_model_usage WHERE session_id = ?`. The
   model, the billing provider, and the enabled `reasoning_config.effort` must
   all match, all for that one session. Neither a usage file nor a request dump
   is accepted as correlation evidence. Any mismatch, any absent table or column,
   and any uncorrelated session reports `MODEL_CONTRACT_UNAVAILABLE`.
8. Apply the managed files through the existing installer.
9. Apply only the marked Vault contract section.
10. Set the user and process `HONG_VAULT_ROOT`.
11. `hermes plugins enable hongs-vault-router --no-allow-tool-override`.
12. Compare the parsed configuration before and after, permitting only the three
    model leaves, `plugins.enabled`, `plugins.disabled`, and
    `plugins.entries.hongs-vault-router.allow_tool_override=false`. Every
    unrelated key must remain semantically equal, including across a reformat.
13. Verify the managed hashes and the exact Vault section.

The three model keys are therefore the first mutation and the proof is the gate
that stands between them and everything else. Any failure up to and including
the proof restores exactly those three keys, leaves the managed files, the Vault
section, the environment variable, and the plugin state untouched, and reports
`MODEL_CONTRACT_UNAVAILABLE`. Any failure after the proof rolls the whole
transaction back to the snapshot. Both exit non-zero with the retained backup
path.

### Rollback acceptance requirements

Activation is accepted only when all seven of these hold. Each is reported
separately; none is merged into another, and a requirement without its own
evidence is a gap, not a pass.

1. **A verified snapshot precedes every mutation.** The schema version 2
   snapshot, including its ordered `modelKeys` record, is written and proved
   restorable before the first `config set` runs.
2. **Only the three approved keys change before the probe.** Exactly
   `model.default`, `model.provider`, `agent.reasoning_effort`, in that order,
   and nothing else — no managed file, no Vault section, no environment
   variable, no plugin state.
3. **The probe is the exact caller with correlated evidence.** Exactly
   `hermes chat --cli -Q -q '<contract prompt>'` with no override, and the model,
   the billing provider, and the enabled `high` effort all bound to the one
   session identifier the proof emitted.
4. **A probe failure restores exactly the three keys.** Later mutation stays at
   zero, the snapshot is retained, and the run reports
   `MODEL_CONTRACT_UNAVAILABLE`.
5. **Every later injected failure restores every approved target.** Each of the
   Installer, VaultSection, Environment, PluginEnable, ConfigDiff, and Verify
   stages is failed on its own and each restores the full snapshot.
6. **A fresh post-rollback read shows no partial activation.** The configuration
   and state are re-read from a brand new process, not from a value the applying
   session already held.
7. **The pre-gate live retry count stays at 0.** This one is supervisor process
   evidence, not a unit test: the supervisor records that no live `-Apply` was
   retried before the gate. A Pester case asserting a hard-coded retry count
   would measure the fixture rather than the live runtime and is deliberately
   not written. The adjacent facts that *can* be measured are tested instead —
   the proof runs exactly once per `-Apply`, and it is not retried after a
   failure.

Requirements 1 through 6 are proved by the named cases in
`tests/pester/RuntimeContractApply.Tests.ps1`, which run against disposable
fixtures. Disposable fixtures prove the script's behaviour; they do not prove
the installed runtime, which is why requirement 7 stays process evidence.

`rollback-runtime-contract.ps1` restores the same snapshot explicitly: the exact
previous managed targets — deleting the ones that were previously absent — the
byte-exact `config.yaml`, the byte-exact `wiki/index.md` including its dirty
user content, and the previous `HONG_VAULT_ROOT` value or its absence.
Restoring `config.yaml` restores the previous plugin enablement and the previous
three model values with it. Routing and cost logs are never deleted, running it
twice is a no-op the second time, and the snapshot is kept as evidence. A
snapshot with an unknown schema, different destination roots, an unsafe
destination, or a hash that no longer matches is refused before any write.

## Static validation

`scripts/validate-harness.py` is fail-closed: it exits non-zero on any finding
and prints only rule ids, paths, line numbers, and anchor identifiers — never
file content.

| Rule | Checks |
| --- | --- |
| E001 | the managed file set under `baseline/` is exactly the allowlist |
| E002 | every `SKILL.md` has `---` delimiters, a `name` matching its directory, and a non-empty `description` |
| E003 | no machine-local absolute path inside a portable skill |
| E010 | the exactly-one-line mechanical exception, including two-line and model-routing full-gate rules |
| E011 | the brainstorming gate |
| E012 | `writing-plans` as the single plan authority |
| E013 | the approved worker task contract |
| E014 | Goal Fidelity in `writing-plans`, `supervised-agent-workflow`, `subagent-coding-context`, `execution-continuity`, and `verification-before-completion` |
| E015 | the non-executing proposal duty |
| E016 | bounded parallelism: independence checklist, three-worker cap, worktree isolation |
| E017 | direct supervisor verification |
| E018 | review is exceptional and trigger-gated |
| E020 | no active default mandate for a two-stage review per task, a fresh reviewer per task, or a Sol review by default |
| E030 | the imported Claude and Codex graphify blocks survive byte-for-byte |
| E031 | the `plan` skill stays an adapter and does not duplicate the plan specification |
| E040 | `SOUL.md` carries the global harness rules |
| E041 | the global Claude `CLAUDE.md` carries the independent-session trigger |
| E042 | the global Codex `AGENTS.md` carries the independent-session trigger |

E030 reads the original graphify blocks from git revision `7b34b89` at runtime,
so the check never depends on any in-flight branch existing. A global trigger may
be added around a graphify block; it may never be edited inside it.

E040, E041, and E042 require the global instruction triggers. Until that work
lands they are the expected RED identifiers; every other rule passes.

## Tests

The complete Python policy suite below is a **canonical-source gate**. It
intentionally reads the private design-record tree and the original graphify
history anchor, so it is not self-contained in the one-commit public snapshot.
For the public snapshot, use `verify-public-snapshot.py`, the manifest `--check`,
the installer Pester suite, and `test-download-function.mjs`; those are the
supported public-artifact checks and do not require the excluded history.

```text
python -m unittest discover -s tests/python -t tests/python -v
Invoke-Pester -Script tests/pester/HarnessInstaller.Tests.ps1
Invoke-Pester -Script tests/pester/HarnessProbe.Tests.ps1
powershell.exe -NoProfile -NonInteractive -Command "$ProgressPreference='SilentlyContinue'; Invoke-Pester .\tests\Test-RuntimeContractApply.ps1 -EnableExit"
```

The Python suite is red-capable: each policy rule has a mutation test that
proves the validator actually fails when the rule is removed. The Pester suites
run entirely inside one GUID-named temp root with explicitly disposable
Hermes/Claude/Codex homes; they never read or write a live home, a credential
store, or a runtime database. The runtime-contract suite adds a disposable Vault
root, a fake Hermes CLI, a disposable user-environment store, and a disposable
state database, so the transaction, every failure stage, and the rollback are
exercised without touching live runtime state.

## Execution roles today

| Role | Runtime | Status |
| --- | --- | --- |
| Supervisor / integrator | Hermes root agent | active |
| Currently configured supervisor model | `openai-codex/gpt-5.6-sol`, `medium` effort | **current** |
| Target supervisor model | `openai-codex/gpt-5.6-sol`, `high` effort | target, applied only through the runtime contract gate |
| Implementation worker | Claude Code CLI `claude -p --model opus` | active |
| Codex Sol reviewer | same family as the current default | exceptional adjudication only |

Report the *currently configured* model when describing routing. The only
configured change between current and target is the reasoning effort, and it is
applied exclusively by `bootstrap/apply-runtime-contract.ps1 -Apply` after
explicit confirmation. Orchestration work must not change model configuration as
a side effect. Terra is not a target runtime here: it appears only as the
comparison baseline in the monthly cost record.

The implementation worker must reach Opus through the authenticated,
subscription-backed **first-party** Claude Code CLI route, with the canonical
model/provider probe passing before dispatch. Forbidden as substitutes: Hermes
native Anthropic delegation, an MoA Anthropic reference, automatic fallback to
an Anthropic API-key route, and enabling Extra Usage or any paid fallback. The
probe script enforces the API-key part of this directly: it refuses to run while
`ANTHROPIC_API_KEY` is set, and records a missing CLI as `UNAVAILABLE` rather
than falling back.

## Phase boundary

**In scope here (Phase 1).** Harness source, the managed skill fork, the concise
global rules, provenance metadata, static policy validation, the manifest, the
installer with its apply gate, disposable verification, and read-only behaviour
probes.

**Explicitly out of scope (Phase 2 or later).** GitHub repository creation or
push; Supabase schema, Storage, or Action secrets; deploying the download page;
Vault publication; live model or provider config mutation; Anthropic Extra Usage
activation; production deployment.

Phase 2 re-brainstorms and re-plans that work *using* the verified harness. The
earlier globalisation drafts are reference material, not an approved contract
that bypasses the new gates.
