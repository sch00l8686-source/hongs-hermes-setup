#!/usr/bin/env python3
"""Append one explicit monthly supervisor cost snapshot to the local record.

This collector is run by hand. It is not a daemon, a cron job, or a billing
integration. It opens ``state.db`` through a SQLite read-only URI, aggregates
the requested UTC month of primary Sol/high supervisor usage, prices that usage
twice — once at the Sol rates and once at the Terra rates — and appends a single
JSON line to ``$HERMES_HOME/logs/supervisor-cost-monthly.jsonl``.

The difference between the two estimates is the Sol-versus-Terra *virtual*
premium: what staying on Sol costs against the Terra alternative for the same
token counts. It is not an invoice. Amounts actually billed by the provider and
amounts actually billed as Extra Usage stay separate fields that are only ever
filled from explicit command arguments; absence stays ``unknown``/``null``
rather than being inferred.

Token buckets follow the installed Hermes accounting for the ``openai-codex``
route (``hermes-agent/agent/usage_pricing.py``): the provider's input total has
cache reads and cache writes subtracted out of it before storage, so the four
buckets are disjoint and each is priced exactly once. Reasoning tokens are
reported but not charged, because the provider's output total already includes
them.

Rates are the dated Standard short-context snapshot
``openai-gpt-5.6-standard-short-2026-08-14``. They are ``Decimal`` on purpose:
the premium is a difference of two similar amounts, and binary floats turn
25.05 into 25.049999999999997.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import urllib.parse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_EVEN

SCHEMA_VERSION = 1
RECORD_FILENAME = "supervisor-cost-monthly.jsonl"
PRICING_SNAPSHOT = "openai-gpt-5.6-standard-short-2026-08-14"

SUPERVISOR_MODEL = "gpt-5.6-sol"
SUPERVISOR_BILLING_PROVIDER = "openai-codex"
SUPERVISOR_EFFORT = "high"

#: USD per million tokens, dated Standard short-context snapshot.
SOL_RATES = {
    "input": Decimal("5.00"),
    "output": Decimal("30.00"),
    "cache_read": Decimal("0.50"),
    "cache_write": Decimal("6.25"),
}
TERRA_RATES = {
    "input": Decimal("2.00"),
    "output": Decimal("12.00"),
    "cache_read": Decimal("0.20"),
    "cache_write": Decimal("2.50"),
}
ONE_MILLION = Decimal(1000000)

REVIEW_THRESHOLD_USD = Decimal("100")
REVIEW_REASON_PREMIUM = "sol-vs-terra-virtual-premium-above-threshold"

RECORD_KEYS = (
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

TOKEN_KEYS = (
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_write_tokens",
    "reasoning_tokens",
)

REQUIRED_COLUMNS = {
    "sessions": ("id", "model_config"),
    "session_model_usage": (
        "session_id",
        "model",
        "billing_provider",
        "task",
        "api_call_count",
    )
    + TOKEN_KEYS
    + ("first_seen",),
}

MONTH_PATTERN = re.compile(r"^(\d{4})-(0[1-9]|1[0-2])$")
STATUS_PATTERN = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")

#: Substrings that would mean conversation content leaked into the record.
FORBIDDEN_SUBSTRINGS = ("prompt", "message")


class CollectorError(Exception):
    """A condition that must abort the run before anything is written."""


# --- month window ----------------------------------------------------------


def month_bounds(month):
    """Return the half-open ``[start, end)`` UTC epoch bounds of ``month``."""
    matched = MONTH_PATTERN.match(month)
    if matched is None:
        raise CollectorError("--month must be YYYY-MM with a real month: %r" % month)
    year, number = int(matched.group(1)), int(matched.group(2))
    start = datetime(year, number, 1, tzinfo=timezone.utc)
    if number == 12:
        end = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end = datetime(year, number + 1, 1, tzinfo=timezone.utc)
    return start.timestamp(), end.timestamp()


# --- pricing ---------------------------------------------------------------


def estimate_cost(totals, rates):
    """Price the four disjoint buckets once each, as installed Hermes does."""
    amount = (
        Decimal(totals["input_tokens"]) * rates["input"]
        + Decimal(totals["output_tokens"]) * rates["output"]
        + Decimal(totals["cache_read_tokens"]) * rates["cache_read"]
        + Decimal(totals["cache_write_tokens"]) * rates["cache_write"]
    )
    return amount / ONE_MILLION


def review_reasons(premium):
    """Reasons the month needs hybrid review; strictly above the threshold."""
    if premium > REVIEW_THRESHOLD_USD:
        return [REVIEW_REASON_PREMIUM]
    return []


def decimal_text(value):
    """Render ``value`` at six decimal places or fewer, without exponents."""
    text = format(value.quantize(Decimal("0.000001"), rounding=ROUND_HALF_EVEN), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def usd(value):
    """The JSON number for a USD amount, rounded to six decimal places."""
    return float(decimal_text(value))


# --- read-only aggregation -------------------------------------------------


def open_read_only(path):
    absolute = os.path.abspath(path)
    if not os.path.isfile(absolute):
        raise CollectorError("state database not found: %s" % absolute)
    uri = "file:" + urllib.parse.quote(absolute.replace(os.sep, "/"), safe="/:") + "?mode=ro"
    try:
        return sqlite3.connect(uri, uri=True)
    except sqlite3.Error as error:
        raise CollectorError("cannot open state database read-only: %s" % error)


def assert_schema(connection):
    """Fail before querying when a required column is absent."""
    missing = []
    for table, columns in REQUIRED_COLUMNS.items():
        try:
            present = {row[1] for row in connection.execute("PRAGMA table_info(%s)" % table)}
        except sqlite3.Error as error:
            raise CollectorError("cannot read schema of %s: %s" % (table, error))
        missing.extend("%s.%s" % (table, name) for name in columns if name not in present)
    if missing:
        raise CollectorError("state database is missing columns: %s" % ", ".join(missing))


def has_supervisor_effort(model_config):
    """True when the session ran at the required reasoning effort."""
    if not isinstance(model_config, str):
        return False
    try:
        parsed = json.loads(model_config)
    except ValueError:
        return False
    if not isinstance(parsed, dict):
        return False
    reasoning = parsed.get("reasoning_config")
    if not isinstance(reasoning, dict):
        return False
    return reasoning.get("effort") == SUPERVISOR_EFFORT


QUERY = """
SELECT u.session_id, u.api_call_count, u.input_tokens, u.output_tokens,
       u.cache_read_tokens, u.cache_write_tokens, u.reasoning_tokens,
       s.model_config
FROM session_model_usage AS u
JOIN sessions AS s ON s.id = u.session_id
WHERE u.task = ''
  AND u.model = ?
  AND u.billing_provider = ?
  AND u.first_seen >= ?
  AND u.first_seen < ?
"""


def collect(connection, start, end):
    """Aggregate the month; return ``(totals, session_ids)``."""
    totals = {"supervisor_requests": 0}
    for key in TOKEN_KEYS:
        totals[key] = 0
    session_ids = set()

    rows = connection.execute(
        QUERY, (SUPERVISOR_MODEL, SUPERVISOR_BILLING_PROVIDER, start, end)
    )
    for row in rows:
        session_id, requests = row[0], row[1]
        if not has_supervisor_effort(row[7]):
            continue
        session_ids.add(session_id)
        totals["supervisor_requests"] += int(requests or 0)
        for offset, key in enumerate(TOKEN_KEYS, start=2):
            totals[key] += int(row[offset] or 0)

    totals["supervisor_sessions"] = len(session_ids)
    return totals, session_ids


# --- record shape and local append -----------------------------------------


def build_record(month, totals, options):
    estimated = estimate_cost(totals, SOL_RATES)
    premium = estimated - estimate_cost(totals, TERRA_RATES)
    reasons = review_reasons(premium)
    return {
        "schema_version": SCHEMA_VERSION,
        "month": month,
        "observed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "supervisor_sessions": totals["supervisor_sessions"],
        "supervisor_requests": totals["supervisor_requests"],
        "input_tokens": totals["input_tokens"],
        "output_tokens": totals["output_tokens"],
        "cache_read_tokens": totals["cache_read_tokens"],
        "cache_write_tokens": totals["cache_write_tokens"],
        "reasoning_tokens": totals["reasoning_tokens"],
        "hermes_api_equivalent_estimated_cost_usd": usd(estimated),
        "sol_vs_terra_virtual_premium_usd": usd(premium),
        "pricing_snapshot": PRICING_SNAPSHOT,
        "actual_provider_billing_status": options.actual_provider_billing_status,
        "actual_provider_billed_usd": options.actual_provider_billed_usd,
        "extra_usage_status": options.extra_usage_status,
        "actual_billed_extra_usage_usd": options.actual_billed_extra_usage_usd,
        "review_required": bool(reasons),
        "review_reasons": reasons,
    }


def assert_recordable(record, session_ids=()):
    """Reject anything that is not exactly the contracted, content-free record."""
    if tuple(record) != RECORD_KEYS:
        raise ValueError("record keys are not exactly the contract keys, in order")
    forbidden = set(session_ids)
    for key, value in record.items():
        _assert_value(key, value, forbidden)


def _assert_value(key, value, session_ids):
    if value is None or isinstance(value, (bool, int, float)):
        return
    if isinstance(value, str):
        if value in session_ids:
            raise ValueError("%s carries a session id" % key)
        folded = value.casefold()
        for token in FORBIDDEN_SUBSTRINGS:
            if token in folded:
                raise ValueError("%s carries %r content" % (key, token))
        if "/" in value or "\\" in value:
            raise ValueError("%s carries a filesystem path" % key)
        return
    if isinstance(value, list):
        for item in value:
            _assert_value(key, item, session_ids)
        return
    raise ValueError("%s carries unexpected metadata" % key)


def append_record(hermes_home, record):
    """Append one UTF-8 JSON line; return the record path."""
    directory = os.path.join(os.path.abspath(hermes_home), "logs")
    path = os.path.join(directory, RECORD_FILENAME)
    try:
        os.makedirs(directory, exist_ok=True)
        with open(path, "a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError as error:
        # The record is this command's only requested effect, so a failed write
        # is a failed run. This says nothing about the router, which fails open.
        raise CollectorError("cannot append the monthly record: %s" % error)
    return path


# --- command ---------------------------------------------------------------


def parse_status(name, value):
    if STATUS_PATTERN.match(value) is None:
        raise CollectorError("%s must be a lowercase token: %r" % (name, value))
    return value


def parse_amount(name, value):
    if value is None:
        return None
    try:
        amount = Decimal(value)
    except InvalidOperation:
        raise CollectorError("%s must be a decimal amount: %r" % (name, value))
    if amount < 0:
        raise CollectorError("%s must not be negative: %r" % (name, value))
    return usd(amount)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Append one explicit monthly supervisor cost snapshot."
    )
    parser.add_argument("--state-db", required=True, help="path to a Hermes state.db")
    parser.add_argument(
        "--hermes-home", required=True, help="Hermes home holding logs/"
    )
    parser.add_argument("--month", required=True, help="UTC month as YYYY-MM")
    parser.add_argument("--actual-provider-billing-status", default="unknown")
    parser.add_argument("--actual-provider-billed-usd", default=None)
    parser.add_argument("--extra-usage-status", default="disabled")
    parser.add_argument("--actual-billed-extra-usage-usd", default=None)
    options = parser.parse_args(argv)
    options.actual_provider_billing_status = parse_status(
        "--actual-provider-billing-status", options.actual_provider_billing_status
    )
    options.extra_usage_status = parse_status(
        "--extra-usage-status", options.extra_usage_status
    )
    options.actual_provider_billed_usd = parse_amount(
        "--actual-provider-billed-usd", options.actual_provider_billed_usd
    )
    options.actual_billed_extra_usage_usd = parse_amount(
        "--actual-billed-extra-usage-usd", options.actual_billed_extra_usage_usd
    )
    return options


def main(argv=None):
    try:
        options = parse_args(argv if argv is not None else sys.argv[1:])
        start, end = month_bounds(options.month)
        connection = open_read_only(options.state_db)
        try:
            assert_schema(connection)
            totals, session_ids = collect(connection, start, end)
        finally:
            connection.close()
        record = build_record(options.month, totals, options)
        assert_recordable(record, session_ids)
        path = append_record(options.hermes_home, record)
    except CollectorError as error:
        sys.stderr.write("record-supervisor-cost: %s\n" % error)
        return 1
    except sqlite3.Error as error:
        sys.stderr.write("record-supervisor-cost: state database error: %s\n" % error)
        return 1

    print(
        "month=%s record=%s sol_vs_terra_virtual_premium_usd=%s review_required=%s"
        % (
            record["month"],
            path,
            record["sol_vs_terra_virtual_premium_usd"],
            "true" if record["review_required"] else "false",
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
