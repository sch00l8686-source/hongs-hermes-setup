---
name: subagent-driven-development
description: "Execute an approved plan by dispatching Claude CLI Opus5 implementation workers, then verifying artifacts and tests directly."
version: 2.0.0
author: Hermes Agent (adapted from obra/superpowers)
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [delegation, subagent, implementation, workflow, parallel]
    related_skills: [executing-plans, dispatching-parallel-agents, verification-before-completion]
---

# Subagent-Driven Development

## Overview

Execute an approved implementation plan by dispatching bounded implementation workers, then verifying their output yourself with real artifacts and real tests.

**Core principle:** The supervisor owns the goal, the decomposition, and the verification. Workers own only the source and test edits the plan assigned to them.

> **Hong policy extension.** The default per-task implementer + spec reviewer + quality reviewer + final reviewer loop is removed. Direct supervisor verification replaces it. Separate reviewers are exceptional, not routine. Upstream skill name and structure are preserved.

## When to Use

- You have a user-approved implementation plan (from superpowers:writing-plans or the `plan` skill)
- The plan defines tasks, ownership, dependencies, and complete worker messages
- You are supervising, not editing the planned product source/test files yourself

## The Process

### 1. Parse the Plan Once

Read the plan file **once** and extract everything you will need for the whole run:

- task list with full task text
- Goal Fidelity Lock: authoritative goal, authoritative runtime, runtime evidence, approved behavior delta, explicit non-goals, forbidden substitutions
- per-task goal clause, allowed paths, forbidden paths
- task dependency graph
- parallel groups and serialization points
- per-task complete first-dispatch worker message
- per-task prewritten correction/retry worker message
- exact verification commands and expected evidence
- integration order and Hermes direct verification steps

Create the todo list from that extraction.

**Key:** Read the plan ONCE. Workers never read the plan file — you hand them the complete message text the plan already contains. You do not author open-ended prompts at runtime.

### 2. Dispatch the Implementation Worker

Dispatch **one worker per plan task**, using the plan's first-dispatch message verbatim.

**Route.** When the plan assigns the Claude CLI Opus5 route, use it:

```text
Claude Code CLI
→ authenticated subscription-backed first-party route
→ claude -p --model opus
→ canonical model/provider probe passes before dispatch
```

Forbidden as substitutes for that route:

- Hermes native Anthropic delegation (`delegate_task` to a native Anthropic delegate)
- MoA Anthropic references
- automatic fallback to an Anthropic API-key route
- enabling Extra Usage or any paid fallback

If the assigned route is unavailable, report it as a concrete blocker. Do not silently swap routes.

**Worker message header.** Every implementation worker message begins with the plan's Goal Fidelity header:

```text
You are implementing an approved bounded task, not choosing the product goal.

AUTHORITATIVE GOAL:
[exact observable goal]

AUTHORITATIVE RUNTIME:
[exact runtime and evidence]

DO NOT SUBSTITUTE:
[stale/dormant platforms and historical plans]

Every changed file must directly trace to the goal.
If the goal cannot be reached inside the assigned route, return GOAL_CONFLICT.
Do not implement an alternative route.
```

**Worker limits.** A worker may not brainstorm, may not make architecture/product/release decisions, and may not touch files outside its allowlist. It owns the approved task's source and test edits only.

### 3. Parallel Groups

Run a parallel group only when the plan already proved the boundaries are disjoint — see superpowers:dispatching-parallel-agents for the full independence checklist.

- Every parallel writer gets its **own isolated worktree**. Never two concurrent writers in one shared source directory.
- Mutable and runtime boundaries must not overlap: write paths, DB, server, ports, fixtures, lockfiles, generated artifacts, migrations, release targets.
- Any overlap → serialize the tasks.
- **At most three active implementation workers** at a time, unless the user changes that policy.

### 4. Verify Before Integrating — Supervisor, Not Reviewer

A worker's self-report is **not** completion evidence. Before integrating any task:

1. **Inspect the actual artifact** — `git status`, `git diff`, the written files, the generated output.
2. **Changed-path allowlist check** — every changed path is in the plan's allowlist for that task.
3. **Goal Fidelity check** — for each changed file: does the authoritative runtime caller actually reach it? Does the change directly produce the approved behavior delta? Did it activate a deprecated platform or historical plan? Did it substitute a migration/refactor/framework conversion for the requested result?
4. **Run the focused verification yourself** — the plan's exact commands, fresh, reading the real output and exit code.
5. **Integrate in the plan's order.**
6. **Run the integration/full gate** the plan specifies.

Goal Fidelity failure is auto-rejected, not escalated:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

Discard and retry the same approved task with the plan's prewritten correction message.

### 5. Task Failure Handling

Test failures, type/lint failures, worker timeouts, and malformed reports are handled autonomously: re-dispatch the plan's correction message for that task. They are not user decision gates and they do not send you back to brainstorming. See superpowers:executing-plans for the user-gate boundary.

Do not hand-edit the planned product source/test files yourself to paper over a worker failure — re-run the bounded correction worker.

### 6. Exceptional Review Only

A separate reviewer agent is dispatched **only** when one of these is true:

- the plan preidentified this boundary as high-risk and specified a bounded adjudication
- worker evidence conflicts and measurement cannot settle it
- direct verification cannot establish a required clause and the remaining evidence is materially insufficient
- the user explicitly requests a review

Otherwise there is no spec reviewer, no quality reviewer, and no final integration reviewer.

When an exceptional review is warranted, prefer a **bounded read-only Opus review** with a specific question. Codex Sol is reserved for exceptional adjudication, never a default reviewer.

## Task Granularity

**Each task = one bounded, verifiable unit of work.**

**Too big:** "Implement user authentication system"

**Right size:**
- "Create User model with email and password fields"
- "Add password hashing function"
- "Create login endpoint"

## Red Flags — Never Do These

- Start implementation without an approved plan
- Author a new open-ended worker prompt at runtime instead of using the plan's message
- Substitute a native Anthropic delegate, MoA reference, or API-key fallback for the assigned Claude CLI Opus5 route
- Dispatch concurrent writers onto overlapping files, DB, server, fixtures, lockfiles, or generated artifacts
- Run more than three active implementation workers without the user changing the policy
- Let concurrent writers share one working directory
- Treat a worker's "success" report as completion evidence
- Integrate before the changed-path allowlist and Goal Fidelity checks
- Make a worker read the plan file (provide the complete message text instead)
- Escalate a routine test failure to the user
- Add a routine per-task reviewer "just to be safe"
- Edit planned product source/test files yourself as the supervisor

## Integration with Other Skills

| Skill | Relationship |
|---|---|
| superpowers:writing-plans | Produces the plan this skill executes, including complete worker and correction messages |
| superpowers:executing-plans | Owns the execution-contract, user-gate, and drift-rejection rules this skill follows |
| superpowers:dispatching-parallel-agents | Owns the independence checklist and isolation rules for parallel groups |
| superpowers:verification-before-completion | Owns the completion gate, requirement-to-evidence mapping, and Goal Fidelity completion checks |
| superpowers:test-driven-development | Worker messages carry TDD steps when the plan specifies a behavior change |
| superpowers:systematic-debugging | Root-cause process when a task hits a real bug |

## Example Workflow

```
[Read approved plan once: extract tasks, Goal Fidelity Lock, worker messages, verification commands]
[Create todo list]

--- Group A (disjoint boundaries, isolated worktrees, 2 workers) ---
[Dispatch Opus worker: Task 1 message verbatim]
[Dispatch Opus worker: Task 2 message verbatim]

  Task 1 worker: reports done
  → git diff inspected: 2 files, both in allowlist
  → Goal Fidelity: production caller reaches both, matches behavior delta
  → ran plan's focused check: 7/7 pass
  → integrated

  Task 2 worker: reports done
  → git diff inspected: touched a path outside allowlist
  → GOAL_DRIFT_REJECTED, changes discarded
  → re-dispatched Task 2 correction message
  → second result clean, focused check passes, integrated

--- Task 3 (serialized: shares a fixture with Task 2) ---
[Dispatch Opus worker: Task 3 message verbatim]
  → inspected, checked, verified, integrated

[Run integration/full gate from the plan]
[verification-before-completion: requirement-to-evidence matrix]
```

No spec reviewer, no quality reviewer, no final reviewer was dispatched — direct verification established every clause.

## Remember

```
Parse the plan once
Dispatch the plan's message, never improvise one
Disjoint boundaries + isolated worktrees, max three active workers
Inspect artifacts and run tests yourself
Reviewers are exceptional, not routine
```

## Further reading (load when relevant)

When the orchestration involves significant context usage or complex validation checkpoints, load these references for the specific discipline:

- **`references/context-budget-discipline.md`** — Four-tier context degradation model (PEAK / GOOD / DEGRADING / POOR), read-depth rules that scale with context window size, and early warning signs of silent degradation. Load when a run will clearly consume significant context (multi-phase plans, many workers, large artifacts).
- **`references/gates-taxonomy.md`** — The four canonical gate types (Pre-flight, Revision, Escalation, Abort) with behavior, recovery, and examples. Load when designing or reviewing a workflow's validation checkpoints, so each gate has defined entry, failure behavior, and resumption rules. Under this skill's policy, the correction-message retry is the Revision gate, and Escalation is limited to the user-decision boundaries in superpowers:executing-plans.

Both references adapted from gsd-build/get-shit-done (MIT © 2025 Lex Christopherson).
