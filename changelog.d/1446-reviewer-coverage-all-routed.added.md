- **`workflow-reviewer-coverage.sh` now reports execution coverage for every
  routed reviewer, not only `workflow-reviewer`** (temperloop#1446). The §3e
  gap (#1387/#1430) stayed invisible for ~a month because nothing measured
  whether reviews executed; #1450 fixed that for one reviewer over one path
  class (command-doc PRs) — every other routed reviewer (`shell-reviewer`,
  `docs-reviewer`, `python-reviewer`, `typescript-reviewer`, …) still had no
  execution signal at all. For every merged PR in the window, the rollup now
  derives the reviewer SET `reviewer-routing.tsv`'s extension/path-glob axis
  routes for that PR's changed files (plus the in-prose
  `claude/commands/*.md -> workflow-reviewer` override), and checks each
  routed reviewer for the same machine-emitted evidence #1450 introduced —
  including its same-line skip-clause termination, generalized to every
  reviewer rather than only `workflow-reviewer`. `--json` gains a purely
  additive `by_reviewer` array, one row per reviewer in the tsv+override
  roster: a reviewer with zero routed PRs this window reports `routed:false`
  (nothing to review) and a reviewer that WAS routed but never documented as
  having run reports `routed:true, coverage_pct:0` — the two states are
  always distinguishable, and no routed reviewer is ever silently omitted
  from the table. Stays a reporting rollup, never a `checks` gate.
