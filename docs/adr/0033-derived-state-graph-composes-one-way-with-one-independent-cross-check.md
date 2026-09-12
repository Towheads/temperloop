---
title: "0033: The derived state graph composes one way, and one independent cross-check survives"
---

## Status

Proposed

## Context

One piece of work's state is scattered across the board, git worktrees,
open pull requests, plan notes, the build workflow's own journal, and
per-window tmux markers. Nothing owns the union today. Recovery from a
crashed session, an overlapping claim, or a status write left in flight
falls to at least nine hand-written reconcile scripts plus a prose
"authority ordering" table a model re-executes on every `/build` resume.
The recurring failure shape is a typed state (`unknown`, `absent`,
`pending merge`) collapsed into an untyped one (`empty`, `closed`,
`done`) at a join nobody guards, because every consumer re-derives its own
join over the same sources instead of reading one already-typed
projection.

epic: Towheads/temperloop#1910 — ratified brief
`Designs/temperloop - graph of record` (private knowledge store)

## Decision

`state-graph.sh build --board N` builds one derived snapshot per repo,
read-only, from exactly these sources: one `board_resolve` (issue state
and native `blocked_by`/`sub_issue_of` edges), one `gh pr list --state
open` (PR nodes and `closes` edges), `git worktree list`, the approved or
in-progress plan notes, the build workflow's journal, and the tmux window
markers. The snapshot is written through the existing board cache library
(`workflows/scripts/board/lib/cache.sh`) — its repo-keyed directory, its
atomic temp-then-rename write, and its `cache_dirty` invalidation are
inherited, not reimplemented. Every source carries a typed status —
`ok`, `absent`, `error`, or `stale` — never collapsed to a bare empty
result; a query that depends on an absent or errored source answers
`unknown` for that part, never an empty set, because an empty set standing
in for "I don't know" is exactly the bug class this design exists to end.
The graph is strictly one-way: nothing that writes to a source ever reads
the graph back, and the graph is never treated as a lock — the board claim
stamp remains the only cross-session lock.

`state-graph.sh query <name>` answers `status-drift`, `stale-claims`,
`unlinked-prs`, `orphan-worktrees`, and `resume` (the Step 0.5 authority
ordering as one ranked merge, emitting routes from the ontology
registry's route alphabet). Once a fourteen-day soak (a `kind: spike` item
with a written kill condition) shows `query status-drift` matching
`reconcile.sh --status` daily, including one day audited by hand against
the live tracker, the existing bespoke reconcile lenses (`reconcile.sh
--labels`, `--marker`, and `env-reconcile.sh`'s worktree lens) become thin
wrappers over the matching query, each keeping its command line and
deleting its own bespoke join in the same PR. **`reconcile.sh --status` is
kept permanently as the one exception** — an independent join that never
becomes a wrapper, so a confidently wrong snapshot can still be caught by
disagreement. This was an explicit operator decision at the design's
review fold-back; any disagreement between it and the snapshot files a
bug on the graph-update milestone.

## Consequences

**Benefits.** Every consumer of "where does this stand" — `/build`'s
resume, `/fix`'s probe, `/next`, `/sweep`'s pool filters, `/tidy`'s
store-comparison sweeps — reads one typed projection instead of
re-deriving its own join, so the collapsed-state bug class loses its
recurring surface. The typed `ok`/`absent`/`error`/`stale` status per
source makes a missing or degraded input visible in the Step 6 build
summary instead of silently returning nothing. REST cost falls rather
than rises: the state graph's one `board_resolve` plus one `gh pr list`
replace the three separate resolves the reconcile lenses make today.

**Costs — two accepted risks, named rather than hidden.** First, a new
state store introduced after this ships and never wired into a reader is
not `absent`, it is invisible, and every consumer of the shared snapshot
silently inherits the blind spot; the ontology registry's `source` axis
(ADR 0032) is the mitigation — a new store must be declared there first —
but no lint can detect an undeclared store, so this stays a standing risk
the verdict note names rather than one a mechanism closes. Second, the
eventual move from one JSON snapshot file to SQLite is a measured trigger,
not a design-time judgment call: the named setting
`STATE_GRAPH_QUERY_SLOW_MS` in `build.config.sh` is the threshold, tripped
only once a bench run shows a query actually crossing it at scale.

**Follow-on work.** The soak's verdict note records the daily diff, the
scale-benchmark curve, and either *proceed* (unlocking the merge-gate
workflow and the triples extractor that build on this graph) or *stop*
(leaving only the ontology registry and the graph-traversal library
behind as net deletions). A `state-graph` per-build telemetry record
(node count, edge count, drift found, build time) ships only after a
*proceed* verdict, so no stream is added for a mechanism that might still
be killed.
