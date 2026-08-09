- **Optional cross-family judge rotation** (#1260, epic #1225 "model
  comparison harness"). New `judge.sh judge-rotate` subcommand scores one
  replay record with judges from more than one provider family (a
  comma-separated `--judges provider:model,provider:model,...` panel) and
  reports the **variance** of their `quality_score` across the panel —
  consumed from `stats.sh`'s own sample-stddev (squared here in a single line
  of jq arithmetic), never a second statistics implementation. **OFF by
  default** (`MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=0`): with it off,
  `judge-rotate` refuses immediately (`CANNOT_EVALUATE`) and `judge`/
  `judge-batch`'s own behaviour is byte-identical to the pre-rotation module.
  Each rotation member is scored via the exact same judge≠candidate guard,
  non-default-provider allowlist+disclosure gate (the same committed
  allowlist and same disclosure log a candidate replay uses), and
  `candidate-session.sh` spawn (containment overlay + provider-key health
  check) the single-judge path already uses — reused verbatim, never
  reimplemented for the panel case. Every emitted record carries an explicit
  disclaimer: rotation **REPORTS** family-bias variance and does **NOT
  PROVE** the resulting judgment is free of model-family bias. Fail-closed
  throughout (temperloop#1365 class): too few JUDGED members, JUDGED members
  from only one provider family, or a genuine `stats.sh` failure all
  `CANNOT_EVALUATE` the variance rather than reporting a fabricated or
  zero-standing-in figure. Two new registered settings
  (`MODEL_COMPARISON_JUDGE_ROTATION_ENABLED`,
  `MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_judge_rotation.sh`).
