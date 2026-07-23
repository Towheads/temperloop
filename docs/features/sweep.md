---
title: Sweep
slug: sweep
---

# Sweep

## Problem

Not every triaged issue is epic material — a lone, ungrouped fix has no
natural home in the seam-decomposition-and-build-plan machinery built for
multi-item epics, yet it still needs to move from triaged to merged
somehow. Left alone, these "singleton" issues either get bundled into
awkward one-item plans (paying planning overhead for no real
decomposition) or sit untouched because nothing owns draining them.
`/sweep` exists to drain exactly this pool — the triaged, Ready issues
that are not a sub-issue of any epic — one at a time, without requiring a
plan note for each.

## How it works

`/sweep` is the singleton-path peer to the epic-execution stage: that
stage drains the *epic'd* work via a structured plan; `/sweep` drains the
*ungrouped* Ready issues directly from the board. Together the two cover
the whole Ready pool with no overlap — an issue with a parent epic belongs
to the plan-driven path and is skipped here; an issue with no parent
belongs here.

Because singletons skip the seam-decomposition stage entirely, they arrive
with no pre-execution round of contract clarification the way an epic's
members do. `/sweep` compensates with its own **Phase 1**: an upfront,
one-time question sweep across the whole pool. The judgment of which
unflagged issues are underspecified fans out across parallel read-only
subagents, whose model tier is set by the `SWEEP_DETECT_MODEL` knob — its
empty default deliberately inherits the session's own model, because
ambiguity detection is judgment work and a missed ambiguity is the costly
failure mode. Any issue that is flagged as needing clarification (whether
already flagged at triage time, or newly judged underspecified here) has
its open question surfaced in one batch; answers are recorded back onto
the issue and its clarification marker is cleared so it becomes drivable.
Any issue left unanswered simply stays flagged and re-enters the next
run's Phase 1 automatically — nothing is lost, and nothing blocks the rest
of the pool.

**Phase 2 then drains the remaining pool in chunked parallel fanout.** The
set is partitioned, in pool order, into chunks of up to
`SWEEP_FANOUT_WIDTH` issues; each chunk is one multi-item invocation of
the identical claim-worktree-fix-gate-PR-CI mechanics already used
elsewhere in the pipeline — the same within-level parallel path epic
execution uses — run synchronously to completion, followed by a per-chunk
merge pass that disposes every issue in the chunk (merge the green PRs,
close the verdict-only items, park the escalations) before the next chunk
launches. Setting `SWEEP_FANOUT_WIDTH=1` restores the legacy behavior
exactly — strictly sequential drive and questions-first ordering — as a
config-only rollback lever. Issues known to touch the same shared file are
never placed in one chunk; the later one is deferred to a following chunk
so it rebases onto its sibling's merged result. If an issue's fix work
hits a genuine question or blocker partway through, `/sweep` never halts
the whole run to ask about it interactively — it parks that one issue back
onto the board with its question recorded as a comment and a clarification
marker attached, then simply continues disposing the rest of the chunk. A
parked issue is picked back up automatically by a later run's Phase 1,
once its question is answered. Because a driving chunk holds several
claims at once (a multi-claim window), the park path's claim-marker
release is best-effort by design: the release helper correctly refuses to
clear a non-latest marker, that refusal is expected and non-fatal, and the
claim is simply held until the issue reaches its terminal state.

Every pooled issue reaches one of a small set of terminal outcomes by the
end of a run — merged, resolved as a verdict-only item, or parked on an
open question — and the run structurally cannot report success while an
issue is left with no recorded outcome: an explicit tracked checklist,
verified complete immediately before the summary is produced, is what
makes silently skipping an issue impossible rather than merely unlikely.

## Integration

`/sweep` reuses the same per-issue build mechanics (claim, isolated
worker, acceptance gate, push, PR open, CI poll) that epic execution uses
for each of its items, invoked here as a chunk-sized multi-item level
driven through the very same within-level parallel machinery — there is no
separate, parallel implementation of the fix loop. It reads the board
through the same shared adapter library `/triage` and the
seam-decomposition stage use, and it defers entirely to that shared
library's idempotency and rate-limit protections. `/sweep` also composes
with the same release-management gate the rest of the pipeline honors —
checked between chunks, at the same clean boundary where merges batch —
pausing and auto-resuming later in-session if usage runs low rather than
letting a run burn through headroom that other work also depends on.

## Resource impact

The board is read once per run to build the singleton pool, not once per
issue. Each pooled issue costs exactly one lightweight parentage check to
confirm it isn't secretly an epic member. Because each chunk invocation is
a fresh, isolated process whose workers' contexts are discarded on return,
memory and context usage stay flat regardless of pool size — nothing
accumulates across issues or chunks within a single run. The fanout does
change the run's concurrency posture: up to `SWEEP_FANOUT_WIDTH` issues
build and run CI at the same time, so board work-in-progress and
concurrent CI load both rise to at most the chunk width (the same posture
epic execution already has per level); `SWEEP_FANOUT_WIDTH=1` restores the
flat, one-at-a-time footprint.

## Telemetry

Each run appends one JSON-lines record to the same append-only, monthly-
rotated raw telemetry stream `/triage` writes to, carrying the size of the
pool actually driven, how many issues merged or resolved, and how many
were parked. As with `/triage`, the record's own absence for a run that
should have executed is the observable failure signal, rather than
anything more elaborate.
