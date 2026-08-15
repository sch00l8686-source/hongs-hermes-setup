"""Shared fixtures for the harness policy tests.

Every test that mutates policy text does so inside a disposable copy of the
repository baseline under the system temp directory. No test writes into the
repository working tree, and no test touches a live Hermes, Claude, or Codex
home.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, os.pardir, os.pardir))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")

VALIDATOR = os.path.join(SCRIPTS_DIR, "validate-harness.py")
MANIFEST_BUILDER = os.path.join(SCRIPTS_DIR, "build-harness-manifest.py")

ATTRIBUTES_RELATIVE = ".gitattributes"
MANIFEST_RELATIVE = "manifest/harness-manifest.json"

sys.path.insert(0, SCRIPTS_DIR)

import harness_baseline as baseline  # noqa: E402  (path set above)

#: Rules that depend on the global instruction triggers owned by the global
#: instruction worker. Until that work lands these are the only permitted RED
#: identifiers on this branch.
PENDING_GLOBAL_TRIGGER_RULES = frozenset(("E040", "E041", "E042"))


def make_fixture_root():
    """Copy the parts of the repository the validator reads into a temp root."""
    root = tempfile.mkdtemp(prefix="harness-policy-")
    for relative in ("baseline", "provenance"):
        shutil.copytree(os.path.join(REPO_ROOT, relative), os.path.join(root, relative))
    return root


def fixture_path(root, relative):
    return baseline.repo_path(root, relative)


def read_fixture(root, relative):
    return baseline.read_text(fixture_path(root, relative))


def write_fixture(root, relative, text):
    path = fixture_path(root, relative)
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, "wb") as handle:
        handle.write(text.encode("utf-8"))


def run_validator(root, git_root=None):
    """Run the validator against ``root``; return ``(exit_code, findings)``."""
    command = [
        sys.executable,
        VALIDATOR,
        "--root",
        root,
        "--git-root",
        git_root or REPO_ROOT,
        "--json",
    ]
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=REPO_ROOT
    )
    stdout = completed.stdout.decode("utf-8", "replace")
    if completed.returncode == 2:
        raise AssertionError("validator could not run: " + completed.stderr.decode("utf-8", "replace"))
    payload = json.loads(stdout)
    return completed.returncode, payload["findings"]


def failing_rules(findings):
    return sorted({finding["rule"] for finding in findings})


def run_manifest_builder(root, output, check=False):
    """Run the manifest builder; return ``(exit_code, stdout, stderr)``."""
    command = [sys.executable, MANIFEST_BUILDER, "--root", root, "--output", output]
    if check:
        command.append("--check")
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=REPO_ROOT
    )
    return (
        completed.returncode,
        completed.stdout.decode("utf-8", "replace"),
        completed.stderr.decode("utf-8", "replace"),
    )


def _git_env():
    """A git environment that reads no user or system config and writes none.

    ``GIT_CONFIG_GLOBAL`` and ``GIT_CONFIG_SYSTEM`` point at paths that do not
    exist, which git treats as empty config. Nothing here touches the developer's
    real ``~/.gitconfig``.
    """
    env = dict(os.environ)
    absent = os.path.join(tempfile.gettempdir(), "harness-absent-gitconfig")
    env["GIT_CONFIG_GLOBAL"] = absent
    env["GIT_CONFIG_SYSTEM"] = absent
    env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = "harness-test"
    env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = "harness-test@example.invalid"
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def _git(root, *args):
    """Run ``git -C root <args>``; return raw stdout bytes."""
    command = ["git", "-C", root]
    command.extend(args)
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=_git_env()
    )
    if completed.returncode != 0:
        raise AssertionError(
            "git %s failed: %s"
            % (" ".join(args), completed.stderr.decode("utf-8", "replace"))
        )
    return completed.stdout


def git_blob(root, relative):
    """Return the exact committed bytes of ``relative`` at ``HEAD``."""
    return _git(root, "show", "HEAD:" + relative)


def read_bytes(root, relative):
    with open(baseline.repo_path(root, relative), "rb") as handle:
        return handle.read()


def make_portable_checkout(attributes=None):
    """Build a fresh ``core.autocrlf=true`` checkout of the managed tree.

    The working-tree ``baseline/``, ``manifest/``, and ``.gitattributes`` are
    copied into a disposable repository, committed, then cloned and checked out
    with ``core.autocrlf=true`` — the Windows default that rewrites LF to CRLF
    unless an attribute pins the file. Pass ``attributes`` to substitute a
    deliberately weakened ``.gitattributes`` and prove the checker goes red.

    Returns ``(scratch_root, checkout_path)``; the caller removes ``scratch_root``.
    """
    scratch = tempfile.mkdtemp(prefix="harness-portable-")
    origin = os.path.join(scratch, "origin")
    os.makedirs(origin)
    for relative in ("baseline", "manifest"):
        shutil.copytree(os.path.join(REPO_ROOT, relative), os.path.join(origin, relative))
    if attributes is None:
        attributes = read_bytes(REPO_ROOT, ATTRIBUTES_RELATIVE).decode("utf-8")
    with open(os.path.join(origin, ATTRIBUTES_RELATIVE), "wb") as handle:
        handle.write(attributes.encode("utf-8"))

    _git(origin, "init", "--quiet")
    _git(origin, "config", "core.autocrlf", "true")
    _git(origin, "add", "--all")
    _git(origin, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")

    checkout = os.path.join(scratch, "checkout")
    _git(scratch, "clone", "--quiet", "--no-checkout", "--local", origin, checkout)
    _git(checkout, "config", "core.autocrlf", "true")
    _git(checkout, "checkout", "--quiet")
    return scratch, checkout


def portable_checkout_failures(checkout):
    """Return the portability failures of a checkout, sorted; empty means clean.

    A managed file is portable when its checked-out bytes equal the Git blob they
    came from — ``git show`` applies no line-ending filter — and when its SHA-256
    still equals the hash the tracked manifest records.
    """
    manifest = json.loads(read_bytes(checkout, MANIFEST_RELATIVE).decode("utf-8"))
    recorded = {record["source"]: record["sha256"] for record in manifest["files"]}
    failures = []
    for relative in baseline.managed_sources() + [MANIFEST_RELATIVE]:
        checked_out = read_bytes(checkout, relative)
        if checked_out != git_blob(checkout, relative):
            failures.append("%s: checkout bytes differ from the Git blob" % relative)
        elif relative in recorded and (
            baseline.sha256_file(baseline.repo_path(checkout, relative)) != recorded[relative]
        ):
            failures.append("%s: sha256 differs from the tracked manifest" % relative)
    return sorted(failures)
