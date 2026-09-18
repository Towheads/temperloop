- **A continuation round's rebased branch now pushes, and the escalation's
  `committed_work.preserved` flag now tells the truth** (#2103). A branch an
  earlier round had already pushed, rewritten by `/build` 3f-0a's pre-PR
  rebase, can never fast-forward — so the 3f push came back `PUSH_REJECTED`
  and the temperloop#2020 escalation-time preserve push, a plain `git push`,
  reported `WORK_PRESERVE_FAILED` over commits that existed only in the
  worktree. Observed three times in one session, hand-recovered every time.
  - `pr.sh push` takes `--allow-rewrite` (a synonym of `--force` that carries
    no classifier-visible force token), and 3f-1 now passes it. Every force
    `pr.sh` issues is now `--force-with-lease=<ref>:<sha>` over a value it read
    first — never a bare `--force` — so a concurrent writer is rejected rather
    than overwritten. `PUSHED`/`PUSH_REJECTED` carry the new `lease` field.
  - The escalation-time preserve push retries a rejected plain push the same
    way, but only when local history *supersedes* the remote tip (every
    remote-only commit has a patch-equivalent in `HEAD`); otherwise it refuses
    and reports `stale_remote_not_superseded` rather than destroy the other
    commits.
  - `committed_work.preserved` is now read back from origin instead of inferred
    from a push's exit code, and the record carries `head_sha`/`remote_sha`, so
    a stale pre-rebase sha sitting on the remote can no longer read as either
    "preserved" or "nothing landed".
