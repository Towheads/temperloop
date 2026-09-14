- **`/fix` no longer throws away a finished fix when something blocks it late**
  (#1988). A blocking review finding, or a single acceptance bullet coming
  back false, used to be handled like an unanswered question: the target was
  parked, its claim released and its worktree deleted — discarding a complete,
  committed fix so the whole thing had to be built again from scratch, often
  over a few lines. `/fix` now decides on **facts it can check** — does the
  worktree exist, does it hold a commit ahead of the base, and is it clean? —
  rather than on the name of the escalation, and it spells out every
  combination of those three readings in a single table so no state is left to
  judgement. A commit **and** a clean tree **resumes in place**: it keeps the
  worktree and the claim, hands the findings to the same worker, and carries
  on through the usual gates. Every other state parks, and the worktree is
  deleted only once the tree is **confirmed** to hold neither a commit nor
  uncommitted edits — a dirty tree is kept whatever else it holds, and so is a
  tree the check could not read at all — with its path reported on the issue,
  so parking can no longer quietly destroy work.
  The same table now also gates the *other* half of the hazard: **starting** a
  drive force-clears the worktree just as deleting it would, so every path
  that re-enters a drive — answering the parked question, answering an issue
  that arrived already carrying an open question, adopting an issue whose PR
  vanished, overriding a dependency block — reads the table first and resumes
  against the preserved build instead of rebuilding over it. Resuming also has
  to re-take the board claim that parking released, and that can lose a race to
  another session that picked the issue up in the meantime; if it does, `/fix`
  stops and reports the owning session and the path to the preserved build
  rather than driving on unclaimed or taking a claim that is not its own. And
  the comment `/fix` leaves on a parked issue now says which of the two will
  happen, so it can no longer point the operator at the action that throws the
  work away.
