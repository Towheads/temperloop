- **A build no longer stops — or loses committed work — because the reviewer
  routing table went missing in transit** (#2020). Choosing which review
  agents a change needs requires a small table of file-type-to-reviewer rules.
  On a caller that does not supply that table up front, the build reads it
  and passes it back through an intermediate step, and that copy has
  repeatedly arrived damaged or not at all. Three things change.

  The table is now passed back as a **list of its rows** rather than as one
  block of text. The same intermediate step has always carried the list of
  changed files in exactly that form, and that list has survived every
  observed failure that destroyed the block of text — so the table now
  travels the way the thing next to it already travels reliably. The block-of-
  text form is still accepted, so a caller or a stored result produced before
  this release keeps working, and the existing count and checksum still
  verify what arrives.

  When the table is still missing after one automatic retry, the build now
  **finishes on a reduced set of reviewers**, instead of stopping. Review is
  advisory here — it is not one of the checks that gate a merge — and it
  happens after the work is written, tested and committed, so stopping there
  abandoned a finished change over a step that was never allowed to block it.
  Only the rules that actually read the table are dropped: the rules decided
  from the change itself — above all the one that **always** requires a
  workflow review when a command document is edited — still pick their
  reviewer and still run it, so a missing table can never quietly turn a
  required review into no review. The pull request carries a plain line naming
  what was dropped, and the run summary counts the builds that reviewed on a
  reduced set, so a thin review section can no longer be misread as a clean
  review.

  And **whenever a build stops early, any commits it already made are pushed
  to the remote first**. Previously those commits existed only in a local
  working copy, and the cleanup path for a stopped build deletes that copy and
  its local branch; on one run that destroyed 515 lines of finished, verified
  work, recovered only by hand. The push happens at a single point every early
  stop passes through, so it covers every reason a build can stop, and the
  result — pushed, nothing to push, or push failed — is recorded on the
  stopped build's report so whoever cleans up can see whether a remote copy
  exists before deleting the local one.

  Two details of that rescue push matter to anyone reading its report. It goes
  to **the same remote branch the build's own pull request uses**, so a rescue
  after that pull request already exists adds nothing to the remote rather than
  leaving a second, orphaned branch that no pull request tracks and no cleanup
  ever reclaims. And **"nothing to push" is now reported only when the build
  could genuinely compare** the work against the branch it started from. On a
  repository whose main branch is named something other than `main` or
  `master`, and that records no default, that comparison is impossible — and it
  previously came back as a plain zero, so real unpushed work was reported as
  nothing to preserve, with none of the warning a stopped build otherwise
  prints when it cannot save your work. The build now pushes anyway in that
  case and says the comparison could not be made.
