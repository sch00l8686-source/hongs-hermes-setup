---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

**This skill is the single authority for implementation plans.** Every
implementation plan — for any harness, any project, any size of change — is
written to this specification. Other skills may route work here; none of them
define their own competing plan format.

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** If working in an isolated worktree, it should have been created via the `superpowers:using-git-worktrees` skill at execution time.

**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Task Right-Sizing

A task is the smallest unit that carries its own test cycle and its own
verification gate. When drawing task boundaries: fold setup, configuration,
scaffolding, and documentation steps into the task whose deliverable needs
them; split only where one task's verification could fail while its
neighbor's still passes. Each task ends with an independently testable
deliverable.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task under supervision. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

## Goal Fidelity Lock

[Required. Concrete values, no placeholders. See the Hong policy extension below
for the field list and the authority order.]

## Global Constraints

[The spec's project-wide requirements — version floors, dependency limits,
naming and copy rules, platform requirements — one line each, with exact
values copied verbatim from the spec. Every task's requirements implicitly
include this section.]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Traceability:**
- Goal clause served: [exact clause from the Goal Fidelity Lock]
- Why this file is necessary: [why the goal cannot be reached without it]
- Runtime caller evidence: [the authoritative caller that reaches this file]
- Forbidden adjacent route: [the nearby route this task must not take]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Interfaces:**
- Consumes: [what this task uses from earlier tasks — exact signatures]
- Produces: [what later tasks rely on — exact function names, parameter
  and return types. A task's implementer sees only their own task; this
  block is how they learn the names and types neighboring tasks use.]

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**1. Spec coverage:** Skim each section/requirement in the spec. Can you point to a task that implements it? List any gaps.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## Execution Handoff

After saving the plan, ask the user to approve it. The plan becomes an execution
contract only after that approval.

> "Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Please review it. On your approval I'll execute it under the approved execution harness: supervisor-owned decomposition, plan-defined worker messages, and direct verification of every result."

Once approved, execution runs on the approved harness — not on a per-task review
loop:

- **REQUIRED SUB-SKILL:** superpowers:executing-plans for the execution contract.
- **REQUIRED SUB-SKILL:** superpowers:subagent-driven-development when the plan
  dispatches implementation workers, for plan-defined task dispatch, correction,
  and integration.
- **REQUIRED SUB-SKILL:** superpowers:dispatching-parallel-agents for the
  plan-defined parallel groups.
- **REQUIRED SUB-SKILL:** superpowers:verification-before-completion before any
  completion claim.

Do not offer an execution mode whose value is per-task independent review. Review
is exceptional, and the plan names where it applies.

---

## Hong policy extension

This section is a user policy overlay on top of the upstream skill. The skill name
and the plan format above are unchanged; this section adds the required contents.

### Required sections

Every implementation plan contains all of these, filled with concrete values:

1. **Goal Fidelity Lock** — the block below, at the top of the plan.
2. **Observable goal and explicit non-goals.**
3. **Actual runtime and evidence** — the real surface, delivery path, and the
   production entry point or caller that proves it.
4. **Approved architecture and constraints** — copied from the approved spec.
5. **Repository and file responsibility map** — what each touched file owns.
6. **Task dependency graph** — which task depends on which output.
7. **Parallel groups and serialization points** — with the reason for each
   serialization.
8. **Exact create/modify/test paths** per task.
9. **Interface consumes/produces contract** per task, with exact signatures.
10. **TDD or red-capable check** for every behavior change — a check that can
    actually fail before the change and pass after it.
11. **Exact verification commands and expected evidence** — command text and the
    output that counts as passing.
12. **Worker ownership matrix** — worker, owned paths, forbidden paths, worktree
    or branch, base revision, commit policy, report location.
13. **Complete first-dispatch worker message per task.**
14. **Correction/retry worker message per task.**
15. **GOAL_CONFLICT and OUT_OF_SCOPE report formats.**
16. **Supervisor direct verification steps.**
17. **Backup, rollback, and external-effect gate.**
18. **User decision boundaries.**
19. **Non-executing proposal handling.**
20. **Final requirement-to-evidence matrix.**

### Goal Fidelity Lock

```md
## Goal Fidelity Lock

Authoritative observable goal:
- [the actual result the user will see]

Authoritative runtime:
- [the real surface and delivery path]

Runtime evidence:
- [user confirmation, production entry point/caller, running or deployed artifact]

Approved behavior delta:
- Before: [current observed behavior]
- After: [approved behavior]

Explicit non-goals:
- [deprecated platform or plan]
- [adjacent but unrequested capability]
- [candidate present in the repository but not the active runtime]

Forbidden substitutions:
- [migration, framework conversion, infrastructure replacement, and similar]
```

When sources conflict, resolve in this order: current direct user goal,
user-approved current spec, verified runtime and production caller, current
approved implementation plan, project instructions, historical handoffs and plans
and worktrees and branch names, dormant or deprecated repository code.

Every changed path and every material line must trace to the observable goal or to
an approved prerequisite. "Cleaner", "more complete", "future-proof", "related",
"already present in the repository", and "the platform name is similar" are not
justifications.

### Worker messages belong in the plan

Each task carries the full text of the message that will be dispatched, so the
supervisor never has to invent an open-ended prompt during execution. Each message
states:

- worker role and canonical route
- exact goal and the task's goal clause
- authoritative runtime and evidence
- allowed paths and forbidden paths
- required context sources, and which question each source answers
- exact implementation steps
- exact tests and commands
- allowed and forbidden side effects
- parallel group and shared boundary
- required skills
- final report schema

Every worker message opens with this contract:

```text
You are implementing an approved bounded task, not choosing the product goal.

AUTHORITATIVE GOAL:
[exact observable goal]

AUTHORITATIVE RUNTIME:
[exact runtime and evidence]

DO NOT SUBSTITUTE:
[stale or dormant platforms and historical plans]

Every changed file must directly trace to the goal.
If the goal cannot be reached inside the assigned route, return GOAL_CONFLICT.
Do not implement an alternative route.
```

Each task also carries a correction message: the same bounded task, plus the
observed failure and the plan-compatible repair, for use when the first dispatch
fails verification. A correction retries the approved task; it does not redefine it.

### Report schemas

```text
GOAL_CONFLICT
- assigned task:
- goal clause that cannot be reached:
- what blocks it inside the allowed route:
- evidence:
- smallest decision or change that would unblock it:
- implementation performed: no
```

```text
OUT_OF_SCOPE
- observation:
- why it matters to the goal:
- affected paths:
- trade-offs:
- reversibility:
- smallest next step:
- implementation performed: no
```

### Supervisor verification

The plan states, per task, how the supervisor verifies it directly. A worker's
self-report is never completion evidence. The steps are:

1. Inspect the actual status, diff, and produced artifacts.
2. Run the changed-path allowlist check against the plan's owned paths.
3. Run the Goal Fidelity check: does the authoritative runtime caller reach each
   changed file, does each change produce the approved behavior delta, was any
   deprecated platform or historical plan activated, was a migration or refactor
   produced instead of the requested result?
4. Run the task's focused verification commands.
5. Integrate in the plan's order.
6. Run the integration or full gate.

Drift is rejected automatically rather than escalated to the user:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

### Backup, rollback, and external effects

The plan states the base revision, how to restore it, and what to do with an
isolated worktree after rejection. Any external effect — publish, push, deploy,
external send, real-data mutation, credential or permission grant — is a named
gate in the plan, never an implicit step inside a task.

### User decision boundaries

The plan lists exactly which decisions belong to the user: new product, scope,
architecture, or policy choices; credentials, OAuth, 2FA, payment, permission
grants; unapproved real-data changes; publish, push, deploy, or external send;
unapproved irreversible external effects; physical-device observation; and a real
contradiction between approved requirements that evidence cannot resolve.

Failed tests, worker timeouts, parser errors, and plan-compatible corrections are
not user decision gates. When a genuine user decision appears, present it as:

```text
Decision required:
Evidence:
Options:
Trade-offs:
Reversibility:
Recommended choice:
```

### Non-executing proposal handling

The plan states where out-of-scope improvements are recorded and confirms they are
reported, not implemented, without separate approval.

### Additional no-placeholder failures

Beyond the list above, these also make the plan invalid:

- a step with no real path, symbol, or command
- a blank the worker would have to fill with a product or architecture decision
- a task with no link to a goal clause
- a worker message that is described instead of written out

### Extended self-review

Run all of these before handing the plan to the user:

1. Spec coverage
2. Placeholder scan
3. Path and symbol validity
4. Interface consistency
5. Task dependency consistency
6. Ownership overlap
7. Runtime reachability
8. Goal Fidelity traceability
9. Verification red capability
10. External side-effect and user gate completeness
11. Worker message completeness
12. Proposal and implementation separation

### Final requirement-to-evidence matrix

The plan ends with a table mapping every requirement to the task that implements
it and the exact evidence that will prove it.

| Requirement | Task | Verification command | Expected evidence |
|---|---|---|---|
