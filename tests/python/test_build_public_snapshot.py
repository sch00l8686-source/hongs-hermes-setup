"""Tests for the disposable public snapshot builder and its verifier.

The snapshot is the only artifact that ever leaves this machine, so these tests
prove the two properties that matter before publication: the snapshot contains
exactly the approved content, and the machine-local detail that lives in the
canonical tree is rewritten in the staged copy only.

Every build here writes into a disposable temp directory. The canonical
repository is read and never written: one test captures its local git
configuration and working-tree status around a real build and requires both to
be unchanged.

This file is one of the classified machine-local fixtures. It deliberately
contains synthetic Windows user-profile paths, because the substitution and the
fail-closed rescan cannot be tested without them. The synthetic credential
assignment is assembled at run time instead of being written out, so this file's
own bytes carry no credential-shaped literal for the verifier to find.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import importlib.util

import harness_test_support as support

baseline = support.baseline

BUILDER = os.path.join(support.SCRIPTS_DIR, "build-public-snapshot.py")
VERIFIER = os.path.join(support.SCRIPTS_DIR, "verify-public-snapshot.py")


def load_script(name, path):
    """Import a hyphenated CLI script as ``name`` for direct inspection."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


builder = load_script("public_snapshot_builder_under_test", BUILDER)
verifier = load_script("public_snapshot_verifier_under_test", VERIFIER)

#: A synthetic live-Hermes path under the Windows local application data root.
#: It carries the marker the substitution recognises, so it must be rewritten.
SYNTHETIC_LIVE_HERMES_TEXT = (
    "live skill root: C:\\Users\\snapshot-fixture\\AppData\\Local\\hermes\\skills\n"
)

#: A synthetic machine-local path that carries no recognised marker. The
#: substitution must leave it alone so the rescan fails closed on it rather than
#: guessing at a portable form.
SYNTHETIC_UNKNOWN_LOCAL_TEXT = (
    "scratch notes: C:\\Users\\snapshot-fixture\\Documents\\harness-notes.md\n"
)

#: The synthetic credential assignment, assembled from parts. The name and the
#: value never appear together as a literal in this file, so this file itself
#: stays clean while the fixture it writes is detected.
_ASSIGNMENT_NAME = "api" + "_" + "key"
_ASSIGNMENT_VALUE = "q" * 28
SYNTHETIC_ASSIGNMENT_LINE = '%s = "%s"\n' % (_ASSIGNMENT_NAME, _ASSIGNMENT_VALUE)

#: Forbidden-file fixtures: one path per category the verifier must report.
FORBIDDEN_FIXTURES = (
    "config/.env.local",
    "runtime/router.jsonl",
    "keys/deploy.pem",
)

#: Minimal stand-ins for the four site artifacts every snapshot must carry. A
#: synthetic fixture repository needs them because the builder now refuses a
#: snapshot that would ship without the download site.
SITE_ARTIFACT_FIXTURES = {
    "index.html": "<!doctype html>\n<title>fixture page</title>\n",
    "supabase/config.toml": "[functions.download]\nverify_jwt = false\n",
    "supabase/functions/download/index.ts": "// fixture function\n",
    "scripts/test-download-function.mjs": "// fixture proof\n",
}

#: The build the whole module shares, plus the canonical state captured around
#: it. Building once keeps the suite focused: the mutation tests copy this
#: snapshot rather than rebuilding it.
SNAPSHOT = {}


# --------------------------------------------------------------------------
# git and process helpers
# --------------------------------------------------------------------------

def _git_env():
    """A git environment that reads no user or system config and writes none.

    The author and committer variables are removed rather than set, so a commit
    made inside a staged snapshot takes the identity that snapshot's own local
    configuration declares.
    """
    env = dict(os.environ)
    absent = os.path.join(tempfile.gettempdir(), "public-snapshot-test-absent-gitconfig")
    env["GIT_CONFIG_GLOBAL"] = absent
    env["GIT_CONFIG_SYSTEM"] = absent
    env["GIT_TERMINAL_PROMPT"] = "0"
    for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
        env.pop(name, None)
    return env


def git_bytes(root, *args):
    command = ["git", "-C", root]
    command.extend(args)
    completed = subprocess.run(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=_git_env()
    )
    if completed.returncode != 0:
        raise AssertionError(
            "git %s failed: %s" % (" ".join(args), completed.stderr.decode("utf-8", "replace"))
        )
    return completed.stdout


def git(root, *args):
    return git_bytes(root, *args).decode("utf-8", "replace")


def git_lines(root, *args):
    text = git(root, *args).replace("\r\n", "\n")
    return [line.strip() for line in text.split("\n") if line.strip()]


def run_builder(root, staging):
    completed = subprocess.run(
        [sys.executable, BUILDER, "--root", root, "--staging", staging],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=support.REPO_ROOT,
    )
    return (
        completed.returncode,
        completed.stdout.decode("utf-8", "replace"),
        completed.stderr.decode("utf-8", "replace"),
    )


def run_verifier(staging, verifier_path=None):
    completed = subprocess.run(
        [sys.executable, verifier_path or VERIFIER, "--staging", staging],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=support.REPO_ROOT,
    )
    return (
        completed.returncode,
        completed.stdout.decode("utf-8", "replace"),
        completed.stderr.decode("utf-8", "replace"),
    )


def read_text(root, relative):
    with open(baseline.repo_path(root, relative), "rb") as handle:
        return handle.read().decode("utf-8")


def write_text(root, relative, text):
    path = baseline.repo_path(root, relative)
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, "wb") as handle:
        handle.write(text.encode("utf-8"))


def machine_local_hits(text):
    return sum(len(pattern.findall(text)) for _label, pattern in builder.MACHINE_LOCAL_PATTERNS)


def failed_checks(stdout):
    """Return the check names the verifier reported as FAIL."""
    names = []
    for line in stdout.replace("\r\n", "\n").split("\n"):
        if line.startswith("FAIL "):
            names.append(line.split()[1])
    return sorted(names)


# --------------------------------------------------------------------------
# Module fixture: one real build of the canonical repository
# --------------------------------------------------------------------------

def setUpModule():
    workspace = tempfile.mkdtemp(prefix="public-snapshot-")
    staging = os.path.join(workspace, "snapshot")
    before_config = git(support.REPO_ROOT, "config", "--list", "--local")
    before_status = git(support.REPO_ROOT, "status", "--porcelain", "-uall")
    before_head = git(support.REPO_ROOT, "rev-parse", "HEAD")
    code, stdout, stderr = run_builder(support.REPO_ROOT, staging)
    SNAPSHOT.update(
        workspace=workspace,
        staging=staging,
        code=code,
        stdout=stdout,
        stderr=stderr,
        before_config=before_config,
        before_status=before_status,
        before_head=before_head,
        paths=git_lines(staging, "ls-files") if code == 0 else [],
    )


def tearDownModule():
    shutil.rmtree(SNAPSHOT["workspace"], True)


class SnapshotFixture(unittest.TestCase):
    """Base class exposing the shared build."""

    @property
    def staging(self):
        return SNAPSHOT["staging"]

    @property
    def paths(self):
        return SNAPSHOT["paths"]

    def setUp(self):
        self.assertEqual(0, SNAPSHOT["code"], SNAPSHOT["stderr"])


# --------------------------------------------------------------------------
# Content selection
# --------------------------------------------------------------------------

class SnapshotContentTests(SnapshotFixture):
    def test_build_reports_the_snapshot_shape(self):
        stdout = SNAPSHOT["stdout"]
        self.assertIn("staged %d file(s)" % len(self.paths), stdout)
        self.assertIn("branch main, 1 commit, 0 remotes", stdout)

    def test_every_managed_source_is_included(self):
        staged = set(self.paths)
        missing = [source for source in baseline.managed_sources() if source not in staged]
        self.assertEqual([], missing)

    def test_every_approved_untracked_extra_is_included(self):
        staged = set(self.paths)
        missing = [extra for extra in builder.APPROVED_UNTRACKED_EXTRAS if extra not in staged]
        self.assertEqual([], missing)

    def test_this_test_file_is_published_as_an_approved_extra(self):
        """The extras list is what publishes an untracked file, not discovery."""
        relative = "tests/python/test_build_public_snapshot.py"
        self.assertIn(relative, builder.APPROVED_UNTRACKED_EXTRAS)
        self.assertIn(relative, self.paths)

    def test_excluded_documentation_trees_are_absent(self):
        canonical = git_lines(support.REPO_ROOT, "ls-files")
        excluded_in_canonical = [
            path for path in canonical if path.startswith(builder.EXCLUDED_PREFIXES)
        ]
        self.assertTrue(excluded_in_canonical, "the canonical tree has nothing to exclude")
        leaked = [path for path in self.paths if path.startswith(builder.EXCLUDED_PREFIXES)]
        self.assertEqual([], leaked)

    def test_excluded_prefixes_are_exactly_status_and_superpowers(self):
        self.assertEqual(("docs/status/", "docs/superpowers/"), builder.EXCLUDED_PREFIXES)


# --------------------------------------------------------------------------
# Snapshot-only substitution
# --------------------------------------------------------------------------

class PortableSubstitutionTests(SnapshotFixture):
    def test_the_three_substitution_files_are_rewritten_in_the_snapshot(self):
        for relative in builder.PORTABLE_SUBSTITUTION_FILES:
            self.assertIn(relative, self.paths, relative)
            staged = read_text(self.staging, relative)
            self.assertIn(builder.LOCAL_APP_DATA_PLACEHOLDER, staged, relative)
            self.assertEqual(0, machine_local_hits(staged), relative)

    def test_the_canonical_files_still_carry_their_machine_local_paths(self):
        """Substitution is snapshot-only: the canonical bytes are untouched."""
        for relative in builder.PORTABLE_SUBSTITUTION_FILES:
            canonical = read_text(support.REPO_ROOT, relative)
            self.assertGreater(machine_local_hits(canonical), 0, relative)
            self.assertNotEqual(canonical, read_text(self.staging, relative), relative)

    def test_substitution_is_an_allowlist_not_a_sweep(self):
        self.assertEqual(
            (
                "docs/provenance.md",
                "docs/specs/global-agent-harness-design.md",
                "provenance/upstream-lock.json",
            ),
            builder.PORTABLE_SUBSTITUTION_FILES,
        )

    def test_a_marked_live_hermes_path_becomes_portable(self):
        portable = builder.to_portable_text(SYNTHETIC_LIVE_HERMES_TEXT)
        self.assertIn(builder.LOCAL_APP_DATA_PLACEHOLDER, portable)
        self.assertEqual(0, machine_local_hits(portable))

    def test_an_unmarked_machine_local_path_is_left_for_the_rescan(self):
        portable = builder.to_portable_text(SYNTHETIC_UNKNOWN_LOCAL_TEXT)
        self.assertEqual(SYNTHETIC_UNKNOWN_LOCAL_TEXT, portable)
        self.assertGreater(machine_local_hits(portable), 0)


class MachineLocalScanTests(SnapshotFixture):
    def test_no_unclassified_machine_local_path_survives(self):
        unclassified, classified = builder.scan_machine_local(self.staging, self.paths)
        self.assertEqual({}, unclassified)
        self.assertTrue(classified, "the classified fixtures are missing from the snapshot")
        for relative in classified:
            self.assertIn(relative, builder.CLASSIFIED_MACHINE_LOCAL_FIXTURES, relative)

    def test_this_file_is_classified_rather_than_rewritten(self):
        relative = "tests/python/test_build_public_snapshot.py"
        self.assertEqual(
            "snapshot-builder-machine-local-fixture",
            builder.CLASSIFIED_MACHINE_LOCAL_FIXTURES[relative],
        )
        _unclassified, classified = builder.scan_machine_local(self.staging, self.paths)
        self.assertIn(relative, classified)


# --------------------------------------------------------------------------
# Commit shape and identity
# --------------------------------------------------------------------------

class SnapshotCommitTests(SnapshotFixture):
    def test_exactly_one_commit_on_main_with_no_remote(self):
        self.assertEqual("1", git(self.staging, "rev-list", "--count", "HEAD").strip())
        self.assertEqual("main", git(self.staging, "rev-parse", "--abbrev-ref", "HEAD").strip())
        self.assertEqual([], git_lines(self.staging, "remote"))

    def test_the_commit_tree_matches_the_staged_worktree(self):
        committed = sorted(git_lines(self.staging, "ls-tree", "-r", "--name-only", "HEAD"))
        self.assertEqual(sorted(self.paths), committed)
        self.assertEqual([], git_lines(self.staging, "status", "--porcelain", "-uall"))
        for relative in self.paths:
            with open(baseline.repo_path(self.staging, relative), "rb") as handle:
                worktree = handle.read()
            self.assertEqual(git_bytes(self.staging, "show", "HEAD:" + relative), worktree, relative)

    def test_the_commit_carries_the_staging_local_noreply_identity(self):
        recorded = git(self.staging, "log", "-1", "--format=%an%n%ae%n%cn%n%ce")
        name, email, committer_name, committer_email = recorded.replace("\r\n", "\n").split("\n")[:4]
        self.assertEqual(builder.SNAPSHOT_AUTHOR_NAME, name.strip())
        self.assertEqual(builder.SNAPSHOT_AUTHOR_EMAIL, email.strip())
        self.assertEqual(builder.SNAPSHOT_AUTHOR_NAME, committer_name.strip())
        self.assertEqual(builder.SNAPSHOT_AUTHOR_EMAIL, committer_email.strip())
        self.assertTrue(email.strip().endswith("@users.noreply.github.com"))

    def test_the_builder_and_the_verifier_agree_on_the_identity(self):
        self.assertEqual(builder.SNAPSHOT_AUTHOR_NAME, verifier.EXPECTED_AUTHOR_NAME)
        self.assertEqual(builder.SNAPSHOT_AUTHOR_EMAIL, verifier.EXPECTED_AUTHOR_EMAIL)

    def test_the_identity_is_written_into_the_staging_repository_only(self):
        configured = git(self.staging, "config", "--list", "--local")
        self.assertIn("user.email=" + builder.SNAPSHOT_AUTHOR_EMAIL, configured.replace("\r\n", "\n"))
        self.assertNotIn(
            builder.SNAPSHOT_AUTHOR_EMAIL, SNAPSHOT["before_config"] + git(support.REPO_ROOT, "config", "--list", "--local")
        )

    def test_the_builder_git_environment_neutralises_user_configuration(self):
        env = builder.git_env()
        self.assertFalse(os.path.exists(env["GIT_CONFIG_GLOBAL"]))
        self.assertFalse(os.path.exists(env["GIT_CONFIG_SYSTEM"]))
        for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
            self.assertNotIn(name, env)

    def test_the_canonical_repository_is_only_read(self):
        self.assertEqual(SNAPSHOT["before_config"], git(support.REPO_ROOT, "config", "--list", "--local"))
        self.assertEqual(
            SNAPSHOT["before_status"], git(support.REPO_ROOT, "status", "--porcelain", "-uall")
        )
        self.assertEqual(SNAPSHOT["before_head"], git(support.REPO_ROOT, "rev-parse", "HEAD"))


# --------------------------------------------------------------------------
# The verifier against the real snapshot
# --------------------------------------------------------------------------

class VerifierPassTests(SnapshotFixture):
    def test_the_verifier_passes_the_freshly_built_snapshot(self):
        code, stdout, stderr = run_verifier(self.staging)
        self.assertEqual(0, code, stdout + stderr)
        self.assertEqual([], failed_checks(stdout))
        self.assertIn("verify-public-snapshot: PASS (0 check(s) failed)", stdout)

    def test_the_snapshot_carries_the_twenty_approved_packages(self):
        present = verifier._skill_packages(self.paths)
        approved = set(verifier.APPROVED_SKILL_PACKAGES)
        self.assertEqual(20, len(approved))
        self.assertEqual(approved, present & approved)
        self.assertIn("approved-skill-packages  20/20 approved package(s) present", run_verifier(self.staging)[1])

    def test_the_snapshot_carries_exactly_twenty_one_packages(self):
        present = verifier._skill_packages(self.paths)
        self.assertEqual(21, len(verifier.EXPECTED_SKILL_PACKAGES))
        self.assertEqual(set(verifier.EXPECTED_SKILL_PACKAGES), present)
        self.assertIn(verifier.PRESERVED_SKILL_PACKAGE, present)

    def test_the_expected_package_set_is_the_managed_allowlist(self):
        self.assertEqual(sorted(baseline.APPROVED_SKILLS), sorted(verifier.EXPECTED_SKILL_PACKAGES))

    def test_no_credential_fixture_is_classified_by_default(self):
        self.assertEqual({}, verifier.CLASSIFIED_SECRET_FIXTURES)


# --------------------------------------------------------------------------
# The verifier against deliberately dirtied copies
# --------------------------------------------------------------------------

class VerifierFailureTests(SnapshotFixture):
    def dirty_copy(self, files):
        """Copy the built snapshot, add ``files``, and amend the one commit."""
        workspace = tempfile.mkdtemp(prefix="public-snapshot-dirty-")
        self.addCleanup(shutil.rmtree, workspace, True)
        target = os.path.join(workspace, "snapshot")
        shutil.copytree(self.staging, target)
        for relative, text in files.items():
            write_text(target, relative, text)
            git(target, "add", "--force", relative)
        git(target, "commit", "--quiet", "--amend", "--no-edit")
        return target

    def test_a_synthetic_credential_assignment_fails_without_echoing_it(self):
        relative = "runtime-notes.txt"
        staging = self.dirty_copy({relative: SYNTHETIC_ASSIGNMENT_LINE})
        self.assertIn(_ASSIGNMENT_VALUE, read_text(staging, relative))

        code, stdout, stderr = run_verifier(staging)
        self.assertEqual(1, code, stdout + stderr)
        self.assertIn("secret-assignments", failed_checks(stdout))
        self.assertIn("credential-assignment", stdout)
        self.assertIn(relative, stdout)
        self.assertNotIn(_ASSIGNMENT_VALUE, stdout)
        self.assertNotIn(_ASSIGNMENT_VALUE, stderr)
        self.assertNotIn(_ASSIGNMENT_NAME, stdout)

    def test_forbidden_files_are_detected_by_category(self):
        staging = self.dirty_copy({relative: "# fixture\n" for relative in FORBIDDEN_FIXTURES})
        code, stdout, _stderr = run_verifier(staging)
        self.assertEqual(1, code)
        self.assertIn("forbidden-files", failed_checks(stdout))
        self.assertIn(
            "%d forbidden file(s) across %d category(ies)" % (len(FORBIDDEN_FIXTURES), 3), stdout
        )
        for relative in FORBIDDEN_FIXTURES:
            self.assertIn("forbidden file :: %s" % relative, stdout)

    def test_a_machine_local_path_in_a_new_file_is_unclassified(self):
        staging = self.dirty_copy({"docs/notes.md": SYNTHETIC_UNKNOWN_LOCAL_TEXT})
        code, stdout, _stderr = run_verifier(staging)
        self.assertEqual(1, code)
        self.assertIn("machine-local-paths", failed_checks(stdout))
        self.assertIn("unclassified machine-local path :: docs/notes.md", stdout)

    def test_a_missing_required_artifact_fails_the_verifier(self):
        """The verifier owns the site contract: no artifact, no PASS."""
        workspace = tempfile.mkdtemp(prefix="public-snapshot-artifact-")
        self.addCleanup(shutil.rmtree, workspace, True)
        staging = os.path.join(workspace, "snapshot")
        shutil.copytree(self.staging, staging)
        os.remove(baseline.repo_path(staging, "index.html"))
        git(staging, "add", "--all")
        git(staging, "commit", "--quiet", "--amend", "--no-edit")

        code, stdout, _stderr = run_verifier(staging)
        self.assertEqual(1, code)
        self.assertIn("required-site-artifacts", failed_checks(stdout))
        self.assertIn("index.html", stdout)

    def test_the_verifier_rejects_a_snapshot_whose_builder_was_relaxed(self):
        """Independence is behavioural, not a constant that happens to match.

        The mutated snapshot relaxes its own copy of the builder -- the excluded
        documentation prefixes are emptied and the leaked file is declared a
        classified machine-local fixture -- and then leaks a private file that
        carries a machine-local path. The snapshot's own verifier is the one
        run, so a verifier that read its policy from the builder beside it would
        accept this. The verifier must reject it on its own rules.
        """
        leaked = "docs/superpowers/leaked.md"
        staging = self.dirty_copy(
            {
                leaked: SYNTHETIC_UNKNOWN_LOCAL_TEXT,
                "scripts/build-public-snapshot.py": self.relaxed_builder_source(leaked),
            }
        )
        code, stdout, _stderr = run_verifier(
            staging, os.path.join(staging, "scripts", "verify-public-snapshot.py")
        )
        self.assertEqual(1, code)
        self.assertIn("expected-exclusions", failed_checks(stdout))
        self.assertIn("machine-local-paths", failed_checks(stdout))
        self.assertIn("unclassified machine-local path :: %s" % leaked, stdout)

    def relaxed_builder_source(self, leaked):
        """The staged builder source with its exclusion and fixture lists relaxed."""
        source = read_text(self.staging, "scripts/build-public-snapshot.py")
        relaxed = source.replace(
            'EXCLUDED_PREFIXES = ("docs/status/", "docs/superpowers/")',
            "EXCLUDED_PREFIXES = ()",
        ).replace(
            "CLASSIFIED_MACHINE_LOCAL_FIXTURES = {",
            'CLASSIFIED_MACHINE_LOCAL_FIXTURES = {\n    "%s": "relaxed-builder-fixture",' % leaked,
        )
        self.assertNotEqual(source, relaxed, "the builder relaxation did not apply")
        return relaxed

    def test_a_dropped_approved_package_fails_the_package_checks(self):
        workspace = tempfile.mkdtemp(prefix="public-snapshot-dropped-")
        self.addCleanup(shutil.rmtree, workspace, True)
        staging = os.path.join(workspace, "snapshot")
        shutil.copytree(self.staging, staging)
        dropped = "baseline/skills/note-taking/obsidian-vault-lint"
        shutil.rmtree(baseline.repo_path(staging, dropped))
        git(staging, "add", "--all")
        git(staging, "commit", "--quiet", "--amend", "--no-edit")

        code, stdout, _stderr = run_verifier(staging)
        self.assertEqual(1, code)
        self.assertEqual(
            ["approved-skill-packages", "total-skill-packages"], failed_checks(stdout)
        )
        self.assertIn("19/20 approved package(s) present", stdout)


# --------------------------------------------------------------------------
# Refusals, proved against a disposable fixture repository
# --------------------------------------------------------------------------

class BuildRefusalTests(unittest.TestCase):
    """Refusals are proved on a synthetic repository, never on the canonical one."""

    def make_repository(self, tracked, untracked=None):
        workspace = tempfile.mkdtemp(prefix="public-snapshot-canonical-")
        self.addCleanup(shutil.rmtree, workspace, True)
        root = os.path.join(workspace, "canonical")
        os.makedirs(root)
        git(root, "init", "--quiet", "--initial-branch", "main")
        git(root, "config", "user.name", "snapshot-fixture")
        git(root, "config", "user.email", "snapshot-fixture@example.invalid")
        git(root, "config", "commit.gpgsign", "false")
        for relative, text in tracked.items():
            write_text(root, relative, text)
        git(root, "add", "--all")
        git(root, "commit", "--quiet", "-m", "fixture")
        for relative, text in (untracked or {}).items():
            write_text(root, relative, text)
        return workspace, root

    def build(self, root, staging=None, workspace=None):
        if staging is None:
            staging = os.path.join(workspace, "snapshot")
        return run_builder(root, staging), staging

    def test_an_unapproved_untracked_file_is_never_published(self):
        approved_extra = "scripts/verify-public-snapshot.py"
        managed_source = baseline.managed_sources()[0]
        workspace, root = self.make_repository(
            tracked=dict(
                SITE_ARTIFACT_FIXTURES,
                **{
                    "README.md": "fixture\n",
                    "docs/status/handoff.md": "private handoff\n",
                    "docs/superpowers/specs/design.md": "private design\n",
                }
            ),
            untracked={
                approved_extra: "# approved extra\n",
                managed_source: "# managed source\n",
                "notes/scratch.md": "unapproved scratch\n",
            },
        )
        (code, stdout, stderr), staging = self.build(root, workspace=workspace)
        self.assertEqual(0, code, stderr)

        staged = git_lines(staging, "ls-files")
        self.assertIn("README.md", staged)
        self.assertIn(approved_extra, staged)
        self.assertIn(managed_source, staged)
        self.assertNotIn("notes/scratch.md", staged)
        self.assertNotIn("docs/status/handoff.md", staged)
        self.assertNotIn("docs/superpowers/specs/design.md", staged)
        self.assertIn("skipped 1 unapproved untracked file(s)", stdout)
        self.assertIn("excluded 2 file(s)", stdout)

    def test_a_missing_required_site_artifact_fails_the_build_closed(self):
        """A snapshot without the download site is refused, not published."""
        missing = "index.html"
        tracked = {name: text for name, text in SITE_ARTIFACT_FIXTURES.items() if name != missing}
        tracked["README.md"] = "fixture\n"
        workspace, root = self.make_repository(tracked=tracked)
        (code, _stdout, stderr), staging = self.build(root, workspace=workspace)
        self.assertEqual(1, code)
        self.assertIn("required site artifact", stderr)
        self.assertIn(missing, stderr)
        self.assertFalse(os.path.isdir(os.path.join(staging, ".git")))

    def test_a_nonempty_staging_directory_is_refused(self):
        workspace, root = self.make_repository(
            tracked=dict(SITE_ARTIFACT_FIXTURES, **{"README.md": "fixture\n"})
        )
        staging = os.path.join(workspace, "occupied")
        os.makedirs(staging)
        write_text(staging, "existing.txt", "already here\n")
        (code, _stdout, stderr), _staging = self.build(root, staging=staging)
        self.assertEqual(1, code)
        self.assertIn("staging directory is not empty", stderr)
        self.assertFalse(os.path.isdir(os.path.join(staging, ".git")))

    def test_a_surviving_machine_local_path_fails_the_build_closed(self):
        workspace, root = self.make_repository(
            tracked=dict(
                SITE_ARTIFACT_FIXTURES,
                **{"README.md": "fixture\n", "docs/notes.md": SYNTHETIC_UNKNOWN_LOCAL_TEXT}
            )
        )
        (code, _stdout, stderr), staging = self.build(root, workspace=workspace)
        self.assertEqual(1, code)
        self.assertIn("machine-local path(s) remain", stderr)
        self.assertIn("docs/notes.md", stderr)
        self.assertFalse(os.path.isdir(os.path.join(staging, ".git")))


if __name__ == "__main__":
    unittest.main()
