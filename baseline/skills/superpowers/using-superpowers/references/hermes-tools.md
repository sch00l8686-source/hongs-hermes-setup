# Hermes Agent Tool Mapping

Skills speak in actions ("dispatch a subagent", "create a todo", "read a file"). On Hermes Agent these resolve to the tools below.

## Tools

| Action skills request | Hermes tool |
|---|---|
| Read a file | `read_file` |
| Create a new file | `write_file` |
| Edit a file (targeted patch) | `patch` |
| Run a shell command | `terminal` |
| Search file contents | `search_files` |
| Find files by name | `terminal` with `find` |
| Fetch a URL / read a webpage | `web_extract(urls=[...])` |
| Search the web | `web_search(query=...)` |
| Dispatch a subagent | `delegate_task(goal=..., context=..., toolsets=[...], role="leaf")` |
| Task tracking | `todo` tool |
| Invoke a skill | `skill_view("skill-name")` |

## Instructions file

When a skill mentions "your instructions file," on Hermes Agent this is **`AGENTS.md`** in the project directory, or **`SOUL.md`** globally at `~/.hermes/SOUL.md`.

## Invoking a skill

Hermes Agent has a `skills` toolset with `skill_view` and `skills_list` tools.
To invoke a superpowers skill, use:

```
skill_view("brainstorming")
skill_view("test-driven-development")
```

If `skill_view` cannot find a superpowers skill (it may not appear in the catalog
until the plugin fully registers it), fall back to listing the catalog and then
reading the SKILL.md directly from the installed skills root:

```
skills_list()
read_file(path="<hermes-skills-root>/superpowers/<skill-name>/SKILL.md")
```

`<hermes-skills-root>` is whatever directory the running Hermes installation loads
skills from on this machine. Resolve it from the environment or from
`skills_list()` output — do not hardcode an absolute path, and do not assume any
particular user home or drive layout.

This fallback is the same mechanism used by other harnesses without native skill loading.

## Subagent dispatch

Use `delegate_task` to spawn isolated subagents for parallel or sequential workstreams:

```
delegate_task(goal="...", context="...", toolsets=[...], role="leaf")
```

If `delegate_task` is unavailable, do the work inline rather than inventing tool calls.

## Task tracking

Use the `todo` tool for task tracking within a session. For multi-agent task boards, use `hermes kanban` CLI if available. Treat older `TodoWrite` references as the task-tracking action.

---

## Hong policy extension

On Hermes Agent, Hermes is the supervisor. It owns the current user goal, the
spec, the implementation plan, worker decomposition, worker messages, changed-path
and Goal Fidelity checks, actual command and test execution, integration, and the
completion evidence.

- Hermes does not directly edit the product source and test files a plan assigns
  to an implementation worker. It re-dispatches a bounded correction message
  instead.
- Implementation workers are dispatched with a complete `APPROVED_WORKER_TASK`
  contract, so they execute the bounded task without re-running brainstorming.
- Worker self-reports are not completion evidence. Hermes verifies with the actual
  diff, the runtime caller, and freshly run checks.
- Independent reviewer subagents are not the default. Use one only where the
  approved plan predefines a bounded high-risk boundary, where worker evidence
  conflicts, where direct verification cannot establish a required clause, or
  where the user explicitly asks.
