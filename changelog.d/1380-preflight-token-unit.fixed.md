- **The replay spend gate and the comparison report now speak ONE cost unit,
  and the per-replay constant is grounded in measurement** (#1380, epic #1225
  "model comparison harness"). `workflows/scripts/model-comparison/replay.sh
  preflight` reported `cost_basis: "token_count"` — a RAW token sum — while
  `workflows/scripts/report-producers/model-comparison` reported
  `cost_basis.unit: "token-counts"`, meaning cost-WEIGHTED units (the
  `SPEND_WEIGHT_*` multiply-add). Two non-comparable units sharing the word
  "token", so the batch cost an operator authorized at the gate could not be
  reconciled against the cost the report handed back: on the one observed live
  replay they differ by 5.4x (raw 2,506,371 vs cost-weighted 466,530). Both
  surfaces now emit the same string, `cost-weighted-token-units`, and the gate
  additionally publishes the `SPEND_WEIGHT_*` values that unit is defined by
  (weighted figures are comparable only within one weight-retune epoch).
  **Cost-weighted is the side converged on** because it is the unit that
  tracks spend — the dominant term in a real replay is `cache_read`, 2.38M of
  2.51M raw, which the default weights price at a tenth — and because the
  report is the artifact an operator ultimately reconciles against.
- `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY` moves from a hand-set placeholder to
  the measured cost-weighted figure, rounded up to the nearest 10,000. Its
  **provenance is stated wherever it appears** — in `build.config.sh`, in the
  setting registry, and in a new `tokens_per_replay_basis` field the gate
  emits on every run: it is an ESTIMATE from a SINGLE observed live replay
  (n=1, the #1262 harness validation run), not a fitted average and not
  derived from the operator's own records, so one sample carries no variance
  and it deserves order-of-magnitude confidence only. The old value was 3.1x
  low in the weighted unit and 16.7x low against the same replay's raw total.
  `REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS` follows it into the same unit (a
  stddev denominated differently from the mean it varies around is the same
  collision in miniature).
- **`REPLAY_PREFLIGHT_CEILING_TOKENS` changed MEANING, not just value** — read
  the setting's comment before reusing an old number. It is now denominated in
  cost-weighted units and re-derived under the design rule its predecessor was
  written to ("a default-cap batch sits comfortably under it; raising
  `REPLAY_PREFLIGHT_BATCH_CAP` well past default is what trips it"), with the
  corrected two-arm arithmetic and the measured constant. At the observed
  token mix this is a real-terms LOOSENING of roughly 5.4x versus the old
  literal read as raw tokens. That is deliberate and stated rather than
  silent: the old value was never an external quota or an independent budget —
  it was itself derived from batch cap x a per-replay constant now known to be
  3.1x low — and holding its real-terms strictness would have put the ceiling
  below the cost of the smallest statistically meaningful comparison
  (`MODEL_COMPARISON_MIN_SAMPLE_N` paired outcomes), i.e. a gate that stops
  every batch it could ever be asked about.
- Pre-flight now **FAILS CLOSED on the weights that define its unit**
  (the #1365 class): missing or malformed `SPEND_WEIGHT_*` is
  `outcome:"CANNOT_EVALUATE"` and non-zero, with no estimate and no stop
  verdict emitted — the same refusal the report producer already makes on the
  same input, so the two surfaces fail together rather than one publishing a
  unit the other could not resolve. A negative weight is refused too, which a
  JSON-parse check alone would accept and apply silently.
- New gate `workflows/scripts/model-comparison/tests/test_replay_preflight_cost_unit.sh`
  is the first suite that runs BOTH surfaces and compares what they printed:
  it fails if the two emitted `cost_basis` strings ever diverge (the two files
  share no sourceable seam, so the shared string is a documented duplicate
  held honest mechanically rather than by review). It also pins that the
  shipped per-replay default sits at the measured cost-weighted figure and
  below the raw one — the interval that distinguishes the two units — that the
  estimate scales over executed replays in the declared unit, that the
  ceiling re-derivation is load-bearing (the pre-fix ceiling literal stops a
  floor-sized batch under the new constant, so a half-fix that raised only the
  constant is caught), and the fail-closed weights floor. Two mutation proofs
  against the live `replay.sh`. The #1379 two-arm budget and paired-outcome
  significance check are untouched and still pinned by their own suite.
