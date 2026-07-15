```markdown
# Performance Review

## Result: APPROVE / REJECT

## Summary
{Summarize the performance impact in 1-2 sentences}

## Observed Findings
| # | family_tag | Severity | Location | Issue | Expected impact (scale/frequency) | Fix Suggestion |
|---|------------|----------|----------|-------|-----------------------------------|----------------|
| 1 | perf | High / Medium / Low | `src/file.ts:42` | {Issue, e.g. N+1 query} | {At what input size / call rate} | {Fix direction} |

## Verification Evidence
- Hot paths / call frequency traced: {What was checked}
- Build: {Result, or state unverified}
- Tests / benchmarks: {Result, or state unverified}

## Rejection Gate
- REJECT only when at least one change introduces a real performance regression or clear inefficiency
```

**Cognitive load reduction rules:**
- APPROVE: Summary only (5 lines or fewer)
- REJECT: Include only relevant finding rows (30 lines or fewer)
