"""Behaviour tests for the deterministic Vault routing plugin.

Every test drives the real router module loaded from the plugin directory and
the real versioned contract stored in ``contracts/``. No test touches a live
Hermes home or a live Vault: each case builds a disposable vault root and a
disposable Hermes home under the system temp directory.

The intentional Korean prefix matches (``빔프로젝터``, ``폭발물``) are asserted
positively on purpose. Opening the Korean right boundary is what makes
particle-bearing questions such as ``빔을 쏘는 이펙트`` route at all, and the
approved design accepts the extra index entry rather than a silent miss. A later
"boundary fix" that removes those matches must break these tests.
"""

from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent.parent
PLUGIN_DIR = REPO_ROOT / "baseline" / "hermes" / "plugins" / "hongs-vault-router"
ROUTER_PATH = PLUGIN_DIR / "router.py"
CONTRACT_PATH = REPO_ROOT / "contracts" / "vault-query-routing-contract.md"


def _load_module(name, path, search_locations=None):
    """Import a plugin file without leaving ``__pycache__`` under ``baseline/``.

    ``baseline/`` is a manifest-managed tree whose file set must stay exact, so
    a test run may not drop bytecode into it.
    """
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(
            name, path, submodule_search_locations=search_locations
        )
        if spec is None or spec.loader is None:
            raise ImportError("cannot load %s" % path)
        module = importlib.util.module_from_spec(spec)
        if search_locations is not None:
            module.__package__ = name
        sys.modules[name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        sys.dont_write_bytecode = previous


def _load_router():
    return _load_module("hongs_vault_router_router", ROUTER_PATH)


router = _load_router()

CONTRACT_TEXT = CONTRACT_PATH.read_text(encoding="utf-8")
CONTRACT = router.parse_contract(CONTRACT_TEXT)

FRONTMATTER = "---\ntitle: index\n---\n\n"
INDEX_TEXT = FRONTMATTER + CONTRACT_TEXT + "\n# Index\n\n- [[Niagara]]\n"

START = "<!-- hongs-vault-routing-contract:start -->"
END = "<!-- hongs-vault-routing-contract:end -->"


def make_temp_dir(case) -> Path:
    root = Path(tempfile.mkdtemp(prefix="vault-router-"))
    case.addCleanup(_remove_tree, root)
    return root


def _remove_tree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


def make_vault(parent: Path, index_text: str = INDEX_TEXT) -> Path:
    root = parent / "Vault"
    (root / "wiki").mkdir(parents=True, exist_ok=True)
    (root / "wiki" / "index.md").write_text(index_text, encoding="utf-8")
    return root


def decide(text: str, contract=CONTRACT):
    ready = router.VaultReadiness(available=True, reason="OK", index_path="wiki/index.md")
    return router.decide_route(text, contract, ready)


class ContractParserTests(unittest.TestCase):
    """The stored contract is the single routing source and must be exact."""

    def test_repository_contract_parses(self):
        self.assertEqual(1, CONTRACT.version)
        self.assertIn("/query", CONTRACT.explicit_triggers)
        self.assertIn("Obsidian", CONTRACT.explicit_triggers)
        self.assertEqual(9, len(CONTRACT.groups))
        self.assertEqual("Knowledge-base operations", CONTRACT.audit_priority)
        self.assertIn("FX", CONTRACT.excluded_standalone)
        self.assertIn("열기", CONTRACT.file_op_verbs)

    def test_group_order_and_aliases_are_contract_order(self):
        names = [name for name, _aliases in CONTRACT.groups]
        self.assertEqual("Realtime VFX", names[0])
        self.assertEqual("VFX subject aliases", names[-1])
        niagara = dict(CONTRACT.groups)["Niagara"]
        self.assertEqual(("Niagara", "나이아가라"), niagara)

    def assertRejected(self, index_text, needle=""):
        with self.assertRaises(router.ContractError) as caught:
            router.parse_contract(index_text)
        if needle:
            self.assertIn(needle, str(caught.exception))

    def test_missing_section_is_rejected(self):
        self.assertRejected(FRONTMATTER + "# Index\n", "section")

    def test_duplicate_sections_are_rejected(self):
        self.assertRejected(CONTRACT_TEXT + "\n" + CONTRACT_TEXT, "exactly one")

    def test_unbalanced_section_is_rejected(self):
        self.assertRejected(CONTRACT_TEXT.replace(END, ""), "section")

    def test_reversed_markers_are_rejected(self):
        body = CONTRACT_TEXT.replace(START, "").replace(END, "")
        self.assertRejected(END + body + START, "section")

    def test_unsupported_version_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace("contract-version: 1", "contract-version: 2"),
            "contract-version",
        )

    def test_non_integer_version_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace("contract-version: 1", "contract-version: 1.0"),
            "contract-version",
        )

    def test_missing_required_field_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace("- audit-priority: Knowledge-base operations\n", ""),
            "audit-priority",
        )

    def test_duplicate_required_field_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- audit-priority: Knowledge-base operations",
                "- audit-priority: Knowledge-base operations\n- audit-priority: Niagara",
            ),
            "audit-priority",
        )

    def test_unsupported_field_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- audit-priority:", "- embedding-model: text-3\n- audit-priority:"
            ),
            "embedding-model",
        )

    def test_duplicate_group_name_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- domain-group: Niagara :: Niagara | 나이아가라",
                "- domain-group: Niagara :: Niagara | 나이아가라\n"
                "- domain-group: Niagara :: nia",
            ),
            "Niagara",
        )

    def test_duplicate_alias_inside_group_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- domain-group: Niagara :: Niagara | 나이아가라",
                "- domain-group: Niagara :: Niagara | Niagara",
            ),
            "alias",
        )

    def test_empty_alias_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- domain-group: Niagara :: Niagara | 나이아가라",
                "- domain-group: Niagara :: Niagara |  ",
            ),
            "alias",
        )

    def test_group_without_aliases_is_rejected(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- domain-group: Niagara :: Niagara | 나이아가라",
                "- domain-group: Niagara",
            ),
            "domain-group",
        )

    def test_audit_priority_must_name_a_group(self):
        self.assertRejected(
            CONTRACT_TEXT.replace(
                "- audit-priority: Knowledge-base operations",
                "- audit-priority: Nonexistent group",
            ),
            "audit-priority",
        )


class NormalizationTests(unittest.TestCase):
    def test_nfkc_casefold_and_whitespace_collapse(self):
        self.assertEqual(
            "unreal engine", router.normalize_question("  Ｕｎｒｅａｌ\t\nENGINE  ")
        )

    def test_normalized_forms_still_route(self):
        for text in ("ＮＩＡＧＡＲＡ", "niagara", "Unreal   Engine\n"):
            self.assertEqual("entered", decide(text).decision, text)


class MatcherContractTests(unittest.TestCase):
    def test_korean_particles_and_intentional_prefixes(self):
        for text in ("빔을 쏘는 이펙트", "폭발이 밋밋해", "빔프로젝터", "폭발물"):
            self.assertEqual("entered", decide(text).decision, text)

    def test_left_boundary_and_english_boundaries(self):
        for text in ("새벽빔", "moonbeam"):
            self.assertEqual("skipped", decide(text).decision, text)

    def test_required_positive_examples(self):
        for text in (
            "나이아가라로 구현",
            "셰이더는 어떻게",
            "Niagara",
            "Unreal Engine",
            "Houdini to Unreal",
        ):
            result = decide(text)
            self.assertEqual(("entered", "DOMAIN_MATCH"), (result.decision, result.trigger), text)

    def test_excluded_standalone_aliases_never_match(self):
        for text in ("standalone agent", "standalone FX", "standalone pipeline"):
            result = decide(text)
            self.assertEqual(
                ("skipped", "NO_DOMAIN_MATCH"), (result.decision, result.trigger), text
            )

    def test_explicit_trigger_precedes_file_exclusion(self):
        self.assertEqual("EXPLICIT", decide("/query Niagara.uasset 파일 열기").trigger)

    def test_explicit_triggers_enter(self):
        for text in ("Vault 확인해줘", "위키에서 찾아줘", "check Obsidian", "/query 빔"):
            result = decide(text)
            self.assertEqual(("entered", "EXPLICIT"), (result.decision, result.trigger), text)

    def test_mechanical_file_operation_is_excluded(self):
        result = decide("Niagara.uasset 파일 열기")
        self.assertEqual(("skipped", "FILE_OP_EXCLUSION"), (result.decision, result.trigger))

    def test_file_operation_needs_both_verb_and_file_token(self):
        self.assertEqual("DOMAIN_MATCH", decide("Niagara 파일 구조는 어떻게 설계해?").trigger)
        self.assertEqual("DOMAIN_MATCH", decide("Niagara 로그를 열기 전에 뭘 봐야 해?").trigger)

    def test_path_and_quoted_file_tokens_are_file_operations(self):
        for text in ("read C:\\tmp\\niagara notes", "open 'niagara plan'", "list `niagara`"):
            self.assertEqual("FILE_OP_EXCLUSION", decide(text).trigger, text)

    def test_matched_is_capped_at_two_aliases_in_contract_order(self):
        result = decide("Unreal Engine 에서 Niagara 로 셰이더 와 rendering")
        self.assertEqual("entered", result.decision)
        self.assertEqual(2, len(result.matched))
        self.assertEqual(("Unreal", "Unreal Engine"), result.matched)

    def test_unavailable_readiness_outranks_every_match(self):
        unready = router.VaultReadiness(available=False, reason="UNSET", index_path="")
        for text in ("/query Niagara", "Niagara", "hello"):
            result = router.decide_route(text, CONTRACT, unready)
            self.assertEqual(
                ("unavailable", "VAULT_UNAVAILABLE"), (result.decision, result.trigger), text
            )


class HeartbeatFormatTests(unittest.TestCase):
    def test_marker_shapes(self):
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=skipped trigger=NO_DOMAIN_MATCH",
            router.format_heartbeat(decide("hello")),
        )
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=entered trigger=DOMAIN_MATCH matched=Niagara",
            router.format_heartbeat(decide("Niagara")),
        )
        unready = router.VaultReadiness(available=False, reason="UNSET", index_path="")
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=unavailable trigger=VAULT_UNAVAILABLE",
            router.format_heartbeat(router.decide_route("Niagara", CONTRACT, unready)),
        )

    def test_marker_never_contains_question_text(self):
        marker = router.format_heartbeat(decide("나이아가라 로 폭발 이펙트 만드는 법"))
        self.assertNotIn("이펙트", marker)
        self.assertNotIn("만드는", marker)


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = make_temp_dir(self)

    def test_unset_or_blank_is_unavailable(self):
        for value in (None, "", "   "):
            readiness = router.check_vault(value)
            self.assertFalse(readiness.available)
            self.assertEqual("UNSET", readiness.reason)

    def test_missing_root_directory_is_unavailable(self):
        readiness = router.check_vault(str(self.tmp / "nope"))
        self.assertEqual((False, "ROOT_MISSING"), (readiness.available, readiness.reason))

    def test_missing_index_is_unavailable(self):
        root = self.tmp / "Vault"
        (root / "wiki").mkdir(parents=True)
        readiness = router.check_vault(str(root))
        self.assertEqual((False, "INDEX_MISSING"), (readiness.available, readiness.reason))

    def test_valid_root_is_available(self):
        root = make_vault(self.tmp)
        readiness = router.check_vault(str(root))
        self.assertTrue(readiness.available)
        self.assertEqual("OK", readiness.reason)
        self.assertEqual(str(root / "wiki" / "index.md"), readiness.index_path)


class RouteTurnTests(unittest.TestCase):
    def setUp(self):
        self.tmp = make_temp_dir(self)
        self.home = self.tmp / "hermes-home"
        self.home.mkdir()
        self.root = make_vault(self.tmp)

    def route(self, message, vault_root=None, home=None):
        return router.route_turn(
            message,
            "session-1",
            hermes_home=self.home if home is None else home,
            vault_root=str(self.root) if vault_root is None else vault_root,
        )

    def test_domain_match_enters(self):
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=entered trigger=DOMAIN_MATCH matched=Niagara",
            self.route("Niagara 질문"),
        )

    def test_unrelated_turn_skips(self):
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=skipped trigger=NO_DOMAIN_MATCH",
            self.route("오늘 일정 정리해줘"),
        )

    def test_missing_vault_is_unavailable(self):
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=unavailable trigger=VAULT_UNAVAILABLE",
            self.route("Niagara 질문", vault_root=str(self.tmp / "gone")),
        )

    def test_index_without_contract_is_unavailable(self):
        root = make_vault(self.tmp / "b", index_text="# Index\n")
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=unavailable trigger=VAULT_UNAVAILABLE",
            self.route("Niagara 질문", vault_root=str(root)),
        )

    def test_invalid_contract_is_unavailable(self):
        broken = INDEX_TEXT.replace("contract-version: 1", "contract-version: 9")
        root = make_vault(self.tmp / "c", index_text=broken)
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=unavailable trigger=VAULT_UNAVAILABLE",
            self.route("Niagara 질문", vault_root=str(root)),
        )

    def test_environment_supplies_vault_root_when_argument_is_absent(self):
        previous = os.environ.get("HONG_VAULT_ROOT")
        os.environ["HONG_VAULT_ROOT"] = str(self.root)
        try:
            marker = router.route_turn("Niagara 질문", "session-1", hermes_home=self.home)
        finally:
            if previous is None:
                os.environ.pop("HONG_VAULT_ROOT", None)
            else:
                os.environ["HONG_VAULT_ROOT"] = previous
        self.assertIn("decision=entered", marker)

    def test_exactly_one_event_per_turn(self):
        self.route("Niagara 질문")
        self.route("오늘 일정 정리해줘")
        lines = read_log(self.home)
        self.assertEqual(2, len(lines))

    def test_heartbeat_survives_telemetry_failure(self):
        blocked = self.tmp / "blocked-home"
        blocked.write_text("not a directory", encoding="utf-8")
        self.assertEqual(
            "VAULT_ROUTING_CHECKED decision=entered trigger=DOMAIN_MATCH matched=Niagara",
            self.route("Niagara 질문", home=blocked),
        )

    def test_heartbeat_survives_missing_hermes_home(self):
        previous = os.environ.get("HERMES_HOME")
        os.environ.pop("HERMES_HOME", None)
        try:
            marker = router.route_turn(
                "Niagara 질문", "session-1", vault_root=str(self.root)
            )
        finally:
            if previous is not None:
                os.environ["HERMES_HOME"] = previous
        self.assertIn("decision=entered", marker)


def key_path(home: Path) -> Path:
    return home / "runtime" / "vault-router" / "qhash.key"


def log_path(home: Path) -> Path:
    return home / "logs" / "vault-routing.jsonl"


def read_log(home: Path):
    text = log_path(home).read_text(encoding="utf-8")
    return [line for line in text.split("\n") if line]


class TelemetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = make_temp_dir(self)
        self.home = self.tmp / "hermes-home"
        self.home.mkdir()
        self.decision = router.RoutingDecision(
            decision="entered", trigger="DOMAIN_MATCH", matched=("Niagara",)
        )

    def write(self, question="niagara 질문", session="session-1", decision=None):
        return router.write_routing_event(
            self.home, session, question, decision or self.decision
        )

    def test_event_schema_is_exact(self):
        self.assertTrue(self.write())
        event = json.loads(read_log(self.home)[0])
        self.assertEqual(
            ["decision", "matched", "qhash", "session", "trigger", "ts"],
            sorted(event),
        )
        self.assertEqual("entered", event["decision"])
        self.assertEqual("DOMAIN_MATCH", event["trigger"])
        self.assertEqual(["Niagara"], event["matched"])
        self.assertEqual("session-1", event["session"])
        self.assertTrue(event["ts"].endswith("Z"))

    def test_question_text_is_never_written(self):
        self.assertTrue(self.write(question="supersecrettoken 니아가라"))
        blob = log_path(self.home).read_bytes()
        self.assertNotIn("supersecrettoken".encode("utf-8"), blob)
        self.assertNotIn("니아가라".encode("utf-8"), blob)

    def test_qhash_is_hmac_of_normalized_question(self):
        self.assertTrue(self.write(question="niagara 질문"))
        event = json.loads(read_log(self.home)[0])
        key = key_path(self.home).read_bytes()
        expected = hmac.new(key, "niagara 질문".encode("utf-8"), hashlib.sha256).hexdigest()
        self.assertEqual(expected, event["qhash"])

    def test_key_is_created_once_and_reused(self):
        self.assertTrue(self.write())
        key = key_path(self.home).read_bytes()
        self.assertEqual(32, len(key))
        self.assertTrue(self.write())
        self.assertEqual(key, key_path(self.home).read_bytes())
        first, second = (json.loads(line)["qhash"] for line in read_log(self.home))
        self.assertEqual(first, second)

    def test_corrupt_key_skips_the_event(self):
        key_path(self.home).parent.mkdir(parents=True, exist_ok=True)
        key_path(self.home).write_bytes(b"short")
        self.assertFalse(self.write())
        self.assertFalse(log_path(self.home).exists())

    def test_unwritable_home_returns_false(self):
        blocked = self.tmp / "file-home"
        blocked.write_text("x", encoding="utf-8")
        self.assertFalse(
            router.write_routing_event(blocked, "s", "q", self.decision)
        )

    def test_rotation_keeps_three_generations(self):
        active = log_path(self.home)
        active.parent.mkdir(parents=True, exist_ok=True)
        active.write_bytes(b"a" * router.ROTATE_LIMIT_BYTES)
        for suffix in (1, 2, 3):
            active.with_name(active.name + ".%d" % suffix).write_bytes(b"%d" % suffix)

        self.assertTrue(self.write())

        self.assertEqual(1, len(read_log(self.home)))
        self.assertEqual(
            router.ROTATE_LIMIT_BYTES, active.with_name(active.name + ".1").stat().st_size
        )
        self.assertEqual(b"1", active.with_name(active.name + ".2").read_bytes())
        self.assertEqual(b"2", active.with_name(active.name + ".3").read_bytes())
        self.assertFalse(active.with_name(active.name + ".4").exists())

    def test_no_rotation_below_the_limit(self):
        active = log_path(self.home)
        active.parent.mkdir(parents=True, exist_ok=True)
        active.write_bytes(b"a" * (router.ROTATE_LIMIT_BYTES - 1))
        self.assertTrue(self.write())
        self.assertFalse(active.with_name(active.name + ".1").exists())


class ConcurrentTelemetryTests(unittest.TestCase):
    """Desktop, CLI, and Gateway can append at the same moment."""

    def setUp(self):
        self.tmp = make_temp_dir(self)
        self.home = self.tmp / "hermes-home"
        self.home.mkdir()

    def test_concurrent_writers_keep_one_json_object_per_line(self):
        driver = self.tmp / "driver.py"
        driver.write_text(
            textwrap.dedent(
                """
                import importlib.util, sys
                from pathlib import Path

                spec = importlib.util.spec_from_file_location("r", sys.argv[1])
                module = importlib.util.module_from_spec(spec)
                sys.modules["r"] = module
                spec.loader.exec_module(module)

                home = Path(sys.argv[2])
                tag = sys.argv[3]
                decision = module.RoutingDecision(
                    decision="skipped", trigger="NO_DOMAIN_MATCH", matched=()
                )
                written = 0
                for index in range(10):
                    if module.write_routing_event(home, tag, "%s-%d" % (tag, index), decision):
                        written += 1
                print(written)
                """
            ),
            encoding="utf-8",
        )

        processes = [
            subprocess.Popen(
                [sys.executable, "-B", str(driver), str(ROUTER_PATH), str(self.home), "s%d" % i],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for i in range(4)
        ]
        written = 0
        for process in processes:
            out, err = process.communicate(timeout=120)
            self.assertEqual(0, process.returncode, err)
            written += int(out.strip())

        lines = read_log(self.home)
        self.assertEqual(40, written, "lock contention dropped events")
        self.assertEqual(written, len(lines))
        sessions = set()
        for line in lines:
            event = json.loads(line)
            sessions.add(event["session"])
        self.assertEqual({"s0", "s1", "s2", "s3"}, sessions)
        self.assertEqual(32, len(key_path(self.home).read_bytes()))


class PluginRegistrationTests(unittest.TestCase):
    """The plugin registers exactly one hook and ignores unused hook context."""

    def load_plugin(self):
        self.addCleanup(sys.modules.pop, "hongs_vault_router_pkg", None)
        return _load_module(
            "hongs_vault_router_pkg",
            PLUGIN_DIR / "__init__.py",
            search_locations=[str(PLUGIN_DIR)],
        )

    def test_register_adds_one_pre_llm_call_hook(self):
        plugin = self.load_plugin()
        registered = []

        class FakeContext:
            def register_hook(self, name, callback):
                registered.append((name, callback))

        plugin.register(FakeContext())
        self.assertEqual(1, len(registered))
        self.assertEqual("pre_llm_call", registered[0][0])

    def test_callback_returns_context_and_ignores_history(self):
        plugin = self.load_plugin()
        registered = []

        class FakeContext:
            def register_hook(self, name, callback):
                registered.append(callback)

        plugin.register(FakeContext())
        callback = registered[0]

        class ExplodingHistory(list):
            def __iter__(self):
                raise AssertionError("conversation_history must not be traversed")

        tmp = make_temp_dir(self)
        root = make_vault(tmp)
        previous = os.environ.get("HONG_VAULT_ROOT")
        os.environ["HONG_VAULT_ROOT"] = str(root)
        previous_home = os.environ.get("HERMES_HOME")
        os.environ["HERMES_HOME"] = str(tmp / "hermes-home")
        try:
            result = callback(
                session_id="s1",
                user_message="Niagara 질문",
                conversation_history=ExplodingHistory(),
                turn_id="t1",
                model="gpt-5.6",
                telemetry_schema_version=1,
            )
        finally:
            for name, value in (
                ("HONG_VAULT_ROOT", previous),
                ("HERMES_HOME", previous_home),
            ):
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value

        self.assertEqual(["context"], list(result))
        self.assertIn("VAULT_ROUTING_CHECKED", result["context"])

    def test_manifest_declares_the_plugin_without_tools(self):
        text = (PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
        self.assertIn("name: hongs-vault-router", text)
        self.assertIn("version: 1.0.0", text)
        self.assertIn("kind: standalone", text)
        self.assertNotIn("provides_tools", text)


class ModelContractPromptRoutingTests(unittest.TestCase):
    """The frozen model-contract probe prompt must stay routing-neutral.

    The activation proof runs exactly ``hermes chat --cli -Q -q <contract-prompt>``.
    If this prompt ever routed into the Vault, the model-contract gate would
    silently become a Vault-context test and a routing change could break
    activation for an unrelated reason. Prompt drift must fail here first.
    """

    CONTRACT_PROMPT = "Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools."

    def test_frozen_contract_prompt_is_routing_neutral(self):
        # router.SKIPPED == "skipped"; router.TRIGGER_NO_DOMAIN == "NO_DOMAIN_MATCH".
        result = decide(self.CONTRACT_PROMPT)
        self.assertEqual(
            (router.SKIPPED, router.TRIGGER_NO_DOMAIN),
            (result.decision, result.trigger),
        )
        self.assertEqual((), result.matched)

    def test_prompt_drift_would_change_the_measured_route(self):
        drifted = self.CONTRACT_PROMPT.replace("tools", "Niagara tools")
        result = decide(drifted)
        self.assertEqual(
            (router.ENTERED, router.TRIGGER_DOMAIN), (result.decision, result.trigger)
        )


if __name__ == "__main__":
    unittest.main()
