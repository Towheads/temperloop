- **A code review that finishes just after the review time limit is now used
  instead of discarded** (#2032). The pre-push review pass `/build`, `/fix` and
  `/sweep` run waits for its reviewers under a wall-clock limit
  (`BUILD_REVIEW_AGENT_CEILING_SECS`), and it checked exactly once — the instant
  that wait ended — whether each reviewer had come back. A reviewer whose
  finished review arrived a moment later was already past the only check there
  was: its findings were thrown away, and both the PR body and the run's review
  tally reported it as unavailable for exceeding the limit, with nothing
  recorded as having run. This was not a hang; the reviews arrived and were
  dropped, and one discarded review had already found a real defect that then
  had to be found again by hand. The limit is unchanged and still bounds how
  long the pass waits — what changed is what happens to a result that arrives
  anyway: the pass now reads each reviewer's state as late as it can before
  writing anything, so a review that landed late is reported as having run and
  its findings reach the PR body. A reviewer that genuinely never comes back is
  still reported as skipped, naming the limit as the reason, and a recovered
  review can no longer be counted as both.
