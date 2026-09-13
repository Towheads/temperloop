- **`/workshop` is now two phases with two operator gates, and its coverage
  walk is removed** (temperloop#1958, epic #1938; ADR 0035). **Phase 1**
  executes `/interview` inline in the same session — the premise gate is
  round 1's Q1 (`--first-question`, whose `drop` option still runs the
  unchanged drop action), dimension 4's Contract is the final question by
  construction, and the review tier is priced and picked inside the
  understanding check (`--check-questions`). **Phase 2** runs foreground and
  unattended: every schema dimension is expanded (any the interview never
  touched flagged `_facilitator-drafted, not from interview_`), the brief is
  validated before a single reviewer spawns, the ported panel (3.1–3.4) and
  congruence pass (3.5) run, a targeted interview round fires when more than
  half the dimensions are facilitator-drafted, and the phase ends in one
  chunked **delta report** — full text plus before/after per changed
  dimension, each cluster question carrying its dimensions' Δ inside the
  question block, one `delta` verdict per dimension, and a soft cost
  checkpoint on a third re-presentation. **Phase 3** ratifies (the call now
  also asks "was any chunk of the delta report a rubber stamp?"),
  materializes unchanged, and prints a per-run tally whose
  acknowledgement-only count must be zero.

  **Removed in this release** (the BREAKING half — documented steps drop,
  per `VERSIONING.md` § The contract surface): the per-dimension coverage
  walk and its tier-split proposal stop, the per-dimension `walk` verdict,
  the three-free-rounds challenge bound, and the pre-ratify walkthrough
  pass.

  **Migration:** briefs ratified under the walk grammar keep validating (unstamped ⇒ legacy); a brief authored under the new grammar carries `record_grammar: delta` and requires the post-sync validator on every checkout that validates it.
