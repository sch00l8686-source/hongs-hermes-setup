# Verified Governance Patterns

This reference captures reusable evidence, not project-specific secrets or live state.

## Context-size and discovery check

- Measure context files before promoting them to automatic project instructions.
- Keep the always-loaded constitution narrowly behavioral; long personal strategy belongs in a selectively read note.
- Verify behavior in a fresh global session and a fresh project-root session. A correct file on disk is not proof that the loader selected it.

## Multi-agent release pattern

1. Supervisor defines outcome, write scope, non-goals, acceptance criteria, side-effect boundary, and reporting format.
2. Implementation agent edits a bounded slice.
3. Supervisor runs environment-sensitive tests.
4. Independent reviewer examines the diff and user-facing operational guidance before expensive build/package work.
5. Supervisor runs the serial integration/package gate and independently checks the resulting artifact, hash, and live smoke.
6. Record the current release state in a handoff; promote only reusable observations to knowledge patterns.

## Shared-artifact rule

Do not parallelize commands that generate, delete, copy, or consume the same generated directory, package staging directory, lockfile, database, credential store, or live process. Parallelize only independent writers and read-only review.

## Documentation rule

When an operational command emits an authoritative value such as a network URL, direct the operator to copy that complete output. Do not ask them to reconstruct a value from a simplified hostname pattern.

## Handoff rule

Keep a short, date-stamped current snapshot at the top. Preserve prior detailed records below it as history, but state clearly that historical sections do not override the current snapshot.

## Protected instruction-file rule

If a protected instruction-file write is blocked or an approval prompt expires, stop. Do not retry through a different path. Preserve the intended content and resume only after an explicit user approval in a later foreground interaction.
