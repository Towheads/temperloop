---
title: Next
slug: next
---

# Next

## Problem

The bug-to-merged-PR pipeline has several distinct stages (triage, seam
decomposition, plan approval, execution), and a goal's in-scope work can
be sitting at any one of them at any given moment. Without something that
reads across all of it, "what should I actually do right now to move this
goal forward" requires manually checking the board, the plan notes, and
the priorities doc every time — and it's easy to recommend a downstream
move (say, approving a plan) while an earlier blocker for the same goal
(an untriaged issue, an unresolved design question) is still silently
sitting open upstream of it. `/next` is a read-only conductor that answers
that question directly, once, from live state.

## How it works

Given a guiding principle — either passed explicitly or read from a
project's durable priorities note — `/next` locates every piece of
in-scope work across the pipeline and walks it in a fixed, leftmost-wins
order: an unresolved design decision or investigation blocks everything
specced after it; untriaged Backlog blocks seam decomposition; an
unassessed epic blocks plan approval; an unapproved plan blocks execution;
a Ready singleton with no open question or blocker is directly workable.
The single **recommended next move** is always the earliest stage in that
order that still has open, non-blocked work for the goal — never a later,
more attractive-looking move while an earlier blocker sits open. An item
carrying an open native dependency, an unanswered clarification, or a
stuck-execution marker is explicitly treated as not actionable and skipped
over, with the block itself surfaced rather than silently ignored.

Alongside the single recommended move, `/next` previews the **path
ahead**: the ordered handful of further hops the goal will pass through on
the way to done (for example: decompose an epic, approve its plan, run
execution, watch its items merge, watch the epic close). It is a preview,
not an exhaustive plan, and it is never executed automatically — `/next`
recommends a concrete command and stops; the user decides whether and when
to run it.

**The read is cached per session, not repeated on every call.** The first
call in a session does the full cross-pipeline read and writes a small
session record capturing the recommended move and the exact state it was
based on. Every subsequent call in that session reuses the cached
recommendation — re-presenting the same move — as long as a cheap
re-check confirms nothing named in the cached state has actually changed.
Any drift (the epic got assessed, the plan got approved, the issue got
claimed elsewhere, a new or different guiding principle was given, or an
explicit refresh was requested) forces a full reassessment instead. This
cache is deliberately treated as a memo, never as authoritative state —
the board and the plan notes always remain the source of truth it
re-verifies against.

`/next` also reads the session records other active sessions have left
behind, so that two sessions working different goals in parallel don't
both get pointed at the same piece of work. If another session already
owns the move `/next` would otherwise recommend, it recommends the next
non-overlapping move instead and says why.

**Advisory only — `/next` never mutates anything.** Every board or
document interaction it performs is a read. It never flips a status,
creates an issue, writes a plan note, or invokes any other pipeline stage
on the user's behalf; it only ever points at the command the user should
run next.

## Integration

`/next` reads the same board state (through the shared board-adapter
library) and the same plan notes that the rest of the pipeline produces
and consumes, and it reads a project's durable priorities note to
determine or narrow the goal when none is given explicitly. Its own output
— the session record — is purely a private, per-session cache; nothing
downstream reads or depends on it. A stale record left behind by a session
that ended abnormally is pruned automatically on a later run rather than
being treated as still-active state.

## Resource impact

A full reassessment costs one batched board read (not one call per item)
plus a handful of targeted document reads for plan-note statuses and the
priorities note; a cached re-presentation costs only the cheap fingerprint
re-check against the small set of items the cached recommendation actually
depends on, not a full re-read. The session record itself is a small,
short-lived document, deleted deterministically at session end rather than
accumulating indefinitely.

## Telemetry

None. `/next` emits no dedicated telemetry stream of its own; its only
durable artifact is the ephemeral, per-session cache record described
above, which is not a metrics surface. A failure to recommend correctly is
observable directly in the session's own output — a wrong or missing
recommendation is visible immediately to whoever asked — rather than
through any separate stream.
