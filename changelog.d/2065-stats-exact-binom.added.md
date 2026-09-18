- **`stats.sh` gained an `exact-binom` subcommand** — a two-sided exact
  (Clopper-Pearson) confidence interval for a win proportion `k`/`n` against
  a fixed null of 0.5 (a fair-coin sign test), computed by inverting the
  binomial CDF directly rather than a normal approximation or a bootstrap
  resample, so it stays valid at small sample sizes. It shares the same
  minimum-sample floor as `bootstrap-ci`/`verdict`
  (`MODEL_COMPARISON_MIN_SAMPLE_N`): below the floor it reports
  `below_min_sample: true` with no interval, rather than a hard error.
