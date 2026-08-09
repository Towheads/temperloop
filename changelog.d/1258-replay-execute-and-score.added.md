- **The model-comparison replay module can now RUN a candidate and SCORE it**
  (#1258, epic #1225 "model comparison harness"). `replay.sh execute` drives a
  candidate headlessly inside an already-prepared replay worktree and emits one
  schema-complete `replay-record-v1` record with its `candidate` and `score`
  sub-objects — the diff partition's outcome, the gate result, token counts and
  duration — populated. Those two sub-objects shipped in #1254 as documented
  placeholders for exactly this item; completing them is not a schema v2.

  Scoring lives in the new `workflows/scripts/model-comparison/score.sh` and
  takes its rules from the keystone spike (#1247) rather than re-deriving them:
  the named solution surface is diffed with `--ignore-all-space
  --ignore-blank-lines`, the test surface is scored on presence and pass rather
  than bytes, policy churn is neutral, and the mechanical outcome scorer is
  `scripts/quality-gates.sh` — specifically the copy inside the candidate's own
  base worktree, never today's tree, so a historical item is gated by the gate
  suite it actually shipped under. Contamination-suspect items are flagged in
  the record (template drift, whitespace-only truth churn, residual `.md`
  propagation, acceptance bullets carrying hard numeric literals).

  A record distinguishes an **integration error** from a scored outcome, and
  `score.sh aggregate` reports the two as separate metrics: an integration
  error contributes to a compatibility figure and to no quality figure at all
  — not the numerator, not the denominator — so a vendor integration failure
  can never be read as a model quality failure.

- **`validate-provider-disclosure.sh` now enforces send-vs-log coverage**
  (#1258). A send to a non-default provider — an attribution record in the
  per-seat model-usage stream whose `provider` is not the trusted default —
  with no matching disclosure-log entry for the same `(provider, item_ref)`
  now **fails** the gate. This is the half #1250's own acceptance explicitly
  deferred, unblocked by the `provider` field #1253 added. `replay.sh execute`
  discloses *before* it sends and refuses the send if the disclosure fails, so
  the log may legitimately run ahead of the sends and never behind them.
