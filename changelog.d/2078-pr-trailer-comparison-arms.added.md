- **`model-comparison/tagging.sh` gains a `stamp-arms`/`parse-arms`
  subcommand pair — the `Model-comparison-arms:` PR trailer for the
  dual-build harness** (#2078, epic #2065). `tagging.sh stamp-arms
  --baseline <model> --candidate <model> --pick <baseline|candidate>
  --reason <text>` prints a line naming both models a winning dual-built PR
  was built under, which one won, and a one-line pick reason; `tagging.sh
  parse-arms --pr-body <file>` reads it back. The new line rides alongside —
  never in place of — the existing `Model-provenance:` trailer, so every
  existing single-model consumer keeps parsing exactly what it always has.
  `stamp-arms` has no side effects of its own (no window record, no
  telemetry tag); the dual-build ledger is a separate, later piece of the
  harness.
