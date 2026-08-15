---
name: supervised-agent-workflow
description: Use for scoped code, release, and multi-agent work.
version: 0.3.0
author: HongGyu, Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [orchestration, goal-fidelity, release, verification]
    related_skills: [subagent-driven-development, verification-before-completion, subagent-coding-context]
---

# Supervised Agent Workflow

Hermes owns requirements, scope, runtime truth, decisions, integration, and final evidence. Bounded implementation workers own the planned source and test edits. Independent review is an exception invoked by a named trigger, not a default stage.

## When to Use

- Nontrivial code, debugging, automation, structural, release, data, credential, network, or multi-agent work.
- Do not use a full ceremony for read-only orientation or a trivial reversible prose correction.

## Risk Routing

| Level | Examples | Required path |
|---|---|---|
| A — read-only | explanation, inspection | inspect and report evidence |
| B — narrow/reversible | isolated label, one assertion | goal lock → edit → focused verification |
| C — structural | contract, workflow, shared component | approved options → goal lock → bounded worker implementation → Hermes direct verification → full gate |
| D — live side effect | production data, credentials, send, deployment | C plus explicit approval, backup/rollback, and physical/live evidence |

Level C does not add an independent reviewer by default. Add one only through an **Exceptional Review** trigger below.

Do not downgrade C/D because a diff is small or inflate B into a multi-agent ceremony.

## Goal-Lock Protocol

Complete this before planning files or dispatching workers.

### 1. Observable Goal

Write the user-visible behavior at the actual target surface. Internal architecture, infrastructure quality, and phrases such as “support offline-first” are not sufficient goals.

### 2. Runtime Truth

Name the surface and delivery path the user actually executes and cite evidence. Repository presence alone never proves a runtime is active. Unverified candidates are `UNVERIFIED_RUNTIME`, not implementation targets.

Acceptable evidence includes direct user confirmation, authoritative project instructions, production entry points and callers, deployed artifacts, or observed running paths.

### 3. Scope Envelope

State allowed paths, forbidden paths, non-goals, allowed side effects, and forbidden side effects. Name tempting adjacent work: other platforms, transport redesign, future abstractions, unrelated cleanup, data backfill, or release changes.

### 4. Goal Traceability

Every changed file and material change must directly enable the observable goal or an approved prerequisite. “Cleaner,” “complete,” “future-proof,” “related,” and “already present in the repo” are not sufficient justifications.

### 5. Minimum Necessary Context

Load only context that answers a named unanswered question. Start with repository instructions, task definitions, production callers, and focused tests. Do not load a whole vault, project history, or long handoff by default. Give implementation workers the exact approved task rather than asking them to rediscover it.

### 6. Thin Vertical Slice

Prefer this order:

```text
observable behavior
→ red-capable test
→ production caller
→ minimum internal change
→ focused verification
```

If infrastructure must come first, prove why a smaller route cannot satisfy the current observable goal.

## Goal Fidelity Lock

Goal substitution replaces the user's observable goal with another platform present in the repository, a retired historical plan, an architecture migration, or infrastructure work. Catching it at the user approval gate is already too late; block it at planning and dispatch.

### Authority order

Resolve every conflict between sources in this order:

1. Current direct user goal.
2. Current user-approved spec.
3. Verified runtime and production caller.
4. Current approved implementation plan.
5. Project instructions.
6. Historical handoffs, plans, branches, and worktree names.
7. Dormant, deprecated, or merely present repository code.

Lower-ranked material may explain how to implement a higher-ranked goal, but never replaces the goal itself.

### Locked values

Record these as concrete values before dispatch, not as headings to fill in later:

```text
Authoritative observable goal:
Authoritative runtime:
Runtime evidence:
Approved behavior delta (before / after):
Explicit non-goals:
Forbidden substitutions:
Allowed paths:
Forbidden paths:
Goal clause served by each task:
```

### Drift checks before integration

Run all five before accepting any worker output:

1. Every changed path is on the plan allowlist.
2. Every changed file is reachable from the authoritative runtime caller.
3. Every material change directly produces the approved behavior delta.
4. No deprecated platform, dormant entry point, historical plan, or stale worktree was activated.
5. No migration, framework conversion, or broad refactor was delivered instead of the requested result.

### Drift rejection precedes user escalation

A failed drift check is plan noncompliance, not a product option. Reject it directly and retry the same approved task with the correction message already written in the plan. Do not present the unauthorized alternative to the user for approval.

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

Escalate to the user only when a concrete user-owned decision remains after rejection.

## Expansion Tripwire

Stop and return an `OUT_OF_SCOPE` packet instead of silently expanding when the task needs:

- an unverified or different runtime/platform;
- a forbidden path or side effect;
- a new store, transport, schema, service, architecture, or product behavior;
- materially more scope than the approved brief;
- a check that validates only internal structure, not the observable symptom.

The packet must state the required expansion, evidence of necessity, why the current boundary cannot solve it, smallest option, alternative, and required decision. Treat this stop as correct behavior.

## Supervisor Procedure

1. **Orient selectively.** Read project instructions, live state, relevant definitions/callers, and only task-specific knowledge. Completion: facts and unanswered questions are separated.
2. **Lock goal and runtime.** Record observable goal, verified runtime, scope envelope, and physical/live boundary. Completion: repository presence cannot silently widen scope.
3. **Decide the gate.** For C/D work, present meaningful options, trade-offs, reversal cost, and obtain approval. Completion: decisions and non-goals are explicit.
4. **Plan ownership.** Split mutable boundaries; no overlapping writers or shared generated/live targets.
5. **Dispatch bounded work.** Use `subagent-coding-context`; assign exact installed worker skills and a complete Goal Lock contract.
6. **Verify directly.** Hermes inspects diffs/artifacts and runs environment-sensitive checks. Worker reports are not evidence.
7. **Check goal fidelity.** Run the drift checks; reject drift and reissue the planned correction message before any user escalation.
8. **Close deliberately.** Run the agreed full gate, verify goal traceability, and separate automated proof from remaining physical/live proof.

Independent review is not a step in this procedure. Insert it only when an Exceptional Review trigger fires.

## Worker Task Contract

Every implementation or review request specifies:

1. target runtime and runtime evidence;
2. observable user goal;
3. allowed and forbidden paths;
4. explicit non-goals;
5. allowed and forbidden side effects;
6. focused red-capable check and integration gate;
7. exact required worker skills;
8. context source → question mapping;
9. reporting requirements and expansion tripwire.

Do not dispatch with a blank field. If a required skill is unavailable, repair the runtime or revise the approved route; do not substitute it.

## Review Economy

Default flow — no independent reviewer:

```text
approved plan
→ one bounded implementation worker
→ Hermes direct artifact/diff/caller verification
→ Hermes goal-fidelity check
→ Hermes fresh focused and integration gates
```

Hermes verifies by inspecting the actual diff, the production caller, and command output. A worker self-report is not evidence, and adding a reviewer that re-reads the same context does not substitute for that direct verification.

### Exceptional Review

Add a separate reviewer only when one of these is true, and record which one fired:

- the approved plan declared this boundary high risk and predefined a bounded review;
- worker evidence conflicts and Hermes cannot resolve it by direct measurement;
- direct verification is materially insufficient to establish a required goal clause;
- the user explicitly requests an independent review.

Prefer a bounded read-only review on the same implementation route. Reserve a different model family for exceptional adjudication.

Reviewers receive the approved goal, runtime evidence, scope envelope, diff, and verification contract—not implementation self-evaluation or the full project history. Repeat a review only when new information exists; repetition without it is not a quality gate.

## Parallelism

Parallelize read-only work or writers with disjoint mutable boundaries only. Serialize work sharing source files, fixtures, generated output, lockfiles, package outputs, databases, credentials, live processes, or deployment targets.

## Role Boundaries

| Role | Owns | Does not own |
|---|---|---|
| Hermes | goal/runtime truth, scope, decisions, integration, final evidence | planned product source/test edits, speculative implementation |
| implementer | bounded source/test changes | architecture expansion, release/live authority |
| exceptional reviewer | triggered independent findings | product decisions, silent edits, a default place in the loop |
| user/physical device | intent choices and irreducible physical confirmation | routine automatable checks |

When the approved plan assigns file ownership to an implementation worker, Hermes does not edit those product source or test files itself. A worker failure is answered with the plan's bounded correction message and a fresh worker run, not by Hermes taking over the edit. Hermes still edits plan, spec, and evidence artifacts it owns.

## Completion Gate

Before completion, verify:

- target runtime is backed by evidence;
- every observable-goal clause has decisive evidence;
- every changed file traces to the goal or approved prerequisite;
- forbidden paths, non-goals, and side-effect boundaries were respected;
- focused checks are red-capable for the actual symptom;
- integration gates are fresh and complete;
- goal-fidelity drift checks pass and no forbidden substitution is present;
- findings from any exceptional review that ran are closed or explicitly accepted;
- generated/live artifacts were inspected rather than inferred;
- automated, physical, and live proof are reported separately.

Passing tests do not close an unverified observable-goal clause.

## Evidence and Durable Learning

- Put code regressions in tests, operator mistakes in runbooks, reusable process failures in focused skills, and current state in handoffs.
- Do not duplicate project state into global prompts or memory.
- Prevent repeated scope drift with the cheapest enforceable dispatch guard, not a broader architecture.

## Pitfalls

- More agents and more reviews do not create safety if they repeat the same context. A per-task reviewer loop costs real time and tokens while Hermes still has to verify the diff itself.
- A repository component is not automatically a runtime target.
- Sending observed goal drift to the user as an option launders plan noncompliance into a product question. Reject it first.
- A long handoff can expand scope and token cost; load only the section that answers the current question.
- A passing unit test is not physical-install, deployment, or user-observation evidence.
