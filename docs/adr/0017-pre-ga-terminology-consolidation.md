---
title: 0017: one-shot pre-GA terminology consolidation
---

## Status

Proposed

## Context

epic: Towheads/temperloop#719

The kernel's contracts speak a private vocabulary — live/drain,
prose-resident knobs, batch-at-ritual/batch-at-gate/blocking-now, funnel
rungs, colliding board-number spaces with a documented swap warning —
that the operator himself reports confusing and that a stranger must
absorb before the docs are readable. Terminology names are contract
surfaces (`VERSIONING.md` § The contract surface): overlays redeclare
message-schema templates by name, and consuming checkouts vendor the
synced spine, so renames are breaking changes. The repo is pre-GA with no
known external adopters — the cheapest moment a rename will ever have.

## Decision

Consolidate terminology once, now, as a **one-shot rename PR** — one name
per concept, plain words over coinages — rather than dribbled renames
each forcing a separate relearn. The migration note **enumerates the full
rename map** (old → new, per named surface, message-schema template names
called out explicitly) so an overlay or consumer adapts mechanically at
its own pull; `BREAKING` CHANGELOG markers and a version bump per
`VERSIONING.md`; a compat shim where the existing rename-window precedent
(`FOUNDATION_*`→`TEMPERLOOP_*`) makes one cheap. Verification is a
scripted repo-wide grep sweep of the map shipped inside the rename PR — a
one-time script, deliberately not a new standing validator — plus
`validate-template-refs.sh` within its actual scope (named template refs
only; it does not sweep arbitrary terminology).

## Consequences

Readers stop paying a vocabulary tax, at the cost of a per-checkout
migration: "pre-GA" does not mean zero adopters — early cloners and the
operator's own N consuming checkouts each migrate once, bounded by
`update-kernel.sh`'s per-repo BREAKING ack and the enumerated map.
Integrity claims are scoped to what this repo's checks can see; a
consumer's overlay half adapts via the map at pull time. Accepted gap:
historical knowledge-store notes keep old terms — they are records, not
live contracts, and are not rewritten.
