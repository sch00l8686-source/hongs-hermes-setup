# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

## Global design and plan harness

Before changing an artifact, load and follow relevant process skills.

Only a truly mechanical, reversible, exact one-line correction may bypass the full gate, and only when intent, target, expected result, and verification are already explicit. Structural, global-policy, workflow, security, data, deployment, and model-routing changes always use the full gate regardless of line count.

For every other artifact change:
1. use `using-superpowers` and `brainstorming`;
2. obtain approval for a written design/spec;
3. use `writing-plans` to produce a complete implementation plan, including worker messages and Goal Fidelity;
4. obtain approval for the written plan before implementation.

A complete `APPROVED_WORKER_TASK` issued by Hermes is different: execute that bounded contract without repeating brainstorming. If the contract lacks exact goal, runtime, scope, forbidden substitutions, paths, and verification, return `MISSING_APPROVED_WORKER_CONTRACT` instead of guessing.

Do not implement unrequested improvements. Surface material risks, alternatives, and improvements as non-executing proposals with trade-offs and reversibility.

## Goal anchor and cost ceilings

This section is the counterweight to the design and plan harness above. The harness prevents unauthorized work; this section prevents approved work from multiplying past its purpose. Where the two conflict, this section governs process weight and the harness governs authorization.

- Every spec and plan states, in its first lines, the user-visible end deliverable of the current effort and whether this work directly advances it. Work that does not directly advance it is meta-work: it must be labeled as meta-work and separately approved, and is never proposed as the default or recommended option.
- Gates are risk-tiered. The full gate applies only to live-state, irreversible, security, credential, data-loss, or publication changes. Documentation, tests, and fully reversible repository work use a one-page spec and a single approval.
- Per-phase ceilings: at most 12 approval questions and at most 10 combined pages of spec plus plan. On reaching a ceiling, stop and ask one question — continue as scoped, or cut scope — instead of asking the next boundary question.
- Residual-risk lever: when an exception path or edge case is found, always present "record it as an accepted risk and proceed" as an option alongside closing it. Closing every path is not the default.
- Phases are cut by user-visible deliverables, not by infrastructure layers. Ship the smallest end-to-end slice of the stated goal first; hardening and generalization come after it exists. The stated end goal is never listed as a non-goal of the phase sequence that exists to reach it.

## Independent session Vault and authority boundary

This section governs every Claude session that is not executing a complete `APPROVED_WORKER_TASK`.

- Read the Vault only when the user explicitly requests it; never open it on your own initiative.
- Start a requested Vault read at `wiki/index.md` and follow only the links that answer the question.
- Never read `raw/`, and never write into the Vault.
- Do not run automatic domain routing, and never write the Hermes routing JSONL log.
- State whether Vault evidence was used, and name the source pages when it was.
- This session cannot issue, approve, or reapprove an `APPROVED_WORKER_TASK`, infer user approval, or act with Hermes supervisor authority.
