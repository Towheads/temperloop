- **A build that `worktree.sh create` shelves is now reported instead of
  silently dropped** (#2006). `create` never refuses: when the worktree path it
  needs already holds committed work that preservation could not capture, it
  moves that occupant aside to `<path>.unpreserved-<sha8>` and reports the fact
  on its `CREATED` line as `sidelined` / `sidelined_path` / `sidelined_branch`.
  Nothing downstream read those three fields, so an intact, committed build got
  shelved while a fresh worker rebuilt the same item and nothing said so — a
  wasted re-drive plus an orphaned worktree nobody knew to reclaim. The driver
  now reads them when it creates an item's worktree and tells you three ways: a
  named `SIDELINED BUILD` notice in the run log, carrying the shelved path, its
  branch and a reclaim command you can paste; the same fact travelling with the
  item all the way to the merge gate, whether it ends up parked or escalated;
  and a count on the run's summary. Because the reading lives in the one file
  `/build`, `/sweep` and `/fix` all route through, all three inherit it.
  `worktree.sh` is unchanged — its never-refuse contract still stands.
