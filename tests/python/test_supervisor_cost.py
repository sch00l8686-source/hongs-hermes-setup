"""Behaviour tests for the explicit monthly supervisor cost recorder.

Every test drives the real collector against a disposable SQLite fixture and a
disposable Hermes home under the system temp directory. No test opens the live
``state.db``, and no test appends to the live monthly record.

The fixture column sets are the columns the collector requires, taken from the
observed ``state.db`` schema: ``sessions(id, model_config)`` and
``session_model_usage(session_id, model, billing_provider, task,
api_call_count, input_tokens, output_tokens, cache_read_tokens,
cache_write_tokens, reasoning_tokens, first_seen)``.

The dated Standard short-context rates under test are Sol 5.00/30.00/0.50/6.25
and Terra 2.00/12.00/0.20/2.50 per million tokens, so one million tokens in each
of the four disjoint buckets costs Sol 41.75 and Terra 16.70. Those exact values
are asserted rather than recomputed, because a silent rate edit is the failure
this file exists to catch.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent.parent
RECORDER_PATH = REPO_ROOT / "scripts" / "record-supervisor-cost.py"


def _load_recorder():
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location(
            "record_supervisor_cost", RECORDER_PATH
        )
        if spec is None or spec.loader is None:
            raise ImportError("cannot load %s" % RECORDER_PATH)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module
    finally:
        sys.dont_write_bytecode = previous


recorder = _load_recorder()

SESSION_COLUMNS = ("id", "model_config")
USAGE_COLUMNS = (
    "session_id",
    "model",
    "billing_provider",
    "task",
    "api_call_count",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
    "first_seen",
)

EXPECTED_KEYS = (
    "schema_version",
    "month",
    "observed_at",
    "supervisor_sessions",
    "supervisor_requests",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
    "hermes_api_equivalent_estimated_cost_usd",
    "sol_vs_terra_virtual_premium_usd",
    "pricing_snapshot",
    "actual_provider_billing_status",
    "actual_provider_billed_usd",
    "extra_usage_status",
    "actual_billed_extra_usage_usd",
    "review_required",
    "review_reasons",
)

MONTH = "2026-08"
MONTH_START = datetime(2026, 8, 1, tzinfo=timezone.utc).timestamp()
NEXT_MONTH_START = datetime(2026, 9, 1, tzinfo=timezone.utc).timestamp()
MID_MONTH = datetime(2026, 8, 14, 12, 0, 0, tzinfo=timezone.utc).timestamp()

MILLION = 1000000
OBSERVED_AT_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def session_row(session_id, effort="high", model_config=None):
    if model_config is None:
        model_config = json.dumps(
            {
                "max_iterations": 150,
                "reasoning_config": {"enabled": True, "effort": effort},
                "max_tokens": None,
            }
        )
    return {"id": session_id, "model_config": model_config}


def usage_row(session_id, **overrides):
    row = {
        "session_id": session_id,
        "model": "gpt-5.6-sol",
        "billing_provider": "openai-codex",
        "task": "",
        "api_call_count": 1,
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_tokens": 0,
        "cache_write_tokens": 0,
        "reasoning_tokens": 0,
        "first_seen": MID_MONTH,
    }
    row.update(overrides)
    return row


def million_row(session_id, **overrides):
    """One session's usage: one million tokens in each of the four buckets."""
    row = usage_row(
        session_id,
        api_call_count=7,
        input_tokens=MILLION,
        output_tokens=MILLION,
        cache_read_tokens=MILLION,
        cache_write_tokens=MILLION,
        reasoning_tokens=250000,
    )
    row.update(overrides)
    return row


class RecorderTestCase(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp(prefix="supervisor-cost-"))
        self.addCleanup(shutil.rmtree, root, True)
        self.root = root
        self.hermes_home = root / "hermes-home"
        self.hermes_home.mkdir()
        self.state_db = root / "state.db"

    def build_db(
        self,
        sessions,
        usage,
        session_columns=SESSION_COLUMNS,
        usage_columns=USAGE_COLUMNS,
    ):
        connection = sqlite3.connect(str(self.state_db))
        try:
            with connection:
                connection.execute(
                    "CREATE TABLE sessions (%s)" % ", ".join(session_columns)
                )
                connection.execute(
                    "CREATE TABLE session_model_usage (%s)" % ", ".join(usage_columns)
                )
                for row in sessions:
                    self._insert(connection, "sessions", row)
                for row in usage:
                    self._insert(connection, "session_model_usage", row)
        finally:
            connection.close()

    @staticmethod
    def _insert(connection, table, row):
        columns = list(row)
        connection.execute(
            "INSERT INTO %s (%s) VALUES (%s)"
            % (table, ", ".join(columns), ", ".join("?" for _ in columns)),
            [row[column] for column in columns],
        )

    def run_recorder(self, month=MONTH, extra=()):
        argv = [
            "--state-db",
            str(self.state_db),
            "--hermes-home",
            str(self.hermes_home),
            "--month",
            month,
        ]
        argv.extend(extra)
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            code = recorder.main(argv)
        return code, buffer.getvalue()

    @property
    def record_path(self):
        return self.hermes_home / "logs" / "supervisor-cost-monthly.jsonl"

    def read_lines(self):
        return self.record_path.read_text(encoding="utf-8").splitlines()

    def read_records(self):
        return [json.loads(line) for line in self.read_lines()]

    def record_for(self, sessions, usage, extra=()):
        self.build_db(sessions, usage)
        code, stdout = self.run_recorder(extra=extra)
        self.assertEqual(code, 0, stdout)
        records = self.read_records()
        self.assertEqual(len(records), 1)
        return records[0]


class PricingTests(RecorderTestCase):
    def test_one_million_tokens_per_bucket_costs_the_dated_sol_and_terra_rates(self):
        record = self.record_for(
            [session_row("sess-alpha")], [million_row("sess-alpha")]
        )
        self.assertEqual(record["hermes_api_equivalent_estimated_cost_usd"], 41.75)
        self.assertEqual(record["sol_vs_terra_virtual_premium_usd"], 25.05)
        self.assertIs(record["review_required"], False)
        self.assertEqual(record["review_reasons"], [])

    def test_premium_serialises_without_binary_float_drift(self):
        self.record_for([session_row("sess-alpha")], [million_row("sess-alpha")])
        line = self.read_lines()[0]
        self.assertIn('"sol_vs_terra_virtual_premium_usd": 25.05', line)

    def test_fourfold_usage_crosses_the_review_threshold(self):
        identifiers = ["sess-a", "sess-b", "sess-c", "sess-d"]
        record = self.record_for(
            [session_row(identifier) for identifier in identifiers],
            [million_row(identifier) for identifier in identifiers],
        )
        self.assertEqual(record["hermes_api_equivalent_estimated_cost_usd"], 167.0)
        self.assertEqual(record["sol_vs_terra_virtual_premium_usd"], 100.2)
        self.assertIs(record["review_required"], True)
        self.assertEqual(len(record["review_reasons"]), 1)

    def test_threshold_is_strictly_greater_than_one_hundred(self):
        self.assertEqual(recorder.review_reasons(Decimal("100.000000")), [])
        self.assertEqual(recorder.review_reasons(Decimal("99.999999")), [])
        self.assertEqual(len(recorder.review_reasons(Decimal("100.000001"))), 1)

    def test_buckets_are_priced_once_and_reasoning_is_not_charged(self):
        record = self.record_for(
            [session_row("sess-alpha")],
            [
                usage_row(
                    "sess-alpha",
                    input_tokens=MILLION,
                    reasoning_tokens=MILLION,
                )
            ],
        )
        self.assertEqual(record["hermes_api_equivalent_estimated_cost_usd"], 5.0)
        self.assertEqual(record["sol_vs_terra_virtual_premium_usd"], 3.0)
        self.assertEqual(record["reasoning_tokens"], MILLION)


class SelectionTests(RecorderTestCase):
    def test_medium_effort_sessions_are_excluded(self):
        record = self.record_for(
            [session_row("sess-high"), session_row("sess-medium", effort="medium")],
            [million_row("sess-high"), million_row("sess-medium")],
        )
        self.assertEqual(record["supervisor_sessions"], 1)
        self.assertEqual(record["input_tokens"], MILLION)

    def test_auxiliary_task_rows_are_excluded(self):
        record = self.record_for(
            [session_row("sess-high")],
            [
                million_row("sess-high"),
                million_row("sess-high", task="title_generation"),
                million_row("sess-high", task="compression"),
            ],
        )
        self.assertEqual(record["input_tokens"], MILLION)
        self.assertEqual(record["supervisor_requests"], 7)

    def test_other_models_and_providers_are_excluded(self):
        record = self.record_for(
            [session_row("sess-high")],
            [
                million_row("sess-high"),
                million_row("sess-high", model="gpt-5.6-terra"),
                million_row("sess-high", billing_provider="anthropic"),
            ],
        )
        self.assertEqual(record["output_tokens"], MILLION)

    def test_month_boundaries_are_half_open_in_utc(self):
        record = self.record_for(
            [session_row("sess-high")],
            [
                million_row("sess-high", first_seen=MONTH_START),
                million_row("sess-high", first_seen=MONTH_START - 1),
                million_row("sess-high", first_seen=NEXT_MONTH_START),
            ],
        )
        self.assertEqual(record["input_tokens"], MILLION)

    def test_malformed_reasoning_config_is_excluded_without_failing(self):
        record = self.record_for(
            [
                session_row("sess-high"),
                session_row("sess-broken", model_config="{not json"),
                {"id": "sess-null", "model_config": None},
                session_row(
                    "sess-scalar", model_config=json.dumps({"reasoning_config": "high"})
                ),
            ],
            [
                million_row("sess-high"),
                million_row("sess-broken"),
                million_row("sess-null"),
                million_row("sess-scalar"),
            ],
        )
        self.assertEqual(record["supervisor_sessions"], 1)
        self.assertEqual(record["input_tokens"], MILLION)

    def test_empty_month_records_zero_usage(self):
        record = self.record_for([session_row("sess-high")], [])
        self.assertEqual(record["supervisor_sessions"], 0)
        self.assertEqual(record["supervisor_requests"], 0)
        self.assertEqual(record["hermes_api_equivalent_estimated_cost_usd"], 0.0)
        self.assertEqual(record["sol_vs_terra_virtual_premium_usd"], 0.0)
        self.assertIs(record["review_required"], False)


class RecordShapeTests(RecorderTestCase):
    def test_record_has_exactly_the_contract_keys_in_order(self):
        record = self.record_for(
            [session_row("sess-alpha")], [million_row("sess-alpha")]
        )
        self.assertEqual(tuple(record), EXPECTED_KEYS)

    def test_fixed_fields_and_billing_defaults(self):
        record = self.record_for(
            [session_row("sess-alpha")], [million_row("sess-alpha")]
        )
        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["month"], MONTH)
        self.assertEqual(
            record["pricing_snapshot"], "openai-gpt-5.6-standard-short-2026-08-14"
        )
        self.assertRegex(record["observed_at"], OBSERVED_AT_PATTERN)
        self.assertEqual(record["actual_provider_billing_status"], "unknown")
        self.assertIsNone(record["actual_provider_billed_usd"])
        self.assertEqual(record["extra_usage_status"], "disabled")
        self.assertIsNone(record["actual_billed_extra_usage_usd"])

    def test_actual_billing_comes_only_from_explicit_arguments(self):
        record = self.record_for(
            [session_row("sess-alpha")],
            [million_row("sess-alpha")],
            extra=(
                "--actual-provider-billing-status",
                "billed",
                "--actual-provider-billed-usd",
                "40.5",
                "--extra-usage-status",
                "enabled",
                "--actual-billed-extra-usage-usd",
                "1.25",
            ),
        )
        self.assertEqual(record["actual_provider_billing_status"], "billed")
        self.assertEqual(record["actual_provider_billed_usd"], 40.5)
        self.assertEqual(record["extra_usage_status"], "enabled")
        self.assertEqual(record["actual_billed_extra_usage_usd"], 1.25)

    def test_no_session_identifiers_reach_the_record(self):
        self.record_for(
            [session_row("sess-secret-alpha")], [million_row("sess-secret-alpha")]
        )
        line = self.read_lines()[0]
        self.assertNotIn("sess-secret-alpha", line)
        self.assertNotIn(str(self.hermes_home), line)
        self.assertNotIn(str(self.state_db), line)

    def test_guard_rejects_paths_prompts_and_unexpected_keys(self):
        record = self.record_for(
            [session_row("sess-alpha")], [million_row("sess-alpha")]
        )
        recorder.assert_recordable(record, ["sess-alpha"])

        with_session_id = dict(record, actual_provider_billing_status="sess-alpha")
        with self.assertRaises(ValueError):
            recorder.assert_recordable(with_session_id, ["sess-alpha"])

        with_path = dict(record, pricing_snapshot="C:\\Users\\HongGyu")
        with self.assertRaises(ValueError):
            recorder.assert_recordable(with_path, [])

        with_prompt = dict(record, review_reasons=["system prompt text"])
        with self.assertRaises(ValueError):
            recorder.assert_recordable(with_prompt, [])

        with_extra_key = dict(record, session_id="sess-alpha")
        with self.assertRaises(ValueError):
            recorder.assert_recordable(with_extra_key, [])

        missing_key = dict(record)
        del missing_key["review_reasons"]
        with self.assertRaises(ValueError):
            recorder.assert_recordable(missing_key, [])

    def test_stdout_summary_reports_month_path_premium_and_flag(self):
        self.build_db([session_row("sess-alpha")], [million_row("sess-alpha")])
        code, stdout = self.run_recorder()
        self.assertEqual(code, 0)
        self.assertIn(MONTH, stdout)
        self.assertIn(str(self.record_path), stdout)
        self.assertIn("25.05", stdout)
        self.assertIn("false", stdout)


class AppendAndFailureTests(RecorderTestCase):
    def test_repeated_invocations_append_snapshots(self):
        self.build_db([session_row("sess-alpha")], [million_row("sess-alpha")])
        self.assertEqual(self.run_recorder()[0], 0)
        self.assertEqual(self.run_recorder()[0], 0)
        self.assertEqual(len(self.read_records()), 2)

    def test_nothing_is_written_outside_the_hermes_home_logs_directory(self):
        self.build_db([session_row("sess-alpha")], [million_row("sess-alpha")])
        before = self.state_db.stat()
        self.assertEqual(self.run_recorder()[0], 0)
        after = self.state_db.stat()
        self.assertEqual((before.st_size, before.st_mtime), (after.st_size, after.st_mtime))
        self.assertEqual(sorted(os.listdir(self.root)), ["hermes-home", "state.db"])
        self.assertEqual(os.listdir(self.hermes_home), ["logs"])
        self.assertEqual(
            os.listdir(self.hermes_home / "logs"), ["supervisor-cost-monthly.jsonl"]
        )

    def test_missing_required_column_fails_without_writing(self):
        self.build_db(
            [session_row("sess-alpha")],
            [],
            usage_columns=tuple(
                column for column in USAGE_COLUMNS if column != "reasoning_tokens"
            ),
        )
        code, _ = self.run_recorder()
        self.assertEqual(code, 1)
        self.assertFalse(self.record_path.exists())

    def test_missing_state_db_fails_without_writing(self):
        code, _ = self.run_recorder()
        self.assertEqual(code, 1)
        self.assertFalse(self.record_path.exists())

    def test_invalid_month_fails_without_writing(self):
        self.build_db([session_row("sess-alpha")], [million_row("sess-alpha")])
        code, _ = self.run_recorder(month="2026-13")
        self.assertEqual(code, 1)
        self.assertFalse(self.record_path.exists())


if __name__ == "__main__":
    unittest.main()
