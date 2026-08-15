# Goal Fidelity and User Gates

Use this reference when an approved plan is executed by workers or when repository history contains tempting adjacent routes.

## Authority order

Resolve conflicts in this order:

1. Current direct user goal.
2. Current user-approved spec.
3. Verified runtime and production caller.
4. Current approved implementation plan.
5. Project instructions.
6. Historical handoffs, plans, branches, and worktree names.
7. Dormant, deprecated, or merely present repository code.

Lower-ranked material can explain implementation, but cannot replace the goal.

## Plan packet

Every nontrivial plan should lock:

```text
Authoritative observable goal:
Authoritative runtime:
Runtime evidence:
Approved before/after behavior:
Explicit non-goals:
Forbidden substitutions:
Allowed paths:
Forbidden paths:
Goal clause served by each task:
```

Each worker brief should begin with the exact goal, runtime, and forbidden substitutions. A bounded worker executes the approved task; it does not brainstorm or choose a different product goal.

## Drift checks

Before integration, verify:

- changed paths stay in the allowlist;
- each material change is reachable from the verified production caller;
- each change serves an approved goal clause;
- no dormant platform, migration, historical plan, or adjacent framework was activated;
- cleanup or future-proofing did not replace the requested behavior.

Repository presence, apparent completeness, cleaner architecture, and platform-name similarity are not goal evidence.

## Rejection packet

Reject unauthorized drift before asking the user:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

Use the correction brief already written in the plan. Drift is plan noncompliance, not a new option to offer for approval.

## Genuine user gate

Ask the user only when a concrete decision remains outside the approved plan:

```text
Decision required:
Evidence:
Options:
Trade-offs:
Reversibility:
Recommended choice:
```

Valid gates include a new product/scope/architecture choice, credentials or permission grants, unapproved real-data effects, publication/deployment/external sends, irreversible effects, physical-only observations, or a requirements contradiction that no plan-compatible measurement can resolve.

Test failures, parser errors, worker timeouts, plan-compatible repairs, and rejected goal drift are not user gates.

Generic "the evidence is insufficient" is not a gate either. Name the measurement that would settle it — the artifact to inspect, the check to run, the caller to trace, the competing claims to reproduce — and run it inside the approved plan first. Escalate only if that measurement still leaves a user-owned decision, or if running it would itself cross one of the boundaries above.

## Proposal duty

A useful idea outside scope is neither hidden nor implemented. Report it separately:

```text
Non-executing proposal:
Why it matters:
Trade-offs:
Reversibility:
Smallest next step:
Implementation performed: no
```
