- **`pr.sh rebase` now tells an unstaged-changes refusal apart from a genuine
  rebase conflict** (#735). git refuses to *start* a rebase while tracked files
  carry uncommitted edits, and that refusal exits non-zero exactly like a content
  clash — so a worker that had FINISHED (commit made, gates green) but left one
  tracked file unstaged was reported `{"outcome":"REBASE_CONFLICT","base":X,"tip":X}`:
  base == tip, no rebase needed, no conflict anywhere, and the rebase-conflict
  escalation would have discarded the finished work. The dirtiness is now probed
  from git's own `status --porcelain` before anything is attempted and reported as
  its own `DIRTY_WORKTREE` outcome (with `dirty_paths` and a `rebase_needed` flag
  that also rides `REBASED`); `REBASE_CONFLICT` is left meaning only what it says.
  `build-level.mjs` escalates it under a distinct `dirty-worktree` kind whose
  disposition is commit-the-leftover-and-re-drive, and `issue-state.sh reattach`
  no longer relabels it `stale-base-conflict`. A base that is already current now
  skips the rebase invocation entirely.
