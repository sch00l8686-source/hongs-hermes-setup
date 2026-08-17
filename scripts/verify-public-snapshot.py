#!/usr/bin/env python3
"""Categorical security and privacy proof for the staged public snapshot.

Usage
-----
    python scripts/verify-public-snapshot.py --staging <dir>

The verifier scans the staged tree and its single commit and reports **counts
and classifications only**. It never prints a matched value: not a secret, not a
machine-local path, not the author address. A reader learns how many findings
exist, in which file, and of which category -- never what the finding says.

The expected package set, identity, exclusions, machine-local patterns,
classified fixtures, and required site artifacts are spelled out in this file
rather than read from the staged tree or imported from the builder, so a
snapshot that also rewrote the builder's own allowlist still fails.

Exit codes
----------
    0   every check passed
    1   at least one check failed
    2   the verifier could not run
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile

# --------------------------------------------------------------------------
# Expected snapshot contract
# --------------------------------------------------------------------------

#: Documentation trees that must never appear in a published snapshot.
EXCLUDED_PREFIXES = ("docs/status/", "docs/superpowers/")

#: The four artifacts of the download site the snapshot advertises: the page
#: GitHub Pages serves, the Edge Function that redirects to it, the config
#: declaring that function JWT-less, and the local proof of both. A snapshot
#: whose commit is missing any of them fails.
REQUIRED_SITE_ARTIFACTS = (
    "index.html",
    "supabase/config.toml",
    "supabase/functions/download/index.ts",
    "scripts/test-download-function.mjs",
)

#: Synthetic machine-local fixtures: test inputs that exist to prove a
#: machine-local path is detected, classified here by exact path and category.
#: Declaring a file a fixture is a decision this verifier makes on its own.
CLASSIFIED_MACHINE_LOCAL_FIXTURES = {
    "tests/python/test_validate_harness.py": "validator-machine-local-fixture",
    "tests/python/test_supervisor_cost.py": "cost-record-machine-local-fixture",
    "tests/python/test_build_public_snapshot.py": "snapshot-builder-machine-local-fixture",
}

#: Machine-local path shapes. ``windows-user-profile`` accepts a doubled
#: backslash as a separator as well as a single one, so a path hidden inside a
#: JSON or Python string literal is still found.
MACHINE_LOCAL_PATTERNS = (
    ("windows-user-profile", re.compile(r"[A-Za-z]:(?:\\{1,2}|/)Users(?:(?:\\{1,2}|/)[^\s`'\"<>|)\]\\/]+)+")),
    ("windows-program-dir", re.compile(r"[A-Za-z]:(?:\\{1,2}|/)Program(?: |%20)?Files")),
    ("posix-home", re.compile(r"/(?:home|Users)/[A-Za-z0-9._-]+/")),
    ("windows-env-home", re.compile(r"%(?:LOCALAPPDATA|APPDATA|USERPROFILE|HOMEPATH|HOMEDRIVE)%")),
    ("powershell-env-home", re.compile(r"\$env:(?:LOCALAPPDATA|APPDATA|USERPROFILE)")),
)

EXPECTED_BRANCH = "main"
EXPECTED_COMMIT_COUNT = 1
EXPECTED_REMOTE_COUNT = 0
EXPECTED_AUTHOR_NAME = "HongGyu"
EXPECTED_AUTHOR_EMAIL = "293146566+sch00l8686-source@users.noreply.github.com"

#: The twenty approved public-snapshot skill packages.
APPROVED_SKILL_PACKAGES = (
    "autonomous-ai-agents/agent-context-efficiency",
    "autonomous-ai-agents/agent-context-governance",
    "autonomous-ai-agents/mixed-model-agent-orchestration",
    "autonomous-ai-agents/review-gated-config-distribution",
    "autonomous-ai-agents/subagent-coding-context",
    "autonomous-ai-agents/supervised-agent-workflow",
    "automation/execution-continuity",
    "note-taking/obsidian-vault-ingest",
    "note-taking/obsidian-vault-lint",
    "note-taking/obsidian-vault-query",
    "superpowers/brainstorming",
    "superpowers/dispatching-parallel-agents",
    "superpowers/executing-plans",
    "superpowers/finishing-a-development-branch",
    "superpowers/receiving-code-review",
    "superpowers/subagent-driven-development",
    "superpowers/using-git-worktrees",
    "superpowers/using-superpowers",
    "superpowers/verification-before-completion",
    "superpowers/writing-plans",
)

#: The one preserved package that predates the approved twenty.
PRESERVED_SKILL_PACKAGE = "software-development/plan"

#: Every package the snapshot may carry: the approved twenty plus the preserved
#: adapter, twenty-one in total.
EXPECTED_SKILL_PACKAGES = tuple(sorted(APPROVED_SKILL_PACKAGES + (PRESERVED_SKILL_PACKAGE,)))

SKILL_PREFIX = "baseline/skills/"

# --------------------------------------------------------------------------
# Forbidden files
# --------------------------------------------------------------------------

#: Files that must never reach a public repository, by category. Matching is on
#: the repository path in lowercase, so a nested ``config/.env.local`` is caught.
FORBIDDEN_FILE_PATTERNS = (
    ("dotenv", re.compile(r"(^|/)\.env(\.|$)")),
    ("auth-artifact", re.compile(r"(^|/)(auth|credentials?|\.netrc|\.npmrc|\.pypirc)(\.[a-z0-9]+)?$")),
    ("token-artifact", re.compile(r"(^|/)[^/]*(token|secret)s?[^/]*\.(json|ya?ml|txt|toml|ini|cfg)$")),
    ("private-key", re.compile(r"\.(pem|key|pfx|p12|ppk|asc|jks|keystore)$")),
    ("ssh-key", re.compile(r"(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.|$)")),
    ("state-database", re.compile(r"\.(db|sqlite3?|mdb)$")),
    ("log", re.compile(r"\.(log|jsonl)$")),
    ("backup", re.compile(r"(\.(bak|backup|orig|old|swp|tmp)$|~$)")),
)

# --------------------------------------------------------------------------
# Secret assignments
# --------------------------------------------------------------------------

#: An assignment whose *name* is credential shaped and whose *value* is a
#: literal. A prose mention of a credential name is not an assignment and never
#: matches: the operator and a literal value are both required.
SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b(api[_-]?keys?|secrets?|passwords?|passwd|tokens?|access[_-]?keys?"
    r"|private[_-]?keys?|client[_-]?secrets?|credentials?|authorization)\b"
    r"\s*(?::|=|=>|:=)\s*"
    r"(?P<value>\"[^\"\n]{8,}\"|'[^'\n]{8,}'|`[^`\n]{8,}`|[A-Za-z0-9_\-./+]{20,})"
)

#: A value that references configuration rather than carrying it, is a declared
#: non-secret marker, or is a symbolic constant name. These are the shapes a
#: portable setup repository is supposed to contain. Anything else is reported.
NON_SECRET_VALUE = re.compile(
    r"(?i)(\$\{|\$env:|%[A-Z_]+%|os\.environ|process\.env|deno\.env|getenv"
    r"|^<|placeholder|example|redacted|changeme|your[-_ ]|dummy|fake|sample"
    r"|stub|invalid|none$|null$|true$|false$|^\"\"$|^''$|\.\.\.)"
)

#: A screaming-snake identifier is a symbolic constant, not a credential
#: literal. Matched separately because it is case sensitive.
SYMBOLIC_CONSTANT_VALUE = re.compile(r"^[A-Z][A-Z0-9_]{3,}$")

#: Literal shapes that are a leaked credential whatever their surrounding text.
HARD_SECRET_PATTERNS = (
    ("pem-private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("github-token", re.compile(r"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b")),
    ("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}\b")),
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9]{32,}\b")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_\-]{32,}\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("supabase-service-key", re.compile(r"\bsbp_[A-Za-z0-9]{40,}\b")),
)

#: Secret-shaped fixtures classified by exact path and category. Empty by
#: design: the snapshot is expected to contain no credential assignment at all,
#: so a new entry here is a deliberate, reviewable decision.
CLASSIFIED_SECRET_FIXTURES = {}

_BINARY_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip", ".pdf")


class VerifyRefused(Exception):
    """The verifier could not inspect the staging directory."""


# --------------------------------------------------------------------------
# git plumbing
# --------------------------------------------------------------------------

def git(root, *args):
    command = ["git", "-C", root]
    command.extend(args)
    env = dict(os.environ)
    absent = os.path.join(tempfile.gettempdir(), "public-snapshot-absent-gitconfig")
    env["GIT_CONFIG_GLOBAL"] = absent
    env["GIT_CONFIG_SYSTEM"] = absent
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        completed = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
        )
    except OSError as error:
        raise VerifyRefused("git is not available: %s" % error)
    if completed.returncode != 0:
        raise VerifyRefused(
            "git %s failed (exit %d)" % (" ".join(args), completed.returncode)
        )
    return completed.stdout.decode("utf-8", "replace")


def _lines(text):
    return [line.strip() for line in text.replace("\r\n", "\n").split("\n") if line.strip()]


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

class Report(object):
    """Accumulates categorical check results. No matched value is ever stored."""

    def __init__(self):
        self.rows = []
        self.failed = 0

    def add(self, check, passed, detail):
        self.rows.append((check, "PASS" if passed else "FAIL", detail))
        if not passed:
            self.failed += 1

    def render(self):
        width = max(len(row[0]) for row in self.rows)
        return "".join(
            "%-4s %-*s  %s\n" % (status, width, check, detail)
            for check, status, detail in self.rows
        )


def check_commit_shape(staging, report):
    commit_count = int(git(staging, "rev-list", "--count", "HEAD").strip())
    report.add(
        "commit-count",
        commit_count == EXPECTED_COMMIT_COUNT,
        "%d commit(s), expected %d" % (commit_count, EXPECTED_COMMIT_COUNT),
    )
    remotes = _lines(git(staging, "remote"))
    report.add(
        "configured-remotes",
        len(remotes) == EXPECTED_REMOTE_COUNT,
        "%d remote(s), expected %d" % (len(remotes), EXPECTED_REMOTE_COUNT),
    )
    branch = git(staging, "rev-parse", "--abbrev-ref", "HEAD").strip()
    report.add(
        "branch",
        branch == EXPECTED_BRANCH,
        "branch name matches '%s'" % EXPECTED_BRANCH if branch == EXPECTED_BRANCH
        else "branch name does not match the expected snapshot branch",
    )


def check_identity(staging, report):
    """Author and committer are the expected noreply identity.

    The observed identity is compared, never printed: a mismatch reports that
    the identity differs, not what it is.
    """
    for role, fields in (("author", "%an%n%ae"), ("committer", "%cn%n%ce")):
        recorded = git(staging, "log", "-1", "--format=" + fields).replace("\r\n", "\n").split("\n")
        name = recorded[0].strip() if recorded else ""
        email = recorded[1].strip() if len(recorded) > 1 else ""
        matches = name == EXPECTED_AUTHOR_NAME and email == EXPECTED_AUTHOR_EMAIL
        report.add(
            "%s-identity" % role,
            matches,
            "matches the expected staging-local noreply identity" if matches
            else "does not match the expected staging-local noreply identity",
        )


def _skill_packages(paths):
    packages = set()
    for path in paths:
        if not path.startswith(SKILL_PREFIX):
            continue
        parts = path[len(SKILL_PREFIX):].split("/")
        if len(parts) >= 3:
            packages.add("%s/%s" % (parts[0], parts[1]))
    return packages


def check_skill_packages(paths, report):
    present = _skill_packages(paths)
    approved_present = present & set(APPROVED_SKILL_PACKAGES)
    report.add(
        "approved-skill-packages",
        len(approved_present) == len(APPROVED_SKILL_PACKAGES),
        "%d/%d approved package(s) present"
        % (len(approved_present), len(APPROVED_SKILL_PACKAGES)),
    )
    exact = present == set(EXPECTED_SKILL_PACKAGES)
    report.add(
        "total-skill-packages",
        exact,
        "%d package(s) present, expected exactly %d and no other"
        % (len(present), len(EXPECTED_SKILL_PACKAGES)),
    )


def check_required_artifacts(paths, report):
    """The download site the snapshot advertises is actually committed."""
    present = set(paths)
    missing = sorted(
        artifact for artifact in REQUIRED_SITE_ARTIFACTS if artifact not in present
    )
    report.add(
        "required-site-artifacts",
        not missing,
        "%d/%d required artifact(s) present"
        % (len(REQUIRED_SITE_ARTIFACTS) - len(missing), len(REQUIRED_SITE_ARTIFACTS)),
    )
    return missing


def check_exclusions(paths, report):
    leaked = sorted(path for path in paths if path.startswith(EXCLUDED_PREFIXES))
    report.add(
        "expected-exclusions",
        not leaked,
        "%d file(s) present under %s, expected 0"
        % (len(leaked), ", ".join(EXCLUDED_PREFIXES)),
    )


def _readable_text(staging, relative):
    if relative.lower().endswith(_BINARY_SUFFIXES):
        return None
    absolute = os.path.join(staging, *relative.split("/"))
    if not os.path.isfile(absolute):
        return None
    with open(absolute, "rb") as handle:
        raw = handle.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def check_machine_local(staging, paths, report):
    unclassified = {}
    classified = {}
    for relative in paths:
        text = _readable_text(staging, relative)
        if text is None:
            continue
        total = sum(len(pattern.findall(text)) for _label, pattern in MACHINE_LOCAL_PATTERNS)
        if not total:
            continue
        if relative in CLASSIFIED_MACHINE_LOCAL_FIXTURES:
            classified[relative] = total
        else:
            unclassified[relative] = total
    detail = "%d unclassified occurrence(s) in %d file(s); %d classified fixture occurrence(s) in %d file(s)" % (
        sum(unclassified.values()), len(unclassified), sum(classified.values()), len(classified),
    )
    report.add("machine-local-paths", not unclassified, detail)
    return unclassified, classified


def check_forbidden_files(paths, report):
    findings = {}
    for relative in paths:
        lowered = relative.lower()
        for category, pattern in FORBIDDEN_FILE_PATTERNS:
            if pattern.search(lowered):
                findings.setdefault(category, []).append(relative)
    total = sum(len(items) for items in findings.values())
    report.add(
        "forbidden-files",
        not findings,
        "%d forbidden file(s) across %d category(ies), expected 0"
        % (total, len(findings)),
    )
    return findings


def scan_secrets(staging, paths):
    """Return ``{path: {category: count}}`` of unclassified secret findings.

    Only the path, the category, and the count are returned. The matched text is
    discarded inside this function and never leaves it.
    """
    findings = {}
    for relative in paths:
        text = _readable_text(staging, relative)
        if text is None:
            continue
        counts = {}
        for category, pattern in HARD_SECRET_PATTERNS:
            found = len(pattern.findall(text))
            if found:
                counts[category] = counts.get(category, 0) + found
        for match in SECRET_ASSIGNMENT.finditer(text):
            value = match.group("value").strip("\"'`")
            if NON_SECRET_VALUE.search(value) or SYMBOLIC_CONSTANT_VALUE.match(value):
                continue
            counts["credential-assignment"] = counts.get("credential-assignment", 0) + 1
        if not counts:
            continue
        classified = CLASSIFIED_SECRET_FIXTURES.get(relative)
        if classified is not None and set(counts) <= set(classified):
            continue
        findings[relative] = counts
    return findings


def check_secrets(staging, paths, report):
    findings = scan_secrets(staging, paths)
    total = sum(sum(counts.values()) for counts in findings.values())
    report.add(
        "secret-assignments",
        not findings,
        "%d unclassified credential finding(s) in %d file(s), expected 0"
        % (total, len(findings)),
    )
    return findings


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def verify(staging):
    """Run every check. Returns ``(report, categorical_detail)``."""
    if not os.path.isdir(os.path.join(staging, ".git")):
        raise VerifyRefused("staging directory is not a git repository")

    paths = _lines(git(staging, "ls-files"))
    report = Report()
    report.add("staged-files", bool(paths), "%d tracked file(s) in the snapshot commit" % len(paths))
    check_commit_shape(staging, report)
    check_identity(staging, report)
    check_skill_packages(paths, report)
    missing_artifacts = check_required_artifacts(paths, report)
    check_exclusions(paths, report)
    machine_local, classified = check_machine_local(staging, paths, report)
    forbidden = check_forbidden_files(paths, report)
    secrets = check_secrets(staging, paths, report)

    detail = []
    for relative in missing_artifacts:
        detail.append("missing required site artifact :: %s" % relative)
    for relative, category in sorted(CLASSIFIED_MACHINE_LOCAL_FIXTURES.items()):
        if relative in classified:
            detail.append(
                "classified machine-local fixture :: %s :: %s :: %d occurrence(s)"
                % (relative, category, classified[relative])
            )
    for relative in sorted(machine_local):
        detail.append(
            "unclassified machine-local path :: %s :: %d occurrence(s)"
            % (relative, machine_local[relative])
        )
    for category in sorted(forbidden):
        for relative in sorted(forbidden[category]):
            detail.append("forbidden file :: %s :: %s" % (relative, category))
    for relative in sorted(secrets):
        for category in sorted(secrets[relative]):
            detail.append(
                "unclassified credential :: %s :: %s :: %d occurrence(s)"
                % (relative, category, secrets[relative][category])
            )
    return report, detail


def main(argv=None):
    parser = argparse.ArgumentParser(description="Verify the staged public snapshot.")
    parser.add_argument("--staging", required=True, help="staged snapshot repository")
    args = parser.parse_args(argv)

    staging = os.path.abspath(args.staging)
    if not os.path.isdir(staging):
        sys.stderr.write("verify-public-snapshot: --staging is not a directory\n")
        return 2

    try:
        report, detail = verify(staging)
    except VerifyRefused as error:
        sys.stderr.write("verify-public-snapshot: %s\n" % error)
        return 2

    sys.stdout.write(report.render())
    for line in detail:
        sys.stdout.write("     %s\n" % line)
    sys.stdout.write(
        "verify-public-snapshot: %s (%d check(s) failed)\n"
        % ("PASS" if report.failed == 0 else "FAIL", report.failed)
    )
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
