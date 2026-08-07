---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: ratified
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — minimal conformant brief

This is a purpose-built fixture for
workflows/scripts/tests/test_validate_design_brief.sh — it is deliberately
minimal and unrelated to any real design; it exists only to exercise the
brief-conformance lint's green path against a non-circular brief (see
workflows/scripts/validate-design-brief.sh). Every kernel dimension below
carries exactly one disposition, spanning all three grammar forms.

`status: ratified` on purpose (temperloop#512): a ratified brief is immutable
and therefore EXEMPT from the conditional dimension-0 (`## 0.`) requirement,
so this fixture legitimately starts at `## 1.` and stays green — it exercises
the all-dispositions grammar path, not dim-0. It doubles as the exempt-arm
regression: a ratified brief with no `## 0.` heading must pass unflagged.

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
