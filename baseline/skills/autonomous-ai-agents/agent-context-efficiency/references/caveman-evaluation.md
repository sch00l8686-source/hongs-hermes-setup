# Caveman-Style Compression Evaluation Reference

## What was verified

### Current local Hermes baseline

`hermes prompt-size --json` on the default CLI profile measured:

| Component | Bytes |
|---|---:|
| System prompt | 26,824 |
| Skills index | 9,542 |
| Tool schemas (28 tools) | 55,351 |
| User profile | 1,694 |
| Memory | 398 |

Interpretation: fixed tool schemas and the skills index are material fresh-session costs. Reducing reply prose alone cannot remove them.

### Caveman output skill

Repository: <https://github.com/JuliusBrussee/caveman>

- Its `skills/caveman/SKILL.md` is an output-style instruction with `lite`, `full`, and `ultra` modes.
- It keeps code, commands, technical terms, and exact error strings unchanged; it suppresses filler and tool-call narration.
- The repository's own `docs/HONEST-NUMBERS.md` states that the skill does **not** compress input context, files, tool outputs, or reasoning, and estimates its own fixed context cost at roughly 1–1.5K tokens per turn.
- Therefore do not use its advertised output reduction as a whole-session cost forecast. Compare provider usage on paired real tasks.

### Caveman v2 proxy/engine

- v2 adds a local compression proxy for tool results and other inputs.
- `docs/WRAP-BENCHMARK.md` reports 33.2% fewer provider-reported input tokens in a pinned 18-pair Claude Code benchmark over six deterministic large-output fixtures. It explicitly excludes a universal-workload claim; one HTML case regressed.
- `LICENSING.md` places the skill under MIT, while engine/proxy/MCP/shrink code is BSL-1.1. Internal local/self-hosted use is described as permitted; third-party hosted/managed/embedded use is a commercial boundary.
- A proxy changes provider routing and context fidelity. Treat it as a separate approved integration, not as a harmless style skill.

### Hermes installer claim and compatibility boundary

- Caveman's `INSTALL.md` lists `npx -y github:JuliusBrussee/caveman -- --only hermes`.
- Its current `bin/install.js` copies several skills (`caveman`, commit/review/help/stats/compress, and cavecrew) into `$HERMES_HOME/skills/productivity/` from a local clone.
- The current generated Hermes pack contains always-applied implementation workflow instructions as well as compression-related behavior. It overlaps with an existing supervised workflow stack; do not bulk-install it without a conflict review.

## Safer pilot: adaptive concise output

Use a concise professional mode, not Caveman's global fragments/no-hedging policy.

### Preserve

- User language and Korean grammar
- Exact commands, paths, code, values, units, and errors
- Security warnings and explicit confirmation language
- Ordered operational instructions
- Evidence/citations and material trade-offs
- Detailed explanations explicitly requested by the user

### Remove

- Greeting and self-narration
- Tool-call progress narration unless required for a safety boundary
- Repeated context the user already knows
- Decorative formatting and long non-decisive logs

### Paired pilot matrix

Run with the same model and toolsets where possible.

| Case | Baseline | Pilot evaluation |
|---|---|---|
| Short factual/technical question | normal response | readability and output length |
| Investigation/debugging report | normal response | evidence and causal clarity |
| Decision with alternatives | normal response | trade-off completeness and actionability |
| Large tool-output task | normal response | input/cache/output usage, recovery/fidelity |

Collect provider-reported input, cache, output, total cost if available, latency, quality defects, and user preference. Disable the pilot if it harms clarity or if the fixed rule overhead exceeds savings.

## Sources

- <https://github.com/JuliusBrussee/caveman/blob/main/skills/caveman/SKILL.md>
- <https://github.com/JuliusBrussee/caveman/blob/main/docs/HONEST-NUMBERS.md>
- <https://github.com/JuliusBrussee/caveman/blob/main/docs/WRAP-BENCHMARK.md>
- <https://github.com/JuliusBrussee/caveman/blob/main/LICENSING.md>
- <https://github.com/JuliusBrussee/caveman/blob/main/INSTALL.md>
- <https://github.com/kuba-guzik/caveman-micro>
