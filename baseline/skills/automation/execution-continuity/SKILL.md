---
name: execution-continuity
description: Use for approved work without routine prompts.
version: 0.2.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [automation, verification, workflow, goal-fidelity]
    related_skills: [supervised-agent-workflow, subagent-coding-context]
---

# Execution Continuity

## When to Use

Use this skill for user-approved, bounded automation, coding, verification, or replacement work where repeated routine confirmation or visible run-prompt narration would interrupt progress.

## Principle

Once scope and safety boundaries are approved, execute the normal sequence internally to completion. Do not stop to ask for permission for each routine edit, test, parser check, disposable verification, or reversible local repair.

Do not narrate "I will run…", ask the user to click/approve a routine run, or surface a run-style prompt before each command. Make the tool call immediately and report only decisive outcomes, blockers, or genuine decisions.

## Planning Prerequisite

This skill starts **after** the applicable design and planning gate, not instead of it.

- For any change beyond a truly mechanical, reversible one-line correction, first use the required design workflow (`brainstorming`, then `writing-plans`) and obtain approval for both the design and written plan.
- Treat the approved plan as the execution contract: it must already define scope, ownership boundaries, acceptance criteria, verification, dependencies, and external-effect boundaries.
- Do not turn ordinary implementation uncertainty, test failures, or recoverable local tool errors into a new user approval loop. Diagnose and repair them within the approved plan.
- Pause only when the next action needs a user-owned decision not resolved by that plan: a new requirement or scope choice, credential/permission entry, real-data or irreversible external effect, publication/deployment, a physical-only observation, or a requirement contradiction that no plan-compatible measurement can resolve.
- Do not silently add improvements outside the plan. When a material blind spot, alternative, or improvement would affect the user's decision, surface it as a clearly labeled **non-executing proposal** with rationale, trade-offs, reversibility, and the smallest next step; do not implement it without approval.

### Goal Fidelity During Execution

Treat the approved observable goal and verified runtime as immutable execution inputs. Historical plans, dormant code, worktree names, adjacent platforms, and repository presence may explain implementation details but must never replace the current goal.

Before accepting or integrating worker output:

1. Confirm every changed path is on the plan allowlist.
2. Trace each material change through the verified production caller to an approved goal clause.
3. Reject framework migration, platform substitution, broad refactoring, or revival of a historical plan unless the current plan explicitly authorizes it.
4. If output drifts, reject it before any user gate and issue the plan's bounded correction brief. Do not ask the user to approve an unauthorized alternative.
5. Escalate only when a concrete new user-owned decision remains; ordinary goal drift is plan noncompliance, not a product choice.

See `references/goal-fidelity-and-user-gates.md` for the authority order, worker packet fields, and drift-rejection format.

## Before Starting

1. Establish the bounded target: files, repository, disposable test root, or approved local artifact.
2. Identify real stop conditions before execution:
   - credential/auth/token access or mutation;
   - real configuration/provider/channel/gateway changes;
   - live deployment, live-home apply, external send, publication, force-push, or history rewrite;
   - deletion/overwrite outside an approved reversible scope;
   - a requirement contradiction, or an evidence conflict, that no plan-compatible measurement can resolve.
3. If none apply, treat normal edits and verification as pre-approved execution.

"Evidence is too weak" is not by itself a stop condition. Weak or conflicting evidence is first answered with the plan-compatible measurement that would settle it: read the actual artifact, run the focused check, inspect the production caller, or reproduce the competing claims. Escalate only after that measurement is run and a user-owned decision still remains.

## Continuous Execution Loop

1. Read the exact failure or affected source.
2. Make the smallest scoped correction.
3. Run the focused verification immediately.
4. If it fails, diagnose the new evidence rather than repeating the same command unchanged.
5. Escalate to a broader suite only after the focused gate passes.
6. Continue until the agreed artifact is verified or a real stop condition is reached.

Keep routine progress internal. User-facing messages are reserved for:
- a material decision with alternatives;
- a live/irreversible boundary;
- an unresolvable blocker;
- the final concise evidence report.

## Replacement and Migration Work

For installer, migration, or replacement changes:

- Use disposable targets for normal edit/test iterations.
- Keep live target application separate from implementation verification.
- Preserve the previous artifact or backup path before a destructive approved action.
- Do not treat a worker report as verification; run the relevant check directly.
- Do not abandon an approved ordinary task at an intermediate test failure; diagnose and repair within scope.

## Failure Discipline

- A denied or timed-out tool approval is a boundary, not evidence that the code is wrong. If routine execution is already approved, use the platform's internal approval path where available; do not repeatedly ask the user to approve the same safe operation.
- If an attempted verification command is blocked, inspect the exact blocker before selecting a different mechanism. Never disguise a prohibited action as a different command.
- Avoid ad-hoc verifier scripts unless they provide unique coverage unavailable in the established harness. Prefer the canonical test harness once it exists.
- Do not flood the user with raw logs. Preserve decisive failure lines and final exit status only.

## Completion Gate

Before saying the work is complete:

1. Run the focused or full agreed verification after the final edit.
2. Confirm changed paths stay inside scope.
3. State remaining skips, unresolved risks, and any live check not performed.
4. Do not commit, publish, or apply to a live target unless that boundary was separately approved.

See `references/interaction-boundaries.md` for the routine-versus-explicit-gate decision table.
