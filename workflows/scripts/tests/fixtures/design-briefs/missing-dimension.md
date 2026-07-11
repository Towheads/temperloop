---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: draft
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — missing a dimension disposition

Purpose-built failing fixture for
workflows/scripts/tests/test_validate_design_brief.sh: identical to
minimal-conformant.md except dimension 9's heading is present but carries no
`disposition:` line at all (nothing before the next heading) — the
no-silent-skips failure mode (claude/design-schema.md § Disposition grammar)
this lint exists to catch.

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
