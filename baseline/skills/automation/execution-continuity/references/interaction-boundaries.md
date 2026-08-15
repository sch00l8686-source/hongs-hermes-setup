# Routine Execution Versus Explicit Gate

| Situation | Handling |
|---|---|
| Approved scoped edit, parser check, focused test, disposable verification | Execute internally; do not pause or show a run-style prompt. |
| New test failure inside approved scope | Diagnose from fresh evidence, make a minimal repair, and rerun the affected check. |
| Full suite after focused checks | Execute internally; report only final exit status and material skips. |
| Credential, auth, API-key, OAuth, or `.env` access/mutation | Stop and obtain explicit direction. |
| Actual config/provider/channel/gateway mutation | Stop and obtain explicit direction. |
| First live-home apply, external send, publication, force-push, history rewrite | Stop and obtain explicit direction with rollback facts. |
| Test harness blocked by a platform approval mechanism | Do not make the user repeatedly approve identical routine steps. Use internal approved execution where available; otherwise report the platform blocker once. |
| Weak, missing, or conflicting evidence inside approved scope | Run the plan-compatible measurement that would settle it, then decide. Escalate only if a user-owned decision survives the measurement. |
| Worker output that violates the allowlist, runtime, or behavior delta | Reject as plan noncompliance and reissue the plan's correction message. Do not offer the unauthorized alternative to the user. |

## User-facing reporting

Avoid progress narration such as “I will run this next” or requests to click a Run control. Deliver one concise result after the bounded run, unless a genuine gate or blocker changes the decision.
