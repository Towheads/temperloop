- **`env-reconcile.sh` no longer describes a directory layout the host stopped
  having, and an abandoned operator checkout stops reading as a bare `OK`**
  (#2041). The comment beside the checkout registry asserted that the operator
  clone of the kernel repo "owns the `temperloop.wt/*` worktrees" — true when
  written, silently inverted once the `batch/` layout arrived: measured
  2026-09-15, the operator clone was 544 commits behind with zero worktrees
  while the cron clone held both live ones. It is rewritten to explain the ROLE
  distinction (which baseline each clone is classified against) and to assert
  nothing about which concrete directory currently holds worktrees or gets
  pulled, so it cannot go stale against one host's habits again — the
  classifier never read that claim anyway, since worktrees are discovered by
  scanning `<checkout>.wt/` beside every registered entry in both lists.
  Alongside it, the operator role gains one informational class,
  `DORMANT:<days>d-idle:<n>-behind`: being behind `origin/<default>` stays
  deliberately un-flagged for this role (a checkout may sit on other work), so
  the discriminator between "behind because busy" and "behind because
  abandoned" is LAST ACTIVITY — the newer of HEAD's committer date and the
  newest HEAD reflog ENTRY's own recorded timestamp. Neither mtime is used: the
  index's is refreshed by the reconciler's own `git status`, and the reflog
  FILE's is rewritten by `git gc --auto` (the motivating checkout's reflog was
  zero bytes and dated today while its last real activity was a month old, so
  an mtime reading would have called it active). A checkout that is behind AND idle past
  `ENV_RECONCILE_DORMANT_DAYS` (default 14) now prints its own `DORMANT` line
  instead of `OK`. It raises no alarm, appends nothing to the `--format entry`
  vault surface, and carries no remedy: disposing of an abandoned checkout is
  an operator decision, and the reconciler stays READ-ONLY and fail-open —
  unreadable activity signals emit nothing rather than guessing "abandoned".
