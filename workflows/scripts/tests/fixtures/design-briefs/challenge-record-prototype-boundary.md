---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: ratified
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — unstamped ratified brief, the 2026-09-12 prototype's shape

Purpose-built passing fixture (temperloop item `brief-validator-delta-rule`):
models the real, ratified `Designs/temperloop - workshop two-phase
interview` brief (ADR 0036 § Consequences: "ratified 2026-09-12 under the
old validator with its operator lines recorded outside the parsed
section"). Frontmatter carries NO `record_grammar` field (legacy/unstamped)
and the `### Challenge record` subheading is present but has ZERO `walk`
stop lines in it — under the retired walk-only rule this would have been
`MISSING-WALK-VERDICT` for every dimension; under the stamp-gated rule it is
EXEMPT (legacy brief, no per-dimension requirement at all). `## Working
notes` also carries operator-authored log lines that mention dimensions and
delta-shaped language in prose, but under a DIFFERENT, non-parsed
subheading (`### Interview log`, not `### Challenge record`) — proving
check (C)'s section-scoped parse doesn't misread free-form provenance text
elsewhere in `## Working notes` as challenge-record grammar. Must pass check
(C) clean.

## 0. Premise & null hypothesis
disposition: filled
Fixture premise text.

## 1. Problem & outcome (stranger standpoint)
disposition: filled
Fixture problem statement, fixture outcome statement.

## 2. Audience & interaction modes
disposition: filled
Fixture audience; fixture interaction mode.

## 3. Alignment (guiding principles / routing)
disposition: filled
Fixture alignment rationale.

## 4. Contract seams (Produces / Consumes / Acceptance)
disposition: filled
**Produces:** fixture output.
**Consumes:** fixture input.
**Acceptance:** fixture check.

## 5. Command/mechanism shape
disposition: n/a — this fixture proposes no new command

## 6. Scalability & resource impact
disposition: filled
Fixture cost tier: negligible.

## 7. Maintainability
disposition: filled
Fixture coupling note.

## 8. Testability
disposition: filled
Fixture: fully mechanically gated by the fixture suite itself.

## 9. Telemetry & measurement proxies
disposition: deferred → temperloop#999
Fixture proxy sketch; full wiring deferred.

## 10. Upgrade path
disposition: filled
Fixture: no contract-surface change.

## 11. Uninstallability / reversibility
disposition: n/a — no runtime component; this fixture is a static document

## 12. First-run experience
disposition: filled
Fixture first-run note.

## 13. Docs & marketing surface
disposition: filled
Fixture doc surface note.

## 14. Security / privacy
disposition: n/a — no personal/org content in this fixture

## 15. Failure modes, degradation & capability limits
disposition: filled
Fixture failure story.

## 16. Adoption & enforcement
disposition: filled
Fixture: replaces no existing default.

## Working notes

### Interview log
round 1: D1–D2 [interview] operator: 2 asked, 2 answered — this is
free-form prose, not the machine-checked grammar; it lives under a
different subheading than `### Challenge record` and is never parsed as a
stop line.

### Challenge record
challenge-record-start: 2026-01-01
0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 [walkthrough] step-1-seed: accepted
