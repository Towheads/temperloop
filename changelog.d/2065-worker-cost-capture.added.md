- **`/build`'s per-item worker now carries a cost ledger** — every parked
  record (single-arm and dual-build alike) gains `tokens_in`, `tokens_out`,
  `wall_clock_ms`, `retry_tokens`, `retry_count` and `recovery`, captured at a
  new emitted-shell seam (`workflows/scripts/build/worker-usage.sh`). The seam
  exists because `/build` spawns its workers through the coding harness's own
  built-in subagent call rather than the `claude -p` command line, and that
  call returns neither a timer nor a token-usage envelope to read. The same seam makes the `/build` (and `/sweep`/`/fix`, which share
  the same worker code path) implementation worker a FOURTH emitting seat,
  `build-worker`, in the model-usage attribution stream — joining the
  `report-producers/model-comparison` coverage denominator
  (`MODEL_COMPARISON_EMIT_FEASIBLE_SEATS`, now 4) as attribution-only (no captured
  envelope exists for such a spawn, so its own records honestly read
  `usage_source: "unavailable"` rather than carrying a fabricated token count) (#2065).
