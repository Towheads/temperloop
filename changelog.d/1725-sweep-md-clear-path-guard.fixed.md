- **`/sweep`'s unattended escalation park no longer reads as destroying the
  worker's unlanded work** (#1725). The park branch's `worktree.sh remove` now
  runs first in the branch — `cmd_remove`'s own unlanded-work guard (#1699)
  preserves committed and dirty state to a local `refs/parked/<slug>-<sha8>`
  ref before the force-remove — and the park comment names that ref plus the
  host holding it, since the ref is local-only and never pushed. The old
  "resume = re-run, so discard it" rationale, which justified the destroy by
  the very re-run it made lossy, is gone. A capture failure now surfaces as
  `REMOVE_REFUSED` plus a non-zero exit (#1730) — which this branch reads as
  the work-preservation SUCCESS case, not a park failure: it warns, keeps
  disposing the chunk, and lands a distinct sentence in the park comment naming
  the verbatim `preserved_detail`, the still-standing worktree path and the
  host, so the failure is durable on the issue rather than lost to an
  unattended run's stdout. The spec adds no destroy of its own after one. The
  spec also now states the ref's reap rule: a sweep-originated ref is never
  restored in place, so `prune` reaps it on the originating issue's terminal
  disposition, never on the ancestry gate — which can never fire for it — with
  `prune`'s `PARKED_REF` report and /tidy's stale-claim sweep named as the
  crash-window backstop.
