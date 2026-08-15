# manifest/

`harness-manifest.json` is generated from the explicit allowlist in
`scripts/harness_baseline.py` and **is committed**. It is the reviewed record of
exactly which files the installer may write and where, so a change to the
managed file set shows up as a reviewable diff instead of appearing silently at
apply time.

Generated *and* tracked is only safe because the output is deterministic:
records are sorted by `(targetRoot, destination)` and serialised with sorted
keys, so a rebuild from unchanged sources is byte-identical.

Regenerate it, then prove it did not drift:

```text
python scripts/build-harness-manifest.py --root <repo> --output manifest/harness-manifest.json
git diff --exit-code manifest/harness-manifest.json
```

An empty `git diff` means the tracked manifest still matches `baseline/`. A
non-empty one is a real change to the managed file set and must be reviewed and
committed with the baseline change that caused it.

Confirm the tracked file is current without rewriting it:

```text
python scripts/build-harness-manifest.py --root <repo> --output manifest/harness-manifest.json --check
```
