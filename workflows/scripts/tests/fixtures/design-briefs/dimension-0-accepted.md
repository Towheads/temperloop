---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: draft
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — dimension 0 present and accepted

Purpose-built passing fixture (temperloop#508): identical to
minimal-conformant.md but ALSO carries a `## 0.` (Premise & null hypothesis)
section as its first dimension heading. It proves the validator accepts a
bare-integer `## 0.` heading as a valid kernel dimension — dimension 0 must
NOT be flagged UNKNOWN-DIMENSION / bare-integer-overflow (that boundary now
keys on KERNEL_DIM_MAX=16, so 0..16 are valid bare integers and only >=17 is
overflow). Dimension 0 is `filled`-only per design-schema.md § Disposition
grammar, so it carries `disposition: filled` here. Every kernel dimension
below carries exactly one disposition.

## 0. Premise & null hypothesis
disposition: filled
Fixture premise: the do-nothing cost is a stale drift guard; proceeding is
justified because the schema table already carries dimension 0.

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
