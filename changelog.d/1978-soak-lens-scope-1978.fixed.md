- **`state-graph.sh soak` now compares PER CLASS instead of one flat set
  diff** (#1978). `status-drift` is checked against reconcile.sh's own
  status-label classes, `stale-claims` against its claim-liveness classes,
  and `unlinked-prs`/`orphan-worktrees` (which reconcile.sh never reports on)
  read the literal string `"not-covered"` rather than a false empty-set
  agreement. The appended soak record is now `{day, type:"run", schema:2,
  classes:{...}}` — a pre-existing flat-schema run record (no `type` field)
  is excluded from `soak --count`'s day tally rather than misread as a
  per-class one. The state-graph board source also now reads closed issues
  that still carry an `fnd:status:*` label (Done on the issues-only backend
  is "closed + no status label") as their own residue nodes, so
  `status-drift` can flag that residue directly — scoped entirely to
  state-graph's own board source, `board.sh`'s `--state open` active-set
  convention is unchanged.
