- **`/build`'s class-A activation gate (§3e.6) now actually runs on the default
  path** (#1219). `claude/workflows/build-level.mjs` — the default Step-3 driver
  since #998 — contained zero references to activation, and `activation` was
  missing from the Step 3 `items[]` args contract, so an item's `activation:`
  block never crossed the orchestrator→workflow boundary at all. Since
  `plan.sh` rule 14 hard-fails a product-source item that omits `activation:`,
  every such block was inert: an item could merge green with its feature
  dormant — a runner never registered, a flag never flipped, a rule nothing
  greps for — which is exactly what the activation-completeness contract exists
  to catch. `driveItem` now evaluates a `class: A` item's `proof:` predicate
  against the worker's worktree **between 3e.5 and 3f**, so a Fail loops back to
  3c instead of landing on an open PR, and an absence-asserting predicate gets
  the #944 merge-base control pass first — a proof that also passes at the merge
  base is reported vacuous rather than trusted. A control that cannot be
  *established* is its own outcome (`activation-control-unavailable`), never
  laundered into a pass. Items with no `activation:` block, or `class: B`/`C`,
  take a byte-identical path: the gate returns on its first line and spawns
  nothing.
