- **A stale tmux claim marker is now cleared automatically, in every window, and
  the window's name is un-frozen** (#1037). Nothing ever cleared the
  `@claimed_issue` marker that paints the `status-right` claim chip: `release.sh`
  is a manual same-window call the task workflow explicitly makes *optional and
  best-effort*, `reconcile --fix` repaired only the caller's own window, and the
  close→Done cascade never reached tmux at all. So a marker outlived its work
  indefinitely — observed live as one closed issue's marker branding all four
  windows of a session for over a month, the status bar asserting a claim that
  had not existed since the previous month. Three changes close it:
  **(a)** `reconcile --fix`'s marker lens now sweeps **every window on the tmux
  server** instead of just `$TMUX_PANE`'s, applying the *same* per-marker gates
  to each. GH #297 (a claim branding a concurrent session's window — the
  regression that pinned every marker *write* to the caller's own) is not
  reintroduced, because what makes a cross-window *clear* safe is the **proof**,
  not the ownership: an OPEN issue, an unreadable state, and a live same-host
  claim are each still refused, in every window, and there is no age-based or
  "looks stale" clear. Branding another window remains forbidden;
  `lib/claim_marker.sh` ships no targeted `set`.
  **(b)** The sweep no longer requires being *inside* tmux — the server is a
  socket, not an environment variable — so `/tidy`'s nightly now runs the marker
  lens with `--fix` and the repair happens without the operator noticing the
  drift and hand-running a command in each affected window. It is the one
  auto-applied repair in that step: unlike releasing a board claim, clearing a
  chip whose issue is provably CLOSED/MERGED touches no board state, no claim
  stamp and no work.
  **(c)** Every clear now also restores that window's `automatic-rename`, which
  `claim_marker_set`'s `rename-window` had turned off — previously the window
  name stayed frozen at the claim string forever. The restore *unsets* the
  window-local override rather than forcing `on`, so an operator who globally
  disabled it keeps their setting.

  Widening the sweep exposed a hazard that needed its own guard: a marker records
  `#<n>` but never which **repo** the number belongs to, and every board numbers
  into the same range, so a sweep of one board would misattribute — and wipe —
  a live claim's marker that came from another. `--fix` now refuses to clear any
  number that is a live In-Progress claim for this host on **any** registered
  board. Relatedly, `make test-board` now strips `TMUX`/`TMUX_PANE`/
  `CMUX_WORKSPACE_ID` from every test's environment, so a board test can no
  longer reach the operator's real tmux server whatever isolation seam it missed
  — the leak path that put a test fixture in the live status bar in the first
  place.
