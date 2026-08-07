---
title: 0006: Per-item Seq ordering is retired, not emulated, on issues-only
---

## Status

Accepted

## Context

epic: temperloop#460

The Projects-v2 backend carried a numeric `Seq` field that /triage wrote to
order a board's worklist. Plain GitHub Issues have no ordering field, and
the issues-only backend deliberately left `board_set_number` unimplemented
(a silent `return 1`) rather than guess a convention. With issues-only
becoming the default backend (ADR 0004), that deferral has to resolve: an
issues-only representation could be invented (numeric labels, body markers)
or the concept could be retired.

The ordering consumers were checked before deciding: /build, /assess, and
the funnel compute dependency levels fresh from plan notes and never read
board Seq; the only surviving reader is worklist.sh's display column. A
label encoding (`fnd:seq:<n>`) would mint an unbounded numeric label
namespace — recreating exactly the label sprawl the migration epic exists
to remove.

## Decision

Seq is retired on issues-only, not emulated. Work ordering lives where it
already effectively lived: epic dependency levels (computed from plan
notes) and milestones. `board_set_number` fails loud on issues-only with an
explicit stderr message (replacing today's silent failure), its test
asserts on that message instead of suppressing stderr, /triage stops
setting Seq on issues-only boards, and worklist.sh's Seq column and sort
key are removed in the same change so no vestigial read-side survives.

## Consequences

- No new label namespace; the `fnd:` taxonomy stays bounded to status,
  component, and claim stamps.
- Anyone relying on the Projects board's manual drag-ordering loses it;
  the replacement signal is milestone membership plus dependency level,
  which the pipeline already treats as authoritative.
- The write path and the read path retire together — no permanently-empty
  column, no half-retired contract.
- ISSUES-ONLY-BACKEND.md's "Seq deferred" section resolves to "retired by
  design," closing the last unimplemented Projects-parity gap rather than
  carrying it indefinitely.
