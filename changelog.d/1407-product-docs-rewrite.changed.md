- **Product docs rewritten end to end around a ratified value statement**
  (#1407). `README.md` and the top-level `docs/` pages now lead with what
  TemperLoop delivers (reviewed CI-gated PRs, collision-free parallel
  agents, an autonomous backlog with human-gated merges, free-repo support,
  a readable toolkit) in plain language; the README's opening essay moved to
  `docs/about.md`, and a new `docs/using-the-pipeline.md` carries the
  day-to-day operating guide. Every rewritten page ends with an
  AI-authorship footer (`*Written by <model-id> on <date>.*`), enforced by a
  new quality gate (`workflows/scripts/validate-docs-footer.sh`) whose
  exemption list covers the deliberately-untouched families
  (`docs/features/`, `docs/adr/`, `docs/failure-modes/`) and fails when an
  exempt page gains a footer, so the list can't go stale silently.
