- **`/build` §3e's per-item review tally now names every routed-but-unrun
  reviewer** (#1984). `park()`'s `review` record gains a `routed_not_run` field
  alongside `ran`/`skipped`/`mandatory_ok`, and `/build`'s Step 6 summary
  renders it. `mandatory_ok` covers only the `claude/commands/*.md` →
  `workflow-reviewer` rule (foundation#1007 — the workflow-reviewer mandatory rule), so an extension-axis reviewer
  routed by `reviewer-routing.tsv` — `shell-reviewer` for a `.sh` diff, say —
  could resolve, be skipped, and still leave the tally reading fully clean.
  `routed_not_run` is non-empty exactly when `skipped` is. It is a visibility
  field, not a second gate: a per-language reviewer is routinely inactive in a
  consuming checkout by design (ADR 0007), so blocking on one would go red in
  the ordinary case. Rationale and the rejected alternatives are in
  [ADR 0037](docs/adr/0037-routed-but-unrun-reviewers-are-visible-not-blocking.md).
