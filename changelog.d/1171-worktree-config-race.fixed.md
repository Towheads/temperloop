- **`worktree.sh create` no longer loses a `.git/config` race when two items of
  one level start at once** (#1171). `git worktree add` writes the new branch's
  upstream into `.git/config` and git takes that lock without waiting, so
  concurrent creates — an ordinary `/build` level, a `/sweep` chunk at
  `SWEEP_FANOUT_WIDTH > 1` — failed outright with `could not lock config file
  .git/config: File exists`. Every config- and ref-mutating region of `create`,
  `remove` and `prune` now runs under one per-repo directory lock (portable:
  stock macOS ships no `flock`), so the losers queue instead of failing. A
  failed `git worktree add` is also rolled back now, so the `ERROR` outcome
  leaves no orphan `build/<slug>` branch to delete by hand and a naive retry is
  a clean create.
  A crashed `worktree.sh` no longer wedges the repo either: a lock whose owner
  process is provably gone is reclaimed at once, and one that never recorded an
  owner is reclaimed once it ages past `WORKTREE_LOCK_STALE_SECS`.
