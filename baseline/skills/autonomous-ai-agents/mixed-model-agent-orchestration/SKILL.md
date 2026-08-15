---
name: mixed-model-agent-orchestration
description: Use when mixing Hermes with external coding-agent CLIs.
version: 1.4.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [orchestration, delegation, mixed-model, claude-code, codex]
    related_skills: [hermes-agent, claude-code, codex, supervised-agent-workflow]
---

# Mixed-Model Agent Orchestration

Use one root agent to refine intent and own the final decision while calling another model family through its native coding-agent CLI for bounded execution. Independent cross-model review is an exception with a named trigger, not the default shape of the loop.

## When to Use

Use this skill when:

- the user wants Hermes to remain the root model but mix in Claude Code, Codex, OpenCode, or another agent CLI;
- subscription-backed CLI usage must remain separate from API-key billing;
- an exceptional trigger calls for a different model family to review a design or implementation;
- native Hermes `delegate_task` and external CLI agents need distinct routing rules.

Load the relevant provider skill as well, such as `claude-code` or `codex`. For Claude Code Max details and the verified probe, read `references/claude-code-subscription-routing.md`.

## Current Roles and Runtimes

| Role | Runtime | Status |
|---|---|---|
| Supervisor / integrator | Hermes root agent | active |
| Desired supervisor model | `openai-codex/gpt-5.6-terra`, `high` effort | target, not yet configured |
| Currently configured default | `openai-codex/gpt-5.6-sol`, `medium` effort | current |
| Implementation worker | Claude Code CLI `claude -p --model opus`, subscription-backed first-party route | active |
| Codex Sol reviewer | same Codex family as the current default | exceptional adjudication only |

State the current model when reporting routing. Do not describe Terra as the configured supervisor until the configuration actually changes, and do not change model configuration as a side effect of orchestration work.

The implementation route is:

```text
Claude Code CLI
→ authenticated subscription-backed first-party session
→ `claude -p --model opus`
→ canonical model/provider probe passes
```

Verified on 2026-08-10 with Claude Code CLI `2.1.226`, `authMethod: claude.ai`, `apiProvider: firstParty`, and no `ANTHROPIC_API_KEY` set. Forbidden substitutions for this route:

- Hermes native Anthropic `delegate_task` as a stand-in;
- an MoA Anthropic reference;
- automatic fallback to an Anthropic API-key route;
- enabling Extra Usage or any paid fallback;
- letting the worker make architecture, product, or release decisions;
- letting the worker edit files outside the plan, or brainstorm its own goal.

## Core Distinction

Do not conflate these two execution paths:

1. **Hermes-native delegation** — `delegate_task` uses `delegation.model` and `delegation.provider`. This is ideal for lightweight isolated workers using the configured inference provider.
2. **External coding-agent CLI** — Hermes launches `claude`, `codex`, or another CLI as a separate process. Authentication, subscription semantics, context files, tools, and session storage belong to that CLI.

A provider name such as `anthropic` in Hermes configuration is not proof that requests consume the same allowance as the Claude Code CLI. Verify the current provider documentation and the actual runtime metadata before changing delegation settings.

## Preferred Workflow

### 1. Keep one root decision-maker

The root Hermes agent:

- runs brainstorming exactly once for the work, at the root;
- clarifies constraints and success criteria;
- presents alternatives and gets design approval;
- owns the written spec and the single implementation plan of record;
- decomposes the plan into bounded tasks with complete worker messages;
- owns integration order, direct verification, and the final completion evidence;
- reconciles disagreements and decides when another model family is warranted.

Claude CLI Opus 5 workers receive approved bounded implementation messages and execute them. A worker does not re-run brainstorming, redesign the product, or choose a different route; if the approved route cannot reach the goal, it returns `GOAL_CONFLICT` and stops.

Run Opus workers in parallel only across disjoint mutable boundaries: separate write paths, separate worktrees, no shared fixture, database, lockfile, generated artifact, migration, or release target. Anything shared is serialized under Hermes.

### 2. Inspect both routing layers

Before changing anything, inspect:

- current root model and provider;
- current `delegation.*` configuration;
- external CLI installation, version, and auth status;
- the exact model the CLI resolves from an alias such as `opus` or `sonnet`.

Do not overwrite the root model or all native delegates merely to add one secondary model.

### 3. Verify subscription-backed CLI auth

Use the CLI's own status command. For Claude Code:

```bash
claude --version
claude auth status
```

Look for a successful login and the expected first-party or subscription-backed provider. Never print credential files, tokens, refresh tokens, or authorization codes.

### 4. Probe the canonical model

Aliases are convenient but not evidence. Run a minimal, tool-disabled JSON probe and inspect canonical model metadata:

```bash
claude -p 'Reply with exactly: READY' \
  --model opus \
  --effort low \
  --tools '' \
  --max-turns 1 \
  --output-format json \
  --no-session-persistence
```

Verify all of:

- command exits successfully;
- result contains the expected sentinel;
- `modelUsage` reports the intended canonical model;
- provider metadata matches the intended route.

The CLI may report an estimated `total_cost_usd` even under subscription-backed execution. Treat this as usage metadata, not proof of a separate API charge; confirm billing semantics from the current provider documentation.

### 5. Revalidate inherited implementation plans before dispatch

A previously approved plan can preserve valid product intent while its file paths, caller topology, or host architecture have gone stale. Before handing it to an external implementer:

1. Read the current project instruction files and the existing plan/spec.
2. Locate every planned symbol and caller in the current tree; inspect the actual composition root and tests, not only the plan's named paths.
3. If a named path or integration boundary is obsolete, preserve the approved behavior and constraints, but write a current-path replacement plan before implementation.
4. Do not delegate an agent to "follow the old plan" when its production caller no longer exists. That creates green tests around dead paths.
5. Put the reconciled scope, exclusions, and current paths directly in the bounded worker brief; do not make the worker infer which historical instructions still apply.

This is a preflight evidence gate, not a new user-approval gate, when the product contract stays unchanged. Escalate only if reconciling the plan exposes a real product or architecture choice.

### 6. Dispatch bounded work

Prefer print mode for one-shot tasks:

```bash
claude -p '<approved task brief>' \
  --model opus \
  --max-turns 10 \
  --allowedTools 'Read,Edit,Bash' \
  --output-format json
```

Always set the working directory. Restrict tools to what the task requires. Include:

- exact goal and acceptance criteria;
- relevant design decisions and constraints;
- paths or symbols to inspect;
- required tests or verification commands;
- explicit exclusions and YAGNI boundaries;
- requested output format;
- the `Inherited Coding Context` block from `subagent-coding-context`, explicitly subordinate to the target repository's instructions.

For read-only critique, disable writes and ask for evidence with file/line references.

### 6. Verify independently

A child agent's final message is a self-report. The root agent must inspect changed files, run the relevant tests or build, and compare the result to the approved design before declaring success. Direct root verification, not a second agent, is the default acceptance mechanism.

When an exceptional trigger does call for a second opinion, run the models independently rather than letting one see the other's conclusion first, and compare agreements, disagreements, assumptions, and missing evidence.

### 6.1 Cut off permission/planning loops early

A result that only restates a plan, inventories files, or asks for permission is **not an implementation milestone**, even if the worker says it is ready to proceed. After the first completed result or bounded observation interval, inspect `git status --short`, `git diff --stat`, required test output, and expected commits/artifacts.

- If no intended code/test change exists, stop that worker; do not repeatedly relaunch an equivalently ambiguous prompt.
- If the user already approved the bounded work, launch at most one fresh worker with an explicit "start with the first RED test; do not request permission or return a plan" directive.
- If that retry again returns no verifiable work, Hermes takes over directly or switches execution method. Do not make the user wait through further agent permission cycles.
- A CLI wrapper that remains alive after a structured result must be judged by its artifact and worktree state, then cleaned up once its state is known.

This is a progress-control rule, not a shortcut around verification: direct fallback still requires the same tests, diff review, and goal-fidelity checks, plus any exceptional review the plan declared for that boundary.

### Separate review conclusions from unavailable gates

When an exceptional review runs, a reviewer may reach a sound source/diff conclusion while its isolated worktree cannot execute a required gate because dependencies, package cache, or network access are unavailable there. Record that gate as **unavailable evidence**, not as either a candidate defect or a passing result. Require the reviewer to report the exact command and blocker, keep its worktree clean, and preserve its static findings separately. Then Hermes reruns the same gates in a dependency-equipped trusted worktree before acceptance. Do not silently substitute a blocked reviewer gate with a claimed pass, and do not discard a clean review solely because its runtime environment could not execute tests.

## Sustained Coding Projects: Plan-Scoped Implementer, Root Verification

For a multi-task implementation plan, do not treat every agent invocation as an unrelated one-shot:

- keep one Opus implementation session for one approved plan or milestone, then start a fresh session at the next plan boundary;
- keep Hermes as the only user-facing supervisor, architecture owner, and integrator;
- verify each committed task boundary directly, then issue the next planned task.

The default task loop is:

1. Hermes issues a bounded task from the approved plan, using the complete worker message the plan already contains.
2. The plan-scoped Opus implementer changes code, runs the planned checks and gates, and returns a structured report.
3. Hermes treats that report as a claim, not acceptance: it inspects `git status --short`, the actual diff, and the produced artifacts.
4. Hermes runs the changed-path allowlist check and the goal-fidelity drift checks.
5. Hermes runs the focused and integration gates itself in a dependency-equipped worktree.
6. Hermes integrates in plan order and records one combined progress account.
7. Hermes issues the next planned task, or the plan's bounded correction message if the previous one failed.

There is no default reviewer step between 5 and 6. Insert an independent reviewer only when the plan declared that boundary high risk, worker evidence conflicts and direct measurement cannot settle it, direct verification leaves a required clause materially unproven, or the user asks for one.

For bounded worker deadlines, artifact-only completion, direct fallback, and remediation of any findings, read `references/bounded-worker-evidence.md`. For explicit model-role assignments, current-versus-target supervisor models, exceptional Sol adjudication triggers, the 70% context checkpoint rule, and desktop-versus-iPad final validation, read `references/root-model-adjudication-and-context-checkpoints.md`. For the legacy full two-agent review gate — retained as a calibration baseline and as the procedure to follow when an exceptional review actually fires — read `references/plan-scoped-codex-opus-review-gate.md`.

### Honor explicit model-role assignments

Do not assume a fixed pairing of families to roles. The user's explicit role assignment wins and must be carried unchanged through prompts, report schemas, worktree names, progress labels, and scope boundaries. In the active convention, Hermes supervises and integrates, Claude CLI Opus 5 is the plan-scoped implementer, and no reviewer is assigned by default.

When the user specifies a root-model tiering policy, treat it as routing inside Hermes supervision, not as a reason to rewrite provider configuration or agent roles. Record a real escalation trigger before a one-shot higher-capability adjudication, then return to the default root model immediately.

### Supervisor / Claude-worker split

The active convention assigns Hermes to supervision and Claude Code to implementation:

1. Hermes decomposes the approved work, defines non-overlapping worker scopes, monitors process boundaries, independently verifies artifacts, and owns integration/release decisions. Hermes must not edit product-source or product-test files itself.
2. Claude Code workers make every product code and test edit. Their briefs must name allowed paths, forbidden paths, required commands, the no-commit rule (unless separately authorized), and any data/process exclusions.
3. Parallelize Claude workers only where both file ownership and runtime side effects are disjoint. Keep database migrations, live data, release swaps, and shared integration files serialized under Hermes.
4. A worker's report is evidence, not acceptance. Hermes verifies the actual diff and reruns gates. An exceptional reviewer that reaches a turn limit or returns no parseable verdict provides no approval; record it as unavailable evidence and do not claim review sign-off.
5. Hermes does not edit the product source or test files the plan assigned to a worker. When a worker fails, reissue the plan's bounded correction message to a fresh worker rather than taking over the edit.

### Context-budget checkpoints

Use the agent's actual context meter, runtime metadata, or `/context` rather than aggregate token totals. At 70% or above, stop at the next safe boundary and checkpoint before compression or a new session. The checkpoint must preserve scope, model/role, commits and diff, executed evidence, unresolved decisions, temporary resources, and the next single action. Keep it outside independent-review inputs until the review closes.

Non-interactive CLI agents may not expose a usable context percentage. Do not invent one; checkpoint at every commit, handoff, and task boundary instead. Context reset without a recoverable checkpoint is a workflow failure.

### Exceptional review is not context deprivation

When an exceptional review does fire, hide the implementer's conclusions, not the project structure. Give the reviewer:

- the approved task and acceptance criteria;
- architecture position and adjacent module interfaces;
- authoritative constraints and known failure patterns;
- base and result commits;
- production callers and required gates;
- explicit scope and YAGNI exclusions.

This prevents anchoring while still letting the reviewer detect local changes that would damage future modules.

### Exceptional reviewer edits must be isolated

If a triggered reviewer may improve code, never let it overwrite the implementer's work in place. Start from the verified implementation commit in a separate short-path worktree or branch. Require one coherent finding per commit so Hermes can accept or reject improvements independently. The reviewer does not merge; Hermes owns integration.

Keep implementer and reviewer narratives outside the repository until the independent pass is complete. If the implementer writes its self-evaluation into a progress file first, the reviewer can anchor on it even when the prompt says not to.

### Detect and recover from concurrent worktree writes

A tool warning that a sibling agent changed a file after it was read is evidence that the worktree is not exclusive. Treat it as a coordination failure, not as permission to replay a stale patch:

1. Stop edits to the affected file and re-read its complete current content plus the relevant diff.
2. Check whether the sibling change already implements part of the accepted behavior. Reconcile one coherent version rather than adding duplicate constructor parameters, switch cases, or assertions.
3. If writers are still active or scopes overlap, move the remaining bounded work to an isolated worktree or wait for an explicit handoff; do not make broad rewrites in the shared worktree.
4. A compile error from a partially changed test harness is not a valid TDD RED signal. Repair the test harness, then prove the behavioral failure and rerun the final focused and project-level gates.
5. In the final report, identify unrelated concurrent changes as separate work; do not revert them or claim them as the task's deliverable.

## Autonomous Continuation and User-Gate Discipline

Once the user approves a plan or milestone, routine progress is not a new approval gate. Continue through implementation, verification, integration, and recording without waiting for responses. If the user explicitly pre-approves routine Run actions, do not ask again for local reads/writes, tests, temporary resources, worktrees, checkpoints, or safe retries; preserve the listed escalation boundaries.

Do not interrupt an approved run merely to say what will happen next. Make the next tool call first, and report after the bounded phase is complete. In particular, avoid a sequence of long progress preambles that leaves the artifact unwritten if a response is interrupted.

Hermes should handle without user input:

- local server start/stop and temporary test data;
- builds, tests, clean-clone checks, local publishing and desktop automation;
- ordinary implementation/review disagreements that evidence can resolve;
- reversible choices inside the approved scope;
- agent retries and root-cause debugging.

Escalate only when the remaining decision involves:

- irreversible or insufficiently backed-up real user data;
- secrets, OAuth, 2FA, payments, or permission grants;
- deployment or an external side effect not already approved;
- physical-device-only observation;
- a product/scope/architecture fork that evidence cannot resolve.

For desktop-plus-mobile work, the root agent must complete all automatable desktop-app flows itself during final hands-on validation. Escalate only iPad or other physical-device behavior that cannot be observed through local automation.

### Prevent host approvals from becoming the user bottleneck

Child-agent permission flags and the Hermes host approval layer are separate. A broad user permission grant does not expand task scope or guarantee that an opaque outer terminal command will run without review.

For reversible approved work:

- establish a clean commit, isolated worktree, atomic candidate commits, and any required real-data backup first;
- prefer explicit Claude tools or a verified Codex `--add-dir` over global dangerous-bypass flags;
- prepare schemas and other launch payloads with file tools under the OS temp directory instead of embedding interpreter scripts in the terminal launch command;
- if a launch exits nonzero or reaches a turn limit, inspect commits, dirty diffs, result files, and runtime metadata before rerunning;
- salvage independently verifiable atomic work and rerun only when the missing result blocks the actual decision.

Do not pause merely to explain the next safe step. Execute the checkpoint or fallback first. The detailed procedure and Windows/MSYS path ownership rules are in `references/approval-safe-agent-runs.md`.

An agent disagreement is not itself a user gate. Hermes first reproduces the competing claims and asks only if a genuine product choice remains.

## Measured calibration and legacy baseline

The full mixed-model implementer-plus-reviewer loop was an expensive calibration baseline. It is retained as a measurement reference and as the procedure for an exceptional review, not as a routine ritual. Measure per task:

### Routing after the measured baseline

- The default for every risk level is **plan → Opus implementation → Hermes direct verification and goal-fidelity checks → Hermes fresh gates**.
- Add an **architecture preflight** before implementation when high-risk data, migration, backup, sync, shared-interface, security, or Windows-host boundary work may rest on an unmeasured plan premise. A preflight is Hermes measuring, not a reviewer agent.
- Add an **isolated patch review** only on an Exceptional Review trigger: a plan-declared high-risk boundary, conflicting worker evidence, a required clause direct verification cannot establish, or an explicit user request. Record which trigger fired.
- When a review does run, keep the implementer report out of the reviewer context; give the reviewer the approved brief, authority files, base/result commits, callers, interfaces, exclusions, and gates. Compare `B..C`, `C..O`, and `B..O` before integration.
- Documentation-only evidence correction runs the directly relevant measurement and `git diff --check`, then the full suite once at the enclosing milestone close.
- If a gate — not a reviewer agent — produced a unique defect, prevented duplicated implementation, checked a distinct environment, or exposed a state the other gates cannot create, retain that gate.
- If a CLI wrapper exits nonzero or never reports completion after artifacts appear, inspect the result file, commit, dirty diff, schema, and gates before deciding whether to retry. Wrapper status is not the artifact. For structured Codex JSONL runs, a `turn.completed` event plus a schema-valid `-o` result file can precede a stale PTY wrapper exit: parse the artifact, inspect the isolated worktree, preserve blocked gates as unavailable evidence, and terminate only the lingering wrapper rather than relaunching blindly. Keep any reviewer worktree isolated; if its sandbox cannot commit, root may apply only a byte-for-byte verified diff in the main worktree.

- input, cached-input, and output tokens by agent;
- wall time, tool calls, gate time, and rework cycles;
- implementer self-found defects;
- reviewer-only accepted findings;
- duplicate findings;
- rejected incorrect or YAGNI suggestions;
- root-only findings and user interventions;
- gates that produced unique information;
- later evidence that a saved lesson prevented recurrence.

Also count process waste: duplicate searches, repeated gates with no new signal, unused context, overly granular commits, and reports that cost more than the change.

Use risk-based routing after a measured baseline:

- **High risk** (data, migrations, backup, sync, security, shared interfaces): architecture preflight + implementation + root verification, and a plan-declared exceptional review at the specific boundary that needs it.
- **Medium risk** (multi-layer feature work): implementation + root verification.
- **Low risk**: implementation + root verification.

Change one workflow variable at a time. Prefer replacing prose reminders with cheaper enforceable guards: tests, discrimination experiments, static checks, caller counts, then packet checklist items. A guard that Hermes can run directly is preferable to another agent that re-reads the same context.

## Routing Heuristic

Use the root model for:

- user-facing brainstorming and approval gates;
- project-wide context management;
- task decomposition and final synthesis;
- verification and scope control.

Use a second model family for:

- implementation tasks where its native CLI tooling is advantageous — the standing case, currently Claude CLI Opus 5;
- an independent architecture alternative, on an exceptional trigger;
- deep review of a bounded complex change, on an exceptional trigger;
- adversarial checks for missed assumptions, on an exceptional trigger.

Do not dispatch merely to obtain more opinions, and do not attach a reviewer to each routine task. Dispatch when model diversity or parallelism has a clear decision or execution value.

## External CLI configuration isolation

A repository-scoped external CLI worker can inherit user-level configuration or instructions that are unrelated to the approved task. Treat unexpected workflow injection, CLI configuration-schema errors, or command-policy rejection as a **worker-environment problem**, not evidence against the repository code.

For a bounded Codex implementation or review:

1. Stop the affected worker only after confirming its task boundary is recoverable.
2. Inspect the isolated worktree's `HEAD`, status, and diff before reusing it. Preserve any independently verifiable atomic commit; otherwise require a clean baseline.
3. Prefer Codex's documented one-run `--ignore-user-config` for a clean retry. It suppresses user config while retaining authentication through `CODEX_HOME`; do not globally relax unsafe/custom-binary policy merely to make a worker continue. **Codex CLI 0.146+ parses this as an `exec` option:** use `codex … exec --ignore-user-config …`, not `codex --ignore-user-config … exec`.
4. Keep the repository's canonical `AGENTS.md` and the approved task brief explicit in the clean-run prompt. User-config isolation does not replace repository instructions.
5. Restrict the replacement worker to task-relevant commands and write its raw output outside the repository. Re-run gates and judge artifacts independently before accepting the retry.

Record the actual root cause and the clean retry result separately. A configuration-induced worker failure is not an application defect, and an error-free relaunch is not completion evidence by itself.

## Prior-Policy Recovery

When the user says that a model-role policy was established in earlier project work, do not infer it is absent from only the active directory's rules or the current runtime configuration.

1. Inspect the named project's original instruction hierarchy, including its active worktree root and model-routing documents.
2. Separate the **declared policy** from the **currently applied runtime configuration**, and report any drift before proposing routing changes.
3. Preserve user-assigned roles in worker prompts and routing. Do not silently replace an explicit Claude Code CLI subscription route with native Hermes delegation or MoA inference.
4. If the user wants the policy across projects, keep the role split in the global constitution and use a lightweight, index-routed knowledge reference. Do not copy a whole project policy or Vault body into every session.

## Pitfalls

- **Assuming current config is the whole policy:** a prior project can define an authoritative role split that the active directory does not load. Inspect that source before contradicting the user.
- **Changing global delegation to add one model:** this silently reroutes every native child. Keep native delegation unchanged when the desired secondary path is an external CLI.
- **Assuming an alias identifies the model:** verify `canonicalModel` or equivalent runtime metadata.
- **Repeating brainstorming in every child:** the root owns exploration; children receive approved briefs.
- **Treating CLI output as verified work:** inspect artifacts and run checks yourself.
- **Leaking auth material:** authorization codes and tokens are secrets; send them only to the active authentication process and never preserve them in skills, logs, or prompts.
- **Leaving OAuth helpers alive:** after a CLI worker finishes or an OAuth prompt is abandoned, inspect for the specific `auth add` helper process tree and terminate only that helper's top-level shell/tree; never kill the Hermes Desktop process or gateway to clean it up. Verify after termination. Process-inspection filters must not include their own complete search needle in the launched command line, or they can report the inspection process itself as a false positive.
- **Hard-coding subscription semantics:** provider plans change. Re-read current official docs before asserting which allowance or credit pool a route consumes.
- **Using unrestricted tools by default:** use the narrowest tool set that can complete the bounded task.
- **Duplicating project instructions for every agent harness:** prefer one canonical project instruction file and explicitly direct external CLI agents to read it. If a protected `AGENTS.md` or `CLAUDE.md` write is blocked, do not retry through another tool or pause an already-approved run for a compatibility shim; keep the canonical file, adapt the brief, and verify loading with a sentinel probe. Create a shim only after foreground approval.

## Completion Checklist

- [ ] Root model/provider remains as intended.
- [ ] Native delegation configuration remains intentional.
- [ ] External CLI is installed and authenticated.
- [ ] Minimal probe confirms the canonical secondary model and provider route.
- [ ] Child receives a bounded approved brief, not a fresh brainstorming mandate.
- [ ] Tool permissions and turn limits are explicit.
- [ ] Root independently verifies the returned work by diff, caller, and rerun gates.
- [ ] Goal-fidelity drift checks pass before integration.
- [ ] No reviewer was attached without a recorded Exceptional Review trigger.
- [ ] Reported supervisor model is the currently configured one, not the target one.
