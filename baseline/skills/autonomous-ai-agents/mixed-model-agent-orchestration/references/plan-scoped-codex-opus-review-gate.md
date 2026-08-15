# Plan-Scoped Codex + Task-Scoped Opus Review Gate

**Status: legacy calibration baseline and exceptional-review procedure.** This two-agent implementer-plus-reviewer gate is no longer the default loop. The default is plan → Opus implementation → Hermes direct verification and goal-fidelity checks → Hermes fresh gates, with no reviewer attached per task.

Use this reference in two cases only:

1. An Exceptional Review trigger fired — a plan-declared high-risk boundary, conflicting worker evidence, a required goal clause direct verification cannot establish, or an explicit user request. Follow the packet, worktree, and three-diff procedure below for that one bounded review.
2. You are calibrating: comparing measured cost and unique-finding value of the full loop against direct root verification.

The implementer/reviewer family assignment below is the historical convention. The active convention is Hermes supervising and Claude CLI Opus 5 implementing; carry whichever roles the user actually assigned.

## Proven lifecycle

- **Hermes session:** persists across the project; owns architecture, task issuance, integration, final gates, learning promotion, and user escalation.
- **Implementer session:** persists for one approved plan or milestone. Capture its thread or session ID on the first task and resume it after Hermes closes each task boundary.
- **Exceptional reviewer session:** fresh for each triggered review and re-review. It starts from the verified implementation commit in an isolated worktree. It is created only when a trigger is recorded, not once per task.

Do not create a persistent state file until session recovery actually fails. Within one Hermes session, keep the Codex thread ID in session state. At recovery, compare the CLI session's working directory and commit with live Git before resuming.

## Authority order

1. Live Git branch, commit, status, code, and command output
2. Approved task brief and plan
3. Current handoff
4. Failure-pattern/checklist documents
5. Historical progress and retired handoffs

A handoff that hard-codes `HEAD` becomes stale as soon as the handoff itself is committed. Prefer “last accepted implementation commit” and require live `git rev-parse HEAD` at session start.

## One canonical instruction file

Avoid maintaining parallel full copies of project rules for Codex, Claude Code, and Hermes. Keep one canonical file (for example `AGENTS.md`) and have every bounded external-CLI brief explicitly read it. A minimal harness-specific shim is optional, not a prerequisite.

When a protected instruction-file write needs foreground approval:

1. never retry the blocked write through another tool or path;
2. do not stall an already-approved autonomous run merely to add the shim;
3. continue with the existing canonical file named explicitly in the child brief;
4. verify actual loading with a low-effort sentinel probe before real work.

Example probes:

```bash
codex -m gpt-5.6-sol -s read-only -a never exec --json \
  'Read AGENTS.md and return its first-ranked authority source exactly.'

claude -p --model opus --effort low --permission-mode dontAsk \
  --allowedTools 'Read' --output-format json --no-session-persistence \
  'Read AGENTS.md and return its first-ranked authority source exactly.'
```

Inspect the returned text and canonical model/provider metadata. The proof is the sentinel content, not the existence of a second instruction filename.

## Implementer packet

Include:

- exact plan and task boundary;
- acceptance criteria;
- files/symbols and production callers to inspect;
- required discrimination experiment;
- target and full gates;
- commit message;
- explicit files the implementer must not edit (especially progress and handoff before review);
- structured output schema.

A useful result schema separates:

- `status`, `baseline_commit`, `result_commit`, `changed_files`;
- measured claims with evidence;
- inferences and unresolved decisions;
- failures as symptom/root cause/resolution/guard;
- gates as command/exit code/summary.

## Reviewer packet

Use this only for a triggered exceptional review. Provide structure but hide the implementer's narrative:

- approved task and architecture position;
- base and implementation commits;
- adjacent/future interfaces;
- global constraints and known failure patterns;
- production callers;
- target/full gates;
- allowed scope and YAGNI exclusions.

Do not put the implementer's report into a committed progress file before review. Prompt-level “do not read it” is weaker than making it unavailable.

Reviewer finding fields should include:

- severity and category;
- measured fact and impact;
- proposed change and affected files;
- production callers;
- verification;
- future-module impact;
- YAGNI assessment;
- atomic candidate commit.

## Verified Codex CLI forms

First task:

```bash
codex -m gpt-5.6-sol -s workspace-write -a never exec \
  --json \
  --output-schema path/to/codex-result.schema.json \
  -o path/to/result.json \
  'bounded task brief'
```

Resume the same plan session. `exec resume` options precede the session ID:

```bash
codex -m gpt-5.6-sol -s workspace-write -a never exec resume \
  --json \
  --output-schema path/to/codex-result.schema.json \
  -o path/to/result.json \
  "$CODEX_THREAD_ID" \
  'next bounded task brief'
```

Use `--json` to retain thread and token-usage events. Store raw CLI outputs outside the repository; write only verified summaries into project progress.

## Isolated reviewer edit pass

Run this only after recording an Exceptional Review trigger. Create a short-path worktree from the verified implementation commit:

```bash
C=$(git rev-parse HEAD)
git worktree add -b review/task-opus /c/project-opus-review "$C"
```

Run Claude Code from that worktree with an explicit model, structured output, and bounded tools:

```bash
schema=$(python -c "import json; print(json.dumps(json.load(open('path/to/opus-review.schema.json', encoding='utf-8')), separators=(',',':')))" )
claude -p \
  --model opus \
  --effort high \
  --permission-mode acceptEdits \
  --allowedTools 'Read,Edit,Write,Bash(git *),Bash(npx *),Bash(npm *),Bash(dotnet *)' \
  --output-format json \
  --json-schema "$schema" \
  --no-session-persistence \
  'independent architecture-aware review brief'
```

Verify runtime metadata resolves to the intended canonical model. Tool permissions should be narrowed to the project's actual gates.

## Three-diff integration

Applies when an exceptional reviewer produced candidate commits. Let `B` be the pre-task base, `C` the implementation commit, and `O` the reviewer candidate tip.

```bash
git diff "$B".."$C"   # implementer work
git diff "$C".."$O"   # reviewer improvement delta
git diff "$B".."$O"   # complete candidate
```

Classify every reviewer finding as:

- unique accepted;
- duplicate;
- incorrect;
- YAGNI;
- process-only.

Cherry-pick only accepted atomic commits. Rerun target and full gates in the main worktree. Delete the temporary review branch only after all candidates are classified, the accepted state is recorded, and main-worktree gates are green.

## Progress and learning timing

After independent review, Hermes writes one combined account containing:

- base, implementation, reviewer candidate, and final commits;
- measured differences and gate outputs;
- accepted/rejected findings and reasons;
- token/time/rework metrics;
- the cheapest durable recurrence guard.

Promote information by layer:

- project-specific event and raw summary → project progress;
- cross-project judgment → knowledge-base pattern;
- proven repeatable procedure → orchestration skill.

Do not store transient commit IDs, session IDs, token counts, or task progress in persistent user memory.

## Autonomous user boundary

After plan approval, continue automatically through ordinary implementation, review, integration, verification, and recording. Do not stop after a progress preamble or ask “continue?” between tasks.

Escalate only real-data danger, secrets/auth, deployment/external side effects, physical-device-only observations, or a product/architecture fork that evidence cannot resolve.
