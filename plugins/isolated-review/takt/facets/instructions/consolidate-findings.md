Consolidate the independent perspective reviews into a single finding list.

You are the only step that reads all reviewer reports. Each reviewer ran in its
own isolated session and did not see the others.

Procedure:
1. Read every review report in the Report Directory: `review-target.md` (the
   neutral target) and each `*-review.md` (correctness, regression, tests,
   security, overall, and any optional perspectives present). Read only files in
   the Report Directory.
2. Extract every observed finding from each report, keeping its source perspective,
   location, evidence, severity, and fix suggestion.
3. Deduplicate: merge findings that describe the same issue at the same location.
   Record every source reviewer in `source_reviewers`. Do NOT merge findings that
   differ in location or in the underlying issue.
4. Verify grounding: each kept finding must cite a concrete `location` and
   `evidence`. If evidence is weak, lower `confidence`; do not drop it silently.
5. Normalize `severity` onto one scale: critical / high / medium / low / info.
6. Surface conflicts: when reviewers disagree or a point is a minority opinion,
   record it in `disagreement` rather than silently choosing a side.
7. Assign a stable `id` to each finding: `CR-001`, `CR-002`, ... in descending
   severity order.
8. Do not add findings no reviewer raised. If you judge a reported finding a false
   positive, KEEP it with its original source and set `disagreement` to your reason
   (never delete a grounded finding silently).
9. Set `status`: `findings` if any finding remains, `pass` if none, `inconclusive`
   if the target could not be established.

Organize only. Do not overrule reviewers on the merits or invent evidence.
