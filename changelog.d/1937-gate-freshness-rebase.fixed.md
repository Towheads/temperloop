- **`/build`'s §3e.5 acceptance gate now runs on a worktree rebased onto
  current `origin/main`** (temperloop#1937). Previously a long-running or
  parallel-level item's worktree could fall behind `origin/main` by the time
  the gate ran, so a validator that ratchets against `origin/main` read rows
  main gained in the meantime as this item's own regression and lost a full
  gate round.
