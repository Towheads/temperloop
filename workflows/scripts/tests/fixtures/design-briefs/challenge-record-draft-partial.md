---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: draft
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — in-flight brief with a partial challenge record

Purpose-built passing fixture: a `status: draft` (in-flight, non-ratified)
brief whose `### Challenge record` only covers the three Step-1-seeded
dimensions (0, 1, 3) — exactly what Step 1 has produced so far, with Step 2's
per-remaining-dimension walk not yet run. design-schema.md § Record
completeness's migration/scope carve-out: the per-dimension completeness bar
(rule 1) applies ONLY to a `ratified` brief whose record is present — a
non-ratified brief is never held to it, since its record is still being
built. Must pass check (C) clean (no `MISSING-WALK-VERDICT` for the 14
dimensions this in-flight record hasn't reached yet).

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

### Challenge record
challenge-record-start: 2026-01-01

0 [walk] step-1-seed: accepted
1,3 [walk] step-1-seed: accepted
