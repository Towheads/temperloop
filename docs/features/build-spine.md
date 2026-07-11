---
title: The build spine — worktree isolation, dependency levels, the quota gate, and the plan note as run record
slug: build-spine
---

## Problem

`/build` executes an approved plan note item by item, often several items in
parallel, each driven by its own agent. Left to an LLM orchestrator
improvising shell commands turn by turn, four things reliably go wrong:

- A worker's file writes can escape its own isolated checkout and land,
  uncommitted, in whichever tree the orchestrator happens to be sitting in —
  contaminating unrelated work with no connection back to the worker that
  caused it.
- Watching a pull request's checks to completion is one API call away from
  quietly burning a shared, metered rate-limit budget that other operations
  (a project board, in this repo's case) also depend on — the convenient
  "watch until done" helper for CI checks is GraphQL-backed, and several
  workers polling in parallel for the length of a CI run adds up fast.
- A long unattended run has no way to know it is about to exceed its own
  usage window until a call fails mid-step, at which point the run stalls
  hard instead of pausing and resuming on its own.
- Progress and resume state kept only in an agent's own conversation is
  gone the moment the session ends. A run interrupted between two items —
  or a level whose merge gate nobody has consented to yet — has nothing
  durable to resume from.

## How it works

The build spine is a small set of deterministic scripts that own the parts
of `/build` that are pure functions of observable state with a closed
outcome set — every worktree operation, every CI poll, the quota check, and
the plan-note read/write — so the LLM orchestrator invokes them and branches
on a structured JSON outcome instead of hand-rolling `git worktree` or a
polling loop itself.

**Worktree isolation and dependency-level gating.** `worktree.sh` gives
every plan item a deterministic, git-worktree-isolated checkout: `create`
adds `<repo-root>.wt/<slug>` on branch `build/<slug>` (based on the default
branch) and drops a small marker file in the new worktree root that a
pre-write guard hook checks before honoring any file write — a write whose
resolved path falls outside the worktree it was issued in is rejected at the
source, not merely detected afterward. `remove` and `prune` clean up a
finished or merged worktree and its marker together, and `deps-merged`
answers a single yes/no question — are all of these SHAs actually merged
into the default branch yet — which gates a dependent item's worker from
starting on work whose prerequisite has only reached a merge-pending state,
not landed.

Items are partitioned into **dependency levels** by `plan.sh toposort`,
which walks the union of a plan's `depends-on` and `after` edges: level 0 is
every item with neither edge, and each subsequent level depends only on
items in a prior one. `/build` runs a whole level's items in parallel — one
worktree, one worker, one PR per item — and gates before starting the next
level, so parallelism is bounded by genuine independence rather than by
guesswork.

**Why CI polling uses REST, not GraphQL.** `ci-poll.sh` watches a pull
request's check-runs to completion by polling `gh api` against the REST
check-runs endpoint at a coarse interval (30 seconds by default), deliberately
never using the built-in streaming "watch" helper — that helper is
GraphQL-backed, and GraphQL's cost accounting is flat per query regardless of
how much a single query returns. Run several build workers in parallel, each
watching its own PR every few seconds for the multi-minute length of a CI
run, and that dwarfs anything else sharing the same GraphQL budget (in this
repo's case, project-board reads and writes, which have no REST equivalent
and so cannot be moved off it). Routing the high-frequency polling onto a
separate, REST-backed budget leaves the GraphQL budget for the calls that
have nowhere else to go. The poll resolves the PR's head SHA once and
reports one of `CI_GREEN`, `CI_FAILED` (with the failed run IDs), or
`TIMEOUT` — never prose, so the orchestrator branches on the outcome
directly.

**The 5-hour quota gate.** `quota-gate.sh` reads a locally persisted
rate-limit snapshot after each level (or, in the sweep pipeline, after each
fix) and decides whether the run may proceed or should pause. Its verdict is
one of `proceed`, `pause` (with a wait duration and the window's reset
timestamp), or `unavailable`. The gate never sleeps itself — the calling
command backgrounds a `sleep` for the reported wait and re-invokes the gate
on wake, resuming once the window has actually rolled rather than on a fixed
timer. Critically, the gate is **fail-open**: a missing, stale, or
unparseable snapshot resolves to `unavailable`, and `unavailable` always
means "proceed" — a run must never stall merely because the quota signal
itself is absent.

**The plan note as run record.** `plan.sh` is the sole path by which
`/build` reads and mutates a plan note's execution state. `validate` checks
the plan against its schema before a run starts; `toposort` computes
dependency levels (above); `writeback` flips an item's checkbox sentinel —
`[ ]` untouched → `[~]` in progress → `[m]` merge-pending (CI green, parked
for the batch merge gate) → `[x]` merged, with `[v]` (verdict-captured, no
PR) and `[-]` (skipped) as the two non-merge terminal states — and stamps
sub-lines recording the item's PR number, pushed SHA, and a human-readable
run-status line. Because every one of these writes goes through the same
single indirection, the plan note itself becomes the durable, resumable
record of a run: a session that resumes hours or days later re-reads the
plan note's sentinels rather than any conversational memory, and a batch
merge gate that a level is currently parked at is visible directly in the
note rather than inferred from anything ephemeral.

## Integration

`/build` (`claude/commands/build.md`) is the sole orchestrator that drives
these scripts, at the steps their own headers name (worktree create/remove
at 3b/3h and the stranded-worktree sweep at Step 0.5; plan validate/toposort
at Step 1 and writeback throughout; the CI poll at 3g; the quota gate at
each level boundary). `/sweep` reuses the quota gate the same way, after
each individual fix rather than after a whole level. Every tunable each
script reads — the quota pause threshold, poll intervals and timeouts, the
CI-poll wait buffer — has its one default in `workflows/scripts/build/build.config.sh`,
which every spine script (and the command steps that call them) sources
before referencing the knob by name, so a value never has to be duplicated
across scripts and any override applied at a higher precedence rung is
honored everywhere at once.

## Resource impact

Each active plan item's worktree is a full working-tree checkout of the
repository on disk — the `prune` subcommand reclaims completed or merged
worktrees so this does not grow unbounded across a long-running project. CI
polling runs against the REST rate-limit bucket (`gh api`'s core budget)
rather than the shared GraphQL budget; a poll's cost scales with the
interval and the CI run's wall-clock length, not with the size of what a
single call returns. The quota gate itself reads a small local snapshot file
and performs no network calls, so its own overhead is negligible — the
resource it protects is the run's usage-window budget, which a pause avoids
exceeding at the cost of wall-clock time spent waiting for the window to
reset. Plan-note writebacks are small, single-line patches to one file per
mutation.

## Telemetry

None of these scripts emit a dedicated telemetry stream of their own; each
call's structured JSON outcome (`{"outcome": ...}`) is the observable
surface, and a failure shows up directly in that outcome rather than in a
side channel — a stalled CI poll surfaces as `TIMEOUT`, a stranded worktree
is caught by the Step 0.5 sweep the next run performs, and an unavailable
quota snapshot surfaces as `unavailable` (never a silent stall). The plan
note's own sentinel trail is itself the closest thing to a telemetry log for
a run in progress: grepping a plan note for `[~]` or `[m]` shows exactly
what is in flight at any point without needing a separate dashboard.
