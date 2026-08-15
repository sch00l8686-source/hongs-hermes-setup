# Live Runtime Verification Instruments

Use this reference when a reviewed configuration activation succeeds but the official live verification runner reports contradictory failures.

## Evidence hierarchy

1. Verify the **actual production caller** named by the approved runtime contract. Do not substitute a convenience or legacy entry point merely because the runner already uses it.
2. Bind runtime identity to the same launched session. Parse a bounded session handle in memory and correlate model, provider, and reasoning from authoritative state for that session.
3. Treat response text, a database row from another session, and uncorrelated usage artifacts as supporting evidence only.
4. Persist categorical verdicts, not prompts, model responses, credential values, session identifiers, or machine paths.

## Distinguish runtime failure from instrument failure

When the official runner fails after activation:

1. Reproduce each failed clause once through the approved production caller without changing runtime state.
2. Require the expected behavioral verdict and same-session runtime identity.
3. If the production caller passes while the runner's alternate caller or fixture fails, classify the defect as instrumentation, not runtime.
4. Do **not** rollback a healthy runtime solely because its measuring tool is broken. Rollback is for runtime mutation failure or failed rollback preconditions.
5. The default acceptance path is to correct the official runner and require its fresh canonical pass. Do **not** silently promote an ad-hoc reproduction into a pass.
6. The user may instead apply the residual-risk lever when all of these are explicit: the official result remains **unmeasured** because the observer/wrapper failed before measurement; source and independent evidence are healthy; there is no runtime-defect evidence; and the missing live result is not a prerequisite of the next user-visible deliverable. Record `UNMEASURED — USER-ACCEPTED RESIDUAL RISK`, the exact evidence deficit, and the user's decision. Never rewrite it as a pass. Independent closure evidence may continue, but the risk acceptance does not authorize unrelated retries or weaken future gates.

This preserves both safety directions: a broken instrument cannot undo healthy state, informal evidence cannot silently replace the acceptance contract, and a non-critical measurement gap cannot grow into indefinite meta-work after the user explicitly accepts it.

## Production-caller migration pattern

If source inspection proves that a shortcut caller drops an approved model/provider/reasoning setting before request construction:

- replace the runner caller with the approved production caller exactly;
- preserve each behavior probe's prompt and expected verdict;
- use the frozen identity prompt only for the identity probe;
- remove identity logic that depends on response assertions or a shortcut-only usage file;
- add a RED test that rejects the obsolete caller and a GREEN test for exact argument order plus same-session correlation.

Do not encode a permanent claim that any CLI mode is always broken. Re-check installed source and the production seam; this procedure is triggered by measured caller divergence.

## Credential-free failure fixtures

A custom application home can accidentally change the credential root and make a failure-direction probe test authentication instead of the intended behavior. When the application supports root/profile inheritance:

1. Create UUID-isolated disposable fixtures under the real application root's `profiles/` directory.
2. Let the profile use the application's documented read-only root credential fallback.
3. Never copy `auth.json`, tokens, `.env`, cookies, or provider state into the fixture.
4. Change only the intended failure condition, such as telemetry write denial or plugin disablement.
5. Delete the complete profile in `finally`; test UUID isolation, root containment, and cleanup on success and failure.

## Fresh environment evidence on Windows

A user-scoped environment update does not retroactively change a long-lived parent process. A probe launched by an already-running desktop agent can therefore inherit an empty or stale `$env:NAME` even though activation successfully wrote the User-scope value.

- For post-activation verification, query the authoritative scope in the fresh child: `[Environment]::GetEnvironmentVariable('NAME', 'User')`.
- Validate only presence/resolution unless the value itself is approved evidence; do not print a path or secret merely to prove it exists.
- Keep process-scope and User-scope evidence distinct in reports. An unset inherited process value is not proof that User-scope activation failed.
- Tests should exercise the stale-parent case so a future runner does not regress to `$env:NAME` as its only source.

## Citation probes

A citation acceptance test should tighten the question, not weaken the reducer:

- name the unique index-linked page that contains the answer;
- ask the runtime to read that page;
- keep exact page-name matching;
- never accept a generic answer or a different citation merely because the semantic answer is plausible.

## Minimum decisive gate

For a bounded instrument correction, keep verification proportional:

1. one focused RED/GREEN cycle for the broken measurement;
2. one enclosing source gate if source bytes changed;
3. one fresh official live-runner pass by default, or one explicitly recorded `UNMEASURED — USER-ACCEPTED RESIDUAL RISK` decision under the criteria above.

Additional seams, rollback proofs, or policy expansions require a distinct risk or goal clause; do not add them by habit. An observer/wrapper correction must itself execute the exact preamble against a non-live stub before it is allowed to spend another expensive or one-shot live measurement.
