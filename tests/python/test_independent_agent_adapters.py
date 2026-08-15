"""Tests for the independent Claude and Codex adapter boundaries.

An independent session is any Claude or Codex session that is not executing a
Hermes ``APPROVED_WORKER_TASK``. These tests pin the clauses that keep such a
session from opening the Vault on its own initiative and from claiming
supervisor authority it does not have. Each clause is asserted against both
managed global instruction files, because the boundary is identical even though
the wording is tool-specific.

The tests read the repository baseline only; nothing here writes into the
working tree or touches a live Claude, Codex, or Hermes home.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness_test_support as support  # noqa: E402  (path set above)

#: The managed global instruction file of each independent agent.
ADAPTERS = (
    "baseline/agents/claude/CLAUDE.md",
    "baseline/agents/codex/AGENTS.md",
)

#: Clause identifier -> pattern that must match somewhere in every adapter.
#: Patterns never span a line break, so a requirement cannot be satisfied by
#: unrelated sentences that happen to sit near each other.
CLAUSES = {
    "vault-explicit-request-only": r"(?i)vault[^\n]*only when the user explicitly (?:requests|asks)",
    "vault-index-first": r"(?i)start[^\n]*`wiki/index\.md`",
    "vault-selective-read": r"(?i)(?:read selectively|only the (?:links|pages) that)",
    "vault-raw-forbidden": r"(?i)(?:never|do not) read[^\n]*`raw/`",
    "no-automatic-domain-router": r"(?i)(?:never|do not|no)[^\n]{0,40}automatic domain routing",
    "no-routing-jsonl": r"(?i)(?:never|do not|no)[^\n]{0,60}routing JSONL",
    "disclose-vault-evidence": r"(?i)whether vault evidence was used",
    "name-source-pages": r"(?i)source pages",
    "no-contract-authority": (
        r"(?i)cannot issue, approve, or reapprove[^\n]*APPROVED_WORKER_TASK"
    ),
    "executes-complete-contract": (
        r"(?i)APPROVED_WORKER_TASK[^\n]*without repeating brainstorming"
    ),
}


def read_adapter(relative):
    return support.read_fixture(support.REPO_ROOT, relative)


def original_graphify_block(relative):
    """Return the imported graphify block exactly as it entered the baseline."""
    revision = support.baseline.GRAPHIFY_BASE_REVISION
    completed = subprocess.run(
        ["git", "show", "%s:%s" % (revision, relative)],
        cwd=support.REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        raise AssertionError(
            "cannot read %s at %s: %s"
            % (relative, revision, completed.stderr.decode("utf-8", "replace").strip())
        )
    return completed.stdout.decode("utf-8").replace("\r\n", "\n").strip("\n")


class IndependentAgentAdapterTests(unittest.TestCase):
    """Every clause holds in both the Claude and the Codex adapter."""

    def assertClause(self, clause):
        pattern = CLAUSES[clause]
        for relative in ADAPTERS:
            with self.subTest(adapter=relative):
                self.assertRegex(
                    read_adapter(relative),
                    pattern,
                    "%s does not state the %s clause" % (relative, clause),
                )

    # -- Vault access boundary ---------------------------------------------

    def test_vault_is_read_only_on_explicit_user_request(self):
        self.assertClause("vault-explicit-request-only")

    def test_vault_reads_start_at_the_wiki_index(self):
        self.assertClause("vault-index-first")

    def test_vault_reads_are_selective(self):
        self.assertClause("vault-selective-read")

    def test_raw_directory_is_forbidden(self):
        self.assertClause("vault-raw-forbidden")

    # -- Hermes routing machinery stays out of independent sessions --------

    def test_automatic_domain_routing_is_refused(self):
        self.assertClause("no-automatic-domain-router")

    def test_routing_jsonl_is_never_written(self):
        self.assertClause("no-routing-jsonl")

    # -- Disclosure --------------------------------------------------------

    def test_vault_evidence_use_is_disclosed(self):
        self.assertClause("disclose-vault-evidence")

    def test_source_pages_are_identified(self):
        self.assertClause("name-source-pages")

    # -- Authority boundary ------------------------------------------------

    def test_independent_session_cannot_issue_or_approve_a_worker_contract(self):
        self.assertClause("no-contract-authority")

    def test_complete_worker_contract_runs_without_re_brainstorming(self):
        self.assertClause("executes-complete-contract")

    # -- Preservation ------------------------------------------------------

    def test_imported_graphify_block_is_still_present(self):
        for relative in ADAPTERS:
            with self.subTest(adapter=relative):
                block = original_graphify_block(relative)
                self.assertTrue(block, "%s has no imported graphify block" % relative)
                self.assertIn(
                    block,
                    read_adapter(relative),
                    "%s no longer contains the imported graphify block" % relative,
                )


if __name__ == "__main__":
    unittest.main()
