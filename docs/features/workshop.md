---
title: Workshop
slug: workshop
---

# Workshop

## Problem

`/triage` is the funnel's front door for **discovered** work — a Backlog
item, a sweep finding, something already sitting there waiting for logical
judgment. It has no path for work that is *invented* mid-conversation: an
idea that starts as "we should build X," with no Backlog item behind it. Two
epics (K94, K131) were hand-authored this way before `/workshop` existed — a
rich `## Contract` body typed straight into a GitHub issue, with no coverage
checklist run against it and no ritual forcing the hard questions (does this
change a contract surface? what's the uninstall story? what's the telemetry
proxy?) to get asked before the epic exists. `/workshop` closes that gap: it
gives invented work the same kind of structured, checklist-driven front door
that discovered work already had, so a designed epic arrives at `/assess`
having already answered the questions `/assess` and downstream merge gates
would otherwise have to catch late, or never.

## How it works

`/workshop` walks a fixed sequence — intake, coverage walk, review pass,
ratify, materialize — against the coverage template in
`claude/design-schema.md`. It is modal by construction: there is no
unattended arm, because a design ritual has no meaning without a live
operator to make the calls.

1. **Intake.** Establish the problem statement, the customer-visible
   outcome (from a stranger's standpoint, not the implementation's), and the
   kernel-vs-overlay routing call up front — these gate every dimension that
   follows, so getting them right first means the walk isn't re-litigating
   its own foundation later. A brief is created (or, on a re-run, adopted)
   at `Designs/<short title>.md` in the knowledge store.
2. **Coverage walk.** Walk every dimension `claude/design-schema.md` defines
   — seventeen kernel dimensions, plus any overlay additions — and record
   exactly one of three dispositions for each: `filled`, `n/a — <reason>`,
   or `deferred → <tracking ref>`. No dimension is ever left silently
   unaddressed. Dimension 4 (Contract seams: Produces / Consumes /
   Acceptance) gets special care — its content is copied forward verbatim
   into the epic's `## Contract` at materialize time, so it has to read as
   an actual contract, not a summary of one.
3. **Review pass.** A brief-pass tier (two standing lenses,
   `architecture-reviewer` and `requirements-auditor`, on every review) or a
   full-pass tier (the same two lenses plus a red-team lens, a persona pass,
   and — when the design touches the install surface — a mandatory
   *executed* first-run/uninstall persona run). The operator picks the tier
   after being told what each costs; every lens is capability-probed before
   it is spawned, and an unavailable lens degrades to a legible `skipped —
   <agent> unavailable` line rather than a silent no-op. Every finding is
   then folded into the brief, converted to a `deferred` disposition, or
   explicitly declined — nothing is left dangling.
4. **Ratify.** Confirm every dimension carries a disposition, confirm
   dimension 4 reads as a real contract rather than a summary, then ask the
   operator directly: ratify this brief? On approval, the brief's frontmatter
   flips `status: draft → ratified` and becomes immutable — a later change is
   a new, superseding brief, never an edit in place.
5. **Materialize.** A ratified brief turns into four distinct artifacts, no
   content duplicated across them:
   - **The epic** — a board issue carrying the `## Contract` copied forward
     from dimension 4, plus a `design-brief: [[Designs/<note>]]` provenance
     marker line. Creation is probe-before-create, so a re-run adopts an
     existing epic rather than duplicating it.
   - **Draft ADRs** (Step 5c) — for every architectural call the brief makes
     that passes the stranger test, `/workshop` emits a `docs/adr/NNNN-*.md`
     file conforming to `docs/adr/0000-adr-process.md`'s MADR-lite format,
     `## Status: Proposed` (never `Accepted` — ratifying an ADR is a
     separate human act outside this command). Each ADR links back to the
     epic; the epic gets an `## ADRs` section linking forward. Zero
     architectural calls, or no `docs/adr/` directory in the checkout,
     degrades to a plain "nothing emitted, here's why" notice rather than a
     silent skip.
   - **A `Decisions/` note** — the standard personal-capture record,
     cross-linked to both the brief and the epic.
   - **The brief itself** stays the deliberation record (full reasoning,
     rejected alternatives, persona findings) in `Designs/`; it is never
     copied into the epic or the ADR.

Whatever else is unavailable — no `gh` auth, no registered board, no
reviewer agents declared — the coverage walk still produces a ratified brief
in the knowledge store. That is the floor this command guarantees; every
other dependency degrades legibly instead of blocking the walk.

## Integration

`/workshop` is the funnel's **second front door**, a peer to `/triage` rather
than a patch on top of it:

```
capture.sh (bugs) ┐
sweeps / audits   ┼─► /triage      cull → collapse → group → epic + sub-issues
loose Backlog     ┘
                                                                    │
a design conversation ──► /workshop   intake → coverage walk → review pass → ratify → materialize
                                                                    │
                                                                    ▼
                                              board epic (## Contract, design-brief: marker)
                                                                    │
                                                                    └─► /assess --epic N   (unchanged)
                                                                            └─► /build
```

`/triage` explicitly disclaims decomposing an already-existing, fully-specified
epic; `/workshop` is that epic's point of origin, not something `/triage`
grows into. Both doors converge on the same `/assess --epic N` → `/build`
pipeline — nothing downstream of materialization changes because of which
door an epic came through.

Three seams tie the two doors together so a designed epic can't silently
lose its provenance or slip through the wrong door:

- **`/triage`'s mirror redirect.** A Backlog candidate that reads as
  invented, epic-sized work gets flagged at `/triage`'s preview/summary step
  — "recommend `/workshop` instead of triaging it here" — rather than culled
  or grouped as if it were a discovered defect.
- **`/assess`'s provenance check.** When `/assess --epic N` finds a
  Contract-bearing epic with no sub-issues (the epic-decomposition path), it
  checks for the `design-brief:` marker. Present → proceed silently, this
  came from a ratified `/workshop` walk. Absent → a legible, fail-open ask:
  proceed with the hand-authored Contract as-is, or park and run `/workshop`
  first. Unattended runs take the safe default (proceed) and log it to the
  pending-decisions surface rather than blocking.
- **`/tidy`'s drain backstop.** A provenance-less epic that the live
  `/assess` check never caught (or whose ask went unanswered) is swept up by
  `/tidy`'s own provenance sweep, so the gap doesn't depend on a single
  live session catching it.

## Resource impact

`/workshop` is **operator-present only** — there is no unattended arm, no
`ScheduleWakeup` poll, and no async decision-issue backend, because a design
ritual has no meaning without a live operator making the calls. Cost is
therefore conversational: the coverage-walk conversation itself, plus
whichever review-agent passes the operator picks (a brief pass spawns two
standing lenses; a full pass adds a red-team lens, a persona pass, and — when
the install surface is touched — an executed first-run/uninstall run). At
materialize time there are a handful of one-shot board/API writes (the epic,
its board mirroring if a board is registered) and knowledge-store writes (the
brief, the Decisions note, any draft ADRs) — none of it recurring or
polled. There is no new telemetry stream to budget for; measurement rides
existing proxies (see below).

## Telemetry

`/workshop` introduces no new emitted telemetry stream of its own — its
effect is measured through four **measurement proxies** on existing signal
rather than a dedicated stream:

- **Merge-gate failure rate, designed vs. hand-authored epics.** Whether an
  epic that went through the coverage walk trips fewer merge-time gates
  (leak guard, live/drain pairing, feature-docs coverage, and so on) than a
  hand-authored one — the loop the design-schema dimensions are built
  around (each dimension names the merge-time gate it pre-answers).
- **Mid-build rework rate.** Whether a designed epic's plan items need fewer
  contract reshapes or scope corrections during `/build` than a
  non-designed one — a proxy for whether dimension 4's Contract seams were
  actually filled well enough to decompose with zero changes.
- **`/assess` clarification round-trips.** Whether `/assess --epic N`
  against a designed epic asks fewer clarifying questions than against a
  hand-authored one — a proxy for whether the coverage walk actually
  front-loaded the ambiguity discovered work otherwise pushes downstream.
- **Dimension-disposition distribution.** Across ratified briefs, the mix of
  `filled` / `n/a` / `deferred` dispositions per dimension — a proxy for
  which dimensions are consistently hard to fill (candidates for schema
  clarification) versus consistently `n/a` (candidates for narrowing).

None of these is a live emitted stream today; each is a measurement derived
after the fact from existing artifacts (merge-gate results, plan-note
revisions, brief frontmatter) rather than a new append-only lake stream —
stated plainly rather than implied.
