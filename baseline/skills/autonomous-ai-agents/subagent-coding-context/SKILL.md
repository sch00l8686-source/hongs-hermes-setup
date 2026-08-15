---
name: subagent-coding-context
description: "Inject bounded coding contracts into worker prompts."
version: 0.3.0
author: HongGyu, Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [delegation, coding, context, orchestration, goal-fidelity]
    related_skills: [claude-code, codex, mixed-model-agent-orchestration, supervised-agent-workflow]
---

# Subagent Coding Context

Use this for every Hermes native coding subagent and every Claude/Codex coding or review worker. It converts an approved task into a bounded, testable contract; it is not a substitute for repository instructions.

A worker receives an approved task, never an open design mandate. It does not re-run brainstorming, re-choose the product goal, redesign the architecture, or select a different route. If the approved route cannot reach the stated goal, it stops with `GOAL_CONFLICT` instead of substituting its own plan.

## When to Use

- Coding, debugging, implementation, test, or review work through `delegate_task`, Claude Code, or Codex CLI.
- A fresh continuation after a checkpoint.
- Do not use for pure research, vault operations, or unrelated creative work.

## Precedence

Resolve every conflict between sources in this order:

1. Current direct user goal and approved scope.
2. Current user-approved spec.
3. Verified runtime and production caller.
4. Current approved implementation plan and the task contract below.
5. Target repository instructions.
6. The inherited coding context.
7. Historical handoffs, plans, branches, and worktree names.
8. Dormant, deprecated, or merely present repository code.

Lower-ranked material may explain how to implement a higher-ranked goal; it never replaces the goal. Do not pass unrelated biography, vault rules, project history, or entire handoffs to a worker.

## Mandatory Dispatch Preflight

Hermes must fill every field below before dispatch. Do not infer a runtime from repository presence: a directory, project, platform target, or dormant entry point is not evidence that the user runs it.

- **Target runtime:** the surface and delivery path the user actually executes.
- **Runtime evidence:** user confirmation, production entry point, running process, deployed artifact, routing path, or authoritative project instruction.
- **Observable user goal:** behavior visible at that runtime; internal architecture is not a goal.
- **Scope envelope:** allowed paths, forbidden paths, non-goals, and side-effect boundary.
- **Required skills:** exact names installed in the target worker runtime.
- **Context sources:** only documents or definitions that answer a named task question.
- **Verification:** a red-capable focused check, integration gate, and any remaining physical/live proof.

Every coding or review worker requires `karpathy-guidelines`. A behavior-changing implementation also requires the runtime's test-first skill, normally `superpowers:test-driven-development`. A reviewer or completion gate also requires `superpowers:verification-before-completion`. If a required skill is unavailable, return `MISSING_REQUIRED_SKILL`; never substitute a similarly named skill.

## APPROVED_WORKER_TASK Contract

Append a completed copy of this block and the **Inherited Coding Context** to every coding-worker prompt. Every field carries a concrete value at dispatch; a heading left blank is not a dispatchable task.

```text
APPROVED_WORKER_TASK

## Authority

This message is the approved task. Do not brainstorm, redesign the product, change the runtime, or choose a different route.
Authority order: current user goal → approved spec → verified runtime/production caller → this approved plan → repository instructions → historical plans and worktree names → merely present code.

## Goal Lock

Target runtime: [actual user-facing surface and delivery path]
Runtime evidence: [measured evidence, not repository presence]
Observable user goal: [what the user can see or verify]
Approved behavior delta — before: [current observable behavior]
Approved behavior delta — after: [required observable behavior]
Goal clause served by this task: [the exact clause this task closes]

## Scope Envelope

Non-goals: [explicit tempting adjacent work]
Forbidden substitutions: [platforms, migrations, frameworks, historical plans, dormant entry points that must not replace the goal]
Allowed paths: [exact write boundary]
Forbidden paths: [exact exclusions]
Allowed side effects: [approved writes/commands]
Forbidden side effects: [network, credentials, live data, release, etc.]

## Required Skills

Required skills: [exact target-runtime skill names]

Before editing or reviewing, load and apply every required skill. Presence on disk is not application. If any skill is unavailable, stop with `MISSING_REQUIRED_SKILL`.

## Context Budget

Repository instructions: [authoritative files]
Context source → question answered:
- [specific file or section] → [specific question]

Do not scan the repository, vault, full history, or long handoffs without a named unanswered question. Read definitions and production callers needed for this task.

## Implementation Contract

Start with the thinnest vertical slice: observable behavior → red-capable test → production caller → minimum internal change → verification.
Every changed file and material changed line must trace to the observable goal or an approved prerequisite.
Repository presence alone does not put a runtime, platform, store, transport, or module in scope.

If the work requires a forbidden path, new runtime/platform, new store/transport/schema/service, changed product behavior, or a materially larger scope, do not implement it. Return:

OUT_OF_SCOPE
- required expansion:
- evidence it is necessary for the observable goal:
- why the current boundary cannot solve it:
- smallest option:
- alternative:
- required user/Hermes decision:

If the approved route, plan, or contract cannot produce the stated observable goal — or two clauses of this contract contradict each other — do not pick a substitute goal or route. Stop and return:

GOAL_CONFLICT
- approved goal clause:
- approved route/task as written:
- measured evidence they cannot both hold:
- what is blocked:
- smallest plan-compatible option:
- required Hermes decision:

## Verification

Focused red-capable check: [exact command/observation]
Integration gate: [exact command]
Remaining physical/live proof: [explicitly separate from automated proof]

## Final Report

- skills actually applied
- changed paths
- observable-goal evidence
- commands actually run and exact results
- non-goal work performed: none / details
- unresolved boundary or OUT_OF_SCOPE decision
```

## Expansion Tripwires

Stop instead of broadening when any of these occurs:

- the target runtime is unverified or changes;
- a forbidden path or side effect becomes necessary;
- a new platform, store, transport, schema, service, or product behavior is proposed;
- the test proves only an internal structure and cannot fail on the observable symptom;
- the task becomes materially larger than its brief;
- the justification is future flexibility, completeness, cleanup, or repository presence rather than the current goal.

`OUT_OF_SCOPE` and `GOAL_CONFLICT` are correct scope compliance, not worker failure. Silently substituting a reachable goal for the approved one is the failure.

## Required Dispatch Messages

The plan must contain two complete worker messages for every task before the first dispatch:

1. **Initial message** — the full `APPROVED_WORKER_TASK` block plus the Inherited Coding Context, with every field valued.
2. **Correction message** — a bounded reissue of the same approved task for use after a failed gate, a failed drift check, or a discarded worker diff. It names what to discard, the approved task to resume from, and the specific clause that was violated. It does not widen scope, hand the worker a new goal, or invite redesign.

Writing the correction message at planning time is what makes drift rejection cheap: Hermes reissues it to a fresh worker instead of taking over the edit or escalating to the user.

## Hermes-Side Drift Rejection

A worker return that violates the allowlist, the runtime, the behavior delta, or a forbidden substitution is plan noncompliance, not a product option. Reject it before any user gate, then reissue the correction message:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

Do not present the unauthorized alternative to the user for approval. Escalate only when a concrete user-owned decision remains after rejection.

## Inherited Coding Context

```text
## Inherited Coding Context — subordinate to this repository's instructions

- Match the requested output behavior and quality trend; do not settle for a superficial approximation when the underlying behavior is wrong.
- Do not repeat a known failure. Prefer an enforceable guard, test, or measured verification over a promise in prose.
- Apply YAGNI strictly: do not add speculative files, folders, fields, rules, features, abstractions, or refactors. Preserve only the extensible backbone demonstrably required by the approved goal.
- Separate exploration from implementation. Implementation must not silently reopen product, runtime, or architecture scope.
- Do not invent missing facts, symbols, APIs, formats, or requirements. Read definitions and production callers first; label remaining inference.
- Preserve named external patterns and components; treat additions or omissions as explicit scoped extensions.
- Distinguish measured facts from inference and leave unresolved product choices to Hermes or the user.
- Approved autonomous execution authorizes work inside the scope envelope, not expansion beyond it.
```

## Verification

Before dispatch, verify every contract field is concrete, the runtime has evidence, context sources answer named questions, tempting adjacent work is explicitly excluded, and both the initial and correction messages exist. After return, inspect the actual diff/artifact, run the drift checks, and rerun decisive checks directly; worker reports and skill declarations are not completion evidence, and adding another agent to re-read the same context does not replace direct verification.
