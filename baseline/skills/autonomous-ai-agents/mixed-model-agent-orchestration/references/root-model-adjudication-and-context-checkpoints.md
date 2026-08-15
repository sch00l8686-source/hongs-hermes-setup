# Root-model adjudication and context checkpoints

## Preserve explicit roles

If the user assigns models by role, do not silently reverse them. The active project convention is:

- Hermes is the root supervisor, direct verifier, and final evidence-based integrator.
- Claude CLI Opus 5, invoked as `claude -p --model opus` over the subscription-backed first-party route, is the plan-scoped implementer.
- No reviewer is assigned by default. A separate reviewer session exists only for a recorded Exceptional Review trigger, and it is fresh for that one review.
- When a review does run, the reviewer never receives the implementer's external structured report.

## Hermes model policy

Current and target are different facts; report the current one.

| Supervisor model | Effort | Status |
|---|---|---|
| `openai-codex/gpt-5.6-sol` | `medium` | currently configured default |
| `openai-codex/gpt-5.6-terra` | `high` | desired target, not yet configured |

Terra-high is the intended future default. Until the configuration actually changes, the running supervisor is Sol at medium effort — do not describe Terra as active, and do not modify the provider, profile, fallback chain, or role assignments as a side effect of orchestration work.

Because the current default is already Sol, a separate Sol pass is not a model change; it is an isolated one-shot adjudication with its own context. Run it at `high` only after recording one actual trigger:

- a worker-evidence conflict the supervisor cannot resolve from direct measurement;
- the same failure, test failure, or rejection recurs twice;
- cross-system architecture, destructive data, transformation, migration, security, authentication, secret, payment, or external-access decision;
- contradictory success evidence, or a required goal clause direct verification cannot establish;
- the supervisor cannot confidently approve or reject; or
- explicit user request.

Give the adjudication only the disputed evidence and the decision question. Return to the configured default immediately after success or failure. Do not invoke it for routine routing, summaries, status, ordinary code changes, or evidence-sufficient approvals.

## Context lifecycle

When an agent's own context meter, runtime metadata, or `/context` reports 70% or higher, stop at the next safe boundary. Before compression or a fresh session:

1. Commit completed bounded changes if the task allows it.
2. Create a checkpoint outside any exceptional-review input that records: task scope; role/model/effort; baseline/current HEAD; branch/worktree; changed files or diff; completed/pending steps; commands and observed results; measured facts; inferences; unresolved decisions; failures; temporary resources; and the next single action.
3. Compress or start a fresh session, then resume from the checkpoint plus canonical task documents only.

Do not infer context percentage from aggregate token totals. In non-interactive runtimes without a context meter, create the same checkpoint at every commit, handoff, and task boundary. Never clear context without a checkpoint.

## Autonomy and final hands-on validation

When the user has pre-approved routine runs, do not repeatedly request Run approval. Pause only for irreversible real-data risk, secrets/credential entry, deployment or unapproved external side effects, physical-device-only checks, or evidence-insufficient product/architecture choices.

For a desktop-plus-iPad project, Hermes executes and observes every automatable desktop flow. Escalate only the physical iPad observations that cannot be automated or reproduced locally.
