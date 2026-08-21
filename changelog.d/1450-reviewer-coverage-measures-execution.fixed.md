- **`workflow-reviewer-coverage.sh` now measures whether the reviewer RAN, not
  whether the PR body happens to contain the word `MAJOR`** (temperloop#1450).
  The rollup classified a merged command-doc PR as covered when its body matched
  `workflow-reviewer|BLOCKING|MAJOR`, which measured prose and was wrong in both
  directions: any changelog line, risk note or quoted finding scored as a
  documented pass, and — worst of all — the legible `skipped — workflow-reviewer
  …` degradation notice, which says in so many words that the reviewer did NOT
  run, contains the string `workflow-reviewer` and so scored as *covered*. Before
  temperloop#1430 that skip was structurally guaranteed on every Workflow-path
  command-doc PR (temperloop#1429), so the metric read highest exactly when the
  gate was most broken. It is now keyed on the two structured shapes
  `claude/workflows/build-level.mjs` §3e EMITS into the PR body via the verdict
  summary: the line-anchored tally `§3e review — ran: <reviewer>[, …]`, and the
  spliced `## Review notes` / `### <reviewer>` findings blocks. A prose heading
  such as `## The §3e review caught a destructive default` no longer matches —
  the tally must be at line start and carry the literal `ran:` list.
  Measured against `Towheads/temperloop` over the same 28-day window, the
  reported figure moves from `{command_doc_prs:51, with_workflow_reviewer:18,
  coverage_pct:35}` to `{command_doc_prs:51, with_workflow_reviewer:7,
  coverage_pct:13}` — 11 of the 18 were prose, two of them the skip notice.
  `--json` gains three purely additive fields that make the residue legible
  rather than silently folded into the numerator: `any_reviewer_ran` (a §3e
  record naming any reviewer), `skip_notice_only` (the gate degraded legibly —
  never counted as covered), and `no_review_record` (the build path emitted
  nothing at all); the three partition the denominator. The window fetch also
  collapses from an N+1 fan-out of `gh pr view` calls into a single
  `gh pr list --json number,body,files`, falling back to the old two-call path
  on a `gh` too old to accept `files` there — 112s to 13s against that same
  window, and ~200 fewer calls against the shared GraphQL budget.
