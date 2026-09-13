- **`state-graph.sh`'s `stale-claims` query no longer flags every live claim
  as stale when the journal source is `absent`** (#1980). The journal is
  this query's liveness oracle, so "no journal files found" now answers
  `status:"unknown"` (as it already does for `error`/`stale`) instead of
  computing findings against an effectively-empty Session-node list — a
  false positive that, on a live soak, mis-flagged the very session running
  the soak as a stale claim. The fix is scoped to `_sg_query_stale_claims`;
  `_sg_degraded` and `status-drift`'s "absent = nothing found" reading of
  the board source are unchanged.
