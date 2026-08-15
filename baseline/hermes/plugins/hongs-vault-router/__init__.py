"""hongs-vault-router — one deterministic Vault routing heartbeat per user turn.

The plugin registers exactly one ``pre_llm_call`` callback. Hermes injects the
returned context into the current turn's user message, so the cached system
prompt stays byte-stable.
"""

from __future__ import annotations

from typing import Any, Dict

from .router import route_turn


def _pre_llm_call(session_id: str = "", user_message: str = "", **_unused: Any) -> Dict[str, str]:
    """Return this turn's routing marker.

    Only ``session_id`` and ``user_message`` are read. ``conversation_history``
    and every other hook keyword stay in ``_unused``: they are never traversed,
    hashed, logged, or persisted.
    """
    return {"context": route_turn(user_message, session_id)}


def register(ctx: Any) -> None:
    ctx.register_hook("pre_llm_call", _pre_llm_call)
