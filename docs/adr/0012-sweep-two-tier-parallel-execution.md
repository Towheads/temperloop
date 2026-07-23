---
title: "0012: sweep two-tier parallel execution"
---

# 0012: sweep two-tier parallel execution

## Status

Proposed

## Context

`/sweep` drives a board's Ready singletons strictly one at a time, and its
Phase-1 clarification batch blocks the entire run — so an attended run
serializes fix work that never needed the operator, and an answer given
mid-run is not consumed until the following run. The fanout machinery
already exists: `build-level.mjs` executes its `items[]` through
`parallel()` (the same within-level path `/build` uses daily), so
sequentiality was a driver choice, not a machinery limit. Two constraints
shape any parallel redesign: background Workflow invocation with a
completion notification is a conversational-harness capability only
(headless runs have no re-invoke loop — the #626 constraint), and a chunk
of concurrent items is a multi-claim window, where `release.sh` correctly
refuses non-latest markers (K#275).

epic: temperloop#671

## Decision

`/sweep` Phase 2 becomes **two-tier**:

- **Tier 1 — fanout (all run modes):** the Phase-2 set drives as chunked
  multi-item `build-level.mjs` invocations (width = `SWEEP_FANOUT_WIDTH`),
  each invocation synchronous, with per-chunk merge pass and quota gate.
- **Tier 2 — overlap (attended runs only, width > 1):** chunk 1 (the
  clarification-free set) launches as a background Workflow invocation
  *before* the Phase-1 question batch is presented; issues answered during
  the batch form a same-run tail chunk. Where background invocation is
  unavailable, tier 2 degrades to tier 1 with a legible notice — synchronous
  fanout is the designed floor, not an improvisation.

`SWEEP_FANOUT_WIDTH=1` restores full legacy semantics — sequential drive
*and* questions-first ordering — as a config-only rollback. Phase-1
detection fans out at the tier named by `SWEEP_DETECT_MODEL` (default:
inherit the session model — ambiguity detection is judgment work). The
park path's per-issue release call is best-effort, per the kernel's
claim-held-until-Done contract.

## Consequences

- Attended wall-clock divides by ~chunk width, and operator answers are
  consumed the same run they are given — the run saturates the time the
  operator gives it.
- Merges batch at chunk boundaries (a chunk's wall-clock is its slowest
  item), board WIP rises to chunk width, and the 5-hour quota gate coarsens
  to per-chunk — the same accepted properties `/build` has per level.
- Hotspot-touching siblings in one chunk surface as deterministic
  rebase-conflict parks (never corrupt merges); known same-file issues are
  sequenced apart heuristically.
- The overlap tier's harness dependency is proven empirically by a
  first-run feasibility check recorded in the PR verification surface, and
  the headless/funnel arm never depends on it.
- Follow-on work: the sweep spec rewrite (including the three legacy
  sequential-contract passages), both knob-registry rows, the feature-doc
  update, and an additive CHANGELOG entry naming `SWEEP_FANOUT_WIDTH` as
  the downstream opt-out lever.
