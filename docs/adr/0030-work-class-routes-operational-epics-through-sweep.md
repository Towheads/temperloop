---
title: "0030: Work-class labels route Operational epics through sweep"
---

## Status

Proposed

## Context

The drive-side partition between `/sweep` and `/assess`+`/build` has been
purely structural: an issue with an epic parent takes the plan-ceremony
path, an ungrouped issue takes the sweep path. Triage's group-by-meaning
step therefore reroutes related *operational* fixes onto the heavyweight
path (plan authoring, an operator approval round-trip, per-epic question
gates) purely because a parent issue exists — even though
`claude/work-class-policy.md` already classifies Operational work as
fully autonomous. An 86-plan-note probe (2026-08) found 29% of
triage-born epics produced structurally trivial plans (one level, zero
edges), and the rest mostly shallow structure — while designed
(`/workshop`-born) epics show deep multi-level structure the plan
ceremony genuinely serves.

epic: Towheads/temperloop#1847 — materialized from the ratified brief
`Designs/temperloop - epic-as-metadata for operational work` (private
knowledge store), which carries the full deliberation: the premise gate's
null-hypothesis alternatives (auto-approve, demotion valve, and their
union), the six-lens review findings, and the operator-ratified residuals.

## Decision

The sweep/assess partition keys on the **work-class label**, not on epic
membership. An `Operational` epic's members stay in `/sweep`'s pool
(admission gated by a per-checkout config setting, default off); the epic
parent survives as a metadata artifact — group context, progress
narrative, completion signal via an end-of-run closing gate — never an
execution router. A `Foundational` label anywhere in the group (parent or
any member, evaluated live at every pool build) keeps the whole epic on
the assess→plan→build ceremony path. The partition is guard-enforced from
both sides: `/assess` refuses an Operational epic while the setting is on
(except pipeline-drive-invoked runs; explicit logged override available),
and `/sweep` excludes any epic with a live plan note. Consent on attended
runs is informed named-set consent (the pool report carries each admitted
member's acceptance text) plus modal merges for correlated member sets;
the autonomous pipeline tiers are explicitly not cut over by this
decision (separate, soak-gated follow-up — temperloop#1848).

## Consequences

Operational grouped work drains in one command with questions batched
across epics; plan authoring and approval are reserved for Foundational
work. The work-class labels widen from pipeline-driver autonomy policy to
a pipeline-wide routing key — a breaking contract-surface change
(`claude/work-class-policy.md`'s policy table is a primary edit, carried
under a CHANGELOG BREAKING marker). The class-based partition is
convention-enforced where the structural one was race-free by
construction, bought back with the two-sided mutual-exclusion guard and
claim-first as the last belt. Accepted residuals, operator-ratified: a
uniformly mislabeled epic can still auto-merge specifiable-looking work
(same residual the policy accepts for singletons, wider reach), and
disjoint member sets get no pre-merge cross-member coherence check —
both watched by kill conditions (mis-route incidents; post-merge
revert/rework rate vs the singleton baseline) that flip the admission
setting off pending a retro. Rollback is config-only and gate-tested
byte-identical to legacy behavior.
