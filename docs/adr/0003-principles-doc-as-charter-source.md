---
title: 0003: principles.md as charter-derivation source for adversarial lenses
---

## Status

Proposed

## Context

epic: Towheads/temperloop#498

`/workshop`'s full review pass has always specified a red-team lens, but
no agent ever shipped, so the slot degrades to `skipped — <agent>
unavailable` in every checkout — the review tier prices an adversarial
pass it cannot deliver. Chartering that lens raises the question of what
value set adversarial pushback derives from. The kernel already has a
worked answer for persona agents: their value sets derive from
`docs/who-its-for.md`, never a parallel list in the agent file. It also
already has a guiding-principles doc — `docs/principles.md`
(temperloop#135), twelve principles each carrying a mechanism-receipt
citation — though three principles the premise gate leans on (the
stranger test, minimum-viable-output, legible degradation) exist only as
command-spec operating prose, and no lens consumes the doc.

## Decision

`docs/principles.md` becomes the charter-derivation source for
principle-referencing adversarial machinery — the red-team lens and the
`/workshop` premise gate — extending the doc with the missing principles
rather than minting a second consolidation. The doc's dual use is
explicit: stranger-facing thesis (unchanged) and charter source, the same
dual role `docs/who-its-for.md` already plays for the persona agents.
Charters are self-contained prose *authored from* the doc and naming it
as their derivation source — not runtime file reads — so a deployed agent
copy is auditable standalone. Lens findings must cite a named principle;
an uncited finding is discardable on sight.

## Consequences

Adversarial pushback becomes traceable — "this shouldn't exist" resolves
to a named, cited principle rather than free-form taste — and the
always-skipped red-team slot becomes a running lens wherever project
agents are installed, with the same legible skip as its degradation and
uninstall path. The doc acquires a consumer: thesis edits can now affect
lens behavior, and its per-principle kernel citations are review-checked
only at ship — no lint resolves them, and a citation-staleness check is a
named follow-on, not part of this change. Overlay-scoped extension of the
principles set is deferred to the override-seam pattern (temperloop#112).
