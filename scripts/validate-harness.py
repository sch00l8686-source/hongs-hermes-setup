#!/usr/bin/env python3
"""Fail-closed static validation of the global agent harness baseline.

Usage
-----
    python scripts/validate-harness.py --root <repo>

Optional
--------
    --git-root <path>   repository used to read the original graphify blocks
                        (defaults to ``--root``)
    --json              emit machine-readable findings instead of text

Exit codes
----------
    0   every rule passed
    1   at least one rule failed (findings are printed with rule id and path)
    2   the validator could not run (missing root, unreadable git base)

The validator never prints file content. A finding names the rule id, the
repository-relative path, an optional line number, and the identifier of the
missing or violated anchor -- nothing else.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import harness_baseline as baseline  # noqa: E402


# --------------------------------------------------------------------------
# Rule catalogue
# --------------------------------------------------------------------------

RULES = {
    "E001": "managed file set is exact",
    "E002": "SKILL.md frontmatter delimiters, name, and description",
    "E003": "no machine-local absolute path inside a portable skill",
    "E010": "exactly-one-line mechanical exception is stated",
    "E011": "brainstorming gate is stated",
    "E012": "writing-plans is the single plan authority",
    "E013": "approved worker task contract is stated",
    "E014": "Goal Fidelity is present in every required skill",
    "E015": "non-executing proposal duty is stated",
    "E016": "bounded parallelism rules are stated",
    "E017": "direct supervisor verification is stated",
    "E018": "review is exceptional and trigger-gated",
    "E020": "no active default mandate for routine per-task review",
    "E030": "imported graphify blocks are preserved byte-for-byte",
    "E031": "plan skill stays an adapter and does not duplicate plan authority",
    "E040": "SOUL.md carries the global harness rules",
    "E041": "global Claude CLAUDE.md carries the independent-session trigger",
    "E042": "global Codex AGENTS.md carries the independent-session trigger",
    "E050": "plugin manifest is exact and registers exactly one pre_llm_call hook",
    "E051": "router paths are fixed and routing telemetry carries no content",
    "E052": "routing contract and matching boundaries are exact",
    "E053": "Hermes heartbeat, Vault, and model rules fail closed",
    "E054": "independent Claude/Codex sessions are explicit-only and cannot issue work",
    "E055": "monthly supervisor cost record keeps estimate and actual billing separate",
    "E056": "exactly three shared model keys and no whole-file config copy",
    "E057": "model contract stamp, bootstrap expiry, and no Terra auto-fallback",
}

#: Phase 2 source files that live outside ``baseline/``.
ROUTING_CONTRACT = "contracts/vault-query-routing-contract.md"
COST_COLLECTOR = "scripts/record-supervisor-cost.py"
DESIGN_AUTHORITY = "docs/superpowers/specs/2026-08-14-global-runtime-contract-design.md"

PLUGIN_DIRECTORY = "baseline/hermes/plugins/hongs-vault-router"
PLUGIN_MANIFEST = "%s/plugin.yaml" % PLUGIN_DIRECTORY
PLUGIN_INIT = "%s/__init__.py" % PLUGIN_DIRECTORY
PLUGIN_ROUTER = "%s/router.py" % PLUGIN_DIRECTORY

#: Rules that depend on the global instruction triggers owned by the global
#: instruction worker. They are expected to fail until that work lands.
PENDING_GLOBAL_TRIGGER_RULES = ("E040", "E041", "E042")


# --------------------------------------------------------------------------
# Required-anchor tables
# --------------------------------------------------------------------------

def _skill(path):
    return "baseline/skills/%s/SKILL.md" % path


def _exact_line(text):
    """Anchor that matches ``text`` as a whole line and nothing else."""
    return r"^%s$" % re.escape(text)


#: The global instruction files (SOUL.md, global CLAUDE.md, global AGENTS.md)
#: state the one-line exception as a single conjunctive sentence, not as the
#: skill-surface phrase ``exactly-one-line mechanical exception``. Every
#: conjunct is load bearing, so the anchor requires all of them inside one
#: sentence: the change must be truly mechanical, reversible, and an exact
#: one-line correction before it may bypass the full gate, and only when
#: intent, target, expected result, and verification are already explicit.
#: ``[^.]`` between the conjuncts keeps the match inside a single sentence, so
#: satisfying the anchor by scattering the words across a paragraph fails.
GLOBAL_ONE_LINE_EXCEPTION = (
    r"(?i)truly mechanical\b[^.]{0,40}?\breversible\b[^.]{0,40}?"
    r"\bexact[- ]one[- ]line correction\b[^.]{0,40}?\bmay bypass\b[^.]{0,20}?\bfull gate\b"
    r"[^.]{0,40}?\bintent\b[^.]{0,40}?\btarget\b[^.]{0,40}?\bexpected result\b"
    r"[^.]{0,40}?\bverification\b[^.]{0,40}?\bexplicit\b"
)


# Each entry: rule id -> {repo-relative path -> ((anchor id, regex), ...)}
REQUIRED_ANCHORS = {
    "E010": {
        _skill("superpowers/using-superpowers"): (
            ("exception-name", r"exactly-one-line mechanical exception"),
            ("conjunctive", r"one uncertain condition means full gate"),
            ("two-line-full-gate", r"A two-line change takes the full gate"),
            ("routing-full-gate", r"one-line model-routing change\s+takes the full gate"),
        ),
        _skill("superpowers/brainstorming"): (
            ("exception-name", r"exactly-one-line mechanical exception"),
        ),
        _skill("software-development/plan"): (
            ("exception-name", r"exactly-one-line mechanical exception"),
        ),
    },
    "E011": {
        _skill("superpowers/using-superpowers"): (
            ("gate-order", r"brainstorming\s*\n?→?\s*.*written spec approval"),
        ),
        _skill("superpowers/brainstorming"): (
            ("hard-gate", r"<HARD-GATE>"),
            ("no-simple-bypass", r"Every project goes through this process"),
            ("spec-approval", r"written spec"),
        ),
        _skill("automation/execution-continuity"): (
            ("planning-prerequisite", r"Planning Prerequisite"),
            ("routes-to-design", r"`brainstorming`, then `writing-plans`"),
        ),
    },
    "E012": {
        _skill("superpowers/writing-plans"): (
            ("single-authority", r"single authority for implementation plans"),
            ("required-sections", r"### Required sections"),
            ("no-placeholders", r"## No Placeholders"),
        ),
        _skill("software-development/plan"): (
            ("defers-to-writing-plans", r"single authority for plan contents"),
        ),
    },
    "E013": {
        _skill("superpowers/using-superpowers"): (
            ("contract-name", r"APPROVED_WORKER_TASK"),
            ("no-rebrainstorm", r"Do not re-run brainstorming"),
            ("no-routine-permission", r"Do not ask routine permission"),
        ),
        _skill("autonomous-ai-agents/subagent-coding-context"): (
            ("no-open-mandate", r"never an open design mandate"),
            ("goal-conflict", r"GOAL_CONFLICT"),
        ),
        _skill("superpowers/subagent-driven-development"): (
            ("worker-limits", r"A worker may not brainstorm"),
        ),
    },
    "E014": {
        _skill("superpowers/writing-plans"): (
            ("lock-heading", r"## Goal Fidelity Lock"),
            ("drift-rejected", r"GOAL_DRIFT_REJECTED"),
            ("authority-order", r"current direct user goal"),
        ),
        _skill("autonomous-ai-agents/supervised-agent-workflow"): (
            ("lock-heading", r"## Goal Fidelity Lock"),
            ("drift-rejected", r"GOAL_DRIFT_REJECTED"),
            ("authority-order", r"Authority order"),
        ),
        _skill("autonomous-ai-agents/subagent-coding-context"): (
            ("goal-clause", r"Goal clause served"),
            ("drift-rejected", r"GOAL_DRIFT_REJECTED"),
            ("goal-conflict", r"GOAL_CONFLICT"),
        ),
        _skill("automation/execution-continuity"): (
            ("execution-heading", r"Goal Fidelity During Execution"),
            ("immutable-goal", r"immutable execution inputs"),
        ),
        _skill("superpowers/verification-before-completion"): (
            ("checks-heading", r"## Goal Fidelity Checks"),
            ("drift-rejected", r"GOAL_DRIFT_REJECTED"),
        ),
    },
    "E015": {
        _skill("superpowers/brainstorming"): (
            ("packet", r"Non-executing proposal:"),
            ("duty", r"Proposal duty"),
        ),
        _skill("superpowers/executing-plans"): (
            ("packet", r"Non-executing proposal:"),
            ("no-implementation", r"Implementation performed: no"),
        ),
        _skill("automation/execution-continuity"): (
            ("packet", r"non-executing proposal"),
        ),
        _skill("software-development/plan"): (
            ("packet", r"non-executing\s+proposal"),
        ),
    },
    "E016": {
        _skill("superpowers/dispatching-parallel-agents"): (
            ("checklist", r"## The Independence Checklist"),
            ("serialize", r"One false line\s*→ serialize them"),
            ("cap", r"At most three active implementation workers"),
            ("worktree", r"own worktree"),
        ),
        _skill("superpowers/subagent-driven-development"): (
            ("cap", r"At most three active implementation workers"),
            ("isolation", r"own isolated worktree"),
        ),
        _skill("autonomous-ai-agents/supervised-agent-workflow"): (
            ("disjoint", r"disjoint mutable boundaries"),
        ),
    },
    "E017": {
        _skill("superpowers/subagent-driven-development"): (
            ("not-evidence", r"self-report is \*\*not\*\* completion evidence"),
            ("inspect", r"Inspect the actual artifact"),
        ),
        _skill("autonomous-ai-agents/supervised-agent-workflow"): (
            ("not-evidence", r"Worker reports are not evidence"),
        ),
        _skill("superpowers/verification-before-completion"): (
            ("iron-law", r"NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE"),
            ("matrix", r"Requirement-to-Evidence Matrix"),
        ),
        _skill("superpowers/executing-plans"): (
            ("inspect", r"Inspect the actual artifact/diff"),
        ),
    },
    "E018": {
        _skill("superpowers/subagent-driven-development"): (
            ("heading", r"Exceptional Review Only"),
            ("no-default", r"there is no spec reviewer, no quality reviewer, and no final integration reviewer"),
            ("sol-reserved", r"Codex Sol is reserved for exceptional adjudication"),
        ),
        _skill("autonomous-ai-agents/supervised-agent-workflow"): (
            ("heading", r"### Exceptional Review"),
            ("no-default", r"Independent review is not a step in this procedure"),
        ),
        _skill("autonomous-ai-agents/mixed-model-agent-orchestration"): (
            ("no-default", r"There is no default reviewer step"),
            ("trigger-recorded", r"Record which trigger fired"),
        ),
    },
    "E040": {
        "baseline/hermes/SOUL.md": (
            ("skill-first", r"(?i)skill"),
            ("one-line-exception", GLOBAL_ONE_LINE_EXCEPTION),
            ("full-gate", r"(?i)full (design and plan )?gate"),
            ("brainstorming", r"(?i)brainstorming"),
            ("writing-plans", r"(?i)writing-plans"),
            ("goal-fidelity", r"(?i)goal fidelity"),
            ("proposal-duty", r"(?i)non-executing proposal"),
            ("opus-role", r"(?i)opus"),
            ("vault-entry", r"HONG_VAULT_ROOT"),
        ),
    },
    "E041": {
        "baseline/agents/claude/CLAUDE.md": (
            ("one-line-exception", GLOBAL_ONE_LINE_EXCEPTION),
            ("brainstorming", r"(?i)brainstorming"),
            ("writing-plans", r"(?i)writing-plans"),
        ),
    },
    "E042": {
        "baseline/agents/codex/AGENTS.md": (
            ("one-line-exception", GLOBAL_ONE_LINE_EXCEPTION),
            ("brainstorming", r"(?i)brainstorming"),
            ("writing-plans", r"(?i)writing-plans"),
        ),
    },
    "E052": {
        ROUTING_CONTRACT: (
            ("section-start", _exact_line("<!-- hongs-vault-routing-contract:start -->")),
            ("section-end", _exact_line("<!-- hongs-vault-routing-contract:end -->")),
            ("contract-version", _exact_line("- contract-version: 1")),
            (
                "explicit-triggers",
                _exact_line("- explicit-triggers: /query | Vault | 위키 | Obsidian"),
            ),
            (
                "group-realtime-vfx",
                _exact_line(
                    "- domain-group: Realtime VFX :: VFX | realtime FX | 리얼타임 FX | Unreal FX"
                ),
            ),
            (
                "group-unreal",
                _exact_line("- domain-group: Unreal :: Unreal | UE5 | Unreal Engine"),
            ),
            ("group-niagara", _exact_line("- domain-group: Niagara :: Niagara | 나이아가라")),
            (
                "group-houdini",
                _exact_line(
                    "- domain-group: Houdini pipeline :: Houdini | 후디니 | Houdini to Unreal"
                ),
            ),
            (
                "group-shader",
                _exact_line(
                    "- domain-group: Shader/rendering :: shader | 셰이더 | material | "
                    "머티리얼 | rendering | 렌더링"
                ),
            ),
            (
                "group-simulation",
                _exact_line(
                    "- domain-group: Simulation representation :: simulation representation | "
                    "시뮬레이션 표현"
                ),
            ),
            (
                "group-game-feel",
                _exact_line(
                    "- domain-group: Game feel :: game feel | 타격감 | hit stop | 히트스톱"
                ),
            ),
            (
                "group-knowledge-base",
                _exact_line(
                    "- domain-group: Knowledge-base operations :: RAG | 지식베이스 운영 | "
                    "에이전트 컨텍스트 | 멀티 에이전트 협업"
                ),
            ),
            (
                "group-subject-aliases",
                _exact_line(
                    "- domain-group: VFX subject aliases :: projectile | 투사체 | beam | 빔 | "
                    "explosion | 폭발"
                ),
            ),
            ("excluded-standalone", _exact_line("- excluded-standalone: FX | agent | pipeline")),
            (
                "file-op-verbs",
                _exact_line(
                    "- file-op-verbs: open | read | show | list | copy | move | rename | "
                    "delete | create | edit | save | hash | 열기 | 읽기 | 보여줘 | 목록 | "
                    "복사 | 이동 | 이름변경 | 삭제 | 생성 | 수정 | 저장 | 해시"
                ),
            ),
            ("audit-priority", _exact_line("- audit-priority: Knowledge-base operations")),
        ),
        PLUGIN_ROUTER: (
            ("supported-version", _exact_line("SUPPORTED_VERSION = 1")),
            ("nfkc-casefold", r'unicodedata\.normalize\("NFKC"'),
            ("whitespace-collapse", r'" "\.join\(normalized\.casefold\(\)\.split\(\)\)'),
            (
                "english-two-sided-boundary",
                r"left_ok = start == 0 or not _WORD\.match\(text\[start - 1\]\)",
            ),
            (
                "korean-open-right-boundary",
                r"right_ok = korean or end == len\(text\) or not _WORD\.match\(text\[end\]\)",
            ),
            ("intentional-prefix-cases", r"빔프로젝터[^.]{0,20}폭발물[^.]{0,20}match on purpose"),
        ),
    },
    "E053": {
        "baseline/hermes/SOUL.md": (
            ("heartbeat-skipped", r"VAULT_ROUTING_CHECKED decision=skipped"),
            ("heartbeat-entered", r"VAULT_ROUTING_CHECKED decision=entered"),
            ("heartbeat-unavailable", r"VAULT_ROUTING_CHECKED decision=unavailable"),
            ("absent-marker", r"An absent marker is `VAULT_ROUTER_UNAVAILABLE`"),
            ("no-inferred-skip", r"never infer a skip from absence"),
            (
                "telemetry-independent",
                r"Heartbeat validity is independent of telemetry",
            ),
            (
                "telemetry-cannot-suppress",
                r"never suppresses the marker and never holds the main task hostage",
            ),
            ("vault-evidence-fails-closed", r"stop work whose required evidence lives in the Vault"),
            ("vault-entry-variable", r"HONG_VAULT_ROOT/wiki/index\.md"),
            ("two-hop-ceiling", r"Never follow a hop-2 page onward"),
            ("no-raw", r"never read anything under `raw/`"),
            ("worker-context-cap", r"at most 4,000 characters of required Vault excerpts"),
            ("worker-no-default-access", r"Workers do not open the Vault by default"),
            ("model-unavailable", r"report `MODEL_CONTRACT_UNAVAILABLE`, stop"),
        ),
    },
    "E054": {
        "baseline/agents/claude/CLAUDE.md": (
            ("explicit-only", r"Read the Vault only when the user explicitly requests it"),
            ("no-self-initiated", r"never open it on your own initiative"),
            ("index-entry", r"Start a requested Vault read at `wiki/index\.md`"),
            ("no-raw-no-write", r"Never read `raw/`, and never write into the Vault"),
            (
                "no-routing-no-log",
                r"Do not run automatic domain routing, and never write the Hermes routing JSONL log",
            ),
            (
                "no-issuance",
                r"cannot issue, approve, or reapprove an `APPROVED_WORKER_TASK`",
            ),
            ("no-inferred-approval", r"infer user approval"),
            ("no-supervisor-authority", r"act with Hermes supervisor authority"),
        ),
        "baseline/agents/codex/AGENTS.md": (
            (
                "explicit-only",
                r"Open the Vault only when the user explicitly asks for it in the current request",
            ),
            ("index-entry", r"Start each permitted Vault read at `wiki/index\.md`"),
            ("no-raw-no-write", r"Do not read `raw/`, and do not write anything into the Vault"),
            (
                "no-routing-no-log",
                r"Never run automatic domain routing, and never write the Hermes routing JSONL log",
            ),
            (
                "no-issuance",
                r"cannot issue, approve, or reapprove an `APPROVED_WORKER_TASK`",
            ),
            ("no-inferred-approval", r"infer user approval"),
            ("no-supervisor-authority", r"act as the Hermes supervisor"),
        ),
    },
    "E055": {
        COST_COLLECTOR: (
            ("record-filename", _exact_line('RECORD_FILENAME = "supervisor-cost-monthly.jsonl"')),
            (
                "logs-directory",
                r'os\.path\.join\(os\.path\.abspath\(hermes_home\), "logs"\)',
            ),
            (
                "pricing-snapshot",
                _exact_line(
                    'PRICING_SNAPSHOT = "openai-gpt-5.6-standard-short-2026-08-14"'
                ),
            ),
            ("review-threshold", _exact_line('REVIEW_THRESHOLD_USD = Decimal("100")')),
            ("strictly-above-threshold", r"if premium > REVIEW_THRESHOLD_USD:"),
            ("explicit-collection", r"not a daemon, a cron job"),
            (
                "estimate-field",
                r'"hermes_api_equivalent_estimated_cost_usd": usd\(estimated\)',
            ),
            ("premium-field", r'"sol_vs_terra_virtual_premium_usd": usd\(premium\)'),
            (
                "actual-provider-billing-explicit",
                r'"actual_provider_billed_usd": options\.actual_provider_billed_usd',
            ),
            (
                "extra-usage-explicit",
                r'"actual_billed_extra_usage_usd": options\.actual_billed_extra_usage_usd',
            ),
            ("no-inferred-amounts", r"rather than being inferred"),
        ),
    },
    "E056": {
        DESIGN_AUTHORITY: (
            ("shared-key-heading", r"Exactly these three keys are shared by this phase:"),
            ("no-whole-file-copy", r"Whole-file `config\.yaml` copying is forbidden"),
            ("machine-local-rest", r"All other settings remain\s+machine-local"),
        ),
    },
    "E057": {
        "baseline/hermes/SOUL.md": (
            ("five-classes", r"exactly five material artifact classes"),
            (
                "class-list",
                r"specifications, implementation plans, `APPROVED_WORKER_TASK` contracts, "
                r"Goal Fidelity decisions, and integration or handoff artifacts",
            ),
            ("stamp-provider", _exact_line("provider=openai-codex")),
            ("stamp-model", _exact_line("model=gpt-5.6-sol")),
            ("stamp-reasoning", _exact_line("reasoning=high")),
            ("stamp-status", _exact_line("model-contract-status=conforming")),
            ("bootstrap-stamp", r"contract-status: bootstrap-pre-activation"),
            (
                "bootstrap-expiry",
                r"`bootstrap-pre-activation` stamp expires at Sol/high activation",
            ),
            ("bootstrap-revalidation", r"fresh Sol/high supervisor must revalidate"),
            ("no-configured-fallback", r"no configured fallback provider"),
            ("no-terra-auto-fallback", r"never auto-complete it with Terra"),
        ),
    },
}

#: E031 -- the plan adapter must not restate the writing-plans specification.
PLAN_ADAPTER_FORBIDDEN = (
    ("required-sections-list", r"(?i)^#+\s*required sections\s*$"),
    ("goal-fidelity-lock-template", r"(?i)^#+\s*goal fidelity lock\s*$"),
    ("plan-authority-claim", r"(?i)single authority for implementation plans"),
    ("worker-message-spec", r"(?i)^#+\s*worker messages? belong in the plan\s*$"),
)


# --------------------------------------------------------------------------
# E003 -- machine-local absolute paths
# --------------------------------------------------------------------------

MACHINE_LOCAL_PATTERNS = (
    ("windows-user-profile", re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\s`'\"<>|)\]]+")),
    ("windows-program-dir", re.compile(r"[A-Za-z]:[\\/]Program(?: |%20)?Files")),
    ("posix-home", re.compile(r"/(?:home|Users)/[A-Za-z0-9._-]+/")),
    ("windows-env-home", re.compile(r"%(?:LOCALAPPDATA|APPDATA|USERPROFILE|HOMEPATH|HOMEDRIVE)%")),
    ("powershell-env-home", re.compile(r"\$env:(?:LOCALAPPDATA|APPDATA|USERPROFILE)")),
)

#: Portable skill surface. Machine-local paths are rejected here. Runtime path
#: examples are permitted only in the installer/provenance documentation
#: (``docs/``, ``provenance/``, ``README.md``), which this rule does not scan.
PORTABLE_ROOTS = ("baseline/skills/", "baseline/hermes/", "baseline/agents/")


# --------------------------------------------------------------------------
# E020 -- forbidden active default review mandates
# --------------------------------------------------------------------------

MANDATE_TERMS = re.compile(
    r"\b(always|every|each|by default|defaults?|routinely|routine|must|mandatory|required)\b",
    re.IGNORECASE,
)

REVIEW_OBJECTS = re.compile(
    r"(two[- ]stage review|spec reviewer|quality reviewer|final reviewer"
    r"|independent reviewer|independent review|fresh reviewer|new reviewer"
    r"|reviewer agent|per[- ]task review|sol review|sol reviewer)",
    re.IGNORECASE,
)

NEGATION_TERMS = re.compile(
    r"(\bno\b|\bnot\b|\bnever\b|\bnone\b|\bwithout\b|\bunless\b|\bonly\b|\bexcept\b"
    r"|do not|don't|doesn't|\bremoved?\b|\bexception(al)?\b|\bavoid\b|\binstead\b"
    r"|\brather than\b|\breserved\b|\btrigger(ed|s)?\b|\bno longer\b|❌)",
    re.IGNORECASE,
)

#: A heading whose section is definitionally prohibitive. Statements inside it
#: describe what NOT to do, so they are not active mandates.
PROHIBITIVE_HEADING = re.compile(
    r"(?i)(red flag|never|mistake|pitfall|anti-pattern|antipattern|forbidden"
    r"|do not|don't|rationaliz|common failure|when not to use)"
)


def _split_statements(text):
    """Yield ``(line_number, statement)`` for mandate scanning."""
    for index, line in enumerate(text.split("\n"), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        for part in re.split(r"(?<=[.;:])\s+", stripped):
            part = part.strip()
            if part:
                yield index, part


def scan_review_mandates(text):
    """Return ``(line_number, matched_object)`` for active default review mandates."""
    findings = []
    heading_prohibitive = False
    line_number = 0
    for raw_line in text.split("\n"):
        line_number += 1
        stripped = raw_line.strip()
        if stripped.startswith("#"):
            heading_prohibitive = bool(PROHIBITIVE_HEADING.search(stripped))
            continue
        if heading_prohibitive or not stripped:
            continue
        for part in re.split(r"(?<=[.;:])\s+", stripped):
            part = part.strip()
            if not part:
                continue
            match = REVIEW_OBJECTS.search(part)
            if not match:
                continue
            if not MANDATE_TERMS.search(part):
                continue
            if NEGATION_TERMS.search(part):
                continue
            findings.append((line_number, match.group(1).lower()))
    return findings


# --------------------------------------------------------------------------
# Finding plumbing
# --------------------------------------------------------------------------

class Finding(object):
    __slots__ = ("rule", "path", "line", "detail")

    def __init__(self, rule, path, detail, line=None):
        self.rule = rule
        self.path = path
        self.detail = detail
        self.line = line

    def as_dict(self):
        return {
            "rule": self.rule,
            "rule_description": RULES.get(self.rule, ""),
            "path": self.path,
            "line": self.line,
            "detail": self.detail,
        }

    def render(self):
        location = self.path if self.line is None else "%s:%d" % (self.path, self.line)
        return "%s %s :: %s :: %s" % (self.rule, location, RULES.get(self.rule, ""), self.detail)

    def sort_key(self):
        return (self.rule, self.path, self.line or 0, self.detail)


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check_managed_file_set(root, findings):
    """E001 -- the managed file set is exactly the allowlist, no more, no less."""
    expected = set(baseline.managed_sources())
    for relative in sorted(expected):
        if not os.path.isfile(baseline.repo_path(root, relative)):
            findings.append(Finding("E001", relative, "missing managed file"))

    baseline_dir = os.path.join(root, "baseline")
    if not os.path.isdir(baseline_dir):
        findings.append(Finding("E001", "baseline", "missing baseline directory"))
        return
    for current, _dirs, files in os.walk(baseline_dir):
        for name in files:
            absolute = os.path.join(current, name)
            relative = os.path.relpath(absolute, root).replace(os.sep, "/")
            if relative not in expected:
                findings.append(Finding("E001", relative, "unlisted file under baseline/"))


def check_frontmatter(root, findings):
    """E002 -- every managed SKILL.md has a well-formed name/description block."""
    for skill in baseline.APPROVED_SKILLS:
        relative = baseline.skill_manifest_path(skill)
        absolute = baseline.repo_path(root, relative)
        if not os.path.isfile(absolute):
            continue  # already reported by E001
        lines = baseline.read_text(absolute).split("\n")
        if not lines or lines[0] != "---":
            findings.append(Finding("E002", relative, "missing opening --- delimiter", 1))
            continue
        try:
            closing = lines.index("---", 1)
        except ValueError:
            findings.append(Finding("E002", relative, "missing closing --- delimiter"))
            continue
        block = lines[1:closing]
        name_value = None
        description_value = None
        for entry in block:
            if entry.startswith("name:"):
                name_value = entry[len("name:"):].strip().strip("\"'")
            elif entry.startswith("description:"):
                description_value = entry[len("description:"):].strip().strip("\"'")
        expected_name = skill.split("/")[-1]
        if name_value is None:
            findings.append(Finding("E002", relative, "frontmatter has no name field"))
        elif name_value != expected_name:
            findings.append(
                Finding("E002", relative, "frontmatter name does not match directory name")
            )
        if not description_value:
            findings.append(
                Finding("E002", relative, "frontmatter has no non-empty description field")
            )


def check_machine_local_paths(root, findings):
    """E003 -- portable skill text carries no machine-local absolute path."""
    for relative in baseline.managed_sources():
        if not relative.startswith(PORTABLE_ROOTS):
            continue
        absolute = baseline.repo_path(root, relative)
        if not os.path.isfile(absolute):
            continue
        for number, line in enumerate(baseline.read_text(absolute).split("\n"), start=1):
            for label, pattern in MACHINE_LOCAL_PATTERNS:
                if pattern.search(line):
                    findings.append(
                        Finding("E003", relative, "machine-local path (%s)" % label, number)
                    )


def check_required_anchors(root, findings):
    """E010-E018, E040-E042 -- required policy rules are present."""
    for rule in sorted(REQUIRED_ANCHORS):
        for relative, anchors in sorted(REQUIRED_ANCHORS[rule].items()):
            absolute = baseline.repo_path(root, relative)
            if not os.path.isfile(absolute):
                findings.append(Finding(rule, relative, "file missing, rule unverifiable"))
                continue
            text = baseline.read_text(absolute)
            for anchor_id, pattern in anchors:
                if not re.search(pattern, text, re.MULTILINE):
                    findings.append(
                        Finding(rule, relative, "missing required anchor '%s'" % anchor_id)
                    )


def check_review_mandates(root, findings):
    """E020 -- no active default mandate for routine per-task review."""
    for relative in baseline.managed_sources():
        absolute = baseline.repo_path(root, relative)
        if not os.path.isfile(absolute):
            continue
        text = baseline.read_text(absolute)
        for number, matched in scan_review_mandates(text):
            findings.append(
                Finding(
                    "E020",
                    relative,
                    "active default review mandate referencing '%s'" % matched,
                    number,
                )
            )


def read_git_blob(git_root, revision, relative):
    """Return the text of ``<revision>:<relative>`` or raise ``RuntimeError``."""
    try:
        completed = subprocess.Popen(
            ["git", "-C", git_root, "show", "%s:%s" % (revision, relative)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = completed.communicate()
    except OSError as error:
        raise RuntimeError("git is not available: %s" % error)
    if completed.returncode != 0:
        raise RuntimeError(
            "git show %s:%s failed (exit %d): %s"
            % (revision, relative, completed.returncode, stderr.decode("utf-8", "replace").strip())
        )
    return stdout.decode("utf-8").replace("\r\n", "\n")


def check_graphify_blocks(root, git_root, findings):
    """E030 -- the imported graphify blocks survive byte-for-byte."""
    targets = (
        "baseline/agents/claude/CLAUDE.md",
        "baseline/agents/codex/AGENTS.md",
    )
    for relative in targets:
        try:
            original = read_git_blob(git_root, baseline.GRAPHIFY_BASE_REVISION, relative)
        except RuntimeError as error:
            findings.append(
                Finding("E030", relative, "cannot read original graphify block: %s" % error)
            )
            continue
        original = original.strip("\n")
        if not original:
            findings.append(Finding("E030", relative, "original graphify block is empty"))
            continue
        absolute = baseline.repo_path(root, relative)
        if not os.path.isfile(absolute):
            continue  # already reported by E001
        current = baseline.read_text(absolute)
        if original not in current:
            findings.append(
                Finding(
                    "E030",
                    relative,
                    "original graphify block from %s is not an exact substring"
                    % baseline.GRAPHIFY_BASE_REVISION,
                )
            )


def check_plan_adapter(root, findings):
    """E031 -- the plan skill routes and does not restate the plan specification."""
    relative = baseline.skill_manifest_path("software-development/plan")
    absolute = baseline.repo_path(root, relative)
    if not os.path.isfile(absolute):
        return
    text = baseline.read_text(absolute)
    for anchor_id, required in (
        ("adapter-declaration", r"It does not define planning standards of its own"),
        ("routes-to-brainstorming", r"go to `brainstorming` first"),
        ("no-execution", r"This skill executes nothing"),
    ):
        if not re.search(required, text, re.MULTILINE):
            findings.append(Finding("E031", relative, "missing required anchor '%s'" % anchor_id))
    for anchor_id, forbidden in PLAN_ADAPTER_FORBIDDEN:
        match = re.search(forbidden, text, re.MULTILINE)
        if match:
            line = text.count("\n", 0, match.start()) + 1
            findings.append(
                Finding("E031", relative, "duplicated plan authority '%s'" % anchor_id, line)
            )


# --------------------------------------------------------------------------
# E050 -- plugin manifest and hook registration
# --------------------------------------------------------------------------

#: The plugin manifest declares these keys, in this order, and nothing else.
#: A ``tools`` key, or any other addition, is a different plugin contract.
PLUGIN_MANIFEST_KEYS = ("name", "version", "kind", "description", "provides_hooks")
PLUGIN_MANIFEST_VALUES = (("name", "hongs-vault-router"), ("kind", "standalone"))
PLUGIN_HOOK = "pre_llm_call"

PLUGIN_INIT_REQUIRED = (
    ("bounded-hook-keywords", r"\*\*_unused"),
    ("delegates-to-router", r"route_turn\(user_message, session_id\)"),
)
PLUGIN_INIT_FORBIDDEN = (
    (
        "history-traversal",
        r"conversation_history\s*[\[.(]|\bfor\b[^\n]*\bin\b[^\n]*conversation_history",
    ),
)


def _parse_plugin_manifest(text):
    """Return ``(keys, values, hook_list, malformed_line)`` for the flat manifest."""
    keys = []
    values = {}
    hooks = []
    current = None
    for number, line in enumerate(text.split("\n"), start=1):
        if not line.strip():
            continue
        item = re.match(r"^\s+-\s*(\S.*?)\s*$", line)
        if item is not None:
            if current != "provides_hooks":
                return keys, values, hooks, number
            hooks.append(item.group(1))
            continue
        field = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$", line)
        if field is None:
            return keys, values, hooks, number
        current = field.group(1)
        keys.append(current)
        values[current] = field.group(2).strip("\"'")
    return keys, values, hooks, None


def check_plugin_contract(root, findings):
    """E050 -- exact plugin manifest and exactly one ``pre_llm_call`` registration."""
    manifest_path = baseline.repo_path(root, PLUGIN_MANIFEST)
    if not os.path.isfile(manifest_path):
        findings.append(Finding("E050", PLUGIN_MANIFEST, "file missing, rule unverifiable"))
    else:
        keys, values, hooks, malformed = _parse_plugin_manifest(
            baseline.read_text(manifest_path)
        )
        if malformed is not None:
            findings.append(
                Finding("E050", PLUGIN_MANIFEST, "violated anchor 'manifest-shape'", malformed)
            )
        if keys != list(PLUGIN_MANIFEST_KEYS):
            findings.append(
                Finding("E050", PLUGIN_MANIFEST, "violated anchor 'manifest-keys-exact'")
            )
        for key, expected in PLUGIN_MANIFEST_VALUES:
            if values.get(key) != expected:
                findings.append(
                    Finding("E050", PLUGIN_MANIFEST, "violated anchor 'manifest-%s'" % key)
                )
        if hooks != [PLUGIN_HOOK]:
            findings.append(
                Finding("E050", PLUGIN_MANIFEST, "violated anchor 'declares-one-pre-llm-call'")
            )

    init_path = baseline.repo_path(root, PLUGIN_INIT)
    if not os.path.isfile(init_path):
        findings.append(Finding("E050", PLUGIN_INIT, "file missing, rule unverifiable"))
        return
    text = baseline.read_text(init_path)
    if re.findall(r"register_hook\(\s*[\"']([a-z_]+)[\"']", text) != [PLUGIN_HOOK]:
        findings.append(
            Finding("E050", PLUGIN_INIT, "violated anchor 'registers-one-pre-llm-call'")
        )
    for anchor_id, pattern in PLUGIN_INIT_REQUIRED:
        if not re.search(pattern, text, re.MULTILINE):
            findings.append(
                Finding("E050", PLUGIN_INIT, "missing required anchor '%s'" % anchor_id)
            )
    for anchor_id, pattern in PLUGIN_INIT_FORBIDDEN:
        match = re.search(pattern, text, re.MULTILINE)
        if match:
            findings.append(
                Finding(
                    "E050",
                    PLUGIN_INIT,
                    "forbidden anchor '%s'" % anchor_id,
                    text.count("\n", 0, match.start()) + 1,
                )
            )


# --------------------------------------------------------------------------
# E051 -- fixed router paths and content-free telemetry
# --------------------------------------------------------------------------

#: The routing event carries exactly these keys. Anything else -- a question, a
#: prompt, a path, an index excerpt -- would put Vault or conversation content
#: into a log that outlives the turn.
ROUTING_EVENT_KEYS = ["ts", "session", "decision", "trigger", "matched", "qhash"]

ROUTER_REQUIRED = (
    ("runtime-directory", r'runtime_dir = home / "runtime" / "vault-router"'),
    ("lock-path", r'_routing_lock\(runtime_dir / "vault-routing\.lock"\)'),
    ("key-path", r'_load_or_create_key\(runtime_dir / "qhash\.key"\)'),
    ("log-path", r'log = home / "logs" / "vault-routing\.jsonl"'),
    ("rotate-limit", _exact_line("ROTATE_LIMIT_BYTES = 5 * 1024 * 1024")),
    ("rotations", _exact_line("ROTATIONS = 3")),
    ("key-bytes", _exact_line("KEY_BYTES = 32")),
    (
        "qhash-hmac",
        r'hmac\.new\(\s*key, normalized_question\.encode\("utf-8"\), hashlib\.sha256\s*\)',
    ),
    ("vault-root-variable", r'os\.environ\.get\("HONG_VAULT_ROOT"\)'),
    (
        "content-free-heartbeat",
        r'marker = "VAULT_ROUTING_CHECKED decision=%s trigger=%s"',
    ),
    ("telemetry-fails-open", r"def write_routing_event\("),
)

ROUTER_FORBIDDEN = (
    ("vault-root-fallback", r"os\.environ\.get\(\s*[\"']HONG_VAULT_ROOT[\"']\s*,"),
)


def _routing_event_keys(text):
    """Return the literal key names of the audit event, or ``None``."""
    start = text.find("event = {")
    if start == -1:
        return None
    opening = text.find("{", start)
    depth = 0
    for position in range(opening, len(text)):
        if text[position] == "{":
            depth += 1
        elif text[position] == "}":
            depth -= 1
            if depth == 0:
                return re.findall(r'"([a-z_]+)":', text[opening:position + 1])
    return None


def check_router_paths(root, findings):
    """E051 -- fixed runtime paths, no Vault-root fallback, no content in telemetry."""
    absolute = baseline.repo_path(root, PLUGIN_ROUTER)
    if not os.path.isfile(absolute):
        findings.append(Finding("E051", PLUGIN_ROUTER, "file missing, rule unverifiable"))
        return
    text = baseline.read_text(absolute)
    for anchor_id, pattern in ROUTER_REQUIRED:
        if not re.search(pattern, text, re.MULTILINE | re.DOTALL):
            findings.append(
                Finding("E051", PLUGIN_ROUTER, "missing required anchor '%s'" % anchor_id)
            )
    for anchor_id, pattern in ROUTER_FORBIDDEN:
        match = re.search(pattern, text, re.MULTILINE)
        if match:
            findings.append(
                Finding(
                    "E051",
                    PLUGIN_ROUTER,
                    "forbidden anchor '%s'" % anchor_id,
                    text.count("\n", 0, match.start()) + 1,
                )
            )
    if _routing_event_keys(text) != ROUTING_EVENT_KEYS:
        findings.append(
            Finding("E051", PLUGIN_ROUTER, "violated anchor 'routing-event-fields-exact'")
        )


# --------------------------------------------------------------------------
# E052 -- exact domain-group set
# --------------------------------------------------------------------------

DOMAIN_GROUP_COUNT = 9


def check_routing_contract_groups(root, findings):
    """E052 -- the contract declares exactly the approved domain groups."""
    absolute = baseline.repo_path(root, ROUTING_CONTRACT)
    if not os.path.isfile(absolute):
        return  # already reported by the anchor table
    declared = [
        line
        for line in baseline.read_text(absolute).split("\n")
        if line.startswith("- domain-group:")
    ]
    if len(declared) != DOMAIN_GROUP_COUNT:
        findings.append(
            Finding("E052", ROUTING_CONTRACT, "violated anchor 'domain-groups-exact'")
        )


# --------------------------------------------------------------------------
# E056 -- exactly three shared model keys
# --------------------------------------------------------------------------

SHARED_MODEL_KEY_LINES = (
    "model.default = gpt-5.6-sol",
    "model.provider = openai-codex",
    "agent.reasoning_effort = high",
)


def check_shared_model_keys(root, findings):
    """E056 -- the shared configuration is exactly three keys, copied one by one."""
    absolute = baseline.repo_path(root, DESIGN_AUTHORITY)
    if not os.path.isfile(absolute):
        return  # already reported by the anchor table
    text = baseline.read_text(absolute)
    block = re.search(
        r"Exactly these three keys are shared by this phase:\s*```text\n(.*?)```",
        text,
        re.DOTALL,
    )
    if block is None:
        findings.append(
            Finding("E056", DESIGN_AUTHORITY, "violated anchor 'shared-key-block'")
        )
        return
    declared = tuple(line.strip() for line in block.group(1).split("\n") if line.strip())
    if declared != SHARED_MODEL_KEY_LINES:
        findings.append(
            Finding("E056", DESIGN_AUTHORITY, "violated anchor 'shared-keys-exact'")
        )


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def validate(root, git_root):
    """Run every rule and return the sorted finding list."""
    findings = []
    check_managed_file_set(root, findings)
    check_frontmatter(root, findings)
    check_machine_local_paths(root, findings)
    check_required_anchors(root, findings)
    check_review_mandates(root, findings)
    check_graphify_blocks(root, git_root, findings)
    check_plan_adapter(root, findings)
    check_plugin_contract(root, findings)
    check_router_paths(root, findings)
    check_routing_contract_groups(root, findings)
    check_shared_model_keys(root, findings)
    findings.sort(key=lambda finding: finding.sort_key())
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate the harness baseline.")
    parser.add_argument("--root", required=True, help="repository root to validate")
    parser.add_argument(
        "--git-root",
        default=None,
        help="repository used to read the original graphify blocks (defaults to --root)",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON findings")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.stderr.write("validate-harness: --root is not a directory\n")
        return 2
    git_root = os.path.abspath(args.git_root) if args.git_root else root

    findings = validate(root, git_root)

    if args.json:
        payload = {
            "root": root,
            "failed": bool(findings),
            "findings": [finding.as_dict() for finding in findings],
        }
        sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    else:
        for finding in findings:
            sys.stdout.write(finding.render() + "\n")
        failed_rules = sorted({finding.rule for finding in findings})
        sys.stdout.write(
            "validate-harness: %d finding(s) across %d rule(s)%s\n"
            % (
                len(findings),
                len(failed_rules),
                (" [%s]" % ", ".join(failed_rules)) if failed_rules else "",
            )
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
