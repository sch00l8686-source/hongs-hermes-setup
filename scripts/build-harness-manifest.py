#!/usr/bin/env python3
"""Build the deterministic managed-file manifest for the harness installer.

Usage
-----
    python scripts/build-harness-manifest.py --root <repo> \
        --output manifest/harness-manifest.json

The manifest is produced from the explicit allowlist in ``harness_baseline.py``
only. No directory is walked, no live runtime location is inspected, and no file
outside ``baseline/`` is ever read. Running the builder twice on unchanged
sources produces byte-identical output.

Exit codes
----------
    0   manifest written (or, with ``--check``, already current)
    1   the allowlist and the recorded provenance disagree, a managed source is
        missing, or ``--check`` found stale output
    2   the builder could not run
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness_baseline as baseline  # noqa: E402

PROVENANCE_RELATIVE = "provenance/upstream-lock.json"


def load_provenance_skills(root):
    """Return the skill names recorded in the provenance lock, or ``None``."""
    path = baseline.repo_path(root, PROVENANCE_RELATIVE)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as handle:
        document = json.loads(handle.read().decode("utf-8"))
    return sorted(entry["name"] for entry in document.get("skills", []))


def build_manifest(root):
    """Return the manifest document for ``root``.

    Raises ``ValueError`` when the allowlist disagrees with the recorded
    provenance or when a managed source file is missing.
    """
    recorded = load_provenance_skills(root)
    if recorded is None:
        raise ValueError("missing %s" % PROVENANCE_RELATIVE)
    approved = sorted(baseline.APPROVED_SKILLS)
    if recorded != approved:
        missing = sorted(set(approved) - set(recorded))
        extra = sorted(set(recorded) - set(approved))
        raise ValueError(
            "allowlist and %s disagree (allowlist-only: %s; provenance-only: %s)"
            % (PROVENANCE_RELATIVE, missing or "none", extra or "none")
        )

    records = []
    for source, target_root, destination in baseline.managed_files():
        absolute = baseline.repo_path(root, source)
        if not os.path.isfile(absolute):
            raise ValueError("managed source missing: %s" % source)
        records.append(
            {
                "source": source,
                "targetRoot": target_root,
                "destination": destination,
                "sha256": baseline.sha256_file(absolute),
            }
        )
    records.sort(key=lambda record: (record["targetRoot"], record["destination"]))
    return {"schemaVersion": baseline.SCHEMA_VERSION, "files": records}


def render(document):
    """Serialise the manifest deterministically."""
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the harness install manifest.")
    parser.add_argument("--root", required=True, help="repository root")
    parser.add_argument("--output", required=True, help="manifest output path")
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write; exit 1 if the existing output differs",
    )
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("build-harness-manifest: --root is not a directory\n")
        return 2

    try:
        payload = render(build_manifest(root))
    except ValueError as error:
        sys.stderr.write("build-harness-manifest: %s\n" % error)
        return 1

    output = os.path.abspath(args.output)
    if args.check:
        if not os.path.isfile(output):
            sys.stderr.write("build-harness-manifest: %s does not exist\n" % args.output)
            return 1
        with open(output, "rb") as handle:
            existing = handle.read().decode("utf-8")
        if existing != payload:
            sys.stderr.write("build-harness-manifest: %s is stale\n" % args.output)
            return 1
        sys.stdout.write("build-harness-manifest: %s is current\n" % args.output)
        return 0

    parent = os.path.dirname(output)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(output, "wb") as handle:
        handle.write(payload.encode("utf-8"))
    sys.stdout.write(
        "build-harness-manifest: wrote %d record(s) to %s\n"
        % (payload.count('"sha256"'), args.output)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
