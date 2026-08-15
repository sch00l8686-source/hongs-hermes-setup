---
name: executing-plans
description: Use when you have a written implementation plan to execute - the approved plan is an execution contract, run it to completion without routine user prompts
---

# Executing Plans

## Overview

An approved implementation plan is an **execution contract**, not a proposal. Load it once, confirm it is executable, then run it to completion. Do not re-open design questions, do not ask for routine confirmation between tasks.

**Announce at start:** "I'm using the executing-plans skill to implement this plan."

**Note:** Superpowers works much better with access to subagents (Claude Code, Codex CLI, Codex App, Copilot CLI, and Gemini CLI all qualify; see the per-platform tool refs in `../using-superpowers/references/`). If subagents are available, use superpowers:subagent-driven-development instead of this skill.

> **Hong policy extension.** The autonomy rules, user decision boundaries, and goal-drift rejection below are user policy layered on the upstream Superpowers skill. Upstream structure and naming are preserved.

## The Process

### Step 1: Load and Review Once

1. Ensure an isolated workspace: use superpowers:using-git-worktrees to create one or verify the existing one.
2. Read the plan file in full.
3. Review it **once**, for executable completeness only:
   - Goal Fidelity Lock present with concrete values (goal, runtime, evidence, behavior delta, non-goals, forbidden substitutions)
   - every task names exact create/modify/test paths
   - every task has a complete first-dispatch worker message and a prewritten correction message
   - exact verification commands and expected evidence
   - parallel groups, serialization points, and ownership are stated
   - no `TBD`/`TODO`/"as needed"/"similar to Task N" placeholders
4. If a gap is a **concrete unapproved decision** (see Step 4), raise exactly that decision. Otherwise fill plan-compatible detail yourself and proceed.
5. Create todos for the plan tasks and start.

This review happens once. Do not re-review the plan between tasks.

### Step 2: Execute Tasks

For each task:
1. Mark as in_progress.
2. Follow the task steps exactly.
3. Run the verification commands the plan specifies.
4. Inspect the actual artifact/diff — not a self-report — before marking done.
5. Mark as completed.

Between tasks there is no user checkpoint. Keep going.

### Step 3: Handle Failure Without Escalating

These are **yours to fix**, autonomously, inside the approved plan:

- expected RED test
- implementation test failure
- parser, type, lint, or build failure
- worker timeout or malformed worker report
- plan-compatible local repair
- isolated worktree cleanup
- safe local retry
- worker disagreement that evidence can settle

Collect evidence, apply the safe retry or the fallback the plan already defines, and continue.

**Do not automatically return to brainstorming for routine failures.** A failing test is execution data, not a signal that the design is wrong. Reopen design only when direct evidence shows the approved plan's premise is factually false — and then present it as a concrete decision (Step 4), not as "the plan collapsed".

### Step 4: User Gates — Only These

Stop and ask **only** when the next step needs a decision or effect that is genuinely the user's and is not already approved:

- new product, scope, architecture, or policy choice
- credential, OAuth, 2FA, payment, or permission grant
- unapproved change to real data
- publish, push, deploy, or external send
- unapproved irreversible external effect
- physical-device observation that cannot be automated
- a real contradiction between approved requirements that evidence cannot resolve

Use this packet:

```text
Decision required:
Evidence:
Options:
Trade-offs:
Reversibility:
Recommended choice:
```

Never open a gate with an abstraction alone ("plan collapsed", "premise failed"). Name the concrete decision.

### Step 5: Goal Drift Is Auto-Rejected

Before integrating any task result, check:

1. Are all changed paths inside the plan's allowlist?
2. Is each changed file actually reachable from the authoritative runtime caller?
3. Does each change directly produce the approved behavior delta?
4. Did it activate a deprecated platform, stale worktree, or historical plan?
5. Did it produce a migration, refactor, or framework conversion instead of the requested result?

A failure here is **not** a user decision gate. Reject it automatically:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

Discard the drifted changes and retry the **same approved task** using the plan's prewritten correction message. Do not design a new prompt at runtime.

### Step 6: Complete Development

After all tasks are done and verified:
- **REQUIRED SUB-SKILL:** superpowers:verification-before-completion — fresh evidence, requirement-to-evidence mapping, and Goal Fidelity checks before any completion claim.
- Announce: "I'm using the finishing-a-development-branch skill to complete this work."
- **REQUIRED SUB-SKILL:** superpowers:finishing-a-development-branch.

## Non-Executing Proposals

If you find a material improvement that the current goal does not require, report it — do not implement it, do not hide it:

```text
Non-executing proposal:
Why it matters:
Trade-offs:
Reversibility:
Smallest next step:
Implementation performed: no
```

## Remember

- The approved plan is the contract; execute it
- Review for executable completeness once, not per task
- Routine failures are handled autonomously, not escalated and not sent back to brainstorming
- User gates only for concrete unapproved decisions or external effects
- Goal drift is rejected automatically and retried with the plan's correction message
- Never start implementation on main/master without explicit user consent
