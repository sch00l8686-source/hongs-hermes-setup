---
name: agent-context-efficiency
description: "Use when cutting agent token cost safely."
version: 0.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [context, tokens, prompt-size, compression, skills, toolsets, evaluation]
    related_skills: [agent-context-governance, hermes-agent]
---

# Agent Context Efficiency

Use when an agent feels verbose, expensive, slow, or context-heavy, or before adding a response-compression skill, proxy, tool, or prompt rule. Optimize only the layer demonstrated by measurement; shorter prose does not necessarily reduce provider-billed total tokens.

## When to Use

- A user reports overly detailed replies, high token cost, slow turns, or context-window pressure.
- Evaluating Caveman-style response compression, context proxies, tool-result pruning, skill catalogs, or toolset reduction.
- Designing separate low-context chat, coding, research, and release workflows.
- Do not use merely to make one requested document shorter. Apply a concise edit directly unless persistent agent behavior is under review.

## First Principle: Identify the Cost Layer

Separate these before proposing a fix.

| Layer | Typical contributors | Appropriate response |
|---|---|---|
| Output | filler, repeated context, decorative tables, long status narration | adaptive concise response policy |
| Fixed prompt | system rules, skill index, project instructions, user profile | measure and consolidate canonical rules |
| Tool schema | broad default toolsets and large tool definitions | use task-scoped/minimal toolsets or profiles |
| Turn context | history, large tool results, logs, JSON, file/web output | context compression, result pruning, targeted extraction |
| Model reasoning | provider/model behavior | model/effort evaluation; do not imply style prompts control it |

Never claim that an output-style skill compresses input context, tool schemas, files, or reasoning unless the implementation demonstrably does so.

## Procedure

1. **Measure a clean baseline.** For Hermes, run `hermes prompt-size --json` for the relevant surface. Record system prompt, skill index, memory/profile, tool-schema bytes, enabled tool count, and project-context bytes. Do not infer the largest cost from reply length alone.
2. **Classify the complaint.** Ask or infer whether the user primarily wants less reading, lower billed usage, faster latency, longer-session stability, or all of these. They can require different interventions.
3. **Audit fixed context before adding prompt text.** Check duplicate global/project rules, always-loaded instruction files, skill-index scale, and broad toolsets. Keep one canonical location for a rule; move detailed procedure/reference material out of always-on prompts.
4. **Choose the smallest reversible intervention.** Prefer an opt-in or session-scoped concise policy before global prompt edits, proxy insertion, or installation of a large skill pack.
5. **Protect clarity boundaries.** Do not compress safety warnings, irreversible confirmations, ordered multi-step procedures, material trade-offs, citations/evidence, exact commands/errors, or any response explicitly requested to be detailed.
6. **Pilot with paired real tasks.** Use representative tasks: a short question, a technical investigation, a decision with alternatives, and a tool-heavy task if relevant. Hold model, toolsets, and task intent as constant as feasible.
7. **Compare whole-run evidence.** Prefer provider-reported input/output/cache usage, latency, completion quality, and user readability over an advertised percentage or output-token estimate. Record regressions and turn off the pilot if fixed overhead exceeds benefit.
8. **Promote only proven behavior.** Put a successful concise policy in an appropriately scoped skill or profile. Keep experiment observations in a reference or handoff, not in always-loaded rules.

## Adaptive Concision Policy

A useful baseline policy is not caveman speech. It is concise professional communication:

- Lead with the answer, then only the evidence/action needed to use it.
- Omit greeting, self-narration, tool-call narration, repeated background, and non-decisive raw logs.
- Preserve the user's language and normal grammar; do not sacrifice Korean particles or legibility for English-oriented token tricks.
- Preserve exact technical terms, paths, commands, code blocks, version numbers, units, and error text.
- Use a table only when it makes a comparison easier than short bullets.
- Escalate to normal or detailed explanation when the task or user requests it.

### User-selected global default

When a user explicitly chooses concise reports as the default, a short global constitution rule is appropriate; do not install a large output-style skill solely to enforce it. Use this state-aware shape:

1. **Simple factual question:** conclusion and only the essential distinction.
2. **Routine execution/status report:** conclusion → decisive evidence/reason → next action or decision.
3. **Detail boundary:** expand when the user asks for detail, rationale, comparison, analysis, alternatives, planning, review, or documentation; also expand for creative direction, teaching, debugging diagnosis, architecture, security, data, deployment, irreversible action, approval, or an ambiguous ordered flow.

Keep the rule short. Verify it with a fresh-session concise prompt and a fresh-session explicit-detail prompt. Record the fixed-prompt byte delta, but judge success by real reply usefulness and provider usage over representative work. Treat later user feedback that a reply was too terse or too long as calibration evidence; refine the smallest relevant line rather than adding another compression framework.

## Evaluation of Third-Party Compression

Treat a third-party package as separate components, not one claim:

1. **Output-style skill:** may reduce words but usually adds fixed prompt overhead every turn.
2. **Tool-result/context compressor:** may reduce input but changes what the model sees; requires recovery, fidelity, privacy, and failure-mode review.
3. **Proxy/engine:** changes provider routing and may introduce licensing, credential, local-storage, update, and rollback boundaries.

Do not install all components because the output-style component is attractive. Verify the exact integration surface, active hooks, default activation behavior, license, and uninstall/rollback plan first.

See `references/caveman-evaluation.md` for a verified Caveman-style evaluation example and a pilot checklist.

## Delegated-Worker Cost Controls

For narrow read-only inventory or classification work, default to direct bounded inspection before dispatching an external coding worker. A delegated worker pays its own fixed prompt/cache cost, so a short task can cost more than the useful output.

When delegation is justified:

1. State the exact deliverable, maximum tool turns, budget cap, allowed tools, and prohibited side effects in the worker prompt.
2. On Windows, match the tool allowlist to the worker's actual shell tool name. Claude Code commonly uses `PowerShell` for filesystem inspection; allowing only `Bash` can consume turns on permission denials without producing evidence.
3. Start read-only reconnaissance at the lowest adequate effort and a small bounded turn count; raise limits only when the worker demonstrates a concrete missing step.
4. Treat a permission-denial/max-turn result as an orchestration configuration fault. Correct the minimal allowlist and retry once; do not broaden file, network, Git, or credential permissions.
5. Capture provider-reported cost, turns, and termination reason. Use the measurements to decide whether this task class should stay delegated.

## Hermes-Specific Notes

- Use `hermes prompt-size --json` before structural changes. It reports fresh-session fixed prompt budget offline.
- `compression` handles accumulated conversation context; it does not by itself reduce the fixed tool-schema or skills-index payload.
- Evaluate task-scoped toolsets before trying to shrink tool output: tool schemas are sent to the model and can dominate a fresh request.
- `compression.proactive_prune_*` is a separate tool-result intervention. Test it on recoverable, representative large outputs before enabling it globally.
- Change toolsets only in a new session or reset boundary to preserve prompt caching and obtain a valid A/B comparison.
- Use `hermes config set`, not direct `config.yaml` edits, for approved configuration changes.

## Pitfalls

- Adding a 1K-token “conciseness” prompt to save a few dozen output tokens can be net-negative.
- Do not apply fragments/no-hedging globally: they can erase uncertainty, ordering, and safety conditions.
- Do not use a marketing benchmark as a provider-billing forecast for unrelated workloads.
- Do not equate fewer output tokens with lower reasoning cost, lower latency, or better answers.
- Do not disable safety, verification, or evidence rules merely because they are longer; first remove duplication and scope the rule to the work that needs it.
- Do not turn an experiment into a global default without paired real-task evidence and a clear rollback.

## Verification

Before recommending a permanent change, provide:

- baseline and pilot prompt-size/toolset measurements;
- paired task evidence with model, toolsets, and relevant config held comparable;
- quality/readability review, including a safety or decision task;
- exact scope of the proposed change and how to disable or roll it back;
- a statement separating measured facts, vendor claims, and unverified extrapolation.
