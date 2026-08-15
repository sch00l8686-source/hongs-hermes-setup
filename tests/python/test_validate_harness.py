"""Red-capable tests for the fail-closed harness policy validator.

Each mutation test proves the validator actually fails when a required policy
rule is removed or a forbidden mandate is introduced. A validator that cannot
go red is not a gate.
"""

from __future__ import annotations

import os
import shutil
import unittest

import harness_test_support as support

#: Phase 2 rules read three sources that live outside ``baseline/``: the routing
#: contract, the monthly cost collector, and the approved design authority. The
#: shared fixture root copies only ``baseline/`` and ``provenance/``, so these
#: are copied in as well; otherwise every mutation would also report the Phase 2
#: rules as unverifiable and no test could isolate a single rule.
PHASE2_FIXTURE_FILES = (
    "contracts/vault-query-routing-contract.md",
    "scripts/record-supervisor-cost.py",
    "docs/superpowers/specs/2026-08-14-global-runtime-contract-design.md",
)


def make_phase2_fixture_root():
    """A disposable fixture root the Phase 1 and Phase 2 rules can both read."""
    root = support.make_fixture_root()
    for relative in PHASE2_FIXTURE_FILES:
        support.write_fixture(root, relative, support.read_fixture(support.REPO_ROOT, relative))
    return root


class ValidatorBaselineTests(unittest.TestCase):
    """Checks against the real repository baseline."""

    def test_only_pending_global_trigger_rules_fail(self):
        _code, findings = support.run_validator(support.REPO_ROOT)
        unexpected = set(support.failing_rules(findings)) - support.PENDING_GLOBAL_TRIGGER_RULES
        self.assertEqual(
            set(), unexpected, "unexpected policy failures: %s" % sorted(unexpected)
        )

    def test_global_instruction_triggers_present(self):
        """Rules E040-E042 cover the global instruction triggers.

        E040 (SOUL.md harness rules), E041 (global Claude CLAUDE.md trigger),
        and E042 (global Codex AGENTS.md trigger) are green once the global
        instruction files carry the triggers and the conjunctive one-line
        exception sentence.
        """
        code, findings = support.run_validator(support.REPO_ROOT)
        self.assertEqual(
            0,
            code,
            "global instruction triggers are incomplete: %s"
            % support.failing_rules(findings),
        )


class ValidatorMutationTests(unittest.TestCase):
    """Mutations of a disposable baseline copy must be detected."""

    def setUp(self):
        self.root = make_phase2_fixture_root()
        self.addCleanup(shutil.rmtree, self.root, True)

    def assertRuleFails(self, rule):
        code, findings = support.run_validator(self.root)
        self.assertEqual(1, code)
        self.assertIn(rule, support.failing_rules(findings))

    def assertRulePasses(self, rule):
        _code, findings = support.run_validator(self.root)
        self.assertNotIn(rule, support.failing_rules(findings))

    # -- E001 managed file set -------------------------------------------

    def test_missing_managed_file_is_detected(self):
        os.remove(support.fixture_path(self.root, "baseline/skills/superpowers/writing-plans/SKILL.md"))
        self.assertRuleFails("E001")

    def test_unlisted_baseline_file_is_detected(self):
        support.write_fixture(self.root, "baseline/skills/superpowers/smuggled.md", "extra\n")
        self.assertRuleFails("E001")

    # -- E002 frontmatter -------------------------------------------------

    def test_frontmatter_name_mismatch_is_detected(self):
        relative = "baseline/skills/superpowers/brainstorming/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("name: brainstorming", "name: brainstorm", 1)
        )
        self.assertRuleFails("E002")

    def test_missing_frontmatter_delimiter_is_detected(self):
        relative = "baseline/skills/superpowers/executing-plans/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(self.root, relative, text[4:])
        self.assertRuleFails("E002")

    def test_empty_description_is_detected(self):
        relative = "baseline/skills/superpowers/dispatching-parallel-agents/SKILL.md"
        text = support.read_fixture(self.root, relative)
        old = [line for line in text.split("\n") if line.startswith("description:")][0]
        support.write_fixture(self.root, relative, text.replace(old, "description:", 1))
        self.assertRuleFails("E002")

    # -- E003 machine-local paths ----------------------------------------

    def test_machine_local_path_in_skill_is_detected(self):
        relative = "baseline/skills/automation/execution-continuity/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text + "\nRun from C:\\Users\\HongGyu\\AppData\\Local\\hermes.\n"
        )
        self.assertRuleFails("E003")

    def test_env_home_variable_in_skill_is_detected(self):
        relative = "baseline/skills/software-development/plan/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(self.root, relative, text + "\nSave under %LOCALAPPDATA%/hermes.\n")
        self.assertRuleFails("E003")

    # -- E010-E018 required rules ----------------------------------------

    def test_missing_one_line_exception_is_detected(self):
        relative = "baseline/skills/superpowers/using-superpowers/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text.replace("exactly-one-line mechanical exception", "small-change exception"),
        )
        self.assertRuleFails("E010")

    def test_missing_brainstorming_hard_gate_is_detected(self):
        relative = "baseline/skills/superpowers/brainstorming/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(self.root, relative, text.replace("<HARD-GATE>", "<SOFT-GATE>", 1))
        self.assertRuleFails("E011")

    def test_missing_writing_plans_authority_is_detected(self):
        relative = "baseline/skills/superpowers/writing-plans/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text.replace("single authority for implementation plans", "one option for plans", 1),
        )
        self.assertRuleFails("E012")

    def test_missing_approved_worker_contract_is_detected(self):
        relative = "baseline/skills/superpowers/using-superpowers/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("Do not re-run brainstorming.", "", 1)
        )
        self.assertRuleFails("E013")

    def test_missing_goal_fidelity_lock_is_detected(self):
        relative = "baseline/skills/superpowers/writing-plans/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("## Goal Fidelity Lock", "## Plan Header Notes")
        )
        self.assertRuleFails("E014")

    def test_missing_goal_fidelity_in_worker_contract_is_detected(self):
        relative = "baseline/skills/autonomous-ai-agents/subagent-coding-context/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("GOAL_DRIFT_REJECTED", "REJECTED")
        )
        self.assertRuleFails("E014")

    def test_missing_goal_fidelity_in_completion_gate_is_detected(self):
        relative = "baseline/skills/superpowers/verification-before-completion/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("## Goal Fidelity Checks", "## Extra Checks", 1)
        )
        self.assertRuleFails("E014")

    def test_missing_proposal_duty_is_detected(self):
        relative = "baseline/skills/superpowers/executing-plans/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("Non-executing proposal:", "Idea:", 1)
        )
        self.assertRuleFails("E015")

    def test_missing_parallelism_cap_is_detected(self):
        relative = "baseline/skills/superpowers/dispatching-parallel-agents/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text.replace("At most three active implementation workers", "Dispatch freely"),
        )
        self.assertRuleFails("E016")

    def test_missing_direct_verification_is_detected(self):
        relative = "baseline/skills/autonomous-ai-agents/supervised-agent-workflow/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text.replace("Worker reports are not evidence", "Worker reports suffice", 1),
        )
        self.assertRuleFails("E017")

    def test_missing_exceptional_review_rule_is_detected(self):
        relative = "baseline/skills/superpowers/subagent-driven-development/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root, relative, text.replace("Exceptional Review Only", "Review Stage", 1)
        )
        self.assertRuleFails("E018")

    # -- E020 forbidden default review mandates ---------------------------

    def test_two_stage_review_mandate_is_detected(self):
        relative = "baseline/skills/superpowers/subagent-driven-development/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text + "\n## Standing policy\n\nEvery task runs a two-stage review before integration.\n",
        )
        self.assertRuleFails("E020")

    def test_fresh_reviewer_per_task_mandate_is_detected(self):
        relative = "baseline/skills/autonomous-ai-agents/supervised-agent-workflow/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text + "\n## Standing policy\n\nEach task must receive a fresh reviewer.\n",
        )
        self.assertRuleFails("E020")

    def test_default_sol_review_mandate_is_detected(self):
        relative = "baseline/skills/autonomous-ai-agents/mixed-model-agent-orchestration/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text + "\n## Standing policy\n\nBy default a Sol review runs after every task.\n",
        )
        self.assertRuleFails("E020")

    def test_prohibitive_review_text_is_not_flagged(self):
        """The approved baseline already forbids these mandates; that must stay green."""
        self.assertRulePasses("E020")

    # -- E030 preserved graphify blocks ------------------------------------

    def test_altered_claude_graphify_block_is_detected(self):
        relative = "baseline/agents/claude/CLAUDE.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(self.root, relative, text.replace("graphify", "graphed", 1))
        self.assertRuleFails("E030")

    def test_altered_codex_graphify_block_is_detected(self):
        relative = "baseline/agents/codex/AGENTS.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(self.root, relative, text.replace("graphify-out/", "graph-out/", 1))
        self.assertRuleFails("E030")

    def test_appending_a_trigger_preserves_the_graphify_block(self):
        """A global trigger may be added around the block, never inside it."""
        for relative in ("baseline/agents/claude/CLAUDE.md", "baseline/agents/codex/AGENTS.md"):
            text = support.read_fixture(self.root, relative)
            support.write_fixture(
                self.root,
                relative,
                "# harness\n\nStub trigger.\n\n" + text + "\nTrailing note.\n",
            )
        self.assertRulePasses("E030")

    # -- E031 plan adapter -------------------------------------------------

    def test_duplicated_plan_authority_is_detected(self):
        relative = "baseline/skills/software-development/plan/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text + "\n### Required sections\n\n1. Goal Fidelity Lock\n2. Observable goal\n",
        )
        self.assertRuleFails("E031")

    def test_plan_dropping_its_adapter_declaration_is_detected(self):
        relative = "baseline/skills/software-development/plan/SKILL.md"
        text = support.read_fixture(self.root, relative)
        support.write_fixture(
            self.root,
            relative,
            text.replace("It does not define planning standards of its own", "It defines them", 1),
        )
        self.assertRuleFails("E031")

    # -- E040-E042 global instruction triggers -----------------------------

    #: The conjunctive one-line exception sentence carried by every global
    #: instruction file. Each mutation below removes or weakens one conjunct.
    ONE_LINE_SENTENCE = (
        "Only a truly mechanical, reversible, exact one-line correction may bypass "
        "the full gate, and only when intent, target, expected result, and "
        "verification are already explicit."
    )

    def mutate(self, relative, old, new):
        text = support.read_fixture(self.root, relative)
        self.assertIn(old, text, "fixture no longer contains %r" % old)
        support.write_fixture(self.root, relative, text.replace(old, new, 1))

    def test_soul_dropping_the_one_line_exception_is_detected(self):
        """Removing the sentence outright turns E040 red."""
        self.mutate("baseline/hermes/SOUL.md", self.ONE_LINE_SENTENCE, "")
        self.assertRuleFails("E040")

    def test_claude_weakening_the_one_line_exception_is_detected(self):
        """Dropping 'truly mechanical' and 'reversible' turns E041 red."""
        self.mutate(
            "baseline/agents/claude/CLAUDE.md",
            "a truly mechanical, reversible, exact one-line correction",
            "an exact one-line correction",
        )
        self.assertRuleFails("E041")

    def test_codex_dropping_the_explicitness_clause_is_detected(self):
        """Dropping intent/target/expected result/verification turns E042 red."""
        self.mutate(
            "baseline/agents/codex/AGENTS.md",
            ", and only when intent, target, expected result, and verification "
            "are already explicit.",
            ".",
        )
        self.assertRuleFails("E042")

    def test_one_line_exception_split_across_sentences_is_detected(self):
        """The conjuncts must hold in one sentence, not be scattered."""
        self.mutate(
            "baseline/hermes/SOUL.md",
            "exact one-line correction may bypass the full gate",
            "exact one-line correction is allowed. Such a correction may bypass the full gate",
        )
        self.assertRuleFails("E040")

    def test_intact_one_line_exception_passes(self):
        """The unmutated baseline satisfies all three global trigger rules."""
        for rule in ("E040", "E041", "E042"):
            self.assertRulePasses(rule)


class Phase2ValidatorMutationTests(unittest.TestCase):
    """E050-E057: each mutation removes exactly one decisive Phase 2 anchor.

    Every test asserts the *only* rule that turns red is the intended one, so a
    rule that fires on unrelated edits is caught here rather than in review.
    """

    def setUp(self):
        self.root = make_phase2_fixture_root()
        self.addCleanup(shutil.rmtree, self.root, True)

    def mutate(self, relative, old, new):
        text = support.read_fixture(self.root, relative)
        self.assertIn(old, text, "fixture no longer contains %r" % old)
        support.write_fixture(self.root, relative, text.replace(old, new, 1))

    def assertOnlyRuleFails(self, rule):
        code, findings = support.run_validator(self.root)
        self.assertEqual(1, code)
        failed = set(support.failing_rules(findings)) - support.PENDING_GLOBAL_TRIGGER_RULES
        self.assertEqual([rule], sorted(failed))

    def test_unmutated_phase2_fixture_is_clean(self):
        code, findings = support.run_validator(self.root)
        self.assertEqual(0, code, "unexpected findings: %s" % support.failing_rules(findings))

    # -- E050 plugin manifest and single hook registration -----------------

    def test_plugin_manifest_without_the_hook_is_detected(self):
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/plugin.yaml",
            "provides_hooks:\n  - pre_llm_call\n",
            "provides_hooks:\n",
        )
        self.assertOnlyRuleFails("E050")

    def test_second_hook_registration_is_detected(self):
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/__init__.py",
            '    ctx.register_hook("pre_llm_call", _pre_llm_call)\n',
            '    ctx.register_hook("pre_llm_call", _pre_llm_call)\n'
            '    ctx.register_hook("post_llm_call", _pre_llm_call)\n',
        )
        self.assertOnlyRuleFails("E050")

    # -- E051 fixed router paths and content-free telemetry ----------------

    def test_question_text_in_the_routing_event_is_detected(self):
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/router.py",
            '                "session": session_id,\n',
            '                "session": session_id,\n'
            '                "question": normalized_question,\n',
        )
        self.assertOnlyRuleFails("E051")

    def test_hardcoded_vault_root_fallback_is_detected(self):
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/router.py",
            'os.environ.get("HONG_VAULT_ROOT")',
            'os.environ.get("HONG_VAULT_ROOT", "D:/vault")',
        )
        self.assertOnlyRuleFails("E051")

    def test_moved_routing_log_path_is_detected(self):
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/router.py",
            'log = home / "logs" / "vault-routing.jsonl"',
            'log = home / "vault-routing.jsonl"',
        )
        self.assertOnlyRuleFails("E051")

    # -- E052 routing contract and matching boundaries ---------------------

    def test_dropped_domain_group_is_detected(self):
        self.mutate(
            "contracts/vault-query-routing-contract.md",
            "- domain-group: Niagara :: Niagara | 나이아가라\n",
            "",
        )
        self.assertOnlyRuleFails("E052")

    def test_closed_korean_right_boundary_is_detected(self):
        """Closing the right boundary would silently drop 빔프로젝터 and 폭발물."""
        self.mutate(
            "baseline/hermes/plugins/hongs-vault-router/router.py",
            "right_ok = korean or end == len(text) or not _WORD.match(text[end])",
            "right_ok = end == len(text) or not _WORD.match(text[end])",
        )
        self.assertOnlyRuleFails("E052")

    # -- E053 Hermes heartbeat, Vault, and model fail-closed ---------------

    def test_telemetry_coupled_heartbeat_is_detected(self):
        self.mutate(
            "baseline/hermes/SOUL.md",
            "Heartbeat validity is independent of telemetry",
            "Heartbeat validity depends on telemetry",
        )
        self.assertOnlyRuleFails("E053")

    def test_dropped_worker_vault_context_cap_is_detected(self):
        self.mutate(
            "baseline/hermes/SOUL.md",
            "at most 4,000 characters of required Vault excerpts",
            "the required Vault excerpts",
        )
        self.assertOnlyRuleFails("E053")

    # -- E054 independent Claude/Codex adapters ----------------------------

    def test_claude_dropping_the_no_issuance_clause_is_detected(self):
        self.mutate(
            "baseline/agents/claude/CLAUDE.md",
            "This session cannot issue, approve, or reapprove an `APPROVED_WORKER_TASK`",
            "This session may issue an `APPROVED_WORKER_TASK`",
        )
        self.assertOnlyRuleFails("E054")

    def test_codex_dropping_the_explicit_only_clause_is_detected(self):
        self.mutate(
            "baseline/agents/codex/AGENTS.md",
            "Open the Vault only when the user explicitly asks for it in the current request.",
            "Open the Vault whenever it looks relevant.",
        )
        self.assertOnlyRuleFails("E054")

    # -- E055 monthly supervisor cost record -------------------------------

    def test_changed_hybrid_review_threshold_is_detected(self):
        self.mutate(
            "scripts/record-supervisor-cost.py",
            'REVIEW_THRESHOLD_USD = Decimal("100")',
            'REVIEW_THRESHOLD_USD = Decimal("50")',
        )
        self.assertOnlyRuleFails("E055")

    def test_inferred_actual_billing_amount_is_detected(self):
        """The actually-billed fields may only ever come from explicit arguments."""
        self.mutate(
            "scripts/record-supervisor-cost.py",
            '"actual_provider_billed_usd": options.actual_provider_billed_usd',
            '"actual_provider_billed_usd": usd(estimated)',
        )
        self.assertOnlyRuleFails("E055")

    # -- E056 shared model keys --------------------------------------------

    def test_fourth_shared_model_key_is_detected(self):
        self.mutate(
            PHASE2_FIXTURE_FILES[2],
            "agent.reasoning_effort = high\n",
            "agent.reasoning_effort = high\nagent.max_output_tokens = 64000\n",
        )
        self.assertOnlyRuleFails("E056")

    def test_dropped_whole_file_config_prohibition_is_detected(self):
        self.mutate(
            PHASE2_FIXTURE_FILES[2],
            "Whole-file `config.yaml` copying is forbidden.",
            "Whole-file `config.yaml` copying is allowed.",
        )
        self.assertOnlyRuleFails("E056")

    # -- E057 model stamp, bootstrap expiry, no Terra fallback -------------

    def test_terra_auto_fallback_is_detected(self):
        self.mutate(
            "baseline/hermes/SOUL.md",
            "never auto-complete it with Terra or any other model",
            "auto-complete it with Terra instead",
        )
        self.assertOnlyRuleFails("E057")

    def test_dropped_bootstrap_stamp_expiry_is_detected(self):
        self.mutate(
            "baseline/hermes/SOUL.md",
            "The `bootstrap-pre-activation` stamp expires at Sol/high activation.",
            "The `bootstrap-pre-activation` stamp stays valid.",
        )
        self.assertOnlyRuleFails("E057")


if __name__ == "__main__":
    unittest.main()
