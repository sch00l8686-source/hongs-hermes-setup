"""Explicit allowlist of the managed harness baseline.

This module is the single source of truth for *which* files the harness manages
and *where* each one is installed. It is intentionally a hand-maintained
allowlist: nothing here is discovered by walking the filesystem, and nothing
outside this list is ever read, hashed, copied, or validated.

Standard library only. No third-party imports.

Target roots
------------
``HermesHome``  the live Hermes home (holds ``SOUL.md`` and ``skills/``)
``ClaudeHome``  the global Claude instruction directory (holds ``CLAUDE.md``)
``CodexHome``   the global Codex instruction directory (holds ``AGENTS.md``)
"""

from __future__ import annotations

import hashlib
import os

SCHEMA_VERSION = 1

TARGET_ROOTS = ("HermesHome", "ClaudeHome", "CodexHome")

#: Git revision that carries the original, unmodified global instruction files.
#: The graphify blocks are read from this revision at runtime so the check never
#: depends on any in-flight branch existing.
GRAPHIFY_BASE_REVISION = "7b34b89"

#: The managed skill packages, as ``<category>/<skill-name>``.
#:
#: Twenty of these are the approved public-snapshot skill set; the twenty-first,
#: ``software-development/plan``, is the preserved local adapter that predates
#: that approval and is kept managed rather than dropped. Nothing is discovered:
#: a package that is not spelled out here is not installed, hashed, or validated.
APPROVED_SKILLS = (
    "superpowers/using-superpowers",
    "superpowers/brainstorming",
    "superpowers/writing-plans",
    "superpowers/executing-plans",
    "superpowers/subagent-driven-development",
    "superpowers/dispatching-parallel-agents",
    "superpowers/verification-before-completion",
    "superpowers/finishing-a-development-branch",
    "superpowers/receiving-code-review",
    "superpowers/using-git-worktrees",
    "software-development/plan",
    "autonomous-ai-agents/supervised-agent-workflow",
    "autonomous-ai-agents/mixed-model-agent-orchestration",
    "autonomous-ai-agents/subagent-coding-context",
    "autonomous-ai-agents/agent-context-efficiency",
    "autonomous-ai-agents/agent-context-governance",
    "autonomous-ai-agents/review-gated-config-distribution",
    "note-taking/obsidian-vault-ingest",
    "note-taking/obsidian-vault-lint",
    "note-taking/obsidian-vault-query",
    "automation/execution-continuity",
)

#: Extra (non-``SKILL.md``) files that belong to a managed skill, relative to
#: that skill's directory. A skill absent from this mapping owns exactly one
#: file, its ``SKILL.md``.
SKILL_REFERENCE_FILES = {
    "superpowers/using-superpowers": (
        "references/antigravity-tools.md",
        "references/codex-tools.md",
        "references/gemini-tools.md",
        "references/hermes-tools.md",
        "references/pi-tools.md",
    ),
    "superpowers/subagent-driven-development": (
        "references/context-budget-discipline.md",
        "references/gates-taxonomy.md",
    ),
    "autonomous-ai-agents/mixed-model-agent-orchestration": (
        "references/approval-safe-agent-runs.md",
        "references/bounded-worker-evidence.md",
        "references/claude-code-subscription-routing.md",
        "references/plan-scoped-codex-opus-review-gate.md",
        "references/root-model-adjudication-and-context-checkpoints.md",
    ),
    "automation/execution-continuity": (
        "references/goal-fidelity-and-user-gates.md",
        "references/interaction-boundaries.md",
    ),
    "autonomous-ai-agents/agent-context-efficiency": (
        "references/caveman-evaluation.md",
    ),
    "autonomous-ai-agents/agent-context-governance": (
        "references/observable-runtime-contracts.md",
        "references/verified-governance-patterns.md",
    ),
    "autonomous-ai-agents/review-gated-config-distribution": (
        "references/live-runtime-verification-instruments.md",
        "references/local-runtime-contract-activation.md",
    ),
}

#: The three files of the managed ``hongs-vault-router`` plugin, as
#: ``plugins/``-relative destinations under ``HermesHome``. They are listed one
#: by one on purpose: the plugin directory is never walked, so a file dropped
#: into it later is not silently installed, hashed, or validated.
PLUGIN_FILES = (
    "plugins/hongs-vault-router/__init__.py",
    "plugins/hongs-vault-router/plugin.yaml",
    "plugins/hongs-vault-router/router.py",
)

#: Non-skill managed files: ``(source, targetRoot, destination)``.
SINGLETON_FILES = (
    ("baseline/hermes/SOUL.md", "HermesHome", "SOUL.md"),
    ("baseline/agents/claude/CLAUDE.md", "ClaudeHome", "CLAUDE.md"),
    ("baseline/agents/codex/AGENTS.md", "CodexHome", "AGENTS.md"),
) + tuple(
    ("baseline/hermes/%s" % destination, "HermesHome", destination)
    for destination in PLUGIN_FILES
)


def managed_files():
    """Return the full managed file list as ``(source, targetRoot, destination)``.

    Sources are repository-relative POSIX paths under ``baseline/``.
    Destinations are root-relative POSIX paths.
    The result is deterministic and sorted by ``(targetRoot, destination)``.
    """
    entries = list(SINGLETON_FILES)
    for skill in APPROVED_SKILLS:
        relatives = ("SKILL.md",) + SKILL_REFERENCE_FILES.get(skill, ())
        for relative in relatives:
            entries.append(
                (
                    "baseline/skills/%s/%s" % (skill, relative),
                    "HermesHome",
                    "skills/%s/%s" % (skill, relative),
                )
            )
    return sorted(entries, key=lambda item: (item[1], item[2]))


def managed_sources():
    """Return just the repository-relative source paths, sorted."""
    return sorted(source for source, _root, _destination in managed_files())


def skill_directory(skill):
    """Repository-relative baseline directory for a managed skill."""
    return "baseline/skills/%s" % skill


def skill_manifest_path(skill):
    """Repository-relative ``SKILL.md`` path for a managed skill."""
    return "%s/SKILL.md" % skill_directory(skill)


def repo_path(root, relative):
    """Join a repository-relative POSIX path onto an OS path."""
    return os.path.join(root, *relative.split("/"))


def read_text(path):
    """Read a UTF-8 file and normalise line endings to ``\\n``."""
    with open(path, "rb") as handle:
        raw = handle.read()
    return raw.decode("utf-8").replace("\r\n", "\n")


def sha256_file(path):
    """Return the lowercase hex SHA-256 of a file's exact bytes."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()
