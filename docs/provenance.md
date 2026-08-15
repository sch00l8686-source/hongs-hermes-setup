# Provenance and Source of Truth

## `hongs-hermes-setup` is canonical

This repository is the canonical, version-controlled source of truth for the global
agent harness: the Hermes `SOUL.md` policy, the global Claude and Codex instruction
files, and the managed skill set.

Every intentional change to harness policy is made **here first**, reviewed here, and
only then applied outward to the live runtime.

## Live Hermes is an applied runtime, not a source

`<LOCAL-APP-DATA>/hermes` (and the global `~/.claude` and `~/.codex`
instruction files) are **applied runtime state**. They are the destination of an
install/apply step, not an authoring location.

Consequences:

- The live roots are treated as read-only by this repository's tooling and by any
  agent performing maintenance on the harness.
- Editing a live file directly creates undocumented drift: the change exists on one
  machine, has no review history, and will be silently reverted the next time the
  canonical baseline is applied.
- If a live file has drifted, the fix is to reconcile the change back into
  `baseline/` under review — not to bless the drifted runtime as the new truth.

## Baseline layout

| Path | Contents |
| --- | --- |
| `baseline/hermes/SOUL.md` | Byte-exact snapshot of the live Hermes `SOUL.md` |
| `baseline/skills/` | Byte-exact snapshot of the managed skill directories, including their `references/` files |
| `baseline/agents/claude/CLAUDE.md` | Byte-exact snapshot of the global Claude instruction file |
| `baseline/agents/codex/AGENTS.md` | Byte-exact snapshot of the global Codex instruction file |
| `docs/specs/` | Approved design specifications |
| `provenance/upstream-lock.json` | Per-skill provenance record: name, baseline path, live source path, `SKILL.md` SHA-256, and source type |

The initial import in `baseline/` is a verbatim snapshot. No imported policy content
was edited during the import.

## Upstream updates require reviewed diffs

Skills recorded with `sourceType: obra-superpowers-derived` originate from the
upstream Superpowers skill set. Skills recorded with `sourceType: hong-local-custom`
are Hong-authored Hermes adapters with no upstream.

An upstream refresh is **never** a blind overwrite. The procedure is:

1. Fetch the candidate upstream version into a scratch location.
2. Diff it against the recorded `baseline/` copy for that skill.
3. Review the diff line by line, specifically identifying which hunks are upstream
   improvements and which would clobber local policy.
4. Merge deliberately, preserving local policy extensions.
5. Update the `sourceSha256` in `provenance/upstream-lock.json` in the same change.

The `sourceSha256` values exist to make this diff reviewable and to make silent
substitution detectable. A hash that no longer matches the recorded value means the
file changed outside this process, and that change must be explained before it is
accepted.

## Hong policy extensions must not be auto-overwritten

Several managed skills carry Hong-specific policy layered on top of, or entirely
independent of, upstream text — bounded-worker rules, approval and gating behaviour,
model-routing constraints, and execution-continuity guarantees.

These extensions are load-bearing. Any automation that syncs, installs, or refreshes
skills must:

- Refuse to overwrite a managed skill without a reviewed diff.
- Treat a hash mismatch as a stop condition requiring human review, not as a signal
  to re-copy.
- Never resolve a conflict by preferring upstream automatically.

Losing a Hong policy extension is a policy regression, not a merge inconvenience.

## What the installer is allowed to touch

`provenance/upstream-lock.json` records *where each managed skill came from*.
`scripts/harness_baseline.py` records *which files are managed and where each one
is installed*. The two must agree: the manifest builder compares the twenty-one
managed skill names — the twenty approved packages plus the preserved
`software-development/plan` adapter — against the provenance lock and refuses to
emit a manifest if they diverge. A skill that is not in both lists is not
installed, not hashed, and not validated.

`manifest/harness-manifest.json` is generated from that allowlist and **is
committed**, because what the installer is allowed to touch is itself provenance
and must carry review history. Each record carries `source` (always under
`baseline/`), `targetRoot` (`HermesHome`, `ClaudeHome`, or `CodexHome`),
`destination` (root-relative), and `sha256` of the source bytes. Records are
sorted by `(targetRoot, destination)` and serialised with sorted keys, so a
rebuild from unchanged sources is byte-identical. Staleness is therefore proved
absent rather than assumed: regenerate the manifest and run `git diff
--exit-code manifest/harness-manifest.json`; an empty diff is the evidence, and
a non-empty diff is a real change to the managed file set that must be reviewed
alongside the baseline change that caused it.

Because those hashes are over exact bytes, line endings are part of the
provenance contract. `.gitattributes` pins `baseline/**` and `manifest/*.json`
to `text eol=lf`, so a checkout under `core.autocrlf=true` cannot rewrite a
managed source to CRLF and invalidate every recorded hash. The checked-out
bytes, the Git blob, and the manifest agree on Windows, macOS, and Linux.

Two provenance consequences follow:

- The installer never discovers content. It copies exactly the manifest's
  records and nothing else, so an unreviewed file added under `baseline/` is not
  silently installed — the validator reports it as an unlisted file instead.
- A source whose bytes no longer match its manifest hash aborts the apply before
  any write. A hash mismatch is a stop condition requiring review, exactly as it
  is for an upstream refresh.

The graphify blocks in `baseline/agents/claude/CLAUDE.md` and
`baseline/agents/codex/AGENTS.md` are imported content with their own
provenance: the validator reads the original blocks from git revision `7b34b89`
at runtime and requires each to remain an exact substring of the current file.
Harness triggers may be added around a block; the block itself is never edited.

## The public snapshot substitutes paths in its own copy only

`provenance/upstream-lock.json` records a `liveSourcePath` for each managed
skill, and `docs/provenance.md` and `docs/specs/global-agent-harness-design.md`
name the live roots in prose. Those literals are machine-local, and they are
provenance: they record where each managed file was imported from, so the
canonical copies keep their exact bytes.

`scripts/build-public-snapshot.py` therefore rewrites them to a portable
placeholder **in the staged snapshot copy only**, and only for those three
files. The canonical files are never modified by the build, the recorded
`sourceSha256` values are unaffected, and the rewrite is an allowlist rather
than a sweep: the staged tree is rescanned afterwards, and a machine-local path
that appears in any other file fails the build closed instead of being silently
rewritten. `scripts/verify-public-snapshot.py` reports the result of that scan
categorically — the path, the pattern class, and the count, never the matched
value.

## Excluded from this repository

The baseline snapshot contains policy and skill text only. Runtime and secret-bearing
state is deliberately excluded and must never be imported: environment files, auth or
credential files, databases, session state, agent memory, logs, caches, dependency or
runtime lock files, cron definitions, and process state.
