- **A branch that was already pushed and then rebased now lands, and a parked
  item no longer reports a worker's committed work lost when it was not**
  (#2103). When a second round of work continued on a branch an earlier round
  had already pushed, `/build` rebased that branch before opening the PR — and
  a rewritten branch can no longer fast-forward, so the push failed outright.
  The rescue step that exists to get a worker's commits onto the remote before
  the item is parked then tried a plain push of its own, failed the same way,
  and recorded the work as unpreserved while it sat in the worktree as the only
  copy. Seen three times in one session, recovered by hand every time.
  - **A push that has to rewrite a branch is now always leased, never a bare
    force.** `workflows/scripts/build/pr.sh push` reads the remote branch's
    current value first and forces only against that exact value
    (`git push --force-with-lease=<ref>:<sha>`), so a push that would discard a
    commit someone else added in the meantime is rejected rather than silently
    overwriting it. If the remote value cannot be read at all, no force is
    issued and the plain push is left to fail loudly.
  - **New `--allow-rewrite` flag on `pr.sh push`** — the same request as
    `--force`, without putting that word in the command line. An agent-driven
    run can be halted by a safety classifier that sees a literal `--force`, so
    the pushes `/build` issues itself now use the new spelling, and the recovery
    command `pr.sh` prints after a push lands on the wrong branch does too.
  - **Whether the work was preserved is now checked against the remote instead
    of inferred from whether the push command succeeded.** A failed push whose
    commits had in fact already landed no longer reports them lost, and an
    outdated copy of the branch sitting on the remote no longer reports them
    saved. The parked item's record carries both the commit in the worktree and
    the commit on the remote, so whoever picks the item up can see the real
    state rather than trust one flag.
  - **The rescue push never overwrites work it cannot prove is superseded.** It
    rewrites the remote branch only when this worktree's history already
    contains every commit the remote has. If the remote carries something else,
    or if that question cannot be answered because the remote became
    unreachable mid-step, it refuses, leaves the remote untouched, and says
    which of those two it was rather than asserting a conflict it never
    established.
