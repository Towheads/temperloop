- **`/fix` no longer throws away a finished fix when a reviewer blocks it**
  (#1988). A blocking review finding used to be handled like an unanswered
  question: the target was parked, its claim released and its worktree
  deleted — discarding a complete, committed fix so the whole thing had to be
  built again from scratch, often over a few lines. `/fix` now **resumes such
  a run in place**: it keeps the worktree and the claim, hands the reviewer's
  findings to the same worker, and carries on through the usual gates. Only
  escalations that carry no committed work behind them — an open question, a
  design fork, a failure, a machinery error — still park and discard, where
  starting over costs nothing.
