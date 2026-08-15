# Version

0.1.0

## Scope of this version

Phase 1 harness source only: the managed baseline, the fail-closed static policy
validator, the deterministic managed-file manifest, the rollback-safe installer,
and the read-only behaviour probes.

## Versioning rule

The version tracks the harness *baseline and tooling contract*, not the runtime
it is applied to.

- **Patch** — wording or tooling fixes that change no policy rule and no managed
  file set.
- **Minor** — a new policy rule, a new validator rule id, or a change to the
  managed file set or manifest schema.
- **Major** — a change to the installer's destination contract or to the
  approved skill set.

`manifest/harness-manifest.json` is generated *and* tracked. It is the reviewed
record of the managed file set, so a change to it is a reviewable diff rather
than a silent apply-time surprise. Staleness is prevented by determinism, not by
omission: regenerate it and run `git diff --exit-code
manifest/harness-manifest.json`. An empty diff proves it still matches
`baseline/`; a non-empty diff is a real managed-file-set change and, under the
rule above, at least a minor version bump.

That determinism is platform-independent only because `.gitattributes` pins
`baseline/**` and `manifest/*.json` to `text eol=lf`: the recorded hashes are
over exact bytes, so a CRLF checkout would otherwise produce a diff that reflects
the checkout rather than a policy change.
