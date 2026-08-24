- **A host-config/secret acceptance criterion is now DEFERRED by the `/build`
  worker and verified parent-side by the orchestrator** (#1182). A worktree is
  populated from the git index, so a gitignored host-local file (a credential
  file, an operator-placed secret) is never carried into one — every worker read
  it as absent, on every host, always, and escalated `acceptance-incomplete`
  over a guaranteed false negative. The worker verdict schema gains a
  `deferred_host_config` field: paired with `passed: false` it marks the
  criterion deferred, which §3d treats as neither a pass nor a failure (a bare
  `passed: false` with no marker still blocks, unchanged), `park()` reports as
  `host_config_deferrals`, and `pr.sh` renders in the PR body so an unchecked
  box is not misread as a worker failure. **Every path that invokes the shared
  driver now carries its own parent-side verification seat**, because the worker
  instruction is ungated: `/build` §4a (the level merge gate — and §3h.5's
  as-you-go fast path is explicitly ineligible for such an item, since it never
  reaches §4a), `/sweep`'s per-chunk merge pass (verify before
  `gh pr merge --auto`; not-confirmed parks the issue instead of merging it),
  and `/fix` Step 5's one modal gate (the deferral rides that same single ask as
  a named state caveat). The `/assess` A.8 confirmed-set bar is unchanged — this
  moves who confirms, never whether — and the named file is still never copied
  into a worktree.
