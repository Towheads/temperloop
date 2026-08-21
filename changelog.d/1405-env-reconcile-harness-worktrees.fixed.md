- **`env-reconcile.sh` now surfaces harness agent worktrees as their own named
  class with a remedy pointer, instead of letting them hide inside the parent
  checkout's opaque `DIRTY`** (temperloop#1405). Claude Code's own agent
  isolation (`isolation: "worktree"`) creates worktrees under
  `<checkout>/.claude/worktrees/agent-<id>/` — inside the checkout, untracked,
  on a machine-made `worktree-agent-<id>` branch. The reconciler only ever
  walked the `<repo>.wt/<slug>` layout `worktree.sh` uses, so these were never
  classified at all; what an operator saw was the *parent* checkout reporting a
  bare `DIRTY` (cron role) or `STALE_UNTRACKED:.claude/worktrees/` (operator
  role) — a class with no remedy pointer that said something was there but not
  what to do, and masked any real drift beside it. Observed live on 2026-08-13
  across two checkouts (4 worktrees 8 days stale, 3 worktrees 27 days stale,
  plus their leftover `worktree-agent-*` branches). Three changes.
  **A second scanned layout:** `<checkout>/.claude/worktrees/` is now walked
  beside `<repo>.wt/`, under every cron and operator checkout that has one
  (path-configurable via `ENV_RECONCILE_HARNESS_WT_SUBDIR`). **Its own class,
  with the remedy on the finding line:** `HARNESS_WORKTREE:ACTIVE` (inside the
  staleness horizon — reported on its own line, never counted as drift, since a
  live agent may still be working in it), `HARNESS_WORKTREE:STALE` (past the
  horizon and confirmed clean — the only removable one, and its finding carries
  the exact `worktree remove` **plus** `branch -D` command, so the invisible
  half of the leak gets cleaned up too), and the report-only
  `HARNESS_WORKTREE:STALE_DIRTY` / `STALE_UNCERTAIN`. **No double-reporting:**
  the parent checkout's `DIRTY` / `STALE_UNTRACKED` tests now exclude that one
  path prefix *because* it is classified in its own right — every other dirty
  or untracked path still reports `DIRTY` exactly as before, so nothing real
  gets swallowed. `/tidy`'s env-hygiene step auto-heals `HARNESS_WORKTREE:STALE`
  only, on the same never-`--force` terms as `LEAKED_WORKTREE`.
