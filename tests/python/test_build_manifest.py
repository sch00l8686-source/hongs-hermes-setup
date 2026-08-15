"""Tests for the deterministic managed-file manifest builder.

The manifest is the installer's only source of truth about what gets copied and
where. These tests prove it is deterministic, sorted, restricted to the explicit
allowlist, and consistent with the recorded provenance.
"""

from __future__ import annotations

import json
import os
import shutil
import tempfile
import unittest

import harness_test_support as support

baseline = support.baseline

APPROVED_TARGET_ROOTS = set(baseline.TARGET_ROOTS)

#: The exact managed file count: the 29 Phase 1 files, the three Phase 2 plugin
#: files, and the 14 files of the nine packages added by the public-snapshot
#: expansion. The number is spelled out here so growing the allowlist by
#: accident fails a test instead of silently widening the installed set.
MANAGED_FILE_COUNT = 46

#: The twenty approved skill names, as bare names. The managed baseline carries
#: exactly these twenty plus the preserved ``plan`` package, so the total package
#: count is twenty-one. Both lists are spelled out here: an accidental addition,
#: a rename, or a dropped package fails a test rather than changing the installed
#: set quietly.
APPROVED_SKILL_NAMES = (
    "agent-context-efficiency",
    "agent-context-governance",
    "brainstorming",
    "dispatching-parallel-agents",
    "execution-continuity",
    "executing-plans",
    "finishing-a-development-branch",
    "mixed-model-agent-orchestration",
    "obsidian-vault-ingest",
    "obsidian-vault-lint",
    "obsidian-vault-query",
    "receiving-code-review",
    "review-gated-config-distribution",
    "subagent-coding-context",
    "subagent-driven-development",
    "supervised-agent-workflow",
    "using-git-worktrees",
    "using-superpowers",
    "verification-before-completion",
    "writing-plans",
)

#: The one preserved package that is not part of the approved twenty.
PRESERVED_EXTRA_PACKAGE = "software-development/plan"

#: Every managed package, as ``<category>/<name>``.
MANAGED_PACKAGES = (
    "automation/execution-continuity",
    "autonomous-ai-agents/agent-context-efficiency",
    "autonomous-ai-agents/agent-context-governance",
    "autonomous-ai-agents/mixed-model-agent-orchestration",
    "autonomous-ai-agents/review-gated-config-distribution",
    "autonomous-ai-agents/subagent-coding-context",
    "autonomous-ai-agents/supervised-agent-workflow",
    "note-taking/obsidian-vault-ingest",
    "note-taking/obsidian-vault-lint",
    "note-taking/obsidian-vault-query",
    "software-development/plan",
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

#: The only plugin destinations the harness may ever install, under HermesHome.
PLUGIN_DESTINATIONS = (
    "plugins/hongs-vault-router/__init__.py",
    "plugins/hongs-vault-router/plugin.yaml",
    "plugins/hongs-vault-router/router.py",
)


class ManifestBuilderTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.mkdtemp(prefix="harness-manifest-")
        self.addCleanup(shutil.rmtree, self.workspace, True)
        self.output = os.path.join(self.workspace, "harness-manifest.json")

    def build(self, root=None, check=False, output=None):
        return support.run_manifest_builder(
            root or support.REPO_ROOT, output or self.output, check=check
        )

    def load(self, path=None):
        with open(path or self.output, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))

    def test_build_succeeds_from_the_repository(self):
        code, stdout, stderr = self.build()
        self.assertEqual(0, code, stderr)
        self.assertIn("wrote", stdout)

    def test_output_is_byte_identical_across_runs(self):
        self.build()
        with open(self.output, "rb") as handle:
            first = handle.read()
        second_output = os.path.join(self.workspace, "second.json")
        self.build(output=second_output)
        with open(second_output, "rb") as handle:
            second = handle.read()
        self.assertEqual(first, second, "manifest output is not deterministic")

    def test_check_mode_detects_a_stale_manifest(self):
        self.build()
        code, _stdout, _stderr = self.build(check=True)
        self.assertEqual(0, code)

        with open(self.output, "rb") as handle:
            payload = handle.read().decode("utf-8")
        with open(self.output, "wb") as handle:
            handle.write(payload.replace('"schemaVersion": 1', '"schemaVersion": 2').encode("utf-8"))
        code, _stdout, stderr = self.build(check=True)
        self.assertEqual(1, code)
        self.assertIn("stale", stderr)

    def test_records_cover_the_allowlist_exactly(self):
        self.build()
        document = self.load()
        self.assertEqual(baseline.SCHEMA_VERSION, document["schemaVersion"])
        sources = sorted(record["source"] for record in document["files"])
        self.assertEqual(baseline.managed_sources(), sources)

    def test_manifest_declares_exactly_forty_six_managed_files(self):
        self.build()
        self.assertEqual(MANAGED_FILE_COUNT, len(self.load()["files"]))

    def test_allowlist_is_exactly_the_twenty_one_managed_packages(self):
        self.assertEqual(sorted(MANAGED_PACKAGES), sorted(baseline.APPROVED_SKILLS))
        self.assertEqual(21, len(baseline.APPROVED_SKILLS))

    def test_the_twenty_approved_names_are_covered(self):
        """The twenty approved names, plus ``plan`` as the preserved extra."""
        names = sorted(skill.split("/")[-1] for skill in baseline.APPROVED_SKILLS)
        self.assertEqual(sorted(APPROVED_SKILL_NAMES + ("plan",)), names)
        self.assertEqual(20, len(APPROVED_SKILL_NAMES))
        self.assertIn(PRESERVED_EXTRA_PACKAGE, baseline.APPROVED_SKILLS)

    def test_every_managed_package_installs_under_its_own_skill_tree(self):
        self.build()
        installed = {
            "/".join(record["destination"].split("/")[1:3])
            for record in self.load()["files"]
            if record["destination"].startswith("skills/")
        }
        self.assertEqual(set(MANAGED_PACKAGES), installed)

    def test_plugin_files_are_managed_at_their_exact_destinations(self):
        self.build()
        installed = {
            record["destination"]: record["source"]
            for record in self.load()["files"]
            if record["targetRoot"] == "HermesHome"
            and record["destination"].startswith("plugins/")
        }
        self.assertEqual(
            {
                destination: "baseline/hermes/%s" % destination
                for destination in PLUGIN_DESTINATIONS
            },
            installed,
        )

    def test_records_are_sorted_and_well_formed(self):
        self.build()
        records = self.load()["files"]
        keys = sorted(("source", "targetRoot", "destination", "sha256"))
        ordering = [(record["targetRoot"], record["destination"]) for record in records]
        self.assertEqual(sorted(ordering), ordering, "records are not deterministically sorted")
        self.assertEqual(len(set(ordering)), len(ordering), "duplicate destination in manifest")
        for record in records:
            self.assertEqual(keys, sorted(record.keys()))
            self.assertIn(record["targetRoot"], APPROVED_TARGET_ROOTS)
            self.assertTrue(record["source"].startswith("baseline/"))
            self.assertNotIn("..", record["destination"])
            self.assertFalse(record["destination"].startswith("/"))
            self.assertRegex(record["sha256"], r"^[0-9a-f]{64}$")

    def test_hashes_match_the_baseline_bytes(self):
        self.build()
        for record in self.load()["files"]:
            expected = baseline.sha256_file(
                baseline.repo_path(support.REPO_ROOT, record["source"])
            )
            self.assertEqual(expected, record["sha256"], record["source"])

    def test_destinations_are_restricted_to_the_approved_set(self):
        self.build()
        for record in self.load()["files"]:
            destination = record["destination"]
            root = record["targetRoot"]
            if root == "ClaudeHome":
                self.assertEqual("CLAUDE.md", destination)
            elif root == "CodexHome":
                self.assertEqual("AGENTS.md", destination)
            else:
                approved = (
                    destination == "SOUL.md"
                    or destination in PLUGIN_DESTINATIONS
                    or any(
                        destination.startswith("skills/%s/" % skill)
                        for skill in baseline.APPROVED_SKILLS
                    )
                )
                self.assertTrue(approved, "unapproved destination: %s" % destination)


class ManifestBuilderFailureTests(unittest.TestCase):
    def setUp(self):
        self.root = support.make_fixture_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.workspace = tempfile.mkdtemp(prefix="harness-manifest-fail-")
        self.addCleanup(shutil.rmtree, self.workspace, True)
        self.output = os.path.join(self.workspace, "harness-manifest.json")

    def test_provenance_mismatch_is_rejected(self):
        relative = "provenance/upstream-lock.json"
        document = json.loads(support.read_fixture(self.root, relative))
        document["skills"] = document["skills"][:-1]
        support.write_fixture(self.root, relative, json.dumps(document, indent=2) + "\n")
        code, _stdout, stderr = support.run_manifest_builder(self.root, self.output)
        self.assertEqual(1, code)
        self.assertIn("disagree", stderr)
        self.assertFalse(os.path.exists(self.output))

    def test_missing_managed_source_is_rejected(self):
        os.remove(
            support.fixture_path(self.root, "baseline/skills/software-development/plan/SKILL.md")
        )
        code, _stdout, stderr = support.run_manifest_builder(self.root, self.output)
        self.assertEqual(1, code)
        self.assertIn("managed source missing", stderr)
        self.assertFalse(os.path.exists(self.output))

    def test_missing_provenance_is_rejected(self):
        os.remove(support.fixture_path(self.root, "provenance/upstream-lock.json"))
        code, _stdout, stderr = support.run_manifest_builder(self.root, self.output)
        self.assertEqual(1, code)
        self.assertIn("upstream-lock.json", stderr)

    def test_unlisted_baseline_file_is_not_manifested(self):
        """A file added under baseline/ is never silently discovered."""
        support.write_fixture(self.root, "baseline/skills/superpowers/stray.md", "stray\n")
        code, _stdout, stderr = support.run_manifest_builder(self.root, self.output)
        self.assertEqual(0, code, stderr)
        with open(self.output, "rb") as handle:
            document = json.loads(handle.read().decode("utf-8"))
        sources = [record["source"] for record in document["files"]]
        self.assertNotIn("baseline/skills/superpowers/stray.md", sources)


class PortableLineEndingTests(unittest.TestCase):
    """The managed baseline and manifest must be LF in every checkout.

    SHA-256 is byte-sensitive, so a CRLF checkout silently invalidates all 32
    recorded hashes. ``.gitattributes`` pins them; these tests prove the pin
    works and that removing it is caught.
    """

    def fresh_checkout(self, attributes=None):
        scratch, checkout = support.make_portable_checkout(attributes)
        self.addCleanup(shutil.rmtree, scratch, True)
        return checkout

    def test_worktree_managed_bytes_equal_the_git_blobs(self):
        for relative in baseline.managed_sources():
            worktree = support.read_bytes(support.REPO_ROOT, relative)
            self.assertEqual(
                support.git_blob(support.REPO_ROOT, relative), worktree, relative
            )

    def test_fresh_autocrlf_checkout_is_byte_identical(self):
        self.assertEqual([], support.portable_checkout_failures(self.fresh_checkout()))

    def test_dropping_the_lf_rules_is_caught(self):
        checkout = self.fresh_checkout("# no line-ending rules\n")
        failures = support.portable_checkout_failures(checkout)
        self.assertEqual(
            sorted(baseline.managed_sources() + [support.MANIFEST_RELATIVE]),
            [failure.split(":")[0] for failure in failures],
        )

    def test_weakening_the_manifest_rule_is_caught(self):
        checkout = self.fresh_checkout("baseline/** text eol=lf\n")
        self.assertEqual(
            ["%s: checkout bytes differ from the Git blob" % support.MANIFEST_RELATIVE],
            support.portable_checkout_failures(checkout),
        )


if __name__ == "__main__":
    unittest.main()
