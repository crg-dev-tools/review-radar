```markdown
# Regression Review

## Result: APPROVE / REJECT

## Summary
{Summarize the regression risk in 1-2 sentences}

## Observed Findings
| # | family_tag | Severity | Location | Existing behavior at risk | Impact | Fix Suggestion |
|---|------------|----------|----------|---------------------------|--------|----------------|
| 1 | regression | High / Medium / Low | `src/file.ts:42` | {What used to work} | {How it breaks} | {Fix direction} |

## Verification Evidence
- Affected consumers traced: {What existing call sites were checked}
- Build: {Result, or state unverified}
- Tests: {Result, or state unverified}

## Rejection Gate
- REJECT only when at least one change breaks previously-working behavior
```

**Cognitive load reduction rules:**
- APPROVE: Summary only (5 lines or fewer)
- REJECT: Include only relevant finding rows (30 lines or fewer)
