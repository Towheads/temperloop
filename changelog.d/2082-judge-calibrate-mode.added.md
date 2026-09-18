- **`model-comparison/dual-build-ledger.sh` gains a blind judge-calibration
  mode** (#2082, epic #2065, ADR 0041). `calibrate-sample` picks up to
  `DUAL_BUILD_CALIBRATE_PAIRS_PER_LEVEL` already-judged, fully-archived item
  pairs and prints each as `{slug, baseline_diff, candidate_diff}` — the
  judge's own preference and margin are never included, so a human can
  record a genuinely blind preference. `calibrate-record` looks up that
  slug's real judge verdict itself (a caller can never fake agreement) and
  appends a labelled pair; `--source override` records an operator-override
  pair but excludes it from the agreement statistic, per ADR 0041's
  "disagreement by construction" reasoning. `calibrate-status` (also run
  automatically after every `calibrate-record`) writes the pinned
  `calibration.json` — `{n, agreement_pct, status, bar_pct, bar_n}` — where
  zero recorded pairs reads `"NEVER CALIBRATED"` and the bar values are
  sourced from `DUAL_BUILD_CALIBRATION_BAR_PCT`/`_BAR_N`.
