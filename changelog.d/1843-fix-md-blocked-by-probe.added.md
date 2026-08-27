- **`/fix` now probes native `blocked_by` edges before driving a target** (#1843).
  Step 2's state probe gains a dependency-block gate on the drive routes
  (`fresh` / `adopt` / `ambiguous`): `board_blocked_by_open` runs on the resolved
  target in the pipefail discriminating shape, and a target with open blockers is
  surfaced modally — blocker numbers named, with drive-anyway /
  drive-the-blocker-first / stop offered — never silently driven. An errored read
  is surfaced too, never treated as "unblocked." Aligns the third driving
  consumer with `/next`'s NX.3 skip and `/sweep`'s pool gate (#1835): the native
  `blocked_by` edge is the dependency-block representation. Both the new
  **blocked-stopped** stop and the pre-existing **epic-refused** stop (Step 3)
  now emit the Step 6 run-telemetry record with `--reported-no-op 1` — closing
  the absent-signal gap (the #1103/#1591 class) where a gate stop left no
  record the run happened at all.
