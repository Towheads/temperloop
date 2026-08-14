- **`temperloop uninstall` now accounts for the machine-scoped testbed
  record as its own scope (f)** (#1358): when the record shows a testbed
  repository still live in the operator's GitHub account
  (`artifacts.repo_created = true`), uninstall names each repository
  explicitly and prints the exact `temperloop testbed --teardown --repo …
  --id …` command for it, instead of saying nothing at all. Before this,
  `bin/subcommands/uninstall.sh` contained zero occurrences of the string
  `testbed`, so the only pointer to a live private repo an operator's
  testbed run had created went unmentioned when they uninstalled. The gap
  was introduced by the record's own placement: #1227 deliberately put it
  in machine-scoped XDG state rather than `.temperloop/` (correct — `eject`
  deletes that directory and the CI round trip runs `eject` mid-flight),
  and that decision moved it outside every uninstall scope that existed at
  the time. **The new scope is print-only**, matching the posture of the
  three advisory scopes already there (bootstrap footprint, eject reminder,
  cache root): removing the pointer without removing the repo would convert
  a recoverable artifact into an unrecoverable one, so uninstall never
  deletes the record or the repo — teardown stays `temperloop testbed
  --teardown`'s job. That property is asserted, not assumed: the new test
  diffs the record file byte-for-byte across `uninstall --yes`. The
  no-record and empty-record cases print nothing rather than a dead-end
  "you may have leftover state" line.
