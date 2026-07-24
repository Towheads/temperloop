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

**On an attended run with a chunk width above one, an overlap tier (tier
2) folds the operator's question-answering time into build time.** Once
Phase-1 detection has split the pool into a clean set (no open question)
and a flagged set, the first clean chunk launches as a *background*
invocation before the question batch is even presented: the launch
returns immediately with a task handle, and a completion notification
re-invokes the driver when the chunk finishes — so the operator answers
clarifying questions while the first chunk builds concurrently. Issues
whose questions get answered during the batch accumulate into a **tail
chunk** — driven in that same run, sequenced after any chunk whose merge
pass is still pending and behind the same between-chunk release-management
gate as every other chunk (a usage check run between chunks that pauses
the run when remaining quota is low and auto-resumes it in-session once
headroom returns) — so an answer given mid-run is consumed
immediately rather than waiting for the next run. The overlap tier runs
only when four conditions all hold: the run is attended (a live
operator), the chunk width exceeds one (width one restores full legacy
semantics — sequential drive and questions-first ordering, overlap
disabled), background invocation is available in the harness, and the
run is not a rehearsal (`--dry-run`). An
unattended or headless run never uses the overlap tier — it has no
background-completion re-invoke loop — and keeps the synchronous chunked
path unchanged. If the background launch turns out to be unavailable or
is refused at run time, the run emits an explicit degradation notice
(what was skipped, why, and that results and coverage are unaffected —
only the wall-clock overlap is lost) and falls back to the synchronous
path; the fallback is a designed floor, never a silent behavior change or
a stall. A rehearsal run (`/sweep --dry-run`) never launches anything in
the background: it prints which issues would have formed the overlapped
first chunk and which would have gone to the question batch. Its
zero-mutation guarantee is literal — a dry run does not claim, merge,
park, comment, label, or launch anything; it only prints what would
happen.

Every pooled issue reaches one of a small set of terminal outcomes by the
end of a run — merged, resolved as a verdict-only item, or parked on an
open question — and the run structurally cannot report success while an
issue is left with no recorded outcome: an explicit tracked checklist,
verified complete immediately before the summary is produced, is what
makes silently skipping an issue impossible rather than merely unlikely.
That guarantee is deliberately tier-agnostic: an issue driven by the
overlapped background chunk is tracked on the same checklist as one
driven synchronously, so a background chunk whose completion notification
is lost surfaces as unchecked entries at the pre-summary assertion rather
than vanishing silently.

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
letting a run burn through headroom that other work also depends on. The
overlap tier additionally depends on the conversational harness's
background-invocation contract — an immediate task-handle return plus a
completion notification that re-invokes the driver — which exists only
for an attended conversational session; the gating and degradation
behavior that follows from that dependency is described in the
overlap-tier paragraph under "How it works" above.

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
flat, one-at-a-time footprint. The overlap tier does not raise that
ceiling: only one chunk ever builds at a time — the overlapped first
chunk runs concurrently with the operator answering questions, not with
another chunk — so the concurrency cap stays the chunk width; what the
overlap buys is wall-clock, by reclaiming operator think-time that a
synchronous run would spend idle.

## Telemetry

Each run appends one JSON-lines record to the same append-only, monthly-
rotated raw telemetry stream `/triage` writes to, carrying the size of the
pool actually driven, how many issues merged or resolved, and how many
were parked. As with `/triage`, the record's own absence for a run that
should have executed is the observable failure signal, rather than
anything more elaborate.
