#!/usr/bin/env python3
"""Build the disposable one-commit public snapshot of this repository.

Usage
-----
    python scripts/build-public-snapshot.py --root <repo> --staging <dir>

The snapshot content is the current worktree: every tracked file plus the
untracked files that the managed allowlist already approves, minus the excluded
documentation trees. Nothing is discovered outside those two sources, and the
canonical repository is only ever read.

Machine-local literals survive in a few in-scope documentation and provenance
files. Those are rewritten to a portable placeholder **in the staged copy
only**; the canonical files are never modified. After the rewrite the staged
tree is rescanned, and the build fails closed if any machine-local path remains
outside the classified synthetic test fixtures.

The staging repository is created from scratch: a fresh ``main`` branch, a
staging-local author identity, exactly one commit, and no remote. The global and
system git configuration are neutralised for every git call, so the canonical
identity is neither read nor written.

Exit codes
----------
    0   the snapshot was built and committed
    1   the build refused to run or failed closed
    2   the builder could not run (bad arguments, git unavailable)
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness_baseline as baseline  # noqa: E402

# --------------------------------------------------------------------------
# Snapshot contract
# --------------------------------------------------------------------------

#: Documentation trees that stay private. Status handoffs and the superpowers
#: design/plan record carry working-session detail, not published setup.
EXCLUDED_PREFIXES = ("docs/status/", "docs/superpowers/")

#: Branch, identity, and commit subject of the single snapshot commit. The
#: address is the GitHub ``noreply`` form, so publishing the snapshot exposes no
#: private mailbox. This identity is written into the staging repository only.
SNAPSHOT_BRANCH = "main"
SNAPSHOT_AUTHOR_NAME = "HongGyu"
SNAPSHOT_AUTHOR_EMAIL = "293146566+sch00l8686-source@users.noreply.github.com"
SNAPSHOT_COMMIT_SUBJECT = "Initial public snapshot of the global agent harness setup"

#: The portable stand-in for the machine-local Windows local-application-data
#: root. It deliberately matches none of the machine-local patterns below.
LOCAL_APP_DATA_PLACEHOLDER = "<LOCAL-APP-DATA>"

#: The marker that identifies a rewritable machine-local path: the live Hermes
#: home under the Windows local application data directory. A machine-local path
#: that does not carry this marker is left alone, so the rescan fails closed on
#: it rather than a substitution guessing at its portable form.
LOCAL_HERMES_MARKER = "AppData/Local/hermes"

#: The measured in-scope files that carry machine-local literals. Substitution
#: is applied to exactly these staged copies -- it is an allowlist, not a sweep,
#: so a machine-local path appearing in a new file fails the rescan instead of
#: being silently rewritten.
PORTABLE_SUBSTITUTION_FILES = (
    "docs/provenance.md",
    "docs/specs/global-agent-harness-design.md",
    "provenance/upstream-lock.json",
)

#: Untracked files outside ``baseline/`` that the snapshot publishes anyway: the
#: approved site and publication implementation, which is authored for this
#: snapshot and is not yet committed to canonical history. Like every other list
#: here it is spelled out, so an unrelated untracked file is never published.
APPROVED_UNTRACKED_EXTRAS = (
    "scripts/build-public-snapshot.py",
    "scripts/test-download-function.mjs",
    "scripts/verify-public-snapshot.py",
    "supabase/config.toml",
    "supabase/functions/download/index.ts",
    "tests/python/test_build_public_snapshot.py",
)

#: Synthetic machine-local fixtures: test inputs that exist precisely to prove a
#: machine-local path is detected. They are classified by exact path and
#: category rather than rewritten, because rewriting them would delete the
#: behaviour they test.
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

#: Environment-variable spellings of the same local-application-data root. The
#: alternation groups are written non-contiguously on purpose: this file is
#: itself part of the snapshot and is scanned by the rules above, so spelling
#: the literals out here would make the detector flag its own source and force a
#: classification exception that weakens the rule for everyone else.
_ENV_HOME_PATTERN = re.compile(r"%(?:LOCALAPPDATA)%|\$(?:env):LOCALAPPDATA")

#: Files whose bytes are not text and are never scanned or substituted.
_TEXT_SUFFIX_DENYLIST = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".zip", ".pdf")


class BuildRefused(Exception):
    """The snapshot cannot be built as specified."""


# --------------------------------------------------------------------------
# git plumbing
# --------------------------------------------------------------------------

def git_env():
    """A git environment that neither reads nor writes user or system config.

    ``GIT_CONFIG_GLOBAL`` and ``GIT_CONFIG_SYSTEM`` point at a path that does not
    exist, which git treats as empty configuration. The canonical identity, the
    canonical ``core.autocrlf`` setting, and any signing configuration are
    therefore invisible to every git call this builder makes.
    """
    env = dict(os.environ)
    absent = os.path.join(tempfile.gettempdir(), "public-snapshot-absent-gitconfig")
    env["GIT_CONFIG_GLOBAL"] = absent
    env["GIT_CONFIG_SYSTEM"] = absent
    env["GIT_TERMINAL_PROMPT"] = "0"
    for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
        env.pop(name, None)
    return env


def git(root, *args):
    """Run ``git -C root <args>`` and return stdout text."""
    command = ["git", "-C", root]
    command.extend(args)
    try:
        completed = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=git_env()
        )
    except OSError as error:
        raise BuildRefused("git is not available: %s" % error)
    if completed.returncode != 0:
        raise BuildRefused(
            "git %s failed (exit %d): %s"
            % (" ".join(args), completed.returncode, completed.stderr.decode("utf-8", "replace").strip())
        )
    return completed.stdout.decode("utf-8", "replace")


# --------------------------------------------------------------------------
# File selection
# --------------------------------------------------------------------------

def _lines(text):
    return [line.strip() for line in text.replace("\r\n", "\n").split("\n") if line.strip()]


def select_files(root):
    """Return ``(included, excluded, unapproved_untracked)`` repository paths.

    ``included`` is the snapshot content: tracked files plus untracked files that
    the managed allowlist already approves, minus the excluded documentation
    trees. An untracked file the allowlist does not name is never published --
    it is reported, not guessed at.
    """
    tracked = set(_lines(git(root, "ls-files")))
    untracked = set(_lines(git(root, "ls-files", "--others", "--exclude-standard")))
    approvable = set(baseline.managed_sources()) | set(APPROVED_UNTRACKED_EXTRAS)
    approved_untracked = untracked & approvable
    unapproved_untracked = sorted(untracked - approved_untracked)

    candidates = tracked | approved_untracked
    included = sorted(path for path in candidates if not path.startswith(EXCLUDED_PREFIXES))
    excluded = sorted(path for path in candidates if path.startswith(EXCLUDED_PREFIXES))
    return included, excluded, unapproved_untracked


# --------------------------------------------------------------------------
# Portable substitution and the fail-closed rescan
# --------------------------------------------------------------------------

def _portable_windows_path(match):
    """Rewrite one machine-local Windows path, or leave it for the rescan."""
    normalised = match.group(0).replace("\\\\", "/").replace("\\", "/")
    index = normalised.find(LOCAL_HERMES_MARKER)
    if index == -1:
        return match.group(0)
    tail = normalised[index + len("AppData/Local/"):]
    return "%s/%s" % (LOCAL_APP_DATA_PLACEHOLDER, tail)


def to_portable_text(text):
    """Return ``text`` with the known machine-local roots replaced."""
    text = _ENV_HOME_PATTERN.sub(LOCAL_APP_DATA_PLACEHOLDER, text)
    windows_user_profile = MACHINE_LOCAL_PATTERNS[0][1]
    return windows_user_profile.sub(_portable_windows_path, text)


def _is_scannable(relative):
    return not relative.lower().endswith(_TEXT_SUFFIX_DENYLIST)


def scan_machine_local(root, relatives):
    """Return ``(unclassified, classified)`` machine-local occurrence counts.

    ``unclassified`` maps ``repository path -> {category: count}`` for findings
    that must be zero. ``classified`` maps the same shape for the synthetic
    fixtures named in ``CLASSIFIED_MACHINE_LOCAL_FIXTURES``. Neither carries a
    matched value: only the path, the pattern label, and the count.
    """
    unclassified = {}
    classified = {}
    for relative in relatives:
        if not _is_scannable(relative):
            continue
        absolute = baseline.repo_path(root, relative)
        if not os.path.isfile(absolute):
            continue
        with open(absolute, "rb") as handle:
            try:
                text = handle.read().decode("utf-8")
            except UnicodeDecodeError:
                continue
        counts = {}
        for label, pattern in MACHINE_LOCAL_PATTERNS:
            found = len(pattern.findall(text))
            if found:
                counts[label] = counts.get(label, 0) + found
        if not counts:
            continue
        if relative in CLASSIFIED_MACHINE_LOCAL_FIXTURES:
            classified[relative] = counts
        else:
            unclassified[relative] = counts
    return unclassified, classified


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

def prepare_staging(staging):
    """Create ``staging`` if absent; refuse a directory that is not empty."""
    if os.path.exists(staging):
        if not os.path.isdir(staging):
            raise BuildRefused("staging path exists and is not a directory")
        if os.listdir(staging):
            raise BuildRefused("staging directory is not empty")
        return
    os.makedirs(staging)


def copy_files(root, staging, relatives):
    """Copy each selected file's bytes into the staging tree."""
    for relative in relatives:
        source = baseline.repo_path(root, relative)
        destination = baseline.repo_path(staging, relative)
        parent = os.path.dirname(destination)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        shutil.copyfile(source, destination)


def apply_substitutions(staging, relatives):
    """Rewrite the staged copies of the substitution allowlist.

    Returns ``{repository path: replaced occurrence count}`` for the files that
    actually changed. Counts only -- no rewritten or original value is returned.
    """
    present = set(relatives)
    changed = {}
    for relative in PORTABLE_SUBSTITUTION_FILES:
        if relative not in present:
            continue
        absolute = baseline.repo_path(staging, relative)
        with open(absolute, "rb") as handle:
            original = handle.read().decode("utf-8")
        portable = to_portable_text(original)
        if portable == original:
            continue
        with open(absolute, "wb") as handle:
            handle.write(portable.encode("utf-8"))
        changed[relative] = (
            portable.count(LOCAL_APP_DATA_PLACEHOLDER)
            - original.count(LOCAL_APP_DATA_PLACEHOLDER)
        )
    return changed


def initialise_repository(staging):
    """Create the staging repository: one branch, one identity, one commit."""
    git(staging, "init", "--quiet", "--initial-branch", SNAPSHOT_BRANCH)
    git(staging, "config", "user.name", SNAPSHOT_AUTHOR_NAME)
    git(staging, "config", "user.email", SNAPSHOT_AUTHOR_EMAIL)
    git(staging, "config", "commit.gpgsign", "false")
    git(staging, "add", "--all")
    git(staging, "commit", "--quiet", "-m", SNAPSHOT_COMMIT_SUBJECT)


def build(root, staging):
    """Build the snapshot. Raises ``BuildRefused`` on any fail-closed condition."""
    included, excluded, unapproved_untracked = select_files(root)
    if not included:
        raise BuildRefused("no files selected for the snapshot")

    prepare_staging(staging)
    copy_files(root, staging, included)
    substituted = apply_substitutions(staging, included)

    unclassified, classified = scan_machine_local(staging, included)
    if unclassified:
        raise BuildRefused(
            "machine-local path(s) remain in %d staged file(s): %s"
            % (len(unclassified), ", ".join(sorted(unclassified)))
        )

    initialise_repository(staging)

    commit_count = int(git(staging, "rev-list", "--count", "HEAD").strip())
    remotes = _lines(git(staging, "remote"))
    if commit_count != 1:
        raise BuildRefused("staging repository has %d commit(s), expected exactly 1" % commit_count)
    if remotes:
        raise BuildRefused("staging repository has %d configured remote(s)" % len(remotes))

    return {
        "included": included,
        "excluded": excluded,
        "unapproved_untracked": unapproved_untracked,
        "substituted": substituted,
        "classified_fixtures": classified,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the public snapshot.")
    parser.add_argument("--root", required=True, help="canonical repository root (read only)")
    parser.add_argument("--staging", required=True, help="nonexistent or empty staging directory")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    staging = os.path.abspath(args.staging)
    if not os.path.isdir(root):
        sys.stderr.write("build-public-snapshot: --root is not a directory\n")
        return 2
    if os.path.abspath(os.path.join(staging, "")) == os.path.abspath(os.path.join(root, "")):
        sys.stderr.write("build-public-snapshot: --staging must differ from --root\n")
        return 2

    try:
        result = build(root, staging)
    except BuildRefused as error:
        sys.stderr.write("build-public-snapshot: %s\n" % error)
        return 1

    out = sys.stdout.write
    out("build-public-snapshot: staged %d file(s) into %s\n" % (len(result["included"]), staging))
    out("build-public-snapshot: excluded %d file(s) under %s\n"
        % (len(result["excluded"]), ", ".join(EXCLUDED_PREFIXES)))
    out("build-public-snapshot: skipped %d unapproved untracked file(s)\n"
        % len(result["unapproved_untracked"]))
    for relative in sorted(result["substituted"]):
        out("build-public-snapshot: portable substitution applied to %s (%d occurrence(s))\n"
            % (relative, result["substituted"][relative]))
    for relative in sorted(result["classified_fixtures"]):
        out("build-public-snapshot: classified fixture %s (%s)\n"
            % (relative, CLASSIFIED_MACHINE_LOCAL_FIXTURES[relative]))
    out("build-public-snapshot: branch %s, 1 commit, 0 remotes\n" % SNAPSHOT_BRANCH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
