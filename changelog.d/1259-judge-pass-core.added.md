- **Replay records gain a judge pass** (#1259, epic #1225 "model comparison
  harness"). New `workflows/scripts/model-comparison/judge.sh` scores an
  already-executed `replay-record-v1` record (temperloop#1258) with a
  strong-tier judge model (`MODEL_COMPARISON_JUDGE_MODEL`, default
  `claude-opus-4-8`), attaching the result as a `judge` sub-object alongside
  the record's existing mechanical `score`. The rubric
  (`workflows/scripts/model-comparison/rubric.md`) is plain prompt text
  drawn from this repo's own reviewer-agent charters as source material — no
  reviewer agent is dispatched at judge time. A **judge≠candidate guard**
  compares the judge's provider+model against the record's candidate before
  any call and REFUSES an exact match structurally (no spend, no call); the
  guard is documented, at its own site, as preventing self-grading ONLY — it
  does not address model-family style bias (that is #1260, deliberately
  separate). `judge-batch` never silently drops a row: a judge that becomes
  unavailable mid-batch marks only the affected rows with a named
  `degradation_notice` (`judge.scored:false`, `judge.quality_score:null`),
  structurally distinct from a genuine `judge.quality_score:0` the judge
  actually rendered. Same hermetic-by-construction shape as replay-execute:
  every call routes through an injectable `--judge-runner` seam or the
  explicit `--live` flag, with no implicit fallback to a `claude` binary on
  PATH. Two new registered settings (`MODEL_COMPARISON_JUDGE_MODEL`,
  `MODEL_COMPARISON_JUDGE_TIMEOUT_SECS`) and a new
  `scripts/quality-gates.sh` entry
  (`workflows/scripts/model-comparison/tests/test_judge.sh`).
