- **`state-graph.sh build --board N`** derives one typed nodes+edges JSON
  snapshot per repo from exactly four sources — the board (`fnd:status:*`
  state and `claimed_by` claim-stamp edges), native `sub_issue_of` /
  `blocked_by` edges, open PRs (`closes` edges parsed from a bare
  `Closes #N` body line), and linked git worktrees (#1917, epic #1910, ADR
  0033). Every source is typed `ok`/`absent`/`error`/`stale`, never
  collapsed into an untyped empty result; the snapshot is written and
  invalidated through `lib/cache.sh`'s namespaced store (`kind=state-graph`).
  `clean --board N` removes one repo's snapshot; `bench --scale N` times a
  synthetic N-scaled build. Two new settings, `STATE_GRAPH_MAX_AGE_S` and
  `STATE_GRAPH_QUERY_SLOW_MS`, govern read-time staleness and the future
  query-speed threshold.
