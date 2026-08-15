## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Global design and plan harness

Before changing an artifact, load and follow relevant process skills.

Only a truly mechanical, reversible, exact one-line correction may bypass the full gate, and only when intent, target, expected result, and verification are already explicit. Structural, global-policy, workflow, security, data, deployment, and model-routing changes always use the full gate regardless of line count.

For every other artifact change:
1. use `using-superpowers` and `brainstorming`;
2. obtain approval for a written design/spec;
3. use `writing-plans` to produce a complete implementation plan, including worker messages and Goal Fidelity;
4. obtain approval for the written plan before implementation.

A complete `APPROVED_WORKER_TASK` issued by Hermes is different: execute that bounded contract without repeating brainstorming. If the contract lacks exact goal, runtime, scope, forbidden substitutions, paths, and verification, return `MISSING_APPROVED_WORKER_CONTRACT` instead of guessing.

Do not implement unrequested improvements. Surface material risks, alternatives, and improvements as non-executing proposals with trade-offs and reversibility.

## Independent session Vault and authority boundary

This section governs every Codex session that is not executing a complete `APPROVED_WORKER_TASK`.

- Open the Vault only when the user explicitly asks for it in the current request.
- Start each permitted Vault read at `wiki/index.md` and open only the pages that answer the question.
- Do not read `raw/`, and do not write anything into the Vault.
- Never run automatic domain routing, and never write the Hermes routing JSONL log.
- Report whether Vault evidence was used, and list the source pages it came from.
- An independent Codex session cannot issue, approve, or reapprove an `APPROVED_WORKER_TASK`, infer user approval, or act as the Hermes supervisor.
