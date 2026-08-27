- **The `pending`-milestone workaround on the six retro trackers is unwound**
  (#1814, follow-up to the #1614 intake exclusion). The hand-applied `pending`
  milestone is cleared from trackers #851 #1346 #1361 #1396 #1576 #1598 (board
  write via `board_set_milestone`, precondition-checked per issue), now that the
  `retro-pending` process-record label exclusion keeps them out of `/triage`
  intake on its own. `/triage`'s inactive-milestone example no longer cites
  `pending` as a kernel-board milestone — `pending` is not a release phase, and
  citing it implied the superseded workaround. The `pending` milestone itself is
  left in place (other issues still carry it); `/build` 4d-retro already mints
  trackers with no milestone, unchanged.
