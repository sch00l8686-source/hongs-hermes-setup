# Local Runtime-Contract Activation

Use this reference when a reviewed baseline must add a plugin, a small policy section in an independently edited knowledge index, and a narrow set of machine-local runtime settings.

## Keep source verification and live activation separate

Plan and verify all source artifacts first. Source-plan approval authorizes repository implementation, tests, manifest generation, and disposable rollback proof; it does **not** authorize mutation of a live agent home, knowledge vault, environment variable, plugin enablement state, or model configuration.

After source verification, present one live-activation gate containing:

- integrated source revision and fresh test evidence;
- exact live destinations and setting leaves;
- dry-run actions and hashes;
- pre-activation runtime/readiness probe;
- backup root and tested rollback command;
- explicit confirmation that push, publish, release, credentials, and payment are excluded.

## Patch shared-but-dirty documents by owned section

When a target such as `wiki/index.md` may contain unrelated local edits, never distribute or overwrite the whole file.

1. Store the owned section as a versioned source artifact with unique start/end markers.
2. Build a check/apply patcher that rejects duplicate, nested, reversed, or unbalanced markers.
3. Preserve every byte outside the owned section, including BOM and line-ending style.
4. Test insertion, replacement, idempotence, and unrelated dirty text before and after the section.
5. Back up and hash the live file before activation; rollback restores the exact prior bytes.

## Resolve storage-path gaps in the implementation plan

A design may fix semantics while intentionally leaving the exact machine-local path open. The implementation plan should close that gap without reopening product design:

- choose the smallest profile-local path outside managed, shared, publication, and vault roots;
- name lock/key/log paths explicitly;
- define file schema, retention/rotation, concurrency, and failure direction;
- distinguish operational evidence from source of truth;
- keep values and generated files out of manifests and Git.

For monthly cost observation, prefer an explicit read-only collector over a new daemon or cron job unless automation was approved. Separate token buckets, API-equivalent estimates, virtual model premium, actual provider billing, and Extra Usage. Unknown billed amounts remain `unknown`/`null`; estimates never become cash claims.

When the runtime already stores canonical token buckets, inspect their semantics before writing a new formula. If uncached input, cache-read, and cache-write are disjoint, price each bucket exactly once; do not subtract cache tokens again or double-charge reasoning tokens already included in output accounting.

## Transaction boundary

A bounded live activator should snapshot and restore every state it owns:

- managed files;
- the exact marked external-document section or whole pre-change file bytes;
- the precise configuration leaves it changes;
- plugin enabled/disabled/permission state;
- environment variable set/unset/value state.

Probe model/auth/readiness with invocation-scoped overrides before persistent mutation. On probe failure, preserve existing settings and stop. During apply, permit only a compiled allowlist of semantic deltas; any extra config change triggers rollback.

An accepted CLI override is not proof that the effective request or persisted session used that override. Before making the probe a live gate:

1. identify an authoritative evidence surface that records the **effective session-scoped value**, not merely the global config or requested flag;
2. prove in a disposable fixture that the evidence distinguishes at least one known mismatch from the required value;
3. verify the actual installed CLI arity and option spelling, not only a fake launcher;
4. treat a missing, `null`, reset, or non-persisted field as `EVIDENCE_UNAVAILABLE` and stop before transaction;
5. never weaken the gate, infer success from model/provider alone, or retry Apply until the evidence path is redesigned and reverified.

For conditional approvals, report every requested precondition with exact file/value or `file:line` evidence **before** starting the approved side effect. An internal check that was not reported does not satisfy a user-declared reporting gate.

Telemetry logs are not source of truth and normally need not be deleted on rollback.

## Hash-baseline anomalies

When a before/after hash unexpectedly differs:

1. stop before mutation and capture a new baseline with at least two independent implementations;
2. repeat raw-byte reads and compare size and LastWriteUtc;
3. test only plausible representation transforms such as LF/CRLF and BOM without rewriting the files;
4. if the original value cannot be reproduced, close it explicitly as **not reproducible**, not with a guessed cause;
5. record the stable replacement baseline and require immediate stop/report if the symptom recurs.

A stable re-baseline can support a later dry-run only when the live activation state is independently still unchanged. Dry-run completion must be followed by the same hash/state capture to prove zero writes.

## Verification checklist

- Source full gate passes before the live decision.
- Dirty external files are byte-preserved outside the owned marked section.
- Model/readiness probe runs before persistent settings change.
- Only compiled configuration/plugin leaves change.
- Disposable injected failures restore all owned state.
- Fresh-process probes verify the active runtime caller after activation.
- External publication and credential/payment effects remain separately gated.
