- **A build, fix or sweep run that quietly did nothing is now reported instead
  of counted as a success** (#2004). When the per-level driver was asked to
  work on at least one item and came back having produced no pull request, no
  parked item and no escalation for any of them, `/build`, `/fix` and `/sweep`
  had no branch for that combination and read it as "finished, nothing to
  report" — the item vanished with no signal at all, while its issue was still
  open and marked in progress under a live claim. A run whose own driver
  restarted mid-flight could land exactly there. `claude/workflows/build-level.mjs`
  now recognises the combination and returns it as its own named outcome,
  naming every item it was asked to work on and giving, for each, a ready-to-run
  command that re-checks the issue, any open pull request for its branch, and
  its worktree. The three commands each act on that outcome by running those
  checks and deciding from what they report, rather than concluding anything
  from the empty result. A run that was legitimately asked to do nothing, and a
  read-only investigation item that produces a verdict rather than a pull
  request, are both unaffected and report exactly as before.
