- **`/build` Step 3h.5's as-you-go merge is now explicitly scoped to the
  `--no-workflow` conversational path, instead of being owned by nobody on the
  default path.** `claude/commands/build.md` §3h.5 described an item merging at
  its own CI-green, but on the default Workflow path no actor could perform it:
  `build-level.mjs` **never merges and never writes the plan note** (both seats
  3h.5 needs — the `[>]` flip must be durable *before* the merge call), and the
  orchestrator's `parallel(driveItem)` returns only at the **level boundary**,
  by which time "its own green" has passed for every item. So a `[>]` sentinel
  was defined, consumed by the Step-4 gate and by resume, and produced by no
  one — while §3e's temperloop#1430 paragraph simultaneously claimed the
  workflow *owned* the as-you-go merge, contradicting the same file's
  "NEVER merges" contract. §3h.5 now opens with a SCOPE paragraph naming the
  conversational orchestrator as its actor and stating the **accepted
  trade-off** for the default path — every item parks `[m]` and takes the
  single level-boundary gate, re-paying the merge-queue pileup temperloop#1026
  measured — with `--no-workflow` as the way to get as-you-go merging, the same
  shape as the speculative-next-level NON-GOAL. §3e's #1430 paragraph drops the
  false merge-ownership claim (and its stale "3h has removed the worktree"
  clause: on this path the *orchestrator's* post-return partition removes it)
  while keeping the push-before-review reasoning that puts §3e inside
  `driveItem`. The Step-4 gate, the goal statement, the operating principle,
  the Step-1.4 resume rows, 4d, `claude/plan-schema.md`'s `[>]` and consent-line
  definitions, `docs/features/merge-gate.md`, `docs/features/build-machinery.md`,
  `gate.sh` / `emit-item-efficiency.sh` headers, and the
  `BUILD_MERGE_AS_YOU_GO` config comment + `setting-registry.tsv` row all now
  carry the same path scope — the setting is read on the conversational path
  and inert on the default one. No behavior change: nothing performed 3h.5 on
  the Workflow path before this either.
