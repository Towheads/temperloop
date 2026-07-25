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

As applied (v0.17.0, temperloop#729): funnel→pipeline, knob→setting,
blocking-now/batch-at-gate/batch-at-ritual→ask-now/ask-at-gate/
ask-at-checkin (ritual→check-in/routine), build spine→build machinery,
precedence rung→layer + autonomy rung-5x→level-5x, Live/Drain
pairing→Capture/Backstop pairing, logical board number→board id. The full
per-surface map is the CHANGELOG `[0.17.0]` BREAKING section (the
migration note this ADR calls for). No message-schema template name
needed renaming — all five were already plain words. The legacy window
(`workflows/scripts/lib/rename-compat-0170.sh` env shim, forwarding stubs
at every old script path, the old overlay-registry filename read) closes
in v0.19.0; persisted external state (the `funnel-*` labels/markers and
state paths) keeps its pre-rename values, exactly as `.foundation/` did
in the #165 precedent. One standing gate WAS added beyond the one-time
sweep — `check-terminology-leak-guard.sh` (`make test-kernel-terminology`)
— because the #165 rename's own leak-guard precedent showed a closed,
reviewed exempt set is what keeps retired identifiers from silently
re-entering stranger surfaces.

## Consequences

Readers stop paying a vocabulary tax, at the cost of a per-checkout
migration: "pre-GA" does not mean zero adopters — early cloners and the
operator's own N consuming checkouts each migrate once, bounded by
`update-kernel.sh`'s per-repo BREAKING ack and the enumerated map.
Integrity claims are scoped to what this repo's checks can see; a
consumer's overlay half adapts via the map at pull time. Accepted gap:
historical knowledge-store notes keep old terms — they are records, not
live contracts, and are not rewritten.
