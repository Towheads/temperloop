- **`/assess` now stamps `model: opus` on small and medium code items, not
  `model: sonnet`**, and `claude/plan-schema.md` § Optional `model:` field
  accepts `opus` as a value. The stamp rested on the premise that CI and the
  acceptance gate would catch a cheaper worker's mistakes. A retrospective
  over every workflow-driven item built between 2026-08-14 and 2026-09-16
  measured the opposite: sonnet-built items needed about twice the
  review-and-fix passes and twice the subagent tokens of opus-built items
  before they merged, and the defects were caught by the advisory reviewers
  rather than by any mechanical gate. Existing plan notes with `model: sonnet`
  still run unchanged; only the default `/assess` writes has moved. Operators
  who want the cheaper tier for a deliberate comparison can still set it per
  item, or run `/build --dual-build` to measure both.
