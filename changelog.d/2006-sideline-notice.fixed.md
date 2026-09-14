- **A build that `worktree.sh create` shelves is now reported instead of
  silently dropped** (#2006). `create` never refuses: when the deterministic
  worktree path already holds committed work preservation could not capture, it
  moves that occupant aside to `<path>.unpreserved-<sha8>` and reports the fact
  on its `CREATED` line as `sidelined` / `sidelined_path` / `sidelined_branch`.
  `build-level.mjs` had zero occurrences of those fields and dropped all three,
  so an intact, committed build got shelved while a fresh worker rebuilt the
  same item and nothing said so — a wasted re-drive plus an orphaned worktree
  nobody knew to reclaim. The driver now reads the verdict at 3b and surfaces it
  three ways: a named `SIDELINED BUILD` log notice carrying the path, the branch
  and a concrete reclaim command; the same `{ path, branch, recovery }` object
  stamped onto that item's parked record (or an escalating item's payload), so
  it survives to the merge gate; and a `sidelined` rollup on the level's return
  value. Because the reading lives in the one file `/build`, `/sweep` and `/fix`
  all route through, all three inherit it without restating the rule.
  `worktree.sh` is unchanged — its never-refuse contract still stands.
