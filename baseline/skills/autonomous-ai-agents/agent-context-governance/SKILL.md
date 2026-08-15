---
name: agent-context-governance
description: Separate agent rules, knowledge, state, and evidence.
version: 0.1.0
author: HongGyu, Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [hermes, context, governance, knowledge-management]
    related_skills: [hermes-agent, llm-wiki]
---

# Agent Context Governance

Use this skill to organize how Hermes and external agents receive durable rules, project constraints, procedures, knowledge, handoffs, and evidence. It prevents two failures: loading a whole vault every session, and copying the same rule into multiple files until no one knows the canonical version.

## When to Use

- Designing or changing `SOUL.md`, project context files, skills, handoffs, or an agent knowledge base.
- Deciding what a multi-agent project should remember across sessions.
- Migrating a large `CLAUDE.md`/`AGENTS.md` into responsibility-based layers.
- Do not use for a one-off project status update with no durable governance decision.

## Context Ownership Model

Assign each fact to exactly one canonical layer.

| Layer | Holds | Load policy |
|---|---|---|
| Global constitution | stable collaboration stance, decision rights, safety posture | always loaded; keep short |
| Project contract | ownership, architecture boundaries, project-specific commands and constraints | only in the relevant project |
| Skill | repeatable procedure with triggers and verification | load for the task class |
| Knowledge base | source-backed concepts and reusable success/failure patterns | enter via index and links only when relevant |
| Handoff | current state, artifact locations, rollback, next action, open physical gate | read only when resuming that project |
| Evidence | test output, build logs, review findings, artifact hashes | inspect only to verify or investigate |

Do not duplicate a rule across layers. If the same guidance is needed in two scopes, make one layer canonical and have the other point to it.

## Project Context Files

1. Check the agent's documented discovery order before moving rules. Different agents do not necessarily merge parent and child files. For Hermes in a Git repository, `AGENTS.md` files form a root-to-working-directory chain; align directory-specific rules to that file type when they must be progressively loaded. Hermes selects one project context *type* per session by priority, so do not split interdependent rules between `AGENTS.md` and `CLAUDE.md`.
2. Keep a project context file below its loader's size limit. A large file that is truncated is worse than a smaller explicit contract.
3. Preserve long human context in a normal note and load it only for tasks that require it; do not put biography, long-term strategy, or historical state in always-loaded instructions.
4. Keep subdirectory rules only for rules that change in that directory, such as immutable source material or output audience.
5. Before replacing a protected instruction file, create a readable preservation copy and obtain the required explicit approval. Treat the host's protected-file confirmation as a separate execution gate: prior plan/execution approval does not substitute for a live confirmation prompt. If that prompt expires, stop the migration at a clean boundary, report the exact blocked file, and request a fresh confirmation; do not bypass it with another write path.
6. Start a fresh agent session in the root and a non-project directory to verify both project and global behavior after the change.

## Knowledge Promotion Rules

Choose the cheapest durable guard that prevents the same failure.

| Failure class | Permanent location |
|---|---|
| code can regress | regression test |
| operator can make a repeatable mistake | README or runbook |
| agent repeatedly misses a decision | skill |
| security/data boundary can fail | code guard plus test |
| project-specific current state | handoff |
| reusable, evidence-backed judgment | knowledge-base pattern |

Do not promote a one-off observation into an always-loaded rule unless its first failure can cause data loss, credential exposure, release corruption, or similarly high cost.

## Migration Procedure

1. **Measure.** Read existing rules, current handoffs, knowledge index, and the active agent configuration. Record file sizes and discovery boundaries.
2. **Map.** For every existing section, mark one destination: constitution, project contract, skill, knowledge pattern, handoff, or archive. Mark duplicates and dependencies.
3. **Preserve.** Copy long human context before replacing an instruction file. Never move or modify immutable raw sources.
4. **Apply in dependency order.** Global constitution first, then reusable skill, then project contract, then knowledge/handoff navigation.
5. **Verify.** Test an isolated global session, a project-root session, and the knowledge index/links. Check context sizes and diff hygiene.
6. **Record.** Put current migration status in a handoff and reusable conclusions in the knowledge base. Do not turn the migration log itself into permanent prompt material.

## Resuming From Handoffs Without Goal Drift

A handoff is a state carrier, not permission for its newest finding to redefine the user's task.

1. Reconstruct the **primary observable goal** from the user's request and the handoff's Goal Lock before summarizing remaining work.
2. Classify each recorded item explicitly:
   - primary-goal implementation;
   - verification still required for that goal;
   - secondary review finding;
   - integration/release/operations work;
   - optional follow-up.
3. Report status with separate lifecycle labels. Do not collapse these into “done”:
   - implemented on a candidate branch;
   - focused tests passed;
   - independently accepted;
   - integrated into the main branch;
   - deployed to the runtime the user uses;
   - physically observed by the user.
4. If a reviewer found an adjacent defect, preserve it as a named follow-up unless it directly prevents the primary observable goal. Do not present that finding as though it were the user's original request.
5. Before proposing post-validation work, measure branch containment, integration state, deployment path, and rollback boundary. A successful physical check on a feature branch does not by itself make the change mainline or released.
6. When the user corrects the goal interpretation, restate the primary goal in their observable terms and rebuild the remaining-work list from that goal instead of defending the handoff wording.

## Pitfalls

- A global `AGENTS.md` in a home directory is not necessarily a global project rule. Use the agent's supported global constitution mechanism.
- A project context file and a skill are not interchangeable: the former describes a project; the latter describes a repeatable action.
- A handoff is intentionally stale after the next milestone. Do not treat it as a policy document.
- **Latest-finding bias:** the last review defect is often the most detailed text in a handoff, but it is not automatically the primary goal or next user-visible milestone.
- **Lifecycle collapse:** “implemented,” “tested,” “accepted,” “integrated,” “deployed,” and “physically verified” are different claims requiring different evidence.
- Do not create a new schema, tag, folder, or skill merely because a classification seems elegant. Promote only after use demonstrates a missing boundary.
- Do not assume an external coding agent reads the same instruction hierarchy as Hermes. Provide a short compatibility shim only when the target agent actually needs it.

## Verification

Before declaring governance work complete, confirm:

- exactly one canonical location exists for each durable rule;
- global and project contexts are within documented size limits;
- a fresh global session and a fresh project session exhibit the intended behavior;
- relevant knowledge pages are indexed and linked;
- handoff top sections distinguish current facts from historical records;
- no secrets, credential identities, or transient runtime values were copied into permanent rules.

## Reference

- See `references/verified-governance-patterns.md` for concise field evidence and a migration checklist derived from a Windows installer, release, and multi-agent delivery.
- See `references/observable-runtime-contracts.md` when optional knowledge routing, per-turn health heartbeats, privacy-bounded audit logs, language-aware alias matching, model fail-closed behavior, or one-time activation exceptions are involved.
