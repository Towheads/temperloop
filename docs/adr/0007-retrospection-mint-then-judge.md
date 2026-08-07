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
judge. Because the trigger hands off via a **nested `claude -p "/retro
--pending"`** that does *not* inherit the funnel driver's no-merge
prohibition, the action's safe-tier (non-merging) guarantee rests on
`/retro`'s own contract — which must assert it merges nothing — rather than
on a kernel-side guard; the kernel side classifies the action SAFE and
passes no merge-capable action across the seam. `/retro`'s own contract
must therefore carry a one-line no-merge assertion covering this
delegation — an overlay-side companion change (foundation#1247).

## Amendment — the trigger's probe is CAPABILITY, not presence (temperloop#1150)

The decision above specified the trigger as "one label query, one
age-or-urgent comparison, and a **command-availability** probe." That third
probe was too weak for what the seam actually does: it *spawns* the judge as
a nested `claude -p "/retro --pending"`. `/retro` did not implement that
headless mode, so a probe answering only "is a `retro.md` file present"
returned true and the tick spawned a judge that could not run. The nested
session ended its turn without judging anything and exited `subtype:
success` / `is_error: false` — 13 minutes and ~$7.60 for zero judgments and
zero run-stream rows, indistinguishable from a healthy tick. The loop's
other two halves (the mint, and `/tidy`'s backstop sweep) worked from day
one; only the judge never ran, for months, invisibly.

Amended: the trigger's third probe is a **capability** probe, and the
capability is **declared by the judge, never inferred by the kernel**. The
overlay `/retro` asserts it can complete an unattended `--pending` run with
a marker line in its own command file (`<!-- capability: headless-unattended
-->`, the grammar in ADR 0008's helper); absent that declaration the tick
emits a `skip-retro-judge` action carrying `reason: "headless-unsupported"`
and spawns nothing. This keeps the kernel's side of the seam exactly as thin
as the decision intended — it adds no judgment, only a handshake — while
making the refusal legible instead of silent. **Never silence: either the
judge runs, or the tick records why it did not.** The kernel cannot execute
an overlay command to verify the capability, and does not try; what it can
do is refuse to spawn one that never claimed it.

Amended consequence for observability: the seam is now **detectable**. A
zero-row `retro-runs` stream previously meant both "no retros were due" (the
steady state) and "the judge has never once run" (the dead loop), which is
how the failure hid. `workflows/scripts/build/pipeline-retro-health.sh`
reads the tick's own retro actions against the judge's run stream and
returns a verdict that separates them — `no-signal`, `refused`, `healthy`,
`no-lake`, or `defect` (sub-typed `never-had-a-row` vs `stalled`) — and
`/tidy`'s Retro mint backstop gains a fourth probe that files a `defect`
verdict as a board defect rather than letting it read as steady state.

Deliberately **not** taken here: giving `/retro` a real synchronous headless
mode. That is the judge's own control flow, and `/retro` is overlay content
— out of the kernel's lane per the kernel/overlay routing rule. The kernel's
job at this seam is to not spawn an unrunnable judge, which is what this
amendment does; the overlay half (implement the mode, then declare it) stays
an overlay change.

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
