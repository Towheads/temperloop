- **`archive-plan.sh` no longer reports success for a plan snapshot that never
  landed, and a later run no longer destroys one that is still pending**
  (temperloop#1523). The step printed one `plan-archive-pr-queued: <pr>` line
  that read as success while the snapshot sat only on `chore/plan-archive` —
  and because the shared protected-main kernel force-rebuilt that branch off
  `origin/main` every run, a prior run's snapshot whose PR had not merged was
  overwritten and gone (observed: the 2026-08-10 snapshot, PR #1395 open four
  days, discarded by the next run). Two changes. **Never-destroy:**
  `land-on-protected-main.sh` now bases the archive worktree on
  `origin/<branch>` whenever that branch carries commits `origin/main` does
  not, so an un-merged payload is carried forward and extended, and rebuilds
  off the default branch only when nothing unlanded sits on it.
  **Verdict-matches-payload:** the status vocabulary splits into
  `plan-archived:` (LANDED, the only success), `plan-archive-pending: <pr>`
  (on the PR, auto-merge armed, not on `main`), `plan-archive-failed: <why>`
  (nothing landed and nothing will), and `plan-archive-skipped:` (not
  attempted). The `gh pr merge --auto` result is no longer discarded with
  `|| true` — a PR whose auto-merge could not be armed reports failed instead
  of queued (an already-queued PR still counts as armed) — an empty staged
  diff is now read as "already present" only when the payload is genuinely
  tracked, so a snapshot the index refused (an ignored path) reports failed
  instead of `already current`, and the copy itself is checked and verified
  against the source rather than aborting the script mid-run.
