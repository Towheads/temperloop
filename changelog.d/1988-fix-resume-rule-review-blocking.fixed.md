- **`/fix` no longer throws away a finished fix when something blocks it late**
  (#1988). A blocking review finding, or a single acceptance bullet coming
  back false, used to be handled like an unanswered question: the target was
  parked, its claim released and its worktree deleted — discarding a complete,
  committed fix so the whole thing had to be built again from scratch, often
  over a few lines. `/fix` now decides on a **fact it can check** — is there a
  commit ahead of the base in the worktree? — rather than on the name of the
  escalation. When there is one it **resumes in place**: keeps the worktree
  and the claim, hands the findings to the same worker, and carries on through
  the usual gates. When there is not it parks as before, and deletes the
  worktree only once it has **confirmed** the tree holds neither a commit nor
  uncommitted edits; anything else — including a check that will not resolve —
  is kept, and its path reported on the issue, so parking can no longer
  quietly destroy work.
  The same fact now also gates the *other* half of the hazard: **starting** a
  drive force-clears the worktree just as deleting it would, so every path
  that re-enters a drive — answering the parked question, answering a
  `question-first` target, adopting an issue whose PR vanished, overriding a
  dependency block — checks for a commit first and resumes against the
  preserved build instead of rebuilding over it. And the comment `/fix` leaves
  on a parked issue now says which of the two will happen, so it can no longer
  point the operator at the action that throws the work away.
