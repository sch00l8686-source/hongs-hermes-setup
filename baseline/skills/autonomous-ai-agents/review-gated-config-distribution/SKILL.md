---
name: review-gated-config-distribution
description: Publish reviewed configs safely between environments.
version: 0.2.0
author: 박홍규, Hermes Agent
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [git, security, configuration, release]
    related_skills: []
---

# Review-Gated Configuration Distribution

Use this skill to distribute a small, reviewed configuration baseline from one environment to another through Git without treating an entire user home, credential store, or knowledge vault as synchronizable. It governs the release boundary, not an application-specific installer.

## When to Use

- Publishing a reviewed agent/tool configuration from home to a work machine.
- Building a consumer bootstrap that installs selected policy files or skills.
- Designing a pull/review/apply workflow for machine-local tooling.
- Do not use to sync a complete user profile, credentials, runtime state, or an existing vault with unknown contents.

## Trust Boundaries

1. Create a dedicated baseline repository outside the source application home and outside any content vault.
2. Treat credentials, auth state, sessions, logs, databases, caches, machine paths, provider/channel configuration, and company data as never-sync by default.
3. Keep knowledge/content-vault publication separate from configuration publication. A request to publish “the vault setup” requires its own inventory, denylist, review, and approval.
4. Make the producer a reviewed publisher and the consumer pull-only. Never silently push consumer discoveries upstream.

## Repository Contract

The repository should contain only:

- human-readable trust-boundary and rollback documentation;
- a fixed source manifest with exact managed relative paths and content hashes;
- reviewed baseline policy/skill files;
- an installer/verifier with an intentionally narrow write boundary.

The manifest must fail closed: reject unknown keys, duplicate IDs/destinations, invalid hashes, unapproved components, path traversal, drive/UNC/device forms, Windows reserved names, and any configuration entry not compiled into the installer’s explicit policy.

## Snapshot Distribution and Revision Semantics

When consumers must receive changes immediately after a Git push, keep **Git as the sole source of truth** and make every other delivery surface a one-way mirror:

```text
reviewed Git push → CI publishes immutable snapshot + metadata → download service/storage → pull-only consumers
```

- Do not provide a second direct-upload path to Storage/DB; two writable publishers create an unresolvable "latest" conflict.
- A human release version (for example `v1.2.0`) and a machine revision are separate fields. Use an immutable Git commit SHA or an archive-content hash as `revision`.
- Consumers compare `revision`, not just `version`: unversioned pushes must still report an update when the revision changes.
- Publish a small manifest alongside each snapshot, containing at least `version`, `revision`, `publishedAt`, and an immutable download identifier/hash. A missing local manifest means initial installation is required.
- If a browser is the consumer UI, it can download a snapshot but cannot silently read or install arbitrary local folders. Local-state comparison requires either user-granted folder/file access or a separately installed local helper. Do not represent browser download as successful installation.

## Release and Consumer Procedure

1. **Inventory before mutation.** Inspect repository status, branch, remote, staged paths, tracked paths, manifest entries, and source hashes. Do not inspect secret contents.
   - Completion: one repository and an exact candidate file list are identified.
2. **Verify locally.** Parse installer scripts, validate the full manifest, and run a dry-run that makes no writes or network calls.
   - Completion: fresh output distinguishes source validity, installation state, and planned operations.
3. **Publish gate.** Before commit, tag, remote creation/change, or push, show the exact paths, remote URL, branch/tag, commit message, and rollback cost; obtain explicit approval.
   - Completion: external effects are specifically approved.
4. **Company update gate.** Fetch the approved branch into a reviewable ref, review the complete diff for manifests, bootstrap scripts, and managed content, then approve a fast-forward separately. Never execute a fetched revision before this review.
   - Completion: reviewed revision is the only revision used for dry-run/apply.
5. **Apply gate.** Run the updated verifier and dry-run, review planned writes, then require a separate explicit apply approval.
   - Completion: changed destination paths and residual physical/policy checks are reported.

## Proportional Publish Gates

Match ceremony to the actual boundary rather than inheriting the strongest gate used elsewhere in the project. For a reversible repository publication or removable public site with no live host-runtime mutation, keep the design compact and center verification on the deliverable:

- define the public include set, explicit exclusions, and site composition in a short scope document;
- prove before push that credentials, machine-local paths/state, runtime logs, databases, HMAC keys, auth files, and provider cookies/tokens are absent from both tracked files and generated site output;
- verify the built/downloaded artifact, not only source inputs;
- obtain one explicit approval immediately before the first external push or publication;
- do not add bootstrap stamps, request-seam proofs, transaction rollback machinery, or repeated review loops unless a distinct data, credential, migration, or live-runtime risk requires them.

If process documents or verification artifacts begin to outweigh the requested repository/site deliverable without producing unique evidence, stop the expansion and report it. YAGNI applies to gates as well as features; secret exclusion and the external-side-effect approval remain mandatory.

### Goal anchor for process artifacts

For every spec or plan in a publication/site workflow, put a one-line goal anchor before the document title:

```text
Final deliverable: <the external artifact the user actually wants> | This document: <direct deliverable work or meta-work>
```

If the document is meta-work, state the shortest closure path and the exact point where work returns to the final deliverable. Do not let a verifier correction, handoff, migration note, or policy amendment become an open-ended phase. Count artifacts as a cost signal: when process/verification artifacts exceed direct deliverables without adding unique risk evidence, stop and report the imbalance instead of inventing another gate.

## Installer Requirements

- Default to a read-only dry-run. An apply switch must be explicit and mutually exclusive with dry-run.
- Do not run Git network operations in the same invocation that applies files. Fetch/review/fast-forward/apply are separate actions.
- Use only fixed manifest entries; never recursively replace a skills/config directory or accept arbitrary caller-supplied source/destination/config keys.
- Do not read, copy, merge, or rewrite sensitive config files unless a later, separately approved design supplies a compiled key allowlist.
- Validate every managed source and destination path before action. Reject reparse points/junctions/symlinks at the base and path-component level; re-check immediately before writes.
- Preflight every selected operation before changing any destination. Stage and hash-check source copies first; make timestamped backups only of baseline-owned targets; on failure, restore replaced files and remove newly created targets.
- After apply, hash-verify every target. Report source-only verification separately from installed-target verification.
- For machine-local plugin/config/Vault activation, use `references/local-runtime-contract-activation.md`; it defines conditional evidence reporting, effective override proof, fail-closed pre-transaction probes, dirty-section preservation, and hash-anomaly handling.
- When a live runner contradicts a healthy production caller, use `references/live-runtime-verification-instruments.md`; it separates runtime failure from instrument failure, defines same-session identity evidence, credential-free profile fixtures, strict citation probes, and the minimum decisive correction gate.

## Pitfalls

- `.gitignore` does not make already tracked sensitive content safe; audit `git ls-files` plus staged and unstaged file lists.
- A clean working tree or known remote URL is not proof that newly fetched installer/manifest policy is safe.
- A destructive remote action is not verified by a follow-up command that merely returns an error. Require the destructive command itself to succeed, then query the exact remote resource and accept only its explicit absence response (for example GitHub HTTP 404). Authentication or authorization failures are failures, not evidence of absence.
- A bootstrap that pulls then reloads its manifest can apply attacker-controlled expanded policy in the same run. Keep update and apply separate.
- A path prefix check alone is insufficient on Windows when junctions or symlinks can be introduced between validation and copy.
- A passing parser/hash check does not prove that a live-machine dry-run or apply succeeded; state the remaining verification gap plainly.

## Verification

Before reporting a baseline release or install as complete, obtain fresh evidence for:

- isolated repository boundary and denylist audit;
- manifest schema and source-hash checks;
- installer parser/static validation;
- dry-run with before/after managed-target hashes and backup count unchanged;
- independent review findings resolved or explicitly accepted;
- after apply, target hashes, backup locations, and any remaining company-policy or physical checks.
