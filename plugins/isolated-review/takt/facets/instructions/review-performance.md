Focus on reviewing **performance and resource efficiency**.

Procedure:
1. Read the review-target report and identify diffs on hot paths, loops, queries, network/IO calls, and data-structure choices.
2. Look for N+1 queries, repeated identical IO/API calls, and work repeated inside loops that could be hoisted.
3. Look for unnecessary O(n^2)+ algorithms, full scans where an index/map applies, and redundant serialization/copies.
4. Check for unbounded growth: memory retained, caches without eviction, accumulating collections, missing pagination/limits.
5. Check that added blocking work does not sit on a latency-sensitive or high-frequency path.
6. Ground each finding in the diff and the realistic input size or call frequency; avoid micro-optimizations with no measurable impact.
7. Report only performance regressions or clear inefficiencies introduced by the current diff, with location, expected impact, and fix direction.
8. Do not report preference-only changes or unrelated pre-existing issues. Approve when the change has no performance concern.
