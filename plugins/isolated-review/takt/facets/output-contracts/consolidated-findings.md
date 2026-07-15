Respond with the consolidated review result as a single fenced YAML block in
exactly this shape. Preserve every grounded finding; keep false positives with a
`disagreement` reason rather than deleting them.

```yaml
status: pass | findings | inconclusive
summary: 1-2 sentence overview of the consolidated result
findings:
  - id: CR-001
    severity: critical | high | medium | low | info
    confidence: high | medium | low
    category: correctness | regression | tests | security | overall | <optional-perspective-id>
    location: path/to/file:line
    summary: Short statement of the problem
    evidence: Concrete grounding in the code / diff
    impact: Expected impact if unaddressed
    recommendation: Fix direction (not a mandate)
    source_reviewers: [correctness]           # every perspective that raised it
    disagreement: null                         # or: conflict / minority opinion / false-positive reason
```

Rules:
- Order findings by descending severity; IDs follow that order (CR-001 first).
- `source_reviewers` must list every perspective that raised the finding.
- When `status: pass`, `findings` is an empty list.
- Do not add findings that no reviewer raised. Do not invent evidence or locations.
