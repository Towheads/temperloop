---
title: 0002: Premise gate as kernel dimension 0
---

## Status

Proposed

## Context

epic: Towheads/temperloop#498

The funnel has two front doors. Discovered work (defects, sweep findings)
enters through `/triage`, whose first move is a cull — "should this exist
at all" is asked before anything becomes an epic. Invented work enters
through `/workshop`, which walks a coverage checklist but has no
equivalent: the walk assumes the idea is worth building, and invented
work is the category most exposed to enthusiasm bias. Separately, the
design-brief schema (`claude/design-schema.md`) owns the walk's dimension
list and its enforcement (no-silent-skips at ratify, the forthcoming
brief-conformance lint), so a premise challenge placed only in
`claude/commands/workshop.md` prose would sit outside every mechanism
that makes dimensions non-skippable.

## Decision

Add a kernel dimension `0. Premise & null hypothesis` to the design-brief
schema, walked first at `/workshop` intake. Its body records the
do-nothing cost, the strongest subtraction/existing-surface alternative,
and the operator's justification for proceeding — or the kill rationale.
Three deliberate calls within it:

- **Numbered 0, not 17**: the premise precedes every other question, and
  0 is the one integer that sorts first without renumbering dimensions
  1–16 or colliding with the overlay letter-suffix namespace. This spends
  the only prepend slot — a future intake-time kernel dimension forces a
  renumber; fractional or negative numbering is never the answer.
- **Disposition pinned `filled`-only**: `n/a` and `deferred` are invalid
  for dimension 0. A deferred premise means walking fifteen dimensions on
  an unjustified idea — the exact gap the gate closes — and an `n/a`
  escape recreates the click-through the gate exists to prevent. The
  operator's dial lives upstream (the design-first default's voiced
  rebuttal, and the epic-sized threshold that scopes `/workshop` itself),
  not inside the gate.
- **Drop is durable**: declining to proceed flips the brief to a new
  `status: dropped` frontmatter value, and the probe-before-create path
  stops on a dropped brief instead of silently adopting it — a killed
  idea stays killed unless explicitly reopened, and kills become
  countable corpus data.

## Consequences

Both front doors now filter: invented work gets the same "should this
exist" scrutiny discovered work gets, and the challenge plus its answer
are recorded in the brief rather than lost to conversation. The schema
change is additive (CHANGELOG-marked), but in-flight draft briefs need a
one-touch migration (add dimension 0) before they can ratify, and
reversing the dimension later is a breaking, kernel-wide change every
downstream adopter inherits — an accepted trade of routing the gate
through the kernel schema. The brief-conformance lint (temperloop#216)
must consume the schema's dimension list and the `filled`-only rule
rather than a cached 16-count. Known limit: the gate guarantees the case
against is stated and answered, not that an operator wants to kill an
idea; ritual-theater use is exposed by the dropped/proceed corpus tally,
not prevented mechanically.
