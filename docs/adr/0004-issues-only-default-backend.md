---
title: 0004: Issues-only is the default tracking backend
---

## Status

Proposed

## Context

epic: Towheads/temperloop#460

The board adapter has carried two backends since foundation #799: a
GitHub Projects-v2 arm (GraphQL, org-level boards, a dedicated 5,000-pt/hr
budget with its own guard and structure/state cache machinery) and an
issues-only arm (plain Issues, `fnd:`-namespaced labels, native milestones,
sub-issues, and issue dependencies — REST only). The Projects arm was the
default posture; issues-only existed as board 7's documented sole exception,
serving the kernel's own tracker.

Two forces make that posture wrong for a kernel meant to be adopted by
strangers. First, the "try it" experience: a Projects board is an org-level
artifact that must be provisioned by hand before any tracking works, and
nothing else in the kernel requires more than a repo and `gh auth`. Second,
the maintainers were not dogfooding what they shipped — their four build
repos ran the Projects arm while adopters were pointed at the issues arm.
Everything the tracking flow needs (status, claims, epics, blocking edges,
milestones) has a free, REST-native representation the issues arm already
implements.

## Decision

Issues-only becomes the default tracking backend for every board. All four
maintainer repos migrate off their Projects-v2 boards onto the issues-only
backend. The Projects-v2 arm is deprecated in the same release and removed
in a follow-on breaking release after at least one release of soak. From the
removal onward, the tracking flow issues no GraphQL call and depends on no
paid or org-level GitHub feature: a free GitHub account and a repo are
sufficient, and the maintainers run exactly the code path adopters run.

## Consequences

- The GraphQL budget guard, the structure/state cache split, and the
  Projects-v2 branchwork become removable — the adapter converges on one
  backend instead of maintaining parity across two.
- The migration tooling (`migrate-board-to-issues.sh`) necessarily couples
  to both arms and therefore dies with the Projects arm; the removal
  release's migration note must instruct operators to run it *before*
  pulling past the removal (ADR 0005 covers the cutover mechanics).
- The issues-only path is deliberately uncached and always-live; migrating
  the four active boards onto it is the first real volume test of that
  posture. The soak window monitors REST consumption, with the existing
  per-board `cache=on` axis as the ready mitigation.
- Per-item ordering (the Projects `Seq` field) has no issues-only
  representation and is retired rather than emulated (ADR 0006).
- On a repo with multiple collaborators, adopting label-based tracking is a
  team-level decision — the labels land in shared tracker state. The docs
  state this, and the kernel enforces nothing on collaborators who don't
  run the tooling.
