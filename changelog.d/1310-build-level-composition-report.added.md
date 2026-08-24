- **`/build` now reports each level's composition and disposition in its own
  transcript, so `/workflows` is no longer the only progress surface** (#1310).
  Three blocks per level, printed by the orchestrator: a **launch roster**
  (new § 3-launch) before the level is driven, naming every item with its
  sentinel, issue ref, `kind`, stage and the 3a–3h step it enters; a **gate
  disposition roster** (§ 4a) that accounts for every item in the level rather
  than only the `[m]` merge set, so an item that merged as-you-go, captured a
  `[v]` verdict, was skipped or is still escalated no longer vanishes from the
  one block a reader sees at the level boundary; and a **close-out roster**
  (§ 4d) after the gate's writebacks, naming what actually happened to each
  item plus what comes next.
- **`plan.sh roster` renders those blocks** — a new subcommand of
  `workflows/scripts/build/plan.sh` (#1310). Rendering them in code rather than
  narrating them makes the guarantees structural: the row set is generated from
  the level's own membership so a row cannot be dropped, the header counts are
  derived from the rows rather than restated beside them, an unresolvable value
  is named (`no issue`, the report-only `[?]` marker) instead of inferred from a
  slug, and a roster that cannot account for the whole level exits non-zero
  (`ROSTER_INCOMPLETE`) rather than printing short. It reads the plan note the
  run already parsed and makes no `gh` call.
