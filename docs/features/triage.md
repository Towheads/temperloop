---
title: Triage
slug: triage
---

# Triage

## Problem

Without a front door, a project's Backlog accumulates issues with no
consistent judgment applied to them: duplicates never get closed, symptoms
of the same root cause get worked as separate fixes, and unrelated findings
get bundled into epics that make no logical sense together. Nothing decides
what actually deserves to move forward, or what belongs with what, before
work starts on it — so time gets spent building the wrong things, or
building the right thing five separate times. `/triage` is the one place
that logical judgment happens, once, before anything downstream (seam
decomposition, execution) begins.

## How it works

`/triage` reads a board's **Backlog** (optionally alongside pasted-in
analysis-doc findings) and walks a fixed decision tree, in order, over the
whole candidate set:

1. **Cull.** Drop candidates that are dupes, won't-fix, stale, or already
   fixed (re-verified against the current default branch — a dated Backlog
   item is often already resolved).
2. **Root-cause collapse.** Collapse N symptoms that trace to one underlying
   fix into a single survivor, noting the absorbed symptoms in its body.
   This is a *logical* merge (same cause) — distinct from a later, purely
   *physical* dependency edge.
3. **Group-by-meaning.** Cluster the surviving candidates by shared theme or
   root cause. A cluster of two or more becomes a candidate epic. Grouping
   by "these touch the same file" is explicitly rejected here — that is a
   *physical* fact, decided later during seam decomposition, never a triage
   grouping reason.
4. **Value / priority.** Order survivors and groups by value and assign an
   integer sequence value (lower = sooner). This is the *logical* ordering
   only; *dependency* ordering across items is a later stage's job.
5. **Route decision-only items off-board.** A candidate that is "decide X"
   rather than "build X" is not epic material — it gets written up as a
   short rationale note and taken off the Backlog, re-entering the pipeline
   later only if the decision spawns real build work.

Every survivor that clusters (two or more members sharing a theme)
materializes as a durable **epic**: a parent issue plus the members linked
as native sub-issues — a status-orthogonal relationship that survives
renames and board moves. A lone survivor gets no epic; it is routed
directly per its own release-phase activity.

**Backlog → Ready is the triaged signal.** A survivor's status flip from
`Backlog` to `Ready` is the durable mark that the logical decision tree has
already run over it — `/triage` only ever reads `Backlog`, so an item that
has already reached `Ready` (or later) is automatically excluded from being
re-processed on the next run. This makes re-running `/triage` idempotent
with no separate ledger: issue and epic creation is probe-before-create, so
a re-run adopts existing artifacts instead of duplicating them, and the flip
side is that the *only* way to send an already-`Ready` item back through
triage is to move its status back to `Backlog` by hand. `/triage` also
assigns every unassigned survivor to a release phase and only flips a
survivor to `Ready` when that phase is currently active; a survivor whose
phase isn't active yet stays in `Backlog` and defers automatically until the
phase is activated.

Every candidate that survives the tree is also stamped, per-survivor, with
a handful of carried-forward flags used only by the *next* pipeline stage:
whether it is genuinely underspecified (so the question gets recorded and
routed rather than guessed at), whether it follows an established pattern
or establishes a new one, and — in a checkout that vendors a shared kernel
of generic tooling alongside project-specific content — whether the fix
belongs upstream in that shared kernel rather than in the current repo.

Before any board mutation, `/triage` prints the full set of planned writes
— epics to create, singletons, phase assignments, routing, culls, decision
routes — and gates them behind a single batched confirmation, rather than
asking about each item individually.

### Reviewing what's pending on you

Several pipeline stages can park a piece of work by handing it back to the
operator: a question that has to be answered before a fix can start, a
design choice offered as a closed set of options, or a code change an
automated driver could not land on its own and needs a human to merge or
abandon. Each of these assigns the operator at the moment it is raised, so
"assigned to you" is already a reliable marker for *this one is waiting on
a person*. The counterpart automation that consumes the operator's reply
already exists for each; what was missing was anywhere to actually give it.
The standing expectation was that the operator work a saved issue-search by
hand and page each item's context in from scratch, one at a time.

An optional final step (`--feedback`) closes that loop. It reads the whole
pending set in one search — everything open on this board's repo assigned to
the operator and carrying one of those three markers — and walks it **one
item at a time, with that item's context already assembled**: what parked
it, the question or choice verbatim, the parent epic it belongs to, and,
for a stuck code change, the pull request and its current test verdict.
This is deliberately a sequence rather than a single bulk prompt: each item
is a direction to choose, and the value is in seeing one full picture at a
time. The batching that helps is at the *sitting* level — answering the
queue in one pass, in the same headspace as the rest of triage's batched
judgment — not in collapsing distinct decisions into one question.

Two rules govern how an answer is recorded. First, the answer text is always
written **before** the markers that release the item — a failed write then
leaves the item exactly as it was, to be picked up next run, whereas the
reverse order could leave an item *looking* handled with the answer lost.
Second, how far the step goes depends on what the answer still needs: a
plain clarification is free text the next stage simply reads, so the step
finishes the job and releases the item outright; a typed design choice must
still be translated into an artifact by the automation that owns it, so the
step records the choice, hands the item back, and deliberately leaves that
work to its owner. For typed choices the offered options are read off the
original question and presented **as** the available answers, and the
selected label is checked back against the original text before anything is
posted — so the reply the consuming automation eventually parses can only be
one that automation already offered. That check is what makes the guarantee
real rather than merely likely: the prompt and the parser read different
copies of the question, and only a round-trip against the original closes
the gap between them.

The step is off by default and never fires unmentioned: when it is not
requested and the pending set is non-empty, the run's summary still closes
with a one-line count of what is waiting, on the principle that a queue the
operator has to remember to go look at is a queue that silently grows.

## Integration

`/triage` is the entry point of a four-stage pipeline: candidates culled
and grouped here become epics that a seam-decomposition stage turns into a
structured build plan, which a build-execution stage then carries to
merged, closed work. All board reads and writes route through a shared
board-adapter library rather than ad-hoc API calls, so the same idempotency
and rate-limit protections apply everywhere. `/triage` also folds in a
secondary intake source: a weekly tally of recurring interruption points
(places a run had to stop and ask a question with no good default) is
ingested as its own candidate class, so a repeatedly-annoying missing
default becomes visible board work rather than silent recurring friction.

The optional pending-feedback review reaches across the pipeline rather than
down it. The set it reads is the exact complement of what the automated
driver drains: the driver picks up items the operator has answered and
released, so the ones still assigned to the operator are, by construction,
the ones still waiting on them. That symmetry is why the step needs no state
of its own — it reads a marker every producer already maintains, and its
output is the input those existing drains are already waiting for. It is
also the one part of `/triage` that is purely repo-level: the queue is an
issue search, not a board-field read, so it behaves identically on a project
tracked by a full project board and on one backed only by plain issues.

## Resource impact

Board reads are batched into one resolve call per run rather than one call
per item, and issue/epic creation is probe-before-create, so a re-run over
an unchanged Backlog costs a handful of read calls and mutates nothing.
Analysis-doc ingestion is capped to avoid pulling an oversized document
into the working context outright — large documents are read via an
outline pass with targeted section reads instead of a whole-file read. No
persistent storage is allocated beyond the board itself and the short
rationale notes decision-routed candidates produce.

## Telemetry

Each run appends one JSON-lines record to an append-only, monthly-rotated
raw telemetry stream, carrying the run's candidate counts (board-sourced,
doc-sourced, and recurring-interruption-sourced), how many were promoted to
`Ready`, and how many were left behind in `Backlog` for any reason (an
inactive release phase, an open dependency, or intake deferral). The
absence of this record for a run that should have executed is itself the
observable failure signal — a presence check over the stream catches a run
that silently stopped emitting before it catches anything else.
