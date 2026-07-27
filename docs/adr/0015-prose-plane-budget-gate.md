---
title: 0015: two-tier CI budget gate on the kernel prose plane
---

## Status

Proposed

## Context

epic: Towheads/temperloop#719

The kernel's prose plane — the composed `CLAUDE.md` kernel half plus the
command specs, schemas, and agent charters under `claude/` — is ~10,200
lines and has only intake mechanisms (capture rules, live/drain pairing),
no removal mechanism. The composed half loads into every session of every
repo that actually composes one, so growth there is a permanent
per-session token cost for those repos.

**Correction (see ADR 0018):** this paragraph originally continued "and a
fresh clone must absorb the whole composed surface before its first
session — which cuts against `docs/who-its-for.md`'s own 'No org
membership and no Projects provisioning step stand between "clone" and
"first tracked issue"' framing." That premise has since been measured
false for the case it cites. `workflows/scripts/install/links.sh` §2b
emits the composed-`CLAUDE.md` entry only when **both**
`claude/CLAUDE.kernel.md` and `claude/CLAUDE.overlay.md` exist — a
kernel-only checkout (this repo's own fresh clone) has no overlay file by
construction, so its install writes no composed doc at all. A fresh
clone's auto-loaded footprint is roughly 14 KB (a project-level pointer
file plus agent and command descriptions in the two listings), not the
~63 KB composed-surface figure this premise assumed. See ADR 0018 for the
full measurement and its consequences; per that ADR's own Context, this
ADR is not superseded. Advisory pressure (a lean-authoring norm, standing
prose reviewers) has existed throughout and accretion continued — the
observed leak the maturity ladder (`docs/principles.md` § 5) requires
before a rule earns a mechanical gate.

## Decision

A two-tier budget gate — `workflows/scripts/validate-prose-budget.sh` —
joins the `checks` gate set. It measures both tiers by parsing
`count-prose.sh`'s own report rather than re-implementing either count.
Tier 1 caps the composed **kernel-authored** surface, rendered read-only
through the existing compose seam — never the kernel+overlay total, so an
adopter's own overlay content can never trip a kernel check. Tier 2 caps
every file in the `claude/**/*.md` glob (agent charters included) under one
**uniform** per-file knob — a single knob, because per-file values would
be relocated exemptions. Caps are the `PROSE_BUDGET_TIER1_CAP` (340 lines)
and `PROSE_BUDGET_TIER2_FILE_CAP` (1057 lines) knobs in `build.config.sh`,
registered verbatim-equal in the knob registry; no inline exemption
mechanism exists. Landing order is a **ratchet**: both caps seed at the
tree's own state at merge time, re-measured rather than trusted from an
earlier point — this item's own build re-seeded the tier-1 figure twice
for exactly that reason (once at initial landing, again after a rebase
picked up ~2 unrelated lines of growth in the composed render before
merge), while the tier-2 figure (the largest tracked file) held constant
across both — so the gate merges green by construction and blocks no
unrelated PR; tightening is a later, deliberate config PR after the
subtraction passes land. The failure message is a first-class deliverable:
file, count, cap, and both remediation paths (trim, or open a cap-raise
config PR).

## Consequences

Adding kernel prose stops being free: growth beyond baseline fails CI
mechanically, for every contributor, with a self-explanatory message. The
gate doubles as the standing size sensor (its counts, recorded per run,
are the cheapest telemetry proxy). Coupling is accepted knowingly: a
compose-script change can move the tier-1 number with no prose change —
the per-file deltas in the failure output make that case immediately
attributable to the seam. Residual risk, honestly advisory-only: cap
pressure incentivizes semantic thinning (a load-bearing caveat stripped to
fit the number); no structural semantic check exists, and reviewers on
subtraction PRs carry it. Removal of the gate is clean: validator +
gate-set registration + knobs, with registry-equality catching a
half-removal.
