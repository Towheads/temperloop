---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: ratified
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — ratified brief with an incomplete challenge record

Purpose-built FAILING fixture, MIGRATION CARVE-OUT arm #2 (temperloop item
`brief-record-completeness-lint`): a `status: ratified` brief whose
`### Challenge record` subheading IS present (the `challenge-record-start:`
marker is there, and stop lines follow it — so this is NOT the
`EMPTY-CHALLENGE-RECORD` case) but the record omits a `walk` stop line for
kernel dimension 6. Because the marker is present, this brief is IN SCOPE
for design-schema.md § Record completeness's rule (1) — every kernel
dimension 0..16 needs a `walk` stop line before ratify — so check (C) MUST
fail it with `MISSING-WALK-VERDICT` for dimension 6, proving the
completeness bar actually bites once a record exists (not merely skipped
whenever the marker happens to be absent, as
challenge-record-migration-exempt.md's EXEMPT arm is). This is the
"marker-present / walk-verdict-missing (flagged)" fixture `/workshop`'s
ratify-gate item (Step 4.1c) reuses.

## 0. Premise & null hypothesis
disposition: filled
Fixture premise: the do-nothing cost is a stale drift guard; proceeding is
justified because this fixture exercises the completeness bar's enforcing
arm.

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

### Challenge record
challenge-record-start: 2026-01-01

0,1,2,3,4,5,7,8,9,10,11,12,13,14,15,16 [walk] step-1-seed: accepted
