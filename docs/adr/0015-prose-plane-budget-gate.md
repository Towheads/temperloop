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
consuming repo, so growth is a permanent per-session token cost, and the
audience doc's afternoon-adoption claim is structurally contradicted by
the surface a fresh clone must absorb. Advisory pressure (a lean-authoring
norm, standing prose reviewers) has existed throughout and accretion
continued — the observed leak the maturity ladder requires before a rule
earns a mechanical gate.

## Decision

A two-tier budget gate — `workflows/scripts/validate-prose-budget.sh` —
joins the `checks` gate set. It measures both tiers by parsing
`count-prose.sh`'s own report rather than re-implementing either count.
Tier 1 caps the composed **kernel-authored** surface, rendered read-only
through the existing compose seam — never the kernel+overlay total, so an
adopter's own overlay content can never trip a kernel check. Tier 2 caps
every file in the `claude/**/*.md` glob (agent charters included) under one
**uniform** per-file knob — a single knob, because per-file values would
be relocated exemptions. Caps are the `PROSE_BUDGET_TIER1_CAP` (338 lines)
and `PROSE_BUDGET_TIER2_FILE_CAP` (1057 lines) knobs in `build.config.sh`,
registered verbatim-equal in the knob registry; no inline exemption
mechanism exists. Landing order is a **ratchet**: both caps seed at the
epic's recorded baseline for these two figures (the composed count and the
largest tracked file) — reconfirmed by a fresh measurement at build time,
whose per-file counts matched exactly even though the tracked-file TOTAL
(itself uncapped) had independently drifted a few lines in the interim —
so the gate merges green by construction and blocks no unrelated PR;
tightening is a later, deliberate config PR after the subtraction passes
land. The failure message is a first-class deliverable: file, count, cap,
and both remediation paths (trim, or open a cap-raise config PR).

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
