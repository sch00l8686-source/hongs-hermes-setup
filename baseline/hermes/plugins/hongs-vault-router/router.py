"""Deterministic selective Vault routing for the Hermes ``pre_llm_call`` hook.

The module answers exactly one question per Hermes user turn: may this turn
enter the Vault? It reads the versioned routing-contract section of
``wiki/index.md`` and nothing else, emits exactly one heartbeat marker, and
appends one privacy-bounded audit event.

Two failure directions are deliberately opposite:

* Vault readiness and contract integrity fail **closed** — a missing root, a
  missing index, or an unparsable contract all report ``unavailable`` so
  evidence-bearing work stops instead of silently answering from memory.
* Routing telemetry fails **open** — a key, lock, rotation, or append failure
  returns ``False`` and can never suppress the heartbeat or the user's answer.

Standard library only: the hook runs inside the agent turn and must not add a
dependency, a service, or a network call.
"""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import json
import os
import re
import time
import unicodedata
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, Optional, Sequence, Tuple

SECTION_START = "<!-- hongs-vault-routing-contract:start -->"
SECTION_END = "<!-- hongs-vault-routing-contract:end -->"

SUPPORTED_VERSION = 1

#: The marker exposes at most two aliases, in contract order, so a long
#: multi-domain question cannot leak a reconstructable summary of itself.
MAX_MATCHED = 2

#: Telemetry retention, fixed by the approved design.
ROTATE_LIMIT_BYTES = 5 * 1024 * 1024
ROTATIONS = 3
KEY_BYTES = 32

#: A contended lock is retried briefly and then abandoned. The bound keeps a
#: concurrent Desktop/CLI/Gateway turn from dropping its audit line while still
#: guaranteeing the hook cannot hold a user's response.
LOCK_DEADLINE_SECONDS = 0.5
LOCK_RETRY_SECONDS = 0.005

ENTERED = "entered"
SKIPPED = "skipped"
UNAVAILABLE = "unavailable"

TRIGGER_EXPLICIT = "EXPLICIT"
TRIGGER_DOMAIN = "DOMAIN_MATCH"
TRIGGER_NO_DOMAIN = "NO_DOMAIN_MATCH"
TRIGGER_FILE_OP = "FILE_OP_EXCLUSION"
TRIGGER_UNAVAILABLE = "VAULT_UNAVAILABLE"

REQUIRED_FIELDS = (
    "contract-version",
    "explicit-triggers",
    "excluded-standalone",
    "file-op-verbs",
    "audit-priority",
)
REPEATED_FIELDS = ("domain-group",)


class ContractError(ValueError):
    """The routing contract section is absent, duplicated, or invalid."""


@dataclass(frozen=True)
class RoutingContract:
    version: int
    explicit_triggers: Tuple[str, ...]
    groups: Tuple[Tuple[str, Tuple[str, ...]], ...]
    excluded_standalone: Tuple[str, ...]
    file_op_verbs: Tuple[str, ...]
    audit_priority: str


@dataclass(frozen=True)
class VaultReadiness:
    available: bool
    reason: str
    index_path: str


@dataclass(frozen=True)
class RoutingDecision:
    decision: str
    trigger: str
    matched: Tuple[str, ...]


# ---------------------------------------------------------------------------
# Contract parsing
# ---------------------------------------------------------------------------


def _find_all(text: str, needle: str) -> list:
    found = []
    start = text.find(needle)
    while start != -1:
        found.append(start)
        start = text.find(needle, start + 1)
    return found


def _split_list(field: str, value: str) -> Tuple[str, ...]:
    items = tuple(item.strip() for item in value.split("|"))
    if not items or any(not item for item in items):
        raise ContractError("%s contains an empty entry" % field)
    return items


def parse_contract(index_text: str) -> RoutingContract:
    """Parse the single marked routing-contract section of an index page."""
    starts = _find_all(index_text, SECTION_START)
    ends = _find_all(index_text, SECTION_END)
    if len(starts) != 1 or len(ends) != 1 or starts[0] > ends[0]:
        raise ContractError(
            "expected exactly one balanced routing contract section, found "
            "%d start and %d end markers" % (len(starts), len(ends))
        )

    body = index_text[starts[0] + len(SECTION_START):ends[0]]

    singles: dict = {}
    groups: list = []
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("- "):
            raise ContractError("unexpected contract line: %r" % raw_line)
        field, separator, value = line[2:].partition(":")
        field = field.strip()
        value = value.strip()
        if not separator:
            raise ContractError("contract line is not a field: %r" % raw_line)
        if field in REPEATED_FIELDS:
            groups.append(_parse_group(value))
        elif field in REQUIRED_FIELDS:
            if field in singles:
                raise ContractError("duplicate %s field" % field)
            singles[field] = value
        else:
            raise ContractError("unsupported contract field %r" % field)

    for field in REQUIRED_FIELDS:
        if field not in singles:
            raise ContractError("missing %s field" % field)
    if not groups:
        raise ContractError("contract declares no domain-group")

    names = [name for name, _aliases in groups]
    duplicate = _first_duplicate(names)
    if duplicate is not None:
        raise ContractError("duplicate domain-group %r" % duplicate)

    version = _parse_version(singles["contract-version"])
    audit_priority = singles["audit-priority"]
    if audit_priority not in names:
        raise ContractError("audit-priority %r does not name a domain-group" % audit_priority)

    return RoutingContract(
        version=version,
        explicit_triggers=_split_list("explicit-triggers", singles["explicit-triggers"]),
        groups=tuple(groups),
        excluded_standalone=_split_list(
            "excluded-standalone", singles["excluded-standalone"]
        ),
        file_op_verbs=_split_list("file-op-verbs", singles["file-op-verbs"]),
        audit_priority=audit_priority,
    )


def _parse_version(raw: str) -> int:
    try:
        version = int(raw)
    except ValueError:
        raise ContractError("contract-version must be an integer, got %r" % raw)
    if version != SUPPORTED_VERSION:
        raise ContractError("unsupported contract-version %d" % version)
    return version


def _parse_group(value: str) -> Tuple[str, Tuple[str, ...]]:
    name, separator, alias_text = value.partition("::")
    if not separator:
        raise ContractError("domain-group %r has no '::' alias list" % value)
    name = name.strip()
    if not name:
        raise ContractError("domain-group %r has an empty name" % value)
    aliases = tuple(alias.strip() for alias in alias_text.split("|"))
    if any(not alias for alias in aliases):
        raise ContractError("domain-group %r has an empty alias" % name)
    duplicate = _first_duplicate([normalize_question(alias) for alias in aliases])
    if duplicate is not None:
        raise ContractError("domain-group %r has a duplicate alias" % name)
    return name, aliases


def _first_duplicate(items: Sequence[str]) -> Optional[str]:
    seen = set()
    for item in items:
        if item in seen:
            return item
        seen.add(item)
    return None


# ---------------------------------------------------------------------------
# Normalization and matching
# ---------------------------------------------------------------------------

_WORD = re.compile(r"\w", re.UNICODE)
_HANGUL_RANGES = (
    ("가", "힣"),  # syllables
    ("ᄀ", "ᇿ"),  # conjoining jamo
    ("㄰", "㆏"),  # compatibility jamo
    ("ꥠ", "꥿"),  # jamo extended-A
    ("ힰ", "퟿"),  # jamo extended-B
)

#: A filename with an extension, a path with a separator, or a quoted name.
#: Any of the three is the "file token" half of the file-operation exclusion.
_EXTENSION_TOKEN = re.compile(r"[^\s\"'`/\\]+\.[a-z][a-z0-9]{0,7}(?!\w)")
_PATH_TOKEN = re.compile(r"\S*[/\\]\S+")
_QUOTED_TOKEN = re.compile(r"\"[^\"]+\"|'[^']+'|`[^`]+`")


def normalize_question(question: str) -> str:
    """NFKC, case-fold, then collapse every whitespace run to one space."""
    normalized = unicodedata.normalize("NFKC", question or "")
    return " ".join(normalized.casefold().split())


def _is_hangul(char: str) -> bool:
    return any(low <= char <= high for low, high in _HANGUL_RANGES)


def _is_korean(alias: str) -> bool:
    return any(_is_hangul(char) for char in alias)


def _alias_matches(text: str, alias: str) -> bool:
    """Boundary rules fixed by the approved design.

    English aliases need a non-word character on both sides. Korean aliases need
    only a left boundary; the right boundary stays open so particles and endings
    can attach. That open right boundary is what makes ``빔을`` match, and it is
    also why ``빔프로젝터`` and ``폭발물`` match on purpose.
    """
    if not alias:
        return False
    korean = _is_korean(alias)
    start = text.find(alias)
    while start != -1:
        left_ok = start == 0 or not _WORD.match(text[start - 1])
        end = start + len(alias)
        right_ok = korean or end == len(text) or not _WORD.match(text[end])
        if left_ok and right_ok:
            return True
        start = text.find(alias, start + 1)
    return False


def _matching_aliases(text: str, aliases: Iterable[str], excluded: Iterable[str]) -> Iterator[str]:
    excluded_set = {normalize_question(item) for item in excluded}
    for alias in aliases:
        normalized = normalize_question(alias)
        if normalized in excluded_set:
            continue
        if _alias_matches(text, normalized):
            yield alias


def _has_file_token(text: str) -> bool:
    return bool(
        _EXTENSION_TOKEN.search(text)
        or _PATH_TOKEN.search(text)
        or _QUOTED_TOKEN.search(text)
    )


def _is_file_operation(text: str, contract: RoutingContract) -> bool:
    """Mechanical local file work, not a topical question.

    Both halves are required: a file-operation verb *and* a concrete file
    token. ``Niagara 파일 구조는 어떻게 설계해?`` keeps routing because it names
    no file.
    """
    if not _has_file_token(text):
        return False
    return any(True for _ in _matching_aliases(text, contract.file_op_verbs, ()))


def decide_route(
    question: str, contract: RoutingContract, readiness: VaultReadiness
) -> RoutingDecision:
    """Resolve one turn.

    Precedence: readiness, explicit trigger, file-operation exclusion, domain
    match, skip. Readiness outranks the explicit trigger because the approved
    design states that any readiness failure produces ``unavailable``; entering
    a Vault that is not on disk is not a reachable outcome.
    """
    if not readiness.available:
        return RoutingDecision(UNAVAILABLE, TRIGGER_UNAVAILABLE, ())

    text = normalize_question(question)
    if any(True for _ in _matching_aliases(text, contract.explicit_triggers, ())):
        return RoutingDecision(ENTERED, TRIGGER_EXPLICIT, ())
    if _is_file_operation(text, contract):
        return RoutingDecision(SKIPPED, TRIGGER_FILE_OP, ())

    matched: list = []
    for _name, aliases in contract.groups:
        for alias in _matching_aliases(text, aliases, contract.excluded_standalone):
            matched.append(alias)
            if len(matched) >= MAX_MATCHED:
                return RoutingDecision(ENTERED, TRIGGER_DOMAIN, tuple(matched))
    if matched:
        return RoutingDecision(ENTERED, TRIGGER_DOMAIN, tuple(matched))
    return RoutingDecision(SKIPPED, TRIGGER_NO_DOMAIN, ())


# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------


def check_vault(root_value: Optional[str]) -> VaultReadiness:
    """Three checks, no hardcoded fallback: set, directory exists, index exists."""
    if not root_value or not root_value.strip():
        return VaultReadiness(False, "UNSET", "")
    root = Path(root_value.strip())
    if not root.is_dir():
        return VaultReadiness(False, "ROOT_MISSING", "")
    index = root / "wiki" / "index.md"
    if not index.is_file():
        return VaultReadiness(False, "INDEX_MISSING", "")
    return VaultReadiness(True, "OK", str(index))


# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------


def format_heartbeat(decision: RoutingDecision) -> str:
    """One marker line. It carries no question text, path, or secret."""
    marker = "VAULT_ROUTING_CHECKED decision=%s trigger=%s" % (
        decision.decision,
        decision.trigger,
    )
    if decision.matched:
        marker += " matched=%s" % ",".join(decision.matched)
    return marker


# ---------------------------------------------------------------------------
# Telemetry (fail-open)
# ---------------------------------------------------------------------------


def _acquire(handle) -> None:
    deadline = time.monotonic() + LOCK_DEADLINE_SECONDS
    while True:
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(LOCK_RETRY_SECONDS)


def _release(handle) -> None:
    if os.name == "nt":
        import msvcrt

        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl

        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


@contextlib.contextmanager
def _routing_lock(path: Path):
    """One nonblocking cross-process lock over a single placeholder byte."""
    handle = open(path, "a+b")
    try:
        if os.fstat(handle.fileno()).st_size < 1:
            handle.write(b"\0")
            handle.flush()
        handle.seek(0)
        _acquire(handle)
        try:
            yield
        finally:
            _release(handle)
    finally:
        handle.close()


def _load_or_create_key(path: Path) -> bytes:
    """Machine-local 32-byte HMAC key. Held under the lock, so creation converges."""
    if path.exists():
        key = path.read_bytes()
        if len(key) != KEY_BYTES:
            raise ValueError("routing key is %d bytes, expected %d" % (len(key), KEY_BYTES))
        return key
    key = os.urandom(KEY_BYTES)
    staged = path.with_name(path.name + ".tmp")
    staged.write_bytes(key)
    os.replace(staged, path)
    return key


def _rotate_if_needed(log: Path) -> None:
    if not log.exists() or log.stat().st_size < ROTATE_LIMIT_BYTES:
        return
    oldest = log.with_name("%s.%d" % (log.name, ROTATIONS))
    if oldest.exists():
        oldest.unlink()
    for index in range(ROTATIONS - 1, 0, -1):
        source = log.with_name("%s.%d" % (log.name, index))
        if source.exists():
            os.replace(source, log.with_name("%s.%d" % (log.name, index + 1)))
    os.replace(log, log.with_name("%s.1" % log.name))


def write_routing_event(
    hermes_home: Path,
    session_id: str,
    normalized_question: str,
    decision: RoutingDecision,
) -> bool:
    """Append one audit event. Returns ``False`` instead of raising, always."""
    try:
        home = Path(hermes_home)
        runtime_dir = home / "runtime" / "vault-router"
        runtime_dir.mkdir(parents=True, exist_ok=True)
        with _routing_lock(runtime_dir / "vault-routing.lock"):
            key = _load_or_create_key(runtime_dir / "qhash.key")
            event = {
                "ts": datetime.now(timezone.utc)
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z"),
                "session": session_id,
                "decision": decision.decision,
                "trigger": decision.trigger,
                "matched": list(decision.matched),
                "qhash": hmac.new(
                    key, normalized_question.encode("utf-8"), hashlib.sha256
                ).hexdigest(),
            }
            line = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
            log = home / "logs" / "vault-routing.jsonl"
            log.parent.mkdir(parents=True, exist_ok=True)
            _rotate_if_needed(log)
            with open(log, "ab") as sink:
                sink.write(line.encode("utf-8") + b"\n")
                sink.flush()
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Turn entry point
# ---------------------------------------------------------------------------


def _decide_turn(user_message: str, vault_root: Optional[str]) -> RoutingDecision:
    root_value = vault_root if vault_root is not None else os.environ.get("HONG_VAULT_ROOT")
    readiness = check_vault(root_value)
    if not readiness.available:
        return RoutingDecision(UNAVAILABLE, TRIGGER_UNAVAILABLE, ())
    index_text = Path(readiness.index_path).read_text(encoding="utf-8-sig")
    contract = parse_contract(index_text)
    return decide_route(user_message, contract, readiness)


def route_turn(
    user_message: str,
    session_id: str,
    hermes_home: Optional[Path] = None,
    vault_root: Optional[str] = None,
) -> str:
    """Route one Hermes user turn and return its single heartbeat marker."""
    try:
        decision = _decide_turn(user_message, vault_root)
    except Exception:
        # Unreadable index, invalid contract, or any other routing failure is a
        # Vault-evidence failure: report it fail-closed rather than as a skip.
        decision = RoutingDecision(UNAVAILABLE, TRIGGER_UNAVAILABLE, ())

    home = hermes_home if hermes_home is not None else os.environ.get("HERMES_HOME")
    if home:
        write_routing_event(
            Path(home),
            session_id or "",
            normalize_question(user_message),
            decision,
        )
    return format_heartbeat(decision)
