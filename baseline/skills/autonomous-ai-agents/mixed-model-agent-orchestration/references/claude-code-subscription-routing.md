# Claude Code Subscription Routing Reference

## Purpose

Use this reference when Hermes should remain the root agent while Claude Opus runs through an already authenticated Claude Code subscription session. Re-check current official documentation because subscription and credit semantics can change.

## Verified Environment Pattern

Validated on 2026-08-10 with:

- Claude Code CLI `2.1.226`
- `claude auth status` reporting `loggedIn: true`, `authMethod: claude.ai`, and `apiProvider: firstParty`
- a tool-disabled print-mode probe resolving `--model opus` to `canonicalModel: claude-opus-5`
- probe result returning `provider: firstParty` and `subtype: success`

No API key was required for this CLI probe.

## Minimal Safe Probe

```bash
claude -p 'Reply with exactly: CLAUDE_OPUS_SUBAGENT_READY' \
  --model opus \
  --effort low \
  --tools '' \
  --max-turns 1 \
  --output-format json \
  --no-session-persistence
```

Expected evidence in the JSON result:

```text
result: CLAUDE_OPUS_SUBAGENT_READY
modelUsage.<entry>.canonicalModel: claude-opus-5
modelUsage.<entry>.provider: firstParty
subtype: success
```

Do not rely on the alias alone. Canonical runtime metadata is the proof.

## Hermes Native Anthropic vs Claude Code CLI

These are separate routes:

| Route | Invocation | Auth/config owner | Intended use |
|---|---|---|---|
| Hermes native child | `delegate_task` with `delegation.provider: anthropic` | Hermes provider runtime | Native Hermes subagent using Anthropic inference |
| Claude Code child process | `claude -p ... --model opus` | Claude Code CLI | Subscription-authenticated Claude coding agent |

As documented in the Hermes provider guide on 2026-08-10, native Anthropic OAuth could have plan/extra-credit semantics different from the base Claude Code allowance. This is a time-sensitive provider fact: verify the current docs before configuring native Anthropic delegation.

If the user's goal is specifically to consume the Claude Code subscription route, do not set global `delegation.provider: anthropic` as a substitute. Keep the root and native delegation settings intentional and invoke the Claude CLI explicitly.

When the assigned route is the subscription-backed `claude -p --model opus` CLI, these are forbidden substitutions, not fallbacks:

- Hermes native Anthropic `delegate_task` standing in for the CLI worker;
- an MoA or aggregator Anthropic reference standing in for it;
- automatic failover to an Anthropic API-key route;
- enabling Extra Usage or any paid fallback to keep a run alive;
- setting `ANTHROPIC_API_KEY` to work around an auth or quota failure.

If the route is unavailable, report it as a blocked route with the probe evidence. Do not silently reach the same model over different billing.

## Task Invocation Pattern

For a bounded implementation task:

```bash
claude -p '<task brief>' \
  --model opus \
  --effort high \
  --max-turns 10 \
  --allowedTools 'Read,Edit,Bash' \
  --output-format json
```

For an exceptional independent read-only review — only after recording the trigger, never once per task:

```bash
claude -p '<review brief; require file:line evidence>' \
  --model opus \
  --effort high \
  --max-turns 5 \
  --allowedTools 'Read,Bash(git diff *)' \
  --output-format json \
  --no-session-persistence
```

Set the command working directory to the project root so Claude Code loads the intended `CLAUDE.md` and project rules.

## Prompt Contract

A root-to-Claude brief should include:

1. approved task goal;
2. acceptance criteria;
3. exact scope and exclusions;
4. relevant files or symbols;
5. required tests and verification commands;
6. whether edits are allowed;
7. requested response schema or report format.

Do not ask the child to re-run the user's full brainstorming process. The root agent owns design exploration and approval; the child executes or reviews the approved slice.

## Security Notes

- Never save or reproduce OAuth authorization codes, access tokens, refresh tokens, or credential-file contents.
- If an interactive OAuth process is active, send a one-time code only to that process.
- Prefer `claude auth status` over reading credential stores.
- Do not put subscription tokens in project files, skill references, shell history, or task prompts.

## Verification Notes

Claude's JSON may include `total_cost_usd` even when the request used a subscription-backed first-party session. Treat that field as estimated usage accounting unless the current official provider documentation states otherwise.

After a coding invocation, independently inspect the filesystem and run tests. The CLI's `subtype: success` proves the agent process completed; it does not prove the implementation satisfies the project requirements.
