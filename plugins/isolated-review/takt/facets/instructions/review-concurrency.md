Focus on reviewing **concurrency and race conditions**.

Procedure:
1. Read the review-target report and identify diffs that touch async flows, shared mutable state, caches, locks, queues, timers, or external calls.
2. Look for race conditions on shared state (read-modify-write without atomicity or synchronization).
3. Look for deadlocks, lock-ordering issues, and lock scope that is too wide or too narrow.
4. Check retry/timeout paths for double execution and non-idempotent side effects.
5. Check that resources (connections, file handles, locks) are released on every path including exceptions.
6. Check ordering assumptions between concurrent tasks, and check-then-act gaps (TOCTOU).
7. Trace the affected call sites, not only the changed function in isolation.
8. Report only concurrency issues introduced or exposed by the current diff, with location, impact, and fix direction.
9. Do not report preference-only changes or unrelated pre-existing issues. Approve when the change has no concurrency risk.
