- **The kernel telemetry brief now reports epic funnel health class-
  conditionally** (`workflows/scripts/telemetry-brief.sh` § 2b, epic #1847
  "epic-as-metadata for operational work" Produces #9). A Foundational
  epic's healthy path stays epic → plan (assessed) → built, read from the
  existing `item-efficiency` per-epic merged-item rollup (`/build`'s sole
  emitter). An Operational epic's healthy path is epic →
  members-drained-via-sweep, with no plan-note step at all — read from
  `/sweep`'s end-of-run epic-closing gate tally
  (`epics_reviewed`/`epics_closed`/`epics_left_open` on the `command-runs`
  stream, which only ever covers Operational epics per the
  Foundational-wins mutual-exclusion guard). Plan-note absence on an
  Operational epic no longer has any path to reading as stalled-unassessed:
  each class is rendered from a stream only that class's machinery ever
  writes to. No new telemetry stream — both reads consume records already
  in the lake.
