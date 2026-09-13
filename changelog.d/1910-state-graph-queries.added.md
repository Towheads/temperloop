- **`state-graph.sh query <name> --board N` — five named queries over the
  derived state graph** (epic #1910, ADR 0033): `status-drift`,
  `stale-claims`, `unlinked-prs`, `orphan-worktrees`, and `resume`. Every
  query answers the literal string `"unknown"` for a part that depends on a
  source currently `error`/`stale`, never a bare empty result standing in
  for "nothing found". `resume` implements `/build` Step 0.5's authority
  ordering as a ranked merge (plan-note sentinel over workflow journal over
  git over board) and emits, per plan item, a route drawn from
  `ontology-registry.tsv`'s `state:route` alphabet — the same alphabet
  `issue-state.sh resolve` emits, now shared with both suites via one
  fixture (`tests/fixtures/state-graph-routes.json`). `/build` Step 0.5
  runs `build` then `query resume` beside the existing prose authority
  table for a soak comparison, non-authoritative at this level.
