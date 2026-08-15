---
name: verification-before-completion
description: Use when about to claim work is complete, fixed, or passing, before committing or creating PRs - requires running verification commands and confirming output before making any success claims; evidence before assertions always
---

# Verification Before Completion

## Overview

**Core principle:** Evidence before claims, always.

**Violating the letter of this rule is violating the spirit of this rule.**

> **Hong policy extension.** The Goal Fidelity checks, the requirement-to-evidence matrix, and the automated-vs-physical proof separation are user policy added to the upstream gate. The Iron Law and everything above it are unchanged.

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command in this message, you cannot claim it passes.

## The Gate Function

```
BEFORE claiming any status or expressing satisfaction:

1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence
5. GOAL FIDELITY: Run the four checks below
6. MAP: Fill the requirement-to-evidence matrix
7. ONLY THEN: Make the claim

Skip any step = lying, not verifying
```

## Goal Fidelity Checks

Passing tests prove the code works. They do not prove you built what was asked. Run all four before any completion claim.

### 1. Changed-path allowlist

Every changed path is inside the approved plan's allowlist for the task that produced it.

```
✅ [git diff --name-only] [compare each path to the plan allowlist] "all 6 changed paths in allowlist"
❌ "only touched what I needed to"
```

Any path outside the allowlist is a finding, not a rounding error.

### 2. Production caller reachability

For each changed file, the **authoritative runtime** actually reaches it. Trace from the real production entry point — the running surface the user observes — to the changed file.

```
✅ [grep/trace from the production entry point] "WebUI route /trash → TrashController → the changed query"
❌ "it's in the repository, so it's used"
```

A file no production caller reaches is dormant code. Editing it produces no observable result.

### 3. Goal-clause traceability

Every changed path and every material line maps to a specific goal clause of the observable goal, or to an approved prerequisite.

These are **not** justifications:
- cleaner
- more complete
- future-proof
- related
- already present in the repository
- platform name similarity

### 4. Forbidden-substitution absence

Confirm the work did not replace the requested result with an adjacent one:
- no deprecated platform, stale worktree, or historical plan reactivated
- no migration, framework conversion, or infrastructure replacement standing in for the requested behavior
- nothing on the plan's `Forbidden substitutions` list is present

Failure here is auto-rejected, not reported as done:

```text
GOAL_DRIFT_REJECTED
- observed drift:
- violated goal clause:
- unauthorized runtime/path:
- discard these changes:
- resume from approved task:
```

## Requirement-to-Evidence Matrix

A completion claim ships with this table filled in. Every goal clause gets a row; no row is empty.

| Goal clause | Change that serves it | Verification command | Fresh output / observation | Proof type |
|---|---|---|---|---|
| [clause from the approved goal] | [path:symbol] | [exact command] | [exit code, counts, quoted line] | automated / physical-live |

If a clause has no evidence, the work is not complete — say so and name the gap.

## Automated vs Physical/Live Proof

Keep these separate. Never let one stand in for the other.

**Automated proof** — commands you ran in this session: tests, build, linter, type check, diff inspection, generated-artifact inspection. Reproducible, self-contained.

**Physical/live proof** — anything requiring a real device, a real deployed surface, a human eyeball, or external state you did not create: on-device rendering, deployed-site behavior, hardware response, third-party account state.

Rules:
- Report them in separate sections. Do not merge them into one "verified" claim.
- Automated proof never substitutes for a physical/live requirement. "Tests pass" is not "it renders on the iPad".
- If a clause needs live proof you cannot obtain, mark it **unverified — needs live confirmation** and state exactly what the user must observe.
- Live confirmation the user already gave counts as evidence — cite it as such.

## Common Failures

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Tests pass | Test command output: 0 failures | Previous run, "should pass" |
| Linter clean | Linter output: 0 errors | Partial check, extrapolation |
| Build succeeds | Build command: exit 0 | Linter passing, logs look good |
| Bug fixed | Test original symptom: passes | Code changed, assumed fixed |
| Regression test works | Red-green cycle verified | Test passes once |
| Agent completed | VCS diff shows changes | Agent reports "success" |
| Requirements met | Requirement-to-evidence matrix | Tests passing |
| Built what was asked | Four Goal Fidelity checks | Tests passing |
| Works in the real runtime | Production caller trace, or live observation | File exists in the repository |
| User-visible behavior fixed | Physical/live confirmation | Automated suite green |

## Red Flags - STOP

- Using "should", "probably", "seems to"
- Expressing satisfaction before verification ("Great!", "Perfect!", "Done!", etc.)
- About to commit/push/PR without verification
- Trusting agent success reports
- Relying on partial verification
- Thinking "just this once"
- Tired and wanting work over
- Claiming a user-visible result from automated evidence alone
- A goal clause with no row in the matrix
- A changed path you cannot trace to a goal clause
- **ANY wording implying success without having run verification**

## Rationalization Prevention

| Excuse | Reality |
|--------|---------|
| "Should work now" | RUN the verification |
| "I'm confident" | Confidence ≠ evidence |
| "Just this once" | No exceptions |
| "Linter passed" | Linter ≠ compiler |
| "Agent said success" | Verify independently |
| "I'm tired" | Exhaustion ≠ excuse |
| "Partial check is enough" | Partial proves nothing |
| "It's in the repo so it's wired up" | Trace the production caller |
| "Tests pass, so the user sees it" | Automated ≠ live |
| "It's related to the goal" | Related ≠ traceable to a goal clause |
| "Different words so rule doesn't apply" | Spirit over letter |

## Key Patterns

**Tests:**
```
✅ [Run test command] [See: 34/34 pass] "All tests pass"
❌ "Should pass now" / "Looks correct"
```

**Regression tests (TDD Red-Green):**
```
✅ Write → Run (pass) → Revert fix → Run (MUST FAIL) → Restore → Run (pass)
❌ "I've written a regression test" (without red-green verification)
```

**Build:**
```
✅ [Run build] [See: exit 0] "Build passes"
❌ "Linter passed" (linter doesn't check compilation)
```

**Requirements:**
```
✅ Re-read approved goal → Fill requirement-to-evidence matrix → Report gaps or completion
❌ "Tests pass, phase complete"
```

**Goal fidelity:**
```
✅ [git diff --name-only] → allowlist → caller trace → clause map → substitution scan → then claim
❌ "Tests pass, so it's what they asked for"
```

**Agent delegation:**
```
✅ Agent reports success → Check VCS diff → Verify changes → Report actual state
❌ Trust agent report
```

**Live surface:**
```
✅ "Automated: 34/34 pass. Live: unverified — please confirm the trash page shows one row per project on the iPad."
❌ "Verified — the trash page now shows one row per project."
```

## Completion Report Shape

```text
Automated evidence:
- [command] → [fresh output]

Requirement-to-evidence matrix:
- [table above]

Goal Fidelity:
- changed-path allowlist: [result]
- production caller reachability: [result]
- goal-clause traceability: [result]
- forbidden substitutions: absent / [finding]

Physical or live proof required:
- [clause] → [exact observation the user must make]

Unresolved skips and risks:
- [item, or none]
```

## When To Apply

**ALWAYS before:**
- ANY variation of success/completion claims
- ANY expression of satisfaction
- ANY positive statement about work state
- Committing, PR creation, task completion
- Integrating a worker's output
- Moving to next task
- Delegating to agents

**Rule applies to:**
- Exact phrases
- Paraphrases and synonyms
- Implications of success
- ANY communication suggesting completion/correctness
