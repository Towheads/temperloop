- **`state-graph.sh soak` now compares PER CLASS instead of one flat set
  diff** (#1978). The soak is the one independent cross-check over the
  derived state graph (ADR 0033,
  `docs/adr/0033-derived-state-graph-composes-one-way-with-one-independent-cross-check.md`,
  which defines the query classes named below): it diffs the graph's own
  queries against `reconcile.sh --status`, a separately-derived view of the
  same board. Previously it compared the two as one flat set of issue
  numbers, so a hit that each side classified differently read as a
  disagreement even when both were right. Now each class is compared against
  its own counterpart — `status-drift` (issues whose board status label and
  claim state disagree) against reconcile.sh's status-label classes, and
  `stale-claims` (claims stamped to a session that is no longer live)
  against its claim-liveness classes. `unlinked-prs` / `orphan-worktrees`,
  which reconcile.sh never reports on, read the literal string
  `"not-covered"` rather than a false empty-set agreement.
- The appended soak record is now `{day, type:"run", schema:2,
  classes:{...}}`. A pre-existing flat-schema record (no `type` field) is
  excluded from `soak --count`'s day tally rather than misread as a
  per-class one. Practically: every day whose only record predates this
  rewrite drops out of `--count`, so the fourteen-day independence check
  restarts from zero and needs fourteen new `schema:2` days before it is
  trustworthy again — an expected reset, not a regression.
- The state-graph board source also now reads closed issues that still carry
  an `fnd:status:*` label (Done on the issues-only backend means closed with
  *no* status label) as their own residue nodes, so `status-drift` can flag
  that residue directly. This is scoped entirely to state-graph's own board
  source; `board.sh`'s `--state open` active-set convention is unchanged.
