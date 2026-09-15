- **`workflows/scripts/build/state-graph.sh soak` can now report how long its
  soak clock has been stopped** (#2016). `soak --status --board <N>` prints one
  JSON line carrying three figures — the days recorded so far, the days
  required (`STATE_GRAPH_SOAK_DAYS`), and how many days have passed since the
  most recent record — plus a `state` of `never-recorded`, `stale`, `current`
  or `unreadable`. A soak nothing has ever run and a soak that ran and then
  stopped six days ago now read differently; `soak --count` printed `0` for
  both, and for a soak nothing schedules that `0` never changes, so a stopped
  clock was invisible until someone thought to check. Reporting the elapsed
  days rather than a stale/not-stale flag is deliberate: the number grows while
  the clock is stopped, where a flag repeats itself forever. The new setting
  `STATE_GRAPH_SOAK_STALE_DAYS` (default `1`) sets how old the newest record
  may be before the clock reads stale. `--status` exits 0 in every state,
  including `unreadable` — it reports, it does not gate.
