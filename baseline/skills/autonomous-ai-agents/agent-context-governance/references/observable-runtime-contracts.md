# Observable Runtime-Contract Patterns

Use these patterns when a global agent contract routes optional knowledge, depends on model entitlement, or introduces a one-time activation exception.

## Make silent routing failures observable

A router that emits context only on a match makes two states indistinguishable: a valid no-match and a dead router. Emit exactly one small heartbeat on every turn:

```text
ROUTING_CHECKED decision=skipped|entered|unavailable trigger=<code>
```

Interpret an absent marker as router unavailability, never as a valid skip. Keep the marker ephemeral so the stable system-prompt cache remains unchanged. Test normal skip, match, dependency unavailable, plugin disabled, and plugin crash in fresh processes.

Separate failure directions:

- knowledge readiness or evidence integrity: fail closed when the requested judgment requires that knowledge;
- optional audit persistence: fail open so disk, lock, or rotation failure cannot hold the main task hostage.

## Bound audit data without losing tuning value

Do not store raw prompts merely to tune a router. A useful minimal record contains decision, trigger code, up to two public matched aliases, session/time, and a keyed digest. Prefer:

```text
HMAC-SHA256(machine-local persistent random key, normalized question)
```

The key stays outside managed/shared roots. Same-machine repeats remain correlatable while hashes do not line up across machines. Key creation/read failure skips telemetry but not the heartbeat or answer. Bound logs by fixed-size rotation and test concurrent append as valid JSONL.

## Match language morphology, not English assumptions

Do not transplant symmetric English word boundaries into Korean alias matching. Korean particles and endings attach within the same eojeol, so symmetric boundaries silently miss normal questions.

- English: require boundaries on both sides.
- Korean: require a left token boundary and leave the right side open for particles/endings.
- Document and test intentional low-cost prefix false positives when they protect against high-cost silent false negatives.

Example regression contract:

```text
positive: 빔을, 폭발이, 나이아가라로, 셰이더는
negative: 새벽빔, moonbeam
intentional accepted prefixes: 빔프로젝터, 폭발물
```

Use audit evidence to narrow only the noisy alias or domain group, not the whole matcher.

## Close bootstrap-policy cycles explicitly

If a new runtime contract requires a setting that the contract itself must authorize, do not falsely stamp the first spec as conforming and do not apply the setting before approval. Define a one-time bootstrap stamp that records:

- actual runtime used;
- exact missing contract condition;
- artifacts allowed to use the exception;
- explicit expiry event;
- prohibition on reuse after expiry;
- mandatory fresh conforming-session revalidation before completion.

A degraded model state may produce only an interruption record or handoff. It must not finish or approve a material specification, plan, worker contract, Goal Fidelity decision, or integration judgment.

## Verification checklist

- Every routed turn emits exactly one heartbeat.
- Missing heartbeat differs from valid skip.
- Dependency/readiness failures are classified separately from telemetry failures.
- Matcher tests include particles/endings and intentional accepted prefix cases.
- Audit records exclude prompt text, paths, secrets, and arbitrary metadata.
- One-time exceptions state deficit, scope, expiry, non-reuse, and revalidation.
- Fresh-process behavior probes verify the actual runtime caller, not only parser/unit behavior.
