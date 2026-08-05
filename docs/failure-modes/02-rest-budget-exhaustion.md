---
title: Consolidating onto one API surface removes the relief valve a prior fix depended on
---

## The failure

A CI-automation pipeline had, at one point, split its calls to an external
API host across two independently-metered surfaces: a project-board
integration that could only be reached over GraphQL, and everything else —
issue/PR CRUD, CI-check polling — reached over that same host's separate
REST budget. That split was itself the fix for an earlier incident: a
convenient "watch until done" CI-check helper turned out to be
GraphQL-backed under the hood, and routing it onto REST instead relieved a
shared GraphQL budget the board integration also depended on.

Later, the board integration itself was migrated off GraphQL entirely — a
plain-REST issues backend replaced the GraphQL-only project board, removed
once every consumer had crossed over. That removal was correct and
deliberate, not a regression. But it had a side effect nobody had scoped for
during the migration: with the GraphQL arm gone, **every** remaining call
this pipeline makes — board reads and writes, CI-check polling, ordinary
issue/PR porcelain commands — now shares the **one** REST budget. The two
independently-metered surfaces the earlier fix relied on had quietly become
one, and nothing re-examined whether that was still safe.

## The mechanism

The earlier guard's mitigation was never "reduce call volume" in the
abstract — it was "move this specific high-frequency caller to a *different*
metered bucket than the one under pressure." That works exactly as long as
two conditions hold: there are two buckets, and the caller you moved doesn't
end up back on the one you moved it away from. The board-adapter migration
broke the first condition without anyone checking whether it also broke the
second — the board reads that used to spend GraphQL points now spend REST
calls too, landing right back on the same budget the CI-check poller was
moved onto specifically to get *away* from board-adapter contention.

REST's cost accounting differs from GraphQL's (call-count-based rather than
flat-per-query-regardless-of-size, in the API this pipeline talks to), but
the volume lesson from the original incident still holds: **what drains a
call-count budget is the number of calls, not their individual weight** —
a poller that used to be "the GraphQL problem" is now, structurally, "the
REST problem," just with the labels swapped. The one thing that changed for
the worse is that there is no longer a second, unrelated bucket a caller can
be moved to as a quick relief valve — a drain now has to be fixed at its
source (fewer calls, more caching, coarser polling), not routed around.

Compounding this: the board's own per-item and whole-board read caches were
tied to the now-removed GraphQL arm and were retired along with it. The
plain-REST issues path they were replaced by is **fully live** — every read
is a real network call, with no cache layer in front of it absorbing a
redundant re-read the way the old arm's cache did. So the same migration
that merged two budgets into one also removed the one piece of machinery
that had been quietly keeping call volume down on the surface most likely to
be hit repeatedly in a tight loop.

## The guard

The instrumentation built to diagnose the *original* (two-budget) incident
turned out to be exactly what was needed here too, once retargeted rather
than deleted:

- **Per-call attribution stays load-bearing, arguably more so.** The
  passive call-logger shim's GraphQL/REST/porcelain classification
  (`workflows/scripts/gh-call-logger.sh`) was never actually about
  GraphQL specifically — it derives its classification from each call's
  arguments at report time, so it keeps working unchanged in an all-REST
  world. With no second budget left to separate one subsystem's
  contention from another's by construction, this per-call attribution is
  now the *only* way to tell which subsystem is responsible for a drain,
  not one signal among several.
- **A synthetic before/after anchor beats trusting a "feels faster/slower"
  impression.** The bench harness (`workflows/scripts/probe/gh-bench.sh`)
  runs the same fixed set of adapter operations every time and snapshots
  the REST `core` budget around the run, so a real regression is visible
  as a number, not a vibe — and it still snapshots the (now informational)
  GraphQL figure too, so a stray GraphQL call from outside the tracker
  path stays visible if one ever shows up.
- **A budget consolidation is itself a review trigger.** Moving a caller
  off a shared resource is a fix that quietly expires the moment something
  else moves onto the *same* resource it was moved to relieve. Any change
  that merges two previously-separate metered surfaces into one — a
  backend migration, a provider consolidation, a shared-account rollout —
  should explicitly re-ask "does the two-budget-era mitigation this system
  depends on still hold with one budget?" rather than assuming a prior fix
  keeps working just because nothing about *it* changed.

The general lesson: a fix that works by relocating load onto an
independent, differently-metered resource is only a fix while that
independence holds. When a later, unrelated change collapses the two
resources back into one — often for good reasons that have nothing to do
with the original incident — the mitigation silently stops applying, and
the failure it was built to prevent can recur on the surface everyone
thought was already safe.
