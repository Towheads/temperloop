---
title: "0024: cross-surface coherence is asserted positively at registered anchors, never as a tree-wide absence sweep"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1117

Several invariants in this repository span files that have no structural
relationship to each other. The one that motivated this ADR: the command a
newcomer should run first is named in `bin/temperloop`'s first-run output, in
`README.md`'s quickstart, in `bin/README.md`, and in
`docs/features/install-cli.md`. Nothing ties those four together, so they drift —
and they did drift, silently, when the quickstart was rewritten and the CLI's own
front door was left pointing at the retired command (temperloop#1116).

The obvious mechanical fix is a gate that greps the tree for the retired name and
fails if it appears. That instinct is wrong, and wrong in a way worth recording,
because it fails *by construction* rather than by implementation quality:

- The `CHANGELOG.md` entry announcing a removal must name the removed thing —
  that is what makes it a migration note rather than a silent deletion.
- Architecture decision records and archived plan notes name it because they are
  historical documents; rewriting history to satisfy a lint is not an option.

So an absence sweep ships with an exemption list on day one. An exemption list is
not a neutral cost: every subsequent legitimate mention adds an entry, the list
becomes the thing people edit to make the build green, and the gate degrades into
a formality that fires on the wrong things. That is the same dynamic as a test
suite whose failures are routinely re-baselined — and it arrives pre-broken here
rather than developing over time.

## Decision

**A cross-surface coherence invariant is enforced by asserting the required
content is PRESENT at a registered set of anchors, never by asserting a forbidden
string is ABSENT from the tree.**

Concretely, a gate of this class carries:

- **An explicit anchor registry** — the specific files, and where within them,
  that must agree. The registry is the gate's own data, reviewable as a list, in
  the same shape as the existing gate-path registry.
- **A positive assertion per anchor** — this anchor names the canonical value.
- **A negative assertion scoped to the anchor set only** — no anchor names a
  retired value. Outside that set, the tree is not the gate's business.

Adding a surface to the invariant is an explicit registry edit. Mentioning a
retired name in a changelog, an ADR, or an archived plan is not a gate concern
and never becomes one.

## Consequences

**The gate cannot rot into an exemption list.** There is nothing to exempt: a
file is either a registered anchor or it is outside the invariant. The pressure
that turns absence sweeps into rubber stamps has no surface to act on.

**A new surface is opt-in, and silence is the failure mode.** A file that should
be an anchor but was never registered is not checked, and nothing announces that.
This is a genuine weakness and the honest trade against a tree-wide sweep, which
would at least have noticed. It is accepted because the sweep's failure mode —
a gate everyone has learned to route around — is worse than a gate with a known
and stated blind spot.

**The registry is documentation.** The list of anchors answers "where is this
invariant asserted?" directly, which a grep-based gate never does.

**It generalises past the motivating case.** Any invariant of the form "these N
places must agree about X" takes this shape: version strings, a canonical
entrypoint name, a supported-platform list. The rule is about the *shape* of the
assertion, not about any one invariant.
