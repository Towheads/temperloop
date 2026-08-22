- **`workflow-reviewer-coverage.sh` now reports execution coverage for every
  routed reviewer, not only `workflow-reviewer`** (temperloop#1446). The gap in the
  mandatory pre-push review gate (`claude/commands/build.md` §3e) — temperloop#1387
  (routed reviews never ran) and temperloop#1430 (the gate moved into the
  driver) — stayed invisible for roughly a month because nothing measured
  whether reviews executed; temperloop#1450 (coverage measures execution, not
  prose) fixed that for one reviewer over one path class (command-doc PRs) — every other routed reviewer (`shell-reviewer`,
  `docs-reviewer`, `python-reviewer`, `typescript-reviewer`, …) still had no
  execution signal at all. For every merged PR in the window, the rollup now
  derives the reviewer SET `reviewer-routing.tsv`'s extension/path-glob axis
  routes for that PR's changed files (plus the in-prose
  `claude/commands/*.md -> workflow-reviewer` override), and checks each
  routed reviewer for the same machine-emitted evidence temperloop#1450 introduced —
  including its same-line skip-clause termination, generalized to every
  reviewer rather than only `workflow-reviewer`. `--json` gains a purely
  additive `by_reviewer` array, one row per reviewer in the tsv+override
  roster: a reviewer with zero routed PRs this window reports `routed:false`
  (nothing to review) and a reviewer that WAS routed but never documented as
  having run reports `routed:true, coverage_pct:0` — the two states are
  always distinguishable, and no routed reviewer is ever silently omitted
  from the table. Stays a reporting rollup, never a `checks` gate.
- A reviewer name from `reviewer-routing.tsv` is now escaped before it is used as a regex, and the coverage query's fail-open can no longer be silent. A name carrying a metacharacter made `jq`'s `test` throw, and the blanket `2>/dev/null || echo ''` rendered that throw as the all-zeros fallback — every count `0`, an empty `by_reviewer`, exit `0`: a false all-clear indistinguishable from a genuinely quiet window, on the one tool whose job is making an invisible gap visible. Because the pre-existing temperloop#1450 workflow-reviewer metric shares that single `jq` invocation, one bad routing row could take it down too. The fallback remains, but now prints what `jq` said and states that its figures measure nothing. Separately, an absent or unreadable routing table now warns that the per-reviewer roster is degraded and that other reviewers are **omitted, not measured as zero**. (temperloop#1446)
