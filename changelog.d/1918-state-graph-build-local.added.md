- **`state-graph.sh build --board N` now reads three HOST-LOCAL sources
  alongside the four `gh`/git-backed ones** (#1918, epic #1910, ADR 0033):
  `plan_notes` (approved/in-progress `Plans/` notes in the knowledge store,
  emitting `PlanItem` nodes with their sentinel state, `depends_on`/`after`
  edges, and `pr:`/`pushed_sha:` fields), `journal` (the Workflow runtime's
  `agent-<id>.jsonl` transcripts, emitting `Session` nodes with recorded
  step outcomes), and `tmux` (the per-window `@claimed_issue` claim marker,
  emitting `Marker` nodes and `marked_by` edges). Each is typed
  `ok`/`absent`/`error`/`stale` exactly like the original four sources — a
  host with no tmux binary or server is `absent`, but a reachable server
  holding zero claims is `ok`, never conflated with "nothing to report".
