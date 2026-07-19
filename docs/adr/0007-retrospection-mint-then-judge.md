---
title: 0007: Retrospection is mint-then-judge across the kernel/overlay seam
---

## Status

Proposed

## Context

epic: temperloop#528 (kernel half) · foundation#1247
(overlay half) · design brief: `Designs/temperloop - unified retrospection`

Two partially-overlapping retrospection mechanisms existed: `/build`'s
4d-retro filed a per-epic questionnaire issue nobody was assigned to
answer, and the overlay `/retro` judge — which can answer it — never ran on
its own. Run naively per epic, the judge would re-read the same session
transcripts and re-file the same system findings across quick-succession
epics. The kernel's `/check-in` also referenced `/retro` unconditionally,
dangling on a kernel-only checkout (temperloop#521). Full kernelization of
the judge was considered and rejected at the design's premise gate: the
kernel must work *correctly* without a judge — retrospection depth is an
improvement loop, not core pipeline machinery — and a kernel judge whose
transcript axes mostly skip on a bare checkout is machinery for a degraded
experience.

## Decision

Retrospection is one mechanism with two halves split at the kernel/overlay
seam. The **kernel mints**: at epic close, `/build` files a cheap, durable
tracker (merge friction, a per-signal build-health stamp, an honest state
label) and computes urgency at mint time. The **overlay judges**: `/retro`
answers the tracker — including the process/decomposition questions that
move out of the kernel template — under its own dedup and cap policy. The
connecting trigger is a **thin kernel seam**: the funnel tick performs one
label query, one age-or-urgent comparison, and a command-availability
probe, then hands a typed safe-tier action; it holds no other policy.
Policy loci are fixed: urgency is computed at mint (kernel, where the
health data is), the session cap is enforced judge-side (overlay, where
the deep-reads are), and no kernel surface may invoke or assume `/retro`
without a capability probe. Judgment content has exactly one owner — the
judge.

## Consequences

Benefits: one retrospection brain instead of two overlapping specs;
`/build` gets cheaper at epic close; a kernel-only checkout keeps a
useful mint (or turns it off via `RETRO_MINT_ENABLED`) with legible
degradation everywhere the judge would run — which closes temperloop#521's
dangling references by construction. Costs: five knobs, a new funnel
action type, and a three-probe `/tidy` backstop sweep enter the kernel
contract surface; the four retro questions relocate to the overlay, so the
overlay's sixth-axis change must land before (or same-day as) the kernel
template slim-down, and the handoff-defect KPI's source moves to the
judge's verdict (a named gap on kernel-only checkouts, reflected in
`design-measurement-proxies.md`). Follow-on: kernelizing `/retro` itself
remains deferred, recorded as temperloop#521 option 2.
