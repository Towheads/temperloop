- **`/workshop` is now two phases with two operator gates, and its
  per-dimension coverage walk is removed** (temperloop#1958 — two-phase
  rewrite; epic #1938 — `/workshop` redesign; ADR 0035). The command used
  to walk a design brief's coverage dimensions one at a time, stopping the
  operator at each; a prototype run took 26 modal stops, 10 of which asked
  for nothing but an acknowledgement. It now stops twice. **Phase 1** is an
  interview: `/interview` runs inline in the same session, and its very
  first question is the **premise gate** — a chance to kill the idea
  outright before any design work happens. **Phase 2** then runs unattended
  start to finish: it drafts every dimension the interview did not reach
  (marking each as facilitator-drafted rather than operator-stated),
  validates the brief before spawning any reviewer, runs the adversarial
  review panel and the cross-dimension congruence pass, and ends at the
  second gate — a **delta report** that shows the operator, in roughly two
  batches, the full before/after of everything Phase 2 changed, and takes
  one verdict per dimension rather than one per batch. **Phase 3** ratifies
  and materializes the epic as before, additionally asking whether any
  batch of that report was rubber-stamped, and printing a per-run tally of
  how often the operator was interrupted. The pipeline diagrams in the two
  peer front-door specs — `claude/commands/triage.md` and
  `claude/commands/assess.md` — now name the new phases instead of the
  removed walk.

  **Removed in this release** (the BREAKING half — documented steps drop,
  per `VERSIONING.md` § The contract surface): the per-dimension coverage
  walk and its tier-split proposal stop, the per-dimension `walk` verdict,
  the three-free-rounds challenge bound, and the pre-ratify walkthrough
  pass.

  **Migration:** briefs ratified under the walk grammar keep validating
  (unstamped ⇒ legacy); a brief authored under the new grammar carries
  `record_grammar: delta` in its frontmatter. Nothing checks that stamp
  automatically — `workflows/scripts/validate-design-brief.sh --brief
  <path>` is an **on-demand lint you run yourself**, not a pipeline gate.
