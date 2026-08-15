"""Focused tests for the read-only Hermes reasoning seam verifier.

These tests exercise the verifier's assertion logic, report schema, and exit
codes against minimal in-process fixtures. They are NOT production evidence:
no fixture here proves anything about the installed Hermes source. The only
source evidence is the mandatory installed-source integration command in the
plan's supervisor verification procedure, which cannot be skipped or replaced
by this file.
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "verify-hermes-reasoning-seam.py"
ROUTER_PATH = REPO_ROOT / "baseline" / "hermes" / "plugins" / "hongs-vault-router" / "router.py"
CONTRACT_PATH = REPO_ROOT / "contracts" / "vault-query-routing-contract.md"
PROMPT = "Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools."


def load_verifier():
    spec = importlib.util.spec_from_file_location("verify_hermes_reasoning_seam", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


verifier = load_verifier()


def run_cli(case, source_root, prompt=PROMPT):
    buffer = io.StringIO()
    argv = [
        "--hermes-source", str(source_root),
        "--router", str(ROUTER_PATH),
        "--routing-contract", str(CONTRACT_PATH),
        "--prompt", prompt,
    ]
    with redirect_stdout(buffer):
        code = verifier.main(argv)
    lines = [line for line in buffer.getvalue().splitlines() if line.strip()]
    case.assertEqual(1, len(lines), "verifier must print exactly one JSON line")
    return code, json.loads(lines[0])


class SuccessSchemaTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(tempfile.mkdtemp(prefix="seam-src-"))
        self.addCleanup(_remove_tree, self.source)
        self.addCleanup(verifier._reset_seam_overrides)
        verifier._set_seam_overrides(
            dispatcher=lambda _root: {"status": "PASS", "clauses": "8/8", "failed": []},
            payload=lambda _root: {"status": "PASS", "checks": "4/4", "failed": []},
        )

    def test_pass_report_has_exact_schema_and_exit_zero(self):
        code, report = run_cli(self, self.source)
        self.assertEqual(0, code)
        self.assertEqual(
            {
                "kind", "schemaVersion", "result", "dispatcher", "payload",
                "routing", "externalInference", "liveMutation",
            },
            set(report),
        )
        self.assertEqual("hongs-hermes-reasoning-seam", report["kind"])
        self.assertEqual(1, report["schemaVersion"])
        self.assertEqual("PASS", report["result"])
        self.assertEqual("8/8", report["dispatcher"]["clauses"])
        self.assertEqual("4/4", report["payload"]["checks"])
        self.assertEqual(
            {"status": "PASS", "decision": "SKIPPED", "trigger": "NO_DOMAIN", "matched": 0},
            report["routing"],
        )
        self.assertEqual(0, report["externalInference"])
        self.assertEqual(0, report["liveMutation"])

    def test_report_leaks_no_path_prompt_or_value(self):
        _code, report = run_cli(self, self.source)
        blob = json.dumps(report)
        for forbidden in (str(self.source), str(ROUTER_PATH), PROMPT, "MODEL_CONTRACT_PROBE_OK",
                          "hermes-agent", "gpt-5.6-sol", "session"):
            self.assertNotIn(forbidden, blob, forbidden)


class DispatcherDriftTests(unittest.TestCase):
    def test_parser_branch_drift_fails_with_categorical_clause(self):
        source = Path(tempfile.mkdtemp(prefix="seam-src-"))
        self.addCleanup(_remove_tree, source)
        self.addCleanup(verifier._reset_seam_overrides)
        verifier._set_seam_overrides(
            dispatcher=lambda _root: {
                "status": "FAIL", "clauses": "6/8",
                "failed": ["NOT_ONESHOT", "NO_REASONING_OVERRIDE"],
            },
            payload=lambda _root: {"status": "PASS", "checks": "4/4", "failed": []},
        )
        code, report = run_cli(self, source)
        self.assertEqual(1, code)
        self.assertEqual("FAIL", report["result"])
        self.assertEqual(["NOT_ONESHOT", "NO_REASONING_OVERRIDE"], report["dispatcher"]["failed"])
        self.assertEqual(0, report["externalInference"])


class PayloadEffortTests(unittest.TestCase):
    def test_medium_effort_payload_fails(self):
        source = Path(tempfile.mkdtemp(prefix="seam-src-"))
        self.addCleanup(_remove_tree, source)
        self.addCleanup(verifier._reset_seam_overrides)
        verifier._set_seam_overrides(
            dispatcher=lambda _root: {"status": "PASS", "clauses": "8/8", "failed": []},
            payload=lambda _root: verifier.evaluate_payload_evidence(
                row={"enabled": True, "effort": "high"},
                payload={"reasoning": {"effort": "medium", "summary": "auto"}},
            ),
        )
        code, report = run_cli(self, source)
        self.assertEqual(1, code)
        self.assertEqual("3/4", report["payload"]["checks"])
        self.assertEqual(["PAYLOAD_EFFORT_HIGH"], report["payload"]["failed"])


class RoutingEnteredTests(unittest.TestCase):
    def test_entered_route_fails_and_reports_categorically(self):
        source = Path(tempfile.mkdtemp(prefix="seam-src-"))
        self.addCleanup(_remove_tree, source)
        self.addCleanup(verifier._reset_seam_overrides)
        verifier._set_seam_overrides(
            dispatcher=lambda _root: {"status": "PASS", "clauses": "8/8", "failed": []},
            payload=lambda _root: {"status": "PASS", "checks": "4/4", "failed": []},
        )
        code, report = run_cli(self, source, prompt="Niagara 이펙트 어떻게 만들어?")
        self.assertEqual(1, code)
        self.assertEqual("FAIL", report["routing"]["status"])
        self.assertEqual("ENTERED", report["routing"]["decision"])
        self.assertEqual("DOMAIN", report["routing"]["trigger"])
        self.assertEqual(1, report["routing"]["matched"])


STUB_HERMES_CONSTANTS = '''
def resolve_reasoning_config(config, model):
    return {"enabled": True, "effort": "high", "summary": "auto"}
'''

STUB_HERMES_STATE = '''
import json
import sqlite3
from pathlib import Path

OBSERVATIONS = Path(__file__).resolve().parent / "observations.json"


def record(event, db_path):
    events = []
    if OBSERVATIONS.is_file():
        events = json.loads(OBSERVATIONS.read_text(encoding="utf-8"))
    events.append({"event": event, "temp_dir_exists": Path(db_path).parent.is_dir()})
    OBSERVATIONS.write_text(json.dumps(events), encoding="utf-8")


class SessionDB:
    """Holds no open handle, so temp cleanup always succeeds and only order is measured."""

    def __init__(self, db_path):
        self.db_path = Path(db_path)
        connection = sqlite3.connect(str(self.db_path))
        try:
            connection.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, model_config TEXT)")
            connection.commit()
        finally:
            connection.close()

    def insert_session(self, session_id, model_config):
        connection = sqlite3.connect(str(self.db_path))
        try:
            connection.execute(
                "INSERT INTO sessions (id, model_config) VALUES (?, ?)",
                (session_id, json.dumps(model_config)),
            )
            connection.commit()
        finally:
            connection.close()

    def close(self):
        record("db.close", self.db_path)
'''

STUB_RUN_AGENT = '''
from hermes_state import record


class AIAgent:
    def __init__(self, **kwargs):
        self.session_db = kwargs["session_db"]
        self.reasoning_config = kwargs["reasoning_config"]
        self.session_id = "seam-stub-session"

    def _ensure_db_session(self):
        self.session_db.insert_session(
            self.session_id, {"reasoning_config": self.reasoning_config}
        )

    def _build_api_kwargs(self, messages, tools_for_api=None):
        return {"reasoning": {"effort": self.reasoning_config["effort"], "summary": "auto"}}

    def close(self):
        record("agent.close", self.session_db.db_path)
'''


class PayloadSeamResourceOrderingTests(unittest.TestCase):
    """The payload seam must release state before its temporary directory is removed."""

    def _stub_source(self):
        source = Path(tempfile.mkdtemp(prefix="seam-stub-"))
        self.addCleanup(_remove_tree, source)
        (source / "hermes_constants.py").write_text(STUB_HERMES_CONSTANTS, encoding="utf-8")
        (source / "hermes_state.py").write_text(STUB_HERMES_STATE, encoding="utf-8")
        (source / "run_agent.py").write_text(STUB_RUN_AGENT, encoding="utf-8")
        for name in ("hermes_constants", "hermes_state", "run_agent"):
            sys.modules.pop(name, None)
            self.addCleanup(sys.modules.pop, name, None)
        return source

    def test_agent_and_db_close_before_temporary_directory_is_removed(self):
        source = self._stub_source()

        result = verifier.run_payload_seam(source)

        self.assertEqual("PASS", result["status"])
        events = json.loads((source / "observations.json").read_text(encoding="utf-8"))
        self.assertEqual(["agent.close", "db.close"], [event["event"] for event in events])
        for event in events:
            self.assertTrue(
                event["temp_dir_exists"],
                "%s ran after the temporary directory was already removed" % event["event"],
            )


class MissingSourceTests(unittest.TestCase):
    def test_absent_source_root_is_unavailable_not_pass(self):
        missing = Path(tempfile.mkdtemp(prefix="seam-src-")) / "absent"
        code, report = run_cli(self, missing)
        self.assertEqual(2, code)
        self.assertEqual("UNAVAILABLE", report["result"])
        self.assertEqual(["SOURCE_ROOT_MISSING"], report["dispatcher"]["failed"])
        self.assertNotIn(str(missing), json.dumps(report))


def _remove_tree(path: Path) -> None:
    import shutil

    shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
