"""Mutation-capable tests for the Hermes runtime authority contract.

The managed ``baseline/hermes/SOUL.md`` installs to ``$HERMES_HOME/SOUL.md`` and
is injected globally, so its normative anchors are the runtime contract. Each
mutation test deletes one anchor from an in-memory copy of the real baseline and
proves the check goes red. A check that cannot go red is not a gate. No test
writes into the repository working tree or touches a live home.
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness_test_support as support  # noqa: E402  (path set above)

SOUL_RELATIVE = "baseline/hermes/SOUL.md"

#: Anchors the runtime contract must carry, as ``(label, exact text)``.
REQUIRED_ANCHORS = (
    ("heartbeat marker", "VAULT_ROUTING_CHECKED"),
    ("absent-heartbeat state", "VAULT_ROUTER_UNAVAILABLE"),
    ("vault readiness failure state", "VAULT_UNAVAILABLE"),
    ("model contract failure state", "MODEL_CONTRACT_UNAVAILABLE"),
    ("index-plus-two-hop ceiling", "index-plus-two-hop"),
    ("raw/ read ban", "never read anything under `raw/`"),
    ("worker excerpt cap", "at most 4,000 characters"),
    ("sol model stamp", "model=gpt-5.6-sol"),
    ("high reasoning stamp", "reasoning=high"),
    ("no automatic Terra fallback", "never auto-complete it with Terra"),
    ("bootstrap stamp expiry", "`bootstrap-pre-activation` stamp expires"),
)

#: Text the runtime contract must not carry, as ``(label, exact text)``.
FORBIDDEN_ANCHORS = (
    ("stale Terra routing target", "gpt-5.6-terra"),
)


def missing_anchors(text):
    """Return the labels of required anchors absent from ``text``."""
    return [label for label, anchor in REQUIRED_ANCHORS if anchor not in text]


def present_forbidden_anchors(text):
    """Return the labels of forbidden anchors present in ``text``."""
    return [label for label, anchor in FORBIDDEN_ANCHORS if anchor in text]


def read_soul():
    return support.read_fixture(support.REPO_ROOT, SOUL_RELATIVE)


class SoulRuntimeContractTests(unittest.TestCase):
    """Checks against the real repository baseline."""

    def setUp(self):
        self.text = read_soul()

    def test_required_runtime_anchors_present(self):
        self.assertEqual([], missing_anchors(self.text))

    def test_no_forbidden_runtime_anchors(self):
        self.assertEqual([], present_forbidden_anchors(self.text))


class SoulRuntimeContractMutationTests(unittest.TestCase):
    """Mutations of an in-memory baseline copy must be detected."""

    def setUp(self):
        self.text = read_soul()

    def test_removing_any_required_anchor_is_detected(self):
        for label, anchor in REQUIRED_ANCHORS:
            with self.subTest(anchor=label):
                mutated = self.text.replace(anchor, "")
                self.assertNotEqual(self.text, mutated, "anchor text was already absent")
                self.assertIn(label, missing_anchors(mutated))

    def test_restoring_a_forbidden_anchor_is_detected(self):
        for label, anchor in FORBIDDEN_ANCHORS:
            with self.subTest(anchor=label):
                mutated = self.text + "\n" + anchor + "\n"
                self.assertIn(label, present_forbidden_anchors(mutated))


if __name__ == "__main__":
    unittest.main()
