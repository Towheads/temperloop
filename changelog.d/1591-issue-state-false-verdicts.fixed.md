- **`issue-state.sh resolve` can no longer fabricate a verdict for a target it
  never read** (temperloop#1591, #1518; epic #1626). The probe every `/fix` run
  starts with — before any mutation — collapsed *every* failure of
  `gh issue view` into `{}` (`... 2>/dev/null || echo '{}'`), and the next line's
  `jq -r '.state // "OPEN"'` then invented an open issue out of it. A
  **nonexistent** number resolved `route: fresh` with `issue_state: open`, so a
  consumer would claim-first and drive a target that does not exist (found live
  by `/fix 1710` in a temperloop checkout, aimed at `Towheads/foundation#1710`).
  A **transient** failure — auth, rate-limit, network — was indistinguishable
  from that genuine 404. And because the terminal arm tested one specific value
  (`= "closed"`), a **merged pull request** number fell through to the same
  `fresh` default, emitting `issue_state: merged` beside
  `reason: "open, unclaimed, no linked PR"` — the self-contradiction epic #1626
  is named for.

  The read is now a three-way envelope (`ok` / `not-found` / `error`) instead of
  a swallowed `{}`, and the route table gained three **terminal** arms ordered
  ahead of every other: `not-found` (`issue_state: absent`), `probe-failed`
  (`issue_state: unknown` — the state is genuinely unknown, which is not the
  same as open), and `not-an-issue` for a pull-request target, discriminated by
  the `url` field's `/pull/` vs `/issues/` at no extra API call. Only GitHub's
  own "could not resolve to an issue or pull request" signature counts as a 404;
  an unresolvable *repository*, an auth error and a network error all stay
  `probe-failed`, because asserting "this issue does not exist" off a read that
  never reached the issue is the same fabrication in a new costume.
  `already-done` widened from `closed` to any non-open state, a new
  `is_pull_request` field rides the verdict, the two failure routes print one
  human-readable line to stderr, and neither costs the second `gh` call the
  open-PR linkage probe would have made. `resolve` still always exits 0 once it
  has a verdict — failure is carried by `route`, never the exit code, so a
  caller capturing stdout under `set -e` cannot have the honest verdict killed
  out from under it.

  That ordering is what makes the fix structural rather than four patches: no
  arm below it — `fresh` above all — is reachable unless the target is a
  genuinely open issue, so the `reason` string can no longer name a state the
  `issue_state` field contradicts. Sixteen offline fixture cases pin it
  (nonexistent, merged PR, open PR, simulated auth/network/404/bad-repo
  failures, an unexpected non-open state, plus the open/closed baselines), each
  asserting the route *and* running a mechanical cross-field check that the
  `reason` asserts no lifecycle state other than the reported one; all of them
  fail against the previous implementation. `/fix`'s route table gained the
  matching **4g — no drivable target** arm, which touches nothing and reports.
