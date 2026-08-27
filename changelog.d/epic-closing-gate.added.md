- **`/sweep` now reviews and offers to close fully-drained Operational
  epics at the end of every run** (epic #1847 (epic-as-metadata for
  operational work)). "Operational" is the established-pattern half of
  the Operational/Foundational work-class split (`claude/work-class-policy.md`).
  Once an epic's members admitted into sweep's pool
  have all reached a terminal state — every one of the epic's members, not
  just the ones this run drove — the parent is offered for close on an
  attended run (default: close), with a one-line closing comment pointing
  back at the run's report; a partially-drained epic is instead reported as
  progress, naming what's still open and, where known, what it's blocked
  on. An epic explicitly marked `keep-open` is reported but never offered
  for close, and that label is created on first use rather than assumed to
  already exist. On an unattended run a fully-drained epic's parent is left
  open, with one pending-decision entry recorded per epic ever (a re-run
  never posts a duplicate). A run that admitted no epics still runs the
  review and records a genuine zero. The tally (`epics_reviewed` /
  `epics_closed` / `epics_left_open`) rides the existing per-run
  `emit-command-run.sh` telemetry record as a purely additive schema
  extension, reconciled by its own independent accounting check. See
  `docs/features/sweep.md`.
