---
title: check-in
slug: check-in
---

## Problem

Unattended machinery (the nightly drain pass, the autonomous funnel driver,
an unattended build run) is deliberately designed to never block waiting for
an absent operator — it takes a safe default and keeps moving, or it parks
something it can't safely decide on its own. Without a review ritual, every
one of those defaulted decisions, parked findings, and flagged surfaces just
sits there permanently: a pending decision nobody confirmed, a proposed
supersession nobody linked, a possible-secret flag nobody redacted, a
standing project-priorities note nobody ever revisits. The unattended half
of the pipeline is only trustworthy if a human periodically closes the loop
on what it deferred — otherwise "parked for review" quietly becomes
"dropped."

## How it works

`check-in` is the daily, human-driven review session. It has three parts.

**Part 1 — status readout.** It renders a telemetry brief summarizing
overnight activity, leading with a data-freshness check so a stale rollup is
called out immediately rather than silently trusted.

**Part 2 — dispose the overnight queues.** Several append-only review
surfaces accumulate entries from the unattended machinery: a pending-decisions
surface (safe defaults taken by an unattended run with no operator present),
a proposed-supersessions surface (cross-session contradictions between vault
decisions that a drain pass detected but never auto-resolves), a retro
findings surface (nuanced or unmeasurable findings that a retrospective pass
couldn't file automatically), a candidate-tells surface (extraction-tell
proposals mined from what a drain pass's extraction missed), a vault-hygiene
surface (housekeeping and structural drift a periodic probe flagged), and a
sensitivity-flags surface (possible secrets a drain pass's mandatory scan
found in a session transcript but never copied anywhere). Each subsection
reads its surface's open entries and presents them for a decision: confirm
the default, override it, accept a finding, dismiss it, promote a tell,
discard it, redact a flagged secret, and so on. This command is the **sole
mutator** of every entry's status — every surface above is written
append-only by the unattended side and disposed only here.

**Part 3 — priorities review.** A durable per-project priorities note (the
weighted themes, the definition of "impactful"/"done", the avoid-now list)
drives what an advisory "what should I work on next" recommendation
suggests. This command is the only place that note is written; a downstream
recommender only ever reads it. Most days most projects are simply
confirmed unchanged — the value is catching the one project whose focus
actually shifted.

## Integration

Consumes: every review surface the drain pass (`tidy`) and the autonomous
funnel driver write — pending decisions, proposed supersessions, retro
findings, candidate tells, vault hygiene, sensitivity flags — plus a
telemetry-brief renderer for Part 1's status readout, when one is present
in the checkout.

Produces: resolved/dismissed status on every surface entry it disposes;
worklist issues for accepted retro findings; lexicon updates for promoted
candidate tells; edits to the standing per-project priorities notes that a
downstream advisory recommender reads.

This command is the **read side** of the drain-proposes / operator-disposes
split: `tidy` and the funnel driver **propose** by appending; `check-in`
**disposes** by mutating status. Nothing else in the pipeline reads or
writes the `Status` field on these surfaces.

## Resource impact

Cost is proportional to the number of open entries across the six review
surfaces, not to overall pipeline volume — a quiet night costs a handful of
reads that each report "no open entries." Each disposition is a small,
targeted edit (a status-line patch or a short append), not a full-file
rewrite. The priorities review is bounded by the number of active projects,
each a small note read-and-confirm.

## Telemetry

None as a direct raw-lake emitter — this command is the human-facing
consumer of telemetry rather than a producer of it. Its Part 1 status
readout surfaces whatever the checkout's telemetry-brief renderer already
computed from the raw-lake streams (command runs, issue touches, funnel
ticks, findings, and the rest); if that renderer reports stale or missing
data, that staleness is itself the observable signal that something in the
telemetry pipeline needs attention. Absent any renderer, the way to notice
this command isn't doing its job is indirect: review surfaces (pending
decisions, sensitivity flags, and the rest) accumulating unresolved entries
across multiple days is the tell that check-ins have lapsed.
