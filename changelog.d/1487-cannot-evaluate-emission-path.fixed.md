- **The "cannot evaluate" idiom's `ONE emission path` claim is now true, and its one
  exception is named** (temperloop#1487). `claude/presentation-plane.md` froze
  `workflows/scripts/lib/cannot-evaluate.sh` as "the ONE emission path" while six sites
  still emitted the contract independently — the claim was aspirational. The blocker was
  structural: each model-comparison entry point's `command -v jq` bootstrap guard *is* a
  cannot-evaluate, and the helper built its JSON with `jq`, the very tool that was missing.
  So the guards hand-rolled their own shapes and drifted: `batch.sh` put the machine JSON on
  **stderr** with no human line, and `replay.sh` emitted `outcome:"ERROR"` there instead of
  `CANNOT_EVALUATE` — a consumer parsing stdout for the verdict saw nothing from either.
  `cannot_evaluate_emit` is now **jq-free** (it encodes with `jq` when present and with a
  pure-shell escaper when not, byte-identically), so all four guards in
  `{batch,judge,score,replay}.sh` route through it and emit both frozen shapes on the
  correct streams; each keeps its own documented process exit code (`1`). The fifth site,
  `tagging.sh crosscheck`'s `_cc_eval`, is a **registered carve-out** rather than a silent
  gap: its stdout is its own human `OK`/`FAIL` verdict stream, so it emits the frozen human
  line and *no* machine JSON on either stream, and returns its own documented `1`. That
  accepted shape is stated in the frozen row and pinned by a test, so a future drift into a
  partial emitter goes red.
