- **`/fix` no longer loses an escalated worker's committed work, and no longer
  removes a worktree pre-emptively to defend against the next `create`**
  (#1728). Step 4a's inline-answer branch now mints a preservation ref
  (`worktree.sh remove`) and re-applies it onto a fresh worktree
  (`worktree.sh restore`) before re-driving, so the second worker builds on the
  restored work instead of re-deriving it; the park branch reclaims the path
  through the same guard and names the resulting `refs/parked/*` ref in its
  issue comment. A `REMOVE_REFUSED` outcome plus its non-zero exit (#1730) now
  takes an explicit hold — the claim stays held, no further `worktree.sh` call
  runs, and the git-level failure is reported verbatim alongside the worktree
  and branch `remove` left standing — while still counting as `parked`, so the
  telemetry emitter's four-field taxonomy is unchanged. A bare
  `preserved: false` is the ordinary nothing-at-risk reading and never triggers
  that hold, and `create`'s never-refuse arm is documented as a sideline to
  `sidelined_path` rather than a failure. Step 6 names `worktree.sh prune` as
  the reap owner — of preservation refs and sidelined worktrees alike — and its
  two gates. Previously the spec claimed
  `clear_path` discarded only "uncommitted edits"; it `git branch -D`s
  `build/<slug>` too, so committed work was destroyed just as completely.
