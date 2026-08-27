- **`/build` 4d's `emit-item-efficiency` step now passes every `build-level.mjs`
  invocation's wf id — comma-separated via `--build-run <WF[,WF...]>` — not just
  the initial one** (#1877). The bullet previously named "the wf_ id" (singular)
  of the invocation that drove the level, so on a level with 3d-esc
  escalation-continuation rounds each re-invocation's spend was structurally
  unattributed. The wording now matches `emit-item-efficiency.sh`'s own
  usage-header contract, and `test_item_efficiency.sh`'s prose-rot guard
  asserts the multi-invocation form so a drift back to a single wf id fails
  the gate.
