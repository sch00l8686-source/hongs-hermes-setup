# Approval-safe external agent runs

Use this when Hermes launches Codex or Claude Code inside an approved development workflow and routine permission prompts risk making the user the bottleneck.

## Keep three boundaries separate

1. **Task scope** — the approved plan and explicit exclusions define what may change.
2. **Child CLI permissions** — Codex sandbox roots and Claude `--allowedTools` define what the child process can do.
3. **Host approval policy** — Hermes may independently inspect the outer terminal command. Child permissions do not bypass this layer.

Broad user-granted read/write permission does not expand task scope and is not a reason to disable every safety layer.

## Safety-first autonomous pattern

Before dispatch:

- require a clean baseline commit;
- use a dedicated branch or isolated worktree for reviewer edits;
- keep real data out of test runs, or create and verify a backup before mutation;
- define exact files, commands, exclusions, and the commit boundary;
- prefer atomic candidate commits so Hermes can accept or reject findings independently.

Choose the narrowest non-interactive permissions that complete the task:

- Claude: explicit `Read`, `Edit`, `Write`, `Glob`, `Grep`, and bounded `Bash(...)` grants;
- Codex linked worktree: keep `workspace-write` and add only the verified `.git/worktrees/<name>` directory with `--add-dir` when commits need the external lock file;
- avoid global dangerous-bypass flags for routine work.

## Keep the outer terminal command simple

Host approval scanners may flag an outer command even when the child CLI is correctly configured. Avoid bundling setup scripts, destructive cleanup, and the agent launch into one opaque command.

For structured output:

1. Keep the canonical JSON Schema in the repository.
2. Prepare any CLI-compatibility copy with file tools under the OS temp directory.
3. For Claude Code versions that reject Draft metadata, strip only the top-level `$schema` key from that temporary copy.
4. Let Bash read the prepared one-line file; do not generate it with an inline interpreter inside the launch command.
5. Send native Windows paths (`C:/...`) to native CLI options such as Codex `-o`; use MSYS paths (`/c/...`) only for Bash-owned redirection or `tee`.

This reduces approval prompts without weakening scope or data safety.

## Salvage artifacts before retrying

A nonzero exit, `max_turns`, or missing final narrative does not prove the agent produced nothing. Before spending tokens on a rerun, inspect:

- worktree status and current HEAD;
- new commits and their atomic diffs;
- uncommitted experimental changes;
- structured-output/result files and runtime metadata;
- the exact gates already run.

Then:

1. restore temporary discrimination edits exactly;
2. reject or complete any partial dirty delta rather than mixing it into an accepted commit;
3. independently run the candidate's discrimination experiment and relevant gates;
4. selectively integrate verified atomic commits;
5. rerun the agent only when the artifact is incomplete and cannot be verified without its missing reasoning.

Do not rerun merely to obtain a prettier report when the commit, diff, tests, and runtime metadata already answer the decision.

## User escalation boundary

Continue automatically through safe alternatives, backups, worktrees, commits, tests, and cleanup. Escalate only for:

- secrets, OAuth, 2FA, payment, or external account access;
- irreversible or insufficiently backed-up real-data operations;
- deployment or other unapproved external side effects;
- physical-device-only observations;
- product or architecture choices that evidence cannot resolve.

A host approval prompt for an otherwise reversible local action is a signal to simplify or scope the command, not automatically a reason to stop the approved workflow.