"""Read-only proof of the Hermes reasoning seam.

Measures three things without any inference call and without any live
mutation: that ``chat --cli -Q -q`` dispatches through the classic branch with
no override, that a high in-memory config reaches the provider payload as
effort ``high`` with summary ``auto``, and that the frozen contract prompt is
routing-neutral. Output is categorical JSON only: no source path, home path,
session identifier, prompt text, token, or config value is ever emitted.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

KIND = "hongs-hermes-reasoning-seam"
SCHEMA_VERSION = 1
CONTRACT_PROMPT = "Return exactly MODEL_CONTRACT_PROBE_OK. Do not call tools."
EXPECTED_TOKEN = "MODEL_CONTRACT_PROBE_OK"

EXIT_PASS = 0
EXIT_ASSERTION = 1
EXIT_UNAVAILABLE = 2

DISPATCHER_CLAUSES = (
    "CHAT_COMMAND", "EXPLICIT_CLI", "NOT_ONESHOT", "CLASSIC_BRANCH",
    "QUERY_FORWARDED", "QUIET_FORWARDED", "NO_SESSION_INJECTION",
    "NO_REASONING_OVERRIDE",
)
PAYLOAD_CHECKS = (
    "ROW_REASONING_ENABLED", "ROW_EFFORT_HIGH",
    "PAYLOAD_EFFORT_HIGH", "PAYLOAD_SUMMARY_AUTO",
)

DECISION_MAP = {"skipped": "SKIPPED", "entered": "ENTERED", "unavailable": "UNAVAILABLE"}
TRIGGER_MAP = {
    "NO_DOMAIN_MATCH": "NO_DOMAIN", "DOMAIN_MATCH": "DOMAIN", "EXPLICIT": "EXPLICIT",
    "FILE_OP_EXCLUSION": "FILE_OP", "VAULT_UNAVAILABLE": "UNAVAILABLE",
}

PRE_IMPORT_SIDE_EFFECT_HELPERS = (
    "_resolve_use_tui",                      # main.py:2533
    "_apply_safe_mode",                      # main.py:2535
    "_has_any_provider_configured",          # main.py:2651
    "_termux_should_prefetch_update_check",  # main.py:2685
    "_sync_bundled_skills_for_startup",      # main.py:2695
    "_pin_kanban_board_env",                 # main.py:2725
    "_launch_tui",                           # main.py:2728
)

_ABSENT = object()

_PARSER_MODULE_NAME = "_hongs_seam_hermes_parser"
_CMD_CHAT_NAMESPACE_NAME = "_hongs_seam_cmd_chat"


class SeamUnavailable(Exception):
    """Setup or installed source could not be reached. Carries a categorical reason only."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


_OVERRIDES = {"dispatcher": None, "payload": None}


def _set_seam_overrides(dispatcher=None, payload=None) -> None:
    """Test-only injection point for fixture seams. Never used by the CLI path."""
    _OVERRIDES["dispatcher"] = dispatcher
    _OVERRIDES["payload"] = payload


def _reset_seam_overrides() -> None:
    _OVERRIDES["dispatcher"] = None
    _OVERRIDES["payload"] = None


def _load_parser_module(source_root: Path, neutralizer):
    """Load the installed hermes_cli/_parser.py by exact path, not by import.

    ``spec_from_file_location`` under a private synthetic module name executes
    only that one measured standard-library-only file. The ``hermes_cli``
    package is never imported, so no installed ``__init__`` and no
    ``hermes_cli.main`` module-level bootstrap can run. The caller holds
    ``sys.dont_write_bytecode = True``, so no ``__pycache__`` byte is written
    into the installed tree, and ``neutralizer`` removes the synthetic
    ``sys.modules`` entry in ``finally``.
    """
    import importlib.util

    parser_path = source_root / "hermes_cli" / "_parser.py"
    if not parser_path.is_file():
        raise SeamUnavailable("SOURCE_MODULE_MISSING")
    spec = importlib.util.spec_from_file_location(_PARSER_MODULE_NAME, parser_path)
    if spec is None or spec.loader is None:
        raise SeamUnavailable("SOURCE_MODULE_MISSING")
    module = importlib.util.module_from_spec(spec)
    neutralizer.set_module(_PARSER_MODULE_NAME, module)
    try:
        spec.loader.exec_module(module)
    except Exception:
        raise SeamUnavailable("SOURCE_MODULE_MISSING")
    if not hasattr(module, "build_top_level_parser"):
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    return module


def _compile_installed_cmd_chat(source_root: Path, namespace: dict):
    """Compile the exact installed cmd_chat definition, and nothing else.

    ``hermes_cli/main.py`` is read as UTF-8 and parsed with ``ast``. Only the
    single top-level ``FunctionDef`` named ``cmd_chat`` is compiled and
    executed, into ``namespace``. No module-level statement of that file is
    ever compiled or executed, so the bootstrap block at main.py:46-102 and its
    ``_early_recovery_mod.recover_if_needed()`` call never run. The returned
    object is the installed function body itself, not a description of it.
    """
    import ast

    main_path = source_root / "hermes_cli" / "main.py"
    if not main_path.is_file():
        raise SeamUnavailable("SOURCE_MODULE_MISSING")
    try:
        source_text = main_path.read_text(encoding="utf-8")
    except Exception:
        raise SeamUnavailable("SOURCE_MODULE_MISSING")
    try:
        tree = ast.parse(source_text, filename=str(main_path))
    except SyntaxError:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

    top_level = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            top_level.setdefault(node.name, []).append(node)

    definitions = top_level.get("cmd_chat", [])
    if len(definitions) != 1:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    definition = definitions[0]
    if definition.decorator_list:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    for helper in PRE_IMPORT_SIDE_EFFECT_HELPERS:
        if len(top_level.get(helper, [])) != 1:
            raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

    try:
        module_node = ast.fix_missing_locations(
            ast.Module(body=[definition], type_ignores=[])
        )
        code = compile(module_node, str(main_path), "exec")
        exec(code, namespace)  # defines cmd_chat only; runs no module-level statement
    except Exception:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

    function = namespace.get("cmd_chat")
    if not callable(function):
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    return function


def _require_root_cli_file(source_root: Path) -> None:
    """Confirm the exact root caller file of main.py:2747 exists. Nothing else.

    It is an ``is_file()`` check on ``<source_root>/cli.py`` only: the file is
    never imported, never read, never parsed, and never located through a
    candidate list or ``importlib.util.find_spec``, either of which could
    resolve a ``cli`` module from some other path.
    """
    if not (source_root / "cli.py").is_file():
        raise SeamUnavailable("SOURCE_MODULE_MISSING")


def _unpack_top_level_parser(parser_module):
    """Bind build_top_level_parser() as its exact measured 3-tuple.

    ``hermes_cli/_parser.py`` returns ``(parser, subparsers, chat_parser)`` at
    line 503. The chat subparser comes from that tuple; nothing is scanned.
    """
    import argparse

    built = parser_module.build_top_level_parser()
    if not isinstance(built, tuple) or len(built) != 3:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    parser, subparsers, chat_parser = built
    choices = getattr(subparsers, "choices", None)
    if not isinstance(choices, dict) or choices.get("chat") is not chat_parser:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    command_dest = getattr(subparsers, "dest", None)
    if not command_dest or command_dest == argparse.SUPPRESS:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    return parser, chat_parser, command_dest


def _dest_for(parsers, option_string: str) -> str:
    """Read the dest the installed parser registered for an exact option string."""
    found = {
        action.dest
        for parser in parsers
        for action in parser._actions
        if option_string in getattr(action, "option_strings", ())
    }
    if len(found) != 1:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    return found.pop()


class _ChatRecorder:
    """Stands in for the root ``cli.main`` of main.py:2747.

    Records the forwarded call and stops the dispatch; it never executes the
    real entry point and never reaches a provider, a socket, or a state write.
    """

    class Stop(Exception):
        pass

    def __init__(self) -> None:
        self.reached = False
        self.tui_launched = False
        self.args = ()
        self.kwargs = {}

    def fake_cli_main(self, *args, **kwargs):
        self.reached = True
        self.args = args
        self.kwargs = kwargs
        raise self.Stop()

    def fake_launch_tui(self, *_args, **_kwargs):
        """Stands in for main._launch_tui (main.py:2728). Never launches a TUI."""
        self.tui_launched = True
        raise self.Stop()

    @staticmethod
    def no_tui(*_args, **_kwargs):
        """Stands in for main._resolve_use_tui (main.py:2533), which reads config."""
        return False

    @staticmethod
    def provider_configured(*_args, **_kwargs):
        """Stands in for main._has_any_provider_configured (main.py:2651)."""
        return True

    @staticmethod
    def no_prefetch(*_args, **_kwargs):
        """Stands in for main._termux_should_prefetch_update_check (main.py:2685)."""
        return False

    @staticmethod
    def noop(*_args, **_kwargs):
        """Stands in for _apply_safe_mode, _sync_bundled_skills_for_startup,
        and _pin_kanban_board_env (main.py:2535, 2695, 2725)."""
        return None


def _synthetic_module(name: str, members: dict):
    """Build a bare types.ModuleType carrying only the exact members named."""
    import types

    module = types.ModuleType(name)
    for member, value in members.items():
        setattr(module, member, value)
    return module


def _dispatch_module_substitutes(recorder) -> dict:
    """The exact synthetic modules the compiled body's local imports resolve to.

    ``hermes_cli.xai_retirement`` and ``hermes_cli.config`` cover the xAI
    retirement block at main.py:2627-2648, so the real config is never
    imported and never read. ``cli`` covers the local import at main.py:2747.
    The bare ``hermes_cli`` placeholder carries no ``__path__``: a submodule
    resolved out of ``sys.modules`` never consults it, and any route that did
    would raise and fail closed instead of executing an installed
    ``hermes_cli/__init__.py``.
    """
    return {
        "hermes_cli": _synthetic_module("hermes_cli", {}),
        "hermes_cli.xai_retirement": _synthetic_module(
            "hermes_cli.xai_retirement",
            {
                "MIGRATION_GUIDE_URL": "",
                "RETIREMENT_DATE": "",
                "find_retired_xai_refs": lambda _config: (),
                "format_issue": lambda _ref: "",
            },
        ),
        "hermes_cli.config": _synthetic_module(
            "hermes_cli.config", {"load_config": lambda *_a, **_k: {}}
        ),
        "cli": _synthetic_module("cli", {"main": recorder.fake_cli_main}),
    }


def _dispatch_namespace(recorder) -> dict:
    """The exact synthetic globals the compiled cmd_chat body resolves against.

    These are the measured referenced globals and helpers of the no-resume /
    no-in / no-yolo / no-ignore / source-none path, and nothing else. The dict
    is never registered in ``sys.modules``. An unprovided global reached at run
    time raises ``NameError``, which the seam reports as
    ``SOURCE_SYMBOL_MISSING``; no guessed candidate is ever added.
    """
    import os

    return {
        "__name__": _CMD_CHAT_NAMESPACE_NAME,
        "os": os,
        "sys": sys,
        "_resolve_use_tui": recorder.no_tui,
        "_apply_safe_mode": recorder.noop,
        "_has_any_provider_configured": recorder.provider_configured,
        "_termux_should_prefetch_update_check": recorder.no_prefetch,
        "_sync_bundled_skills_for_startup": recorder.noop,
        "_pin_kanban_board_env": recorder.noop,
        "_launch_tui": recorder.fake_launch_tui,
    }


class _Neutralizer:
    """Applies the measured substitutions and undoes every one of them exactly.

    Every substitution is a ``sys.modules`` key: it goes back to the exact
    module object it held, or is deleted when it was absent. No installed
    module global is patched, because the seam never creates an installed
    module object to patch.
    """

    def __init__(self) -> None:
        self._modules = []

    def set_module(self, name: str, value) -> None:
        self._modules.append((name, sys.modules.get(name, _ABSENT)))
        sys.modules[name] = value

    def restore(self) -> None:
        for name, previous in reversed(self._modules):
            if previous is _ABSENT:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous
        self._modules = []


def _flatten_dispatch(recorder) -> dict:
    """Normalize the forwarded call to {dest: value} plus unnamed positionals.

    A forwarded argparse.Namespace merges by its own dest names; keyword
    arguments merge as given. Values are compared only and never emitted.
    """
    import argparse

    flat = {}
    positional = []
    for value in recorder.args:
        if isinstance(value, argparse.Namespace):
            flat.update(vars(value))
        else:
            positional.append(value)
    flat.update(recorder.kwargs)
    flat["__positional__"] = positional
    return flat


def _prompt_was_modified(forwarded: dict) -> bool:
    """True when a forwarded string carries the frozen prompt plus extra text."""
    values = [value for value in forwarded.values() if isinstance(value, str)]
    values.extend(v for v in forwarded["__positional__"] if isinstance(v, str))
    return any(CONTRACT_PROMPT in v and v != CONTRACT_PROMPT for v in values)


def run_dispatcher_seam(source_root: Path) -> dict:
    import os

    previous_bytecode = sys.dont_write_bytecode
    saved_path = list(sys.path)
    saved_environ = dict(os.environ)
    saved_cwd = os.getcwd()
    neutralizer = _Neutralizer()
    recorder = _ChatRecorder()
    sys.dont_write_bytecode = True
    try:
        # No dotted-name import and no sys.path entry: hermes_cli.main, the
        # hermes_cli package, and root cli.py are never imported or executed.
        parser_module = _load_parser_module(source_root, neutralizer)
        _require_root_cli_file(source_root)

        parser, chat_parser, command_dest = _unpack_top_level_parser(parser_module)
        scopes = (parser, chat_parser)
        dest = {
            option: _dest_for(scopes, option)
            for option in ("--cli", "-Q", "-q", "--oneshot", "--model", "--provider", "--reasoning")
        }

        args = parser.parse_args(["chat", "--cli", "-Q", "-q", CONTRACT_PROMPT])
        parsed = vars(args)

        namespace = _dispatch_namespace(recorder)
        cmd_chat = _compile_installed_cmd_chat(source_root, namespace)
        for name, module in _dispatch_module_substitutes(recorder).items():
            neutralizer.set_module(name, module)

        try:
            cmd_chat(args)
        except _ChatRecorder.Stop:
            pass
        except SystemExit:
            pass
        except SeamUnavailable:
            raise
        except Exception:
            # Includes NameError for an unprovided exact global. Never widened.
            raise SeamUnavailable("SOURCE_SYMBOL_MISSING")
    finally:
        neutralizer.restore()
        if sys.path != saved_path:
            sys.path[:] = saved_path
        sys.dont_write_bytecode = previous_bytecode
        if os.getcwd() != saved_cwd:
            os.chdir(saved_cwd)
        if dict(os.environ) != saved_environ:
            os.environ.clear()
            os.environ.update(saved_environ)

    if not recorder.reached and not recorder.tui_launched:
        raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

    forwarded = _flatten_dispatch(recorder)
    query = forwarded.get(dest["-q"])
    failed = []
    if parsed.get(command_dest) != "chat":
        failed.append("CHAT_COMMAND")
    if parsed.get(dest["--cli"]) is not True:
        failed.append("EXPLICIT_CLI")
    if bool(parsed.get(dest["--oneshot"])):
        failed.append("NOT_ONESHOT")
    if not recorder.reached:
        failed.append("CLASSIC_BRANCH")
    if query != CONTRACT_PROMPT and CONTRACT_PROMPT not in forwarded["__positional__"]:
        failed.append("QUERY_FORWARDED")
    if forwarded.get(dest["-Q"]) is not True:
        failed.append("QUIET_FORWARDED")
    if _prompt_was_modified(forwarded):
        failed.append("NO_SESSION_INJECTION")
    if any(forwarded.get(dest[option]) is not None
           for option in ("--model", "--provider", "--reasoning")):
        failed.append("NO_REASONING_OVERRIDE")

    ordered = [clause for clause in DISPATCHER_CLAUSES if clause in failed]
    return {
        "status": "PASS" if not ordered else "FAIL",
        "clauses": "%d/8" % (len(DISPATCHER_CLAUSES) - len(ordered)),
        "failed": ordered,
    }


def evaluate_payload_evidence(row: dict, payload: dict) -> dict:
    """Pure assertion over already-measured row and payload evidence."""
    reasoning = (payload or {}).get("reasoning") or {}
    failed = []
    if not row.get("enabled"):
        failed.append("ROW_REASONING_ENABLED")
    if row.get("effort") != "high":
        failed.append("ROW_EFFORT_HIGH")
    if reasoning.get("effort") != "high":
        failed.append("PAYLOAD_EFFORT_HIGH")
    if reasoning.get("summary") != "auto":
        failed.append("PAYLOAD_SUMMARY_AUTO")
    ordered = [check for check in PAYLOAD_CHECKS if check in failed]
    return {
        "status": "PASS" if not ordered else "FAIL",
        "checks": "%d/4" % (len(PAYLOAD_CHECKS) - len(ordered)),
        "failed": ordered,
    }


def run_payload_seam(source_root: Path) -> dict:
    import sqlite3
    import tempfile

    root = str(source_root)
    sys.path.insert(0, root)
    try:
        try:
            from hermes_constants import resolve_reasoning_config
            from hermes_state import SessionDB
            from run_agent import AIAgent
        except Exception:
            raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

        resolved = resolve_reasoning_config(
            {"agent": {"reasoning_effort": "high"}}, "gpt-5.6-sol"
        )

        with tempfile.TemporaryDirectory(prefix="hermes-seam-") as temp:
            db_path = Path(temp) / "state.db"
            agent = None
            db = None
            try:
                db = SessionDB(db_path)
                try:
                    agent = AIAgent(
                        model="gpt-5.6-sol",
                        provider="openai-codex",
                        requested_provider="openai-codex",
                        api_mode="codex_responses",
                        api_key="seam-dummy-token",
                        base_url="https://chatgpt.com/backend-api/codex",
                        enabled_toolsets=[],
                        quiet_mode=True,
                        platform="cli",
                        session_db=db,
                        reasoning_config=resolved,
                        skip_context_files=True,
                        skip_memory=True,
                        skip_background_review=True,
                    )
                except Exception:
                    raise SeamUnavailable("SOURCE_SYMBOL_MISSING")

                agent._ensure_db_session()

                connection = sqlite3.connect(str(db_path))
                try:
                    stored = connection.execute(
                        "SELECT model_config FROM sessions WHERE id = ?",
                        (agent.session_id,),
                    ).fetchone()
                except sqlite3.Error:
                    raise SeamUnavailable("STATE_UNAVAILABLE")
                finally:
                    connection.close()

                if not stored or stored[0] is None:
                    raise SeamUnavailable("STATE_UNAVAILABLE")
                try:
                    model_config = json.loads(stored[0])
                    stored_reasoning = model_config["reasoning_config"] or {}
                except (ValueError, TypeError, KeyError):
                    raise SeamUnavailable("STATE_UNAVAILABLE")
                row = {
                    "enabled": bool(stored_reasoning.get("enabled")),
                    "effort": stored_reasoning.get("effort"),
                }

                kwargs = agent._build_api_kwargs(
                    [{"role": "user", "content": "probe"}], tools_for_api=[]
                )
                reasoning = (kwargs or {}).get("reasoning") or {}
                payload = {
                    "reasoning": {
                        "effort": reasoning.get("effort"),
                        "summary": reasoning.get("summary"),
                    }
                }
            finally:
                # Inside the with block on every path: the temporary directory is
                # removed only after both handles on state.db are released.
                if agent is not None:
                    agent.close()
                if db is not None:
                    db.close()
    except SeamUnavailable:
        raise
    except Exception:
        raise SeamUnavailable("STATE_UNAVAILABLE")
    finally:
        if root in sys.path:
            sys.path.remove(root)

    return evaluate_payload_evidence(row, payload)


def run_prompt_routing_seam(router_path: Path, contract_path: Path, prompt: str) -> dict:
    import importlib.util

    if not router_path.is_file():
        raise SeamUnavailable("ROUTER_MODULE_MISSING")
    if not contract_path.is_file():
        raise SeamUnavailable("CONTRACT_UNREADABLE")

    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec = importlib.util.spec_from_file_location("hongs_vault_router_seam", router_path)
        if spec is None or spec.loader is None:
            raise SeamUnavailable("ROUTER_MODULE_MISSING")
        router = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = router
        spec.loader.exec_module(router)
    except SeamUnavailable:
        raise
    except Exception:
        raise SeamUnavailable("ROUTER_MODULE_MISSING")
    finally:
        sys.dont_write_bytecode = previous

    try:
        contract = router.parse_contract(contract_path.read_text(encoding="utf-8"))
    except Exception:
        raise SeamUnavailable("CONTRACT_UNREADABLE")

    readiness = router.VaultReadiness(available=True, reason="OK", index_path="wiki/index.md")
    decision = router.decide_route(prompt, contract, readiness)

    mapped_decision = DECISION_MAP.get(decision.decision, "UNAVAILABLE")
    mapped_trigger = TRIGGER_MAP.get(decision.trigger, "UNAVAILABLE")
    neutral = (
        mapped_decision == "SKIPPED"
        and mapped_trigger == "NO_DOMAIN"
        and len(decision.matched) == 0
    )
    return {
        "status": "PASS" if neutral else "FAIL",
        "decision": mapped_decision,
        "trigger": mapped_trigger,
        "matched": len(decision.matched),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--hermes-source", required=True)
    parser.add_argument("--router", required=True)
    parser.add_argument("--routing-contract", required=True)
    parser.add_argument("--prompt", required=True)
    args = parser.parse_args(argv)

    report = {
        "kind": KIND,
        "schemaVersion": SCHEMA_VERSION,
        "result": "PASS",
        "dispatcher": {"status": "PASS", "clauses": "8/8", "failed": []},
        "payload": {"status": "PASS", "checks": "4/4", "failed": []},
        "routing": {"status": "PASS", "decision": "SKIPPED", "trigger": "NO_DOMAIN", "matched": 0},
        "externalInference": 0,
        "liveMutation": 0,
    }

    unavailable = None
    try:
        source_root = Path(args.hermes_source)
        if not source_root.is_dir():
            raise SeamUnavailable("SOURCE_ROOT_MISSING")
        dispatcher_fn = _OVERRIDES["dispatcher"] or run_dispatcher_seam
        payload_fn = _OVERRIDES["payload"] or run_payload_seam
        report["dispatcher"] = dispatcher_fn(source_root)
        report["payload"] = payload_fn(source_root)
    except SeamUnavailable as exc:
        unavailable = exc.reason
        report["dispatcher"] = {"status": "UNAVAILABLE", "clauses": "0/8", "failed": [exc.reason]}
        report["payload"] = {"status": "UNAVAILABLE", "checks": "0/4", "failed": [exc.reason]}

    try:
        report["routing"] = run_prompt_routing_seam(
            Path(args.router), Path(args.routing_contract), args.prompt
        )
    except SeamUnavailable as exc:
        unavailable = unavailable or exc.reason
        report["routing"] = {
            "status": "UNAVAILABLE", "decision": "UNAVAILABLE",
            "trigger": "UNAVAILABLE", "matched": 0,
        }

    if unavailable is not None:
        report["result"] = "UNAVAILABLE"
        code = EXIT_UNAVAILABLE
    elif all(section["status"] == "PASS" for section in
             (report["dispatcher"], report["payload"], report["routing"])):
        report["result"] = "PASS"
        code = EXIT_PASS
    else:
        report["result"] = "FAIL"
        code = EXIT_ASSERTION

    sys.stdout.write(json.dumps(report, separators=(",", ":")) + "\n")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
