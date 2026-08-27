---
title: "0031: Durable logical order lives on the board as blocked_by"
---

## Status

Proposed

## Context

The pipeline has held an invariant that dependency edges never live on
the board: `/triage` is forbidden to compute or store them ("they churn
every assess run"), and `/assess` recomputes edges and levels fresh into
each plan note. That was right for the edges assess computes — merge-safety
(`depends-on`) ordering is a re-derivable physical fact that genuinely
churns. But it conflates two edge kinds: *logical* order ("the schema item
precedes its consumers") is a durable, meaning-level fact that does not
churn, and trapping it in per-run plan notes leaves every other consumer
(`/next`, `/fix`, `/sweep`) unable to read it. The kernel already
designates the native `blocked_by` edge as the representation of a genuine
dependency block, and the board adapter ships read and write helpers for
it (`board_blocked_by_open` / `_add` / `_remove`).

epic: Towheads/temperloop#1847 — ratified brief
`Designs/temperloop - epic-as-metadata for operational work` (private
knowledge store) carries the deliberation, including the review finding
that forced the supersession to cover every statement site.

## Decision

The edges-stay-off-the-board invariant is formally superseded by a
narrower one: **durable meaning-level order may live on the board as
native `blocked_by` edges; computed merge-safety edges and levels stay
plan-resident and are still never stored.** `/triage` stamps genuine
logical order between an Operational group's members at materialization
(Operational groups only — a Foundational group's ordering stays in its
plan's `after:` edges, so no ordering ever has two live representations),
each edge with a rationale comment, a script-backed cycle check before
every write, and an `edges-considered` marker on the epic that sweep
admission requires (an empty edge read alone never proves order-freedom).
Drive-time consumers honor the edges: `/sweep` defers a blocked pool item
natively (temperloop#1835, landing with this epic); `/build` honors them
via `/assess`'s projection of stamped edges into plan `after:` edges (the
existing toposort); `/next` skips a blocked item advisorily; `/fix`
enforcement is tracked separately (temperloop#1843). The amended invariant
is stated once and pointed to from every prior statement site (both
`triage.md` lines, `assess.md`'s recomputed-fresh line, and the ratifying
decision note).

## Consequences

Ordering becomes board data every consumer can read, instead of command
identity or plan-note internals — the general case (a DAG) subsumes the
degenerate ones (a lone issue, an edgeless pool). Merge-safety ordering
keeps its existing drive-time treatment (hotspot chunk sequencing plus
the deterministic pre-PR rebase), so the churn the old invariant guarded
against never reaches the board. The stamping judgment (logical vs
merge-safety) is honestly advisory — the design's riskiest judgment call
— bounded by the cycle check, the rationale comment, and the marker.
Stamped edges need no cleanup if the feature is removed: they remain
accurate native dependency records that `/next`, `/fix` (temperloop#1843)
and `/sweep` (temperloop#1835) treat correctly on their own terms.
