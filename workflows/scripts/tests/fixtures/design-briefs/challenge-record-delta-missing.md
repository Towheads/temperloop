---
tags: [design-brief, project/fixture]
date: 2026-01-01
status: ratified
record_grammar: delta
source_kind: claude-stamped
source_session: fixture0
source_model: fixture-model
last_verified: 2026-01-01
---

# Design brief: fixture — stamped ratified brief with one dimension's delta line missing

Purpose-built FAILING fixture (temperloop item `brief-validator-delta-rule`),
"not excused" arm: a `status: ratified` brief whose frontmatter carries
`record_grammar: delta` and whose `### Challenge record` subheading IS
present (the `challenge-record-start:` marker is there, and stop lines
follow it — so this is NOT the `EMPTY-CHALLENGE-RECORD` case) but the record
omits a `delta` stop line for kernel dimension 6. Because the brief is both
stamped and ratified, it is IN SCOPE for design-schema.md § Record
completeness's rule (1), stamp-gated arm — every kernel dimension 0..16
needs a `delta` stop line before ratify — so check (C) MUST fail it with
`MISSING-DELTA-VERDICT` for dimension 6, proving the completeness bar
actually bites once a brief is stamped (not merely skipped the way an
unstamped/legacy brief's record is). This is the stamp-gated counterpart to
the retired walk-only enforcing-arm fixture; `/workshop`'s ratify-gate item
(Step 4.1c) reuses this fixture the same way.

## 0. Premise & null hypothesis
disposition: filled
Fixture premise: the do-nothing cost is a stale drift guard; proceeding is
justified because this fixture exercises the stamp-gated completeness bar's
enforcing arm.

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

0,1,2,3,4,5,7,8,9,10,11,12,13,14,15,16 [delta] operator: accepted
