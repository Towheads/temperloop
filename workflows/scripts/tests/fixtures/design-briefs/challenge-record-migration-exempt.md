---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: ratified
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — ratified brief predating the challenge record

Purpose-built passing fixture, MIGRATION CARVE-OUT arm #1 (temperloop item
`brief-record-completeness-lint`): a `status: ratified` brief that carries
`## 0.` (dimension 0 already shipped, temperloop#508/#512) but has NO
`## Working notes` section at all — it ratified before the challenge record
(design-schema.md § Challenge record) existed. Check (C) must treat this as
EXEMPT from the record-completeness bar (design-schema.md § Record
completeness's migration carve-out), never flagged MISSING-WALK-VERDICT —
the same per-brief `status:` signal check (B)'s dimension-0 exemption
already keys on (temperloop#512), never a global version flip. This is the
"pre-change / no-marker (exempt)" fixture `/workshop`'s ratify-gate item
(Step 4.1c) reuses to prove its own carve-out is semantically identical to
check (C)'s.

## 0. Premise & null hypothesis
disposition: filled
Fixture premise: the do-nothing cost is a stale drift guard; proceeding is
justified because dimension 0 already shipped before this record did.

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

Deliberately no `## Working notes` / `### Challenge record` section below —
that absence is the fixture's whole point.
