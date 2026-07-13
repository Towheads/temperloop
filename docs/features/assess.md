---
title: Assess
slug: assess
---

# Assess

## Problem

An epic that has already survived logical triage still isn't buildable: no
one has worked out how it splits into independently-shippable pieces,
which pieces are safe to land in any order versus which must be
sequenced, or what "done" checkably means for each piece. Without that
technical decomposition, execution either serializes everything out of
excess caution (slow) or parallelizes blindly (merge conflicts, silent
scope drift). Worse, a decomposition that describes *how* to build
something rather than *what* it must produce goes stale the moment an
implementation detail changes mid-build. `/assess` is the stage that turns
one triaged epic into a structured, reviewable build plan without ever
re-deciding the logical calls triage already made.

## How it works

Before doing any of that work, `/assess` first checks whether the epic is
*already* assessed: it probes the plan-note store for a note whose epic
link matches the target, and if one exists it warns and stops short of
re-deriving anything — offering to refine the existing note in place,
regenerate a fresh versioned copy, or abort, and defaulting an
operator-absent run to a safe skip. This keeps a second `/assess` on an
already-planned epic from silently re-running the whole decomposition and
clobbering the plan the operator already has.

`/assess` takes exactly one already-triaged epic — its membership is
gospel; `/assess` never re-culls or re-groups it — and reads either the
epic's native sub-issues (the normal case) or, for a pre-designed epic
authored with a rich contract body but deliberately zero sub-issues yet,
the epic's own contract section. In the latter mode, `/assess` decomposes
the contract directly into build items rather than stopping, and the tool
that later executes the plan mints the sub-issues under the existing epic
once building starts.

**Decomposition is seam-scoped, not implementation-scoped.** Every item is
defined by its *contract*: what it produces (an interface, artifact,
schema, or verdict), what it consumes (its dependencies), and its
acceptance check — never by a prescription of how the work gets done
internally. This is deliberate: a contract-scoped item stays parallelizable
(nothing downstream needs to coordinate once the seam itself is fixed) and
stays resistant to going stale (an implementation-level learning discovered
mid-build changes the *how*, never the *what*). An item whose description
starts prescribing internals rather than stating a produced/consumed
contract is the smell that decomposition pulled back too far toward
implementation.

Beyond decomposition, `/assess` computes two kinds of ordering edge fresh
on every run — never stored as durable state, since edges churn as the
plan is refined: a conservative "merge-safety" edge for items that would
genuinely conflict if landed out of order, and a looser "logical-order"
edge for items that must follow another's verdict or outcome without
sharing any code. Those edges resolve into dependency levels, and a
verdict-only investigation item (a "spike," producing a decision rather
than a shippable change) is always isolated into its own earlier level so
its verdict can reshape downstream scope before any build work starts
alongside it.

A read-only sanity pass reviews the draft decomposition for hidden
dependencies, mis-labeled edges, oversized items, and weak acceptance
criteria before anything is written. Any *logical* finding that surfaces
during this technical pass — a suspected duplicate, a member that looks
out of scope, work the epic seems to be missing — is never acted on here;
it is recorded and routed back toward triage instead, since authority over
logical judgment flows one way.

The output is a structured plan note, written with `status: draft`, that
the shape of build execution consumes item by item. `/assess` never
promotes a plan to approved — that promotion is a deliberate human
checkpoint.

## Integration

Every plan note `/assess` writes conforms to the repository's canonical
plan-note schema (`claude/plan-schema.md`), which defines the required
frontmatter, the problem/summary/sequencing/items body structure, and the
full set of per-item fields (title, slug, scope, branch, size, acceptance,
and the optional dependency/gating fields). That schema is the single
contract shared by `/assess` (the producer) and the build-execution stage
(the consumer) — see `claude/plan-schema.md` for the exact field-by-field
definition. `/assess` also reads the same shared board-adapter library
`/triage` uses for any board state it touches (reading epic membership and
labels, and — only when a technical finding needs to be routed back —
flipping a member's status back toward re-triage).

## Resource impact

A run reads one epic and its sub-issues rather than the whole board, so
board API usage is bounded and small regardless of board size. The
read-only sanity pass is a single subagent invocation over the draft item
list, not a whole-repository scan. The one persistent artifact a run
produces is its plan note — a small, versioned document, not a bulk data
store.

## Telemetry

None. `/assess` produces no append-only telemetry record of its own; its
observable output is the plan note it writes (or updates), and a run that
silently fails to produce one is visible directly as a missing or stale
`Plans/` entry against the epic it was asked to decompose, rather than
through a separate metrics stream.
