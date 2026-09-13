- **`state-graph.sh soak --board N` — the fourteen-day cross-check made
  mechanical** (epic #1910, ADR 0033): runs a fresh `build`, reads `query
  status-drift` off that same snapshot, separately runs `reconcile.sh
  --status` through a new overridable `_sg_reconcile` seam, reduces each
  side to a comparable sorted set of flagged issue numbers, and appends one
  `{day, drift_query_set, reconcile_set, diff}` record to a soak log kept
  through `lib/cache.sh`'s own path accessors (kind=`state-graph-soak`).
  Either set — and `diff` — reads the literal string `"unknown"`, never a
  false empty agreement, when its own side is degraded (a board-source
  error, or a failing `reconcile.sh` invocation). `soak --count --board N`
  prints the number of distinct days recorded; `soak --audit --board N
  --items <file>` logs a hand-audited item set against today for a human to
  compare against the mechanical diff. `bench --scale N` now also times
  each of the five named queries against its synthetic snapshot and appends
  one `{day, type:"bench", scale, query_ms, slow_queries}` record to the
  same log, naming the queries whose elapsed time exceeds
  `STATE_GRAPH_QUERY_SLOW_MS` at that scale.
