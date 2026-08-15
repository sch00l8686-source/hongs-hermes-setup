---
name: dispatching-parallel-agents
description: Use when facing 2+ independent tasks that can be worked on without shared state or sequential dependencies
---

# Dispatching Parallel Agents

## Overview

You delegate tasks to agents with isolated context. By precisely crafting their instructions and context, you keep them focused. They never inherit your session history — you construct exactly what they need. This also preserves your own context for coordination work.

**Core principle:** One agent per independent problem domain, and "independent" is a judgment the plan makes before dispatch — not something you assess mid-run.

> **Hong policy extension.** The independence checklist, the pre-dispatch complete-message requirement, the three-worker cap, and mandatory worktree isolation for writers are user policy. Upstream skill name and structure are preserved.

## When to Use

**Use when:**
- 2+ tasks whose boundaries the approved plan has already proved disjoint
- Multiple subsystems broken independently
- Each problem can be understood without context from the others

**Don't use when:**
- Failures are related (fixing one might fix others)
- You need full system state to understand the problem
- You are still exploring and don't know what's broken
- Any mutable or runtime boundary overlaps

## The Independence Checklist

Two tasks may share a parallel group only if **every** line is true. One false line → serialize them.

**Mutable boundaries**
- [ ] Write paths are disjoint (no file written by both)
- [ ] Lockfiles / dependency manifests are not written by both
- [ ] Generated artifacts and build outputs are disjoint
- [ ] Migrations are not authored or applied by both
- [ ] Release targets (tags, versions, publish destinations) are disjoint

**Data flow**
- [ ] Inputs are independent
- [ ] Neither task consumes the other's output
- [ ] Test fixtures / seed data are not shared or mutated by both
- [ ] Dependencies (added, upgraded, pinned) do not overlap

**Runtime boundaries**
- [ ] No shared database, schema, or test DB
- [ ] No shared server, port, or long-running process
- [ ] No shared external service, queue, or account state

**Contract**
- [ ] Each task has its own red-capable focused check
- [ ] The integration interface between them is fixed in the approved plan

For writers, "disjoint write paths" is necessary but not sufficient — the runtime boundaries above must also hold.

## The Pattern

### 1. Confirm the Plan Is Dispatch-Ready

Before any parallel dispatch, the approved plan must already contain, per task:

- the **complete first-dispatch worker message** — role, canonical route, exact goal and goal clause, authoritative runtime and evidence, allowed/forbidden paths, required context sources, exact implementation steps, exact tests and commands, allowed/forbidden side effects, parallel group and shared boundary, required skills, final report schema
- the **prewritten correction/retry message**
- the worktree/branch naming rule, base revision, commit or no-commit policy, result artifact location, and integration order

If a message is incomplete, the plan is not ready. Do not compose an open-ended prompt at dispatch time.

### 2. Isolate Every Writer

**Every agent that writes gets its own worktree.** Concurrent writers never share a working directory. Use superpowers:using-git-worktrees.

Read-only investigation agents may share a checkout.

### 3. Cap Concurrency

**At most three active implementation workers at a time.** This cap changes only when the user changes the policy. Queue the rest; start the next as one finishes.

### 4. Dispatch in Parallel

Issue the dispatches in the same response — they run concurrently:

```text
Worker (isolated worktree wt-a): [Task 1 complete message from the plan, verbatim]
Worker (isolated worktree wt-b): [Task 2 complete message from the plan, verbatim]
Worker (isolated worktree wt-c): [Task 3 complete message from the plan, verbatim]
# Three concurrent, at the cap.
```

Multiple dispatch calls in one response = parallel. One per response = sequential.

### 5. Review and Integrate

When agents return, treat the report as a claim, not evidence:

1. Inspect each worktree's real status/diff/artifact
2. Run the changed-path allowlist check
3. Run the Goal Fidelity check
4. Run each task's focused verification yourself
5. Integrate in the plan's order
6. Run the integration/full gate

See superpowers:subagent-driven-development for the integration procedure and superpowers:verification-before-completion for the completion gate.

## Agent Prompt Structure

Good agent messages are:
1. **Focused** — one clear problem domain
2. **Self-contained** — all context needed, no plan-file reading
3. **Bounded** — explicit allowed and forbidden paths
4. **Specific about output** — a defined report schema

```markdown
Fix the 3 failing tests in src/agents/agent-tool-abort.test.ts:

1. "should abort tool with partial output capture" - expects 'interrupted at' in message
2. "should handle mixed completed and aborted tools" - fast tool aborted instead of completed
3. "should properly track pendingToolCount" - expects 3 results but gets 0

These are timing/race condition issues. Your task:

1. Read the test file and understand what each test verifies
2. Identify root cause - timing issues or actual bugs?
3. Fix by replacing arbitrary timeouts with event-based waiting, fixing bugs in
   the abort implementation, or adjusting expectations if behavior changed

Allowed paths: src/agents/agent-tool-abort.test.ts, src/agents/abort.ts
Forbidden: everything else, including other test files and shared fixtures.
Worktree: wt-abort (base: main). Do not commit.

Do NOT just increase timeouts - find the real issue.

Return: root cause, files changed, command run, exact test output.
```

## Common Mistakes

**❌ Too broad:** "Fix all the tests" — agent gets lost
**✅ Specific:** "Fix agent-tool-abort.test.ts" — focused scope

**❌ No context:** "Fix the race condition" — agent doesn't know where
**✅ Context:** Paste the error messages and test names

**❌ No constraints:** Agent might refactor everything
**✅ Constraints:** Explicit allowed/forbidden path lists

**❌ Shared checkout:** Two writers in one directory — interleaved edits, lost work
**✅ Isolated:** One worktree per writer

**❌ Improvised prompt at dispatch time:** Scope drifts per worker
**✅ Plan-authored complete message, used verbatim**

**❌ Six workers at once:** Beyond the cap, unreviewable
**✅ Three active, rest queued**

## When NOT to Use

**Related failures:** Fixing one might fix others — investigate together first
**Need full context:** Understanding requires seeing the entire system
**Exploratory debugging:** You don't know what's broken yet
**Any shared mutable or runtime boundary:** Serialize instead

## Real Example from Session

**Scenario:** 6 test failures across 3 files after major refactoring

**Failures:**
- agent-tool-abort.test.ts: 3 failures (timing issues)
- batch-completion-behavior.test.ts: 2 failures (tools not executing)
- tool-approval-race-conditions.test.ts: 1 failure (execution count = 0)

**Independence check:** disjoint write paths, no shared fixture, no shared server or DB, each file has its own red-capable check, no lockfile or migration touched → parallel-eligible, and exactly at the three-worker cap.

**Dispatch:**
```
Worker 1 (wt-abort)     → agent-tool-abort.test.ts
Worker 2 (wt-batch)     → batch-completion-behavior.test.ts
Worker 3 (wt-approval)  → tool-approval-race-conditions.test.ts
```

**Results:**
- Worker 1: Replaced timeouts with event-based waiting
- Worker 2: Fixed event structure bug (threadId in wrong place)
- Worker 3: Added wait for async tool execution to complete

**Integration:** diffs inspected in each worktree, allowlists clean, focused checks re-run by the supervisor, merged in plan order, full suite green.

## Verification

After agents return:
1. **Inspect each diff** — the report is a claim, the diff is evidence
2. **Check allowlists** — did any agent write outside its boundary?
3. **Check for conflicts** — did two agents touch the same code despite the plan?
4. **Re-run the focused checks yourself**
5. **Run the full suite** — verify the fixes work together
6. **Spot check** — agents can make systematic errors
