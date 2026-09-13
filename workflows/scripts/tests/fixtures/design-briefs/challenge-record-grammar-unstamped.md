---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: draft
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — a delta stop line with no record_grammar stamp

Purpose-built FAILING fixture (temperloop item `brief-validator-delta-rule`):
the brief's frontmatter carries NO `record_grammar` field, but its
`### Challenge record` carries a `delta` stop line anyway — new-grammar
content authored with no stamp declaring the new grammar in force
(design-schema.md § Record completeness, rule 1: "A record carrying any
`delta` or `interview` stop line while its frontmatter lacks the
`record_grammar: delta` stamp is itself a defect"). Must fail check (C)
with `RECORD-GRAMMAR-UNSTAMPED`, independent of `status` (this fixture is
`draft`, not `ratified` — the defect fires regardless).

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
0 [delta] operator: accepted
