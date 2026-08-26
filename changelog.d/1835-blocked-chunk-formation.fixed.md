- **`/sweep` now honors native `blocked_by` for every pool item** (#1835).
  Step 1's fix pool previously ignored native GitHub issue `blocked_by`
  dependencies entirely — `/next`'s actionable-set build already dropped a
  Ready singleton with an open `blocked_by` edge, but `sweep` would claim
  and drive it anyway, risking a worker building against a base that
  assumed an unmerged blocker's fix. The pool build now calls
  `board_blocked_by_open` for every pooled item (member or singleton,
  forward-provisioned for epic-as-metadata's future Operational-epic
  admission) and defers any item with an open blocker — never co-chunked
  with, or driven ahead of, that blocker, and re-checked at every chunk
  boundary so a blocker that lands mid-run un-defers its dependents within
  the same sweep. The un-defer predicate is explicit and mechanized
  (`workflows/scripts/build/sweep-blocked-undefer.sh`): a blocker releases
  its dependents iff its issue is closed **and** its landing commit —
  resolved via the blocker's linked merged PR — is an ancestor of
  `origin/<default>` (`worktree.sh deps-merged`); a blocker closed with no
  linked merged PR releases its dependents (the ambiguity case), while a
  blocker whose own sweep disposition is `parked` never does. A new
  pool-level cycle walk (`workflows/scripts/build/sweep-pool-cycle-detect.sh`)
  catches a `blocked_by` cycle among pool members, which would otherwise
  defer every member forever with nothing ever explaining why, and the
  Step-4 report gains a blocked-frontier section (blocked item → open
  blockers, cycles called out separately, multi-run stalls noted via a
  durable comment trail on the issue).
