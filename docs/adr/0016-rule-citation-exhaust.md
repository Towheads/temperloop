---
title: 0016: citation markers and a deletion exhaust for standing kernel rules
---

## Status

Proposed

## Context

epic: Towheads/temperloop#719

Kernel rules accrete and never die: nothing records why a standing rule
earns its place, and there is no flow through which a rule leaves the
doc. The intake side is mechanized (capture rules, live/drain pairing,
CI-checked pairing registry); removal is not — an asymmetry the
principles doc itself reflects, where every principle governs adding
discipline. The maturity ladder also lacks a descent: a rule that earns a
mechanical guard keeps its full prose alongside the hook, doubling cost.

## Decision

Three coupled mechanisms give the rule set an exhaust. (1) **Citation
markers:** every standing kernel rule carries a mechanically-detectable
citation — a concrete past incident, the mechanical guard it narrates, or
a named catastrophic failure class (prophylactic rules are legitimate) —
validated for presence by the budget gate (ADR 0015), so the invariant
binds rules added after the founding audit, not only at it. Citations
reference public artifacts only (issues, scripts, commits), never private
store content. (2) **Proposed-deletions surface:** a rule that cannot
cite its place is proposed for deletion on a durable, repo-keyed,
date-keyed pipeline surface disposed at `/check-in` (keep / delete /
demote-to-pointer, safe default keep); every applied deletion lands as an
ordinary reviewable PR carrying the audit rationale in its body, so the
public trail stands alone. The cap — not the disposal flow — is the
forcing function: disposal selects which rules go, never whether
subtraction happens. (3) **Descent rung:** one new append-only principle —
when a rule earns a mechanical guard, its prose collapses to a pointer;
mechanization deletes prose rather than doubling it. The budget and
citation disciplines land as extensions under existing principles 11 and
5/10 respectively — deliberately not new numbered principles, because
appending three principles to enforce subtraction would be the accretion
pattern this change cures.

## Consequences

Every standing rule becomes auditable (why is this here?) and mortal
(what happens if it can't answer?), while deletion stays human-gated and
reversible via git. A wrongly deleted rule whose incident recurs re-files
carrying the citation it previously lacked — the system working, not
failing. The discipline binds kernel authorship only: an adopter's
overlay, personal rules, and project files are never audited or gated.
Named limit: proposal triage runs through the single-operator `/check-in`
ritual; multi-operator triage is out of scope. Per-teammate exemptions
were explicitly declined as the exemption-creep failure mode; the
self-service path is a cap-raise config PR.
