---
title: "0034: Machinery steps are keyed by input identity"
---

## Status

Proposed

## Context

`build-level.mjs` runs a level's machinery in batches, and a mid-level
crash today forces a full-level rebuild on resume: nothing records which
machinery steps already completed against which inputs, so the driver
cannot tell a step that finished from one that didn't. Separately, `/build`
Step 4's merge gate and its human checkpoint live entirely in prose inside
`build.md`, alongside Step 0.5's prose "authority ordering" table for
resume recovery — both are exactly the kind of judgment that should stay
as prose only where genuine judgment is required, with everything that
must always fire moved into code.

epic: Towheads/temperloop#1910 — ratified brief
`Designs/temperloop - graph of record` (private knowledge store)

## Decision

Each machinery batch `build-level.mjs` runs appends one record to a
per-item step ledger at `<repoRoot>.wt/.ledger/<slug>.jsonl` — a sibling
directory outside the repository tree, so it can never appear in `git
status`. Each record is keyed `(slug, step, head_sha, base_sha,
machinery_version)`. On resume, a step whose key matches its last ledger
record is skipped; a step with no matching record replays, which is
always safe (if slower) and is exactly the visible symptom of a missing
ledger write. The `machinery_version` component exists so a kernel bump
invalidates every ledger record rather than skipping a step whose
underlying script has since changed. The ledger is authoritative only for
**intra-level** resume; plan-note sentinels remain authoritative at level
boundaries, and neither the ledger nor an intra-level replay ever reverses
a human-set `[x]` or `[-]` sentinel.

The merge gate moves out of `build.md` prose and into a second Workflow
script, `build-gate.mjs`, fed a level's parked set. Its human checkpoint
reuses the same return-to-driver interrupt `build-level.mjs` already uses
for its own escalations: the workflow returns a `gate-ask` escalation
carrying the composed question, the live session answers it through the
existing `decision_sink_ask` seam, and the workflow is re-invoked with the
verdict. No new ask site is added inside a Workflow, since a Workflow
runtime has no operator seat to add one to. Step 0.5's prose authority
table is deleted from `build.md` outright (superseded by the sibling
state-graph ADR's `resume` query), and the change to `build.md`'s
documented steps ships as an authored `BREAKING` CHANGELOG fragment with a
migration line, per `VERSIONING.md`'s rule that a dropped documented
command step is breaking.

## Consequences

**Benefits.** A forced mid-level crash replays only the machinery steps
whose `(head_sha, base_sha, machinery_version)` changed since the last
ledger record, shown by diffing the ledger before and after — instead of
the full level rebuilding from nothing. `build.md`'s Step 4 becomes a
pointer to `build-gate.mjs`, the same relation Step 3 already has with
`build-level.mjs`, and Step 0.5's authority table disappears entirely
rather than living on beside its code replacement. The prose-cap ratchet
(ADR 0015) can be lowered after this lands, since the table it was sized
against no longer exists to regrow.

**Costs.** The gate's human checkpoint depends on the Workflow runtime
being able to return control to a live session; on a runtime with no
operator seat at all, the fallback is to keep Step 4 in prose and ship
only the ledger, which the L2 verdict must say explicitly rather than
silently degrading. Deleting a documented, prose-authoritative resume
table is a real reverse cost: undoing this change means restoring that
prose from git and removing the ledger reads, which is why it ships as
its own kernel tag — a consuming repo pins the tag before this lands
rather than opting out per teammate, since one teammate cannot disable a
shared gate workflow alone.

**Follow-on work.** `/fix`'s route dispatch moves to sit beside the script
that emits the shared route enum, tracked separately from this ADR. The
ledger and every machinery call site in `build-level.mjs` are a paired
coupling: a new machinery step must write a ledger record in the same PR
that adds it, or the omission surfaces only as an always-replayed step —
safe, but worth registering in the mandatory-step registry alongside the
state-graph's own per-run tally.
