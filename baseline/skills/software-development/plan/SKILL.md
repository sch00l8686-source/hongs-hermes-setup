---
name: plan
description: Non-executing adapter for /plan and plan-only requests; routes to the design and planning gates.
version: 3.0.0
author: Hermes Agent (writing-craft adapted from obra/superpowers)
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [planning, plan-mode, implementation, workflow, design, documentation]
    related_skills: [brainstorming, writing-plans, executing-plans]
---

# Plan Mode

Use this skill when the user runs `/plan` or explicitly asks for a plan instead of
execution. It is an adapter: it decides where the request belongs and hands off.
It does not define planning standards of its own.

## Core behavior

For this turn, you are planning only.

- Do not implement code.
- Do not edit project files except the plan or spec document.
- Do not run mutating terminal commands, commit, push, or perform external actions.
- You may inspect the repo or other context with read-only commands and tools.

## Routing

1. **Read-only question.** If the request is really "explain" or "investigate",
   answer it. Do not produce a plan document for a question.

2. **Nontrivial change without an approved spec.** If the change is anything
   beyond the exactly-one-line mechanical exception defined in
   `using-superpowers`, and brainstorming has not produced a spec the user
   approved, go to `brainstorming` first. Say so plainly:

   > "This needs a design before a plan. Starting with brainstorming; the implementation plan comes after you approve the spec."

   Do not write an implementation plan on top of an unapproved design.

3. **Approved spec in hand.** Invoke `writing-plans` and write the plan to its
   specification. `writing-plans` is the single authority for plan contents —
   required sections, Goal Fidelity Lock, task structure, worker messages,
   verification, gates, rollback, and the requirement-to-evidence matrix. Do not
   restate or vary those requirements here.

4. **Exactly-one-line mechanical change.** No plan document. Confirm the intent,
   make the change, run the focused verification.

## Save location

Default to the location `writing-plans` specifies:
`docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`.

Use `.hermes/plans/YYYY-MM-DD_HHMMSS-<slug>.md` only when the user or the runtime
explicitly asks for it. If the runtime provides a specific target path, use that
exact path. A project-approved `docs/superpowers/` location stays valid and is not
overridden by this skill.

Paths are relative to the active working directory or backend workspace. Hermes
file tools are backend-aware, so a relative path keeps the document with the
workspace on local, docker, ssh, modal, and daytona backends.

## Interaction style

- If no explicit instruction accompanies `/plan`, infer the task from the current
  conversation context.
- If the request is genuinely underspecified, ask a brief clarifying question
  instead of guessing — or route to `brainstorming`, which is built for it.
- After saving, reply briefly with what you planned and the saved path.

## Handoff

A written plan is not an execution contract until the user approves it. After
approval, execution follows `executing-plans` and the plan's own dispatch,
correction, and verification steps. Do not offer an execution mode whose value is
per-task independent review.

---

## Hong policy extension

This section is a user policy overlay. The skill name is unchanged.

- This skill executes nothing. It routes.
- Planning standards live in `writing-plans`. Duplicating them here is how the two
  drift apart.
- Missing brainstorming is not something a plan can compensate for. Route there
  first.
- A useful idea outside the requested scope is reported as a non-executing
  proposal, not folded into the plan.
