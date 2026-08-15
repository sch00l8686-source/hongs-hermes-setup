---
name: using-superpowers
description: Use when starting any conversation. Check skills first.
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, ignore this skill.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## The Rule

**Invoke relevant or requested skills BEFORE any response or action** — including clarifying questions, exploring the codebase, or checking files. If it turns out wrong for the situation, you don't have to use it.

**Before entering plan mode:** if you haven't already brainstormed, invoke the brainstorming skill first.

Then announce "Using [skill] to [purpose]" and follow the skill exactly. If it has a checklist, create a todo per item.

## Skill Priority

When multiple skills apply, process skills come first — they set the approach, then implementation skills (frontend-design, etc.) carry it out. Brainstorming and systematic-debugging are Superpowers' most common process skills, but the rule holds for any of them.

- "Let's build X" → superpowers:brainstorming first, then implementation skills.
- "Fix this bug" → superpowers:systematic-debugging first, then domain skills.

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check git/files quickly" | Files lack conversation context. Check first. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

## Platform Adaptation

If your harness appears here, read its reference file for special instructions:

- Codex: `references/codex-tools.md`
- Pi: `references/pi-tools.md`
- Antigravity: `references/antigravity-tools.md`
- Hermes Agent: `references/hermes-tools.md`

## User Instructions

User instructions (CLAUDE.md, AGENTS.md, GEMINI.md, etc, direct requests) take precedence over skills, which in turn override default behavior. Only skip skill workflows or instructions when your human partner has explicitly told you to.

---

## Hong policy extension

This section is a user policy overlay on top of the upstream skill. It does not
rename or replace any upstream skill or component.

### Routing every request

Check relevant skills before any response or action — including read-only
answers, clarifying questions, file reads, and git inspection. The skill check
comes first; the work classification comes second.

Classify every request into exactly one of three routes.

```text
Read-only question or investigation
→ check relevant skills, read only what the answer needs
→ answer without changing any artifact

Exactly-one-line mechanical change
→ confirm intent in one short exchange
→ make the one-line change
→ run the focused verification

Every other artifact change
→ using-superpowers
→ brainstorming
→ written spec approval
→ writing-plans
→ written implementation plan approval
→ approved-plan execution
```

### Read-only work stays read-only

Explanation, investigation, comparison, and status checks do not produce design
docs, spec files, or plan files. Do not write a plan file for a question. Do not
edit files to "check" something.

If the investigation shows that a change is needed, stop and reclassify the
request into one of the change routes before touching anything.

### The exactly-one-line mechanical exception

A change may skip the full design and plan gate only when **every one** of these
conditions holds. They are conjunctive — one uncertain condition means full gate.

1. The actual diff is exactly one line.
2. Intent, target file, expected result, and verification method are already stated.
3. There is no product, architecture, workflow, or policy meaning to choose.
4. It changes no security, data, deployment, model-routing, or global setting.
5. It is local and reversible.
6. It needs no adjacent file, schema, or interface change.

Structural changes, global policy changes, workflow changes, and security, data,
deployment, or model-routing changes always take the full gate regardless of line
count. A two-line change takes the full gate. A one-line model-routing change
takes the full gate.

There is no other bypass. "Small", "obvious", "bounded", "quick", "trivial", and
"the user is in a hurry" are not exceptions.

### Full design and plan gate

Everything that is not read-only and not the exactly-one-line mechanical
exception goes through the full gate above. `brainstorming` owns the written spec
and its approval. `writing-plans` owns the written implementation plan and its
approval. Neither approval may be assumed, summarized, or self-granted.

### Independent sessions

A Hermes, Claude, or Codex session that starts its own work — not dispatched from
an already-approved plan — runs the full gate itself. A branch name, worktree,
handoff note, historical plan, or dormant repository code is not an approval.

### Approved worker task contract

A session that receives a complete `APPROVED_WORKER_TASK` contract is executing an
already-approved bounded task. That contract is worker context, not a new request.

A contract is complete when it carries the authoritative goal, the authoritative
runtime, the owned paths, the forbidden paths, the required changes, the
verification steps, and the final report schema.

With a complete contract:

- Do not re-run brainstorming.
- Do not re-open the design or the spec.
- Do not ask routine permission.
- Execute only the bounded scope, and only inside the owned paths.

If the contract is incomplete, or the assigned scope cannot reach the stated goal,
report `GOAL_CONFLICT` and stop. If a useful improvement falls outside the scope,
report it as a non-executing proposal and do not implement it. Do not choose an
alternative route on your own.
