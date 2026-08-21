- **`env-reconcile.sh` now detects a leaked worktree whose branch simply
  LANDED — one whose commits are already contained in `origin/<default>`**
  (temperloop#1404). `classify_worktree` decided `LEAKED_WORKTREE:MERGED` from
  `merged_detect_is_merged` alone, and that helper is built for the opposite,
  merge-queue/squash topology where a merged branch's tip is *not* an ancestor
  of `origin/<default>`: its `gh pr view <branch>` probe returns nothing when
  no PR was ever opened under that head-branch name, and its patch-equivalence
  fallback is inconclusive over exactly the empty cumulative diff that
  "contained in `origin/main`" produces. Both fail open to `false`, so the
  whole class reported `OK` forever (observed 2026-08-13:
  `<repo>.wt/land-probe-cwd-873` — clean tree, no PR, tip an ancestor of
  `origin/main` — a leak the reconciler never surfaced, removed by hand). The
  classifier now carries the cheap, network-free plain-ancestor arm its sibling
  `scripts/prune-merged-branches.sh` has had since #173, emitting the same
  `MERGED` reason. Two guards keep it from calling live work a leak
  (temperloop#658's direction): ancestry must be **strict**, so a just-created
  worktree whose tip *equals* `origin/<default>` (no commits of its own) stays
  live, and an **`OPEN` PR** holds the arm back — GitHub saying the branch is
  still in flight outranks local containment. The verdict still routes through
  `_worktree_verdict`, so a landed worktree carrying uncommitted work is
  `DIRTY_WORKTREE:MERGED`, report-only.
