```markdown
# Concurrency Review

## Result: APPROVE / REJECT

## Summary
{Summarize the concurrency risk in 1-2 sentences}

## Observed Findings
| # | family_tag | Severity | Type | Location | Issue | Fix Suggestion |
|---|------------|----------|------|----------|-------|----------------|
| 1 | race-condition | High / Medium / Low | race / deadlock / double-exec / leak | `src/file.ts:42` | {Issue} | {Fix direction} |

## Verification Evidence
- Shared state / async paths traced: {What was checked}
- Build: {Result, or state unverified}
- Tests: {Result, or state unverified}

## Rejection Gate
- REJECT only when at least one concurrency defect is observed
```

**Cognitive load reduction rules:**
- APPROVE: Summary only (5 lines or fewer)
- REJECT: Include only relevant finding rows (30 lines or fewer)
