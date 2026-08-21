- **`architecture-reviewer` now pins its own model tier (`model: opus`)
  instead of declaring `model: inherit`** (temperloop#1456). The seat's own
  charter says its boundary calls "are the gate" and that it is therefore
  "never down-tiered" — but `inherit` resolves to whatever tier the *calling*
  context runs on, so the guarantee held only when a human happened to be
  driving on the strong tier. This went live the moment temperloop#1430 made
  the §3e reviewer gate actually run on the default Workflow path: an
  autonomous drive runs cheap by design (`$PIPELINE_DRIVE_MODEL`), and the
  seat would have silently inherited that tier on exactly the
  `kind: architectural` items it exists to protect — nothing errors, the
  review just runs weaker than designed. The declared intent was taken as
  authoritative and the mechanism corrected to match it. The tier is pinned in
  the agent's **frontmatter** rather than passed as a caller-side override,
  because the harness reads that file at every spawn: one declaration covers
  `/build` 3e, `/assess` Step 3 and `/workshop` Step 3.3/3.5 alike, and a
  future call site inherits the guarantee without knowing it needs to. This
  also brings the seat into line with the kernel's own § Subagent usage
  cost-tier rule, which asks that a seat's tier be set *explicitly* to fit the
  work — `inherit` being the one value that makes tier a function of the
  caller instead. `runReviewers()` in `claude/workflows/build-level.mjs` is
  unchanged and still passes no `model` override, so the change is a strict
  no-op for the three sibling reviewers that already pin `model: sonnet`
  (`workflow-reviewer`, `docs-reviewer`, `requirements-auditor`).
