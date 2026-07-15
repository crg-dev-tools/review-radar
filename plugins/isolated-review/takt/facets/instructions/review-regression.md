Focus on reviewing **regressions in existing behavior**.

Procedure:
1. Read the review-target report (diff, purpose, changed files) and the existing code around each change.
2. For every shared helper, normalizer, builder, adapter, resolver, type, schema, validator, config key, or output contract the diff touches, enumerate the existing consumers and verify each one still gets the same contract.
3. For changed signatures/defaults/behavior, check backward compatibility for callers that are NOT part of the diff.
4. Trace the real entry point of each affected existing feature through validation and resolution, not only the standalone changed function.
5. For diffs with side effects or state changes, compare entry, normal completion, early exit, exception, and cleanup paths against the prior behavior.
6. Check that persisted data, serialized formats, and cross-version compatibility are preserved.
7. Report only regressions that the current diff could cause to previously-working behavior. Include location, the existing feature impacted, and fix direction.
8. Do not report new-feature-only bugs, preference-only changes, or unrelated pre-existing issues.
