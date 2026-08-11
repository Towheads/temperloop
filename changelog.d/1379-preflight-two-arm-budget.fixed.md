- **The replay pre-flight now budgets BOTH comparison arms, and tests
  significance against planned PAIRS** (#1379, epic #1225 "model comparison
  harness"). `workflows/scripts/model-comparison/replay.sh preflight` had two
  unit errors that its existing fixture suite could not see, because every
  number was wired correctly to the wrong quantity. **(a)** The token estimate
  multiplied the per-replay figure by the planned *corpus record* count,
  budgeting a single arm for a comparison that executes every record in
  **both** the baseline and the candidate arm — so every batch was projected at
  exactly half its real cost, and a batch between 1x and 2x
  `REPLAY_PREFLIGHT_CEILING_TOKENS` cleared the spend gate. The estimate is now
  over `planned_records_n * arms_n` executed replays, and that two-arm figure
  is what the ceiling is compared against. **(b)** `significance_reachable`
  compared the whole corpus's eligible-record pool to
  `MODEL_COMPARISON_MIN_SAMPLE_N`, ignoring the batch cap that bounds what the
  invocation will actually replay — so a capped run that could only ever
  produce 10 paired outcomes reported a floor of 20 as reachable. It is now
  decided in **paired outcomes** (`planned_pairs_n`), the same unit
  `workflows/scripts/report-producers/model-comparison` feeds `stats.sh
  verdict --deltas`, and the MDE disclosure is taken at that same n rather than
  at the flattering larger one. The emitted JSON gains a `units` map plus
  `arms_n` / `planned_records_n` / `planned_replays_n` / `planned_pairs_n` /
  `eligible_pairs_n` / `mde_n`, so a reader can tell at a glance whether a
  number counts corpus records, executed replays, or paired outcomes — the
  ground truth being `1 corpus record -> 2 executed replays -> 1 paired
  outcome`. A non-integer value for any setting the estimate multiplies or
  compares is now `outcome:"CANNOT_EVALUATE"` and non-zero rather than a
  silently-zero estimate that would read as "evaluated, and under budget".
  `cost_basis`, `REPLAY_PREFLIGHT_TOKENS_PER_REPLAY` and the `SPEND_WEIGHT_*`
  weighting are deliberately untouched here — that seam is #1380. New gate
  `workflows/scripts/model-comparison/tests/test_replay_preflight_two_arm.sh`
  pins both defects end to end on the emitted JSON and exit code, each with a
  mutation proof.
