- **`worktree.sh` now freshens `origin/<default>` before judging work unlanded,
  and records which basis it judged on** (#2030). Every landed-check in that
  script compares against the LOCAL `origin/<default>` ref, which only moves
  when something fetches; `preserve_unlanded` — the check whose verdict decides
  whether work is recorded as lost — never freshened it, and on the `create`
  path the hand-rolled fetch ran *after* the probe that needed it. Work merged
  minutes earlier therefore read as not-an-ancestor, and `remove` minted a
  `refs/parked/*` preservation for work already in the default branch. The
  freshen is now one shared helper (`create`, `prune` and `deps-merged` use it
  too), bounded by the new `WORKTREE_LANDED_FETCH_TIMEOUT_SECS` through the
  portable-timeout shim. It fails safe: a failed, timed-out or offline fetch is
  never fatal and leaves the local ref as the basis, which can only make work
  read as less landed — so "could not establish" still preserves, unchanged, and
  `remove` never depends on the network being up. Each preservation now carries
  `basis=refreshed` / `basis=unrefreshed` on its mint line and durably on the
  ref's own reflog, and `prune`'s `PARKED_REF` / `PARKED_REF_REAPED` lines
  report it — so a verdict reached against a stale comparison point is
  distinguishable after the fact from one reached against a fresh one.
