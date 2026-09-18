- **`/build`'s per-item worker now carries a cost ledger** — every parked
  record (single-arm and dual-build alike) gains `tokens_in`, `tokens_out`,
  `wall_clock_ms`, `retry_tokens`, `retry_count` and `recovery`, captured at a
  new emitted-shell seam (`workflows/scripts/build/worker-usage.sh`) since the
  Workflow runtime's `agent()` call returns neither a timer nor a usage
  envelope. The same seam makes the `/build` (and `/sweep`/`/fix`, which share
  the same worker code path) implementation worker a FOURTH emitting seat,
  `build-worker`, in the model-usage attribution stream — joining the
  `report-producers/model-comparison` coverage denominator
  (`MODEL_COMPARISON_EMIT_FEASIBLE_SEATS`, now 4) as attribution-only (no
  captured envelope exists for a Workflow `agent()` spawn, so its own records
  are honestly `usage_source: "unavailable"` rather than a fabricated token
  count) (#2065).
