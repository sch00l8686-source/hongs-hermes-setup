# Bounded worker evidence

Use this as a compact checklist when an external implementation or review worker risks blocking user-visible delivery:

1. Define a task-specific deadline, expected artifact, and verification command before launch.
2. Inspect worktree state and artifacts at the deadline; a running wrapper or partial stream is not completion.
3. Treat only an explicit final artifact plus direct root diff/gate inspection as a completed task or review.
4. If no final artifact exists, stop that worker, record its result as incomplete evidence, and reissue the plan's bounded correction message to a fresh worker under the same verification gates. Hermes takes over an assigned product-source edit only when the plan has no worker route left.
5. Convert concrete findings — from a gate, a direct inspection, or an exceptional review — into focused regression tests before resuming broad gates.

This reference intentionally excludes provider/cache/setup failures; those are environment state, not a reusable refusal rule.
