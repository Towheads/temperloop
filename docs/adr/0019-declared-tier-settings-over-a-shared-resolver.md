---
title: "0019: declared tier settings over a shared tier resolver"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#972

The kernel decides which model an agent seat runs on in five unrelated places:
`/assess` stamps a `model:` onto plan items from `size` and `kind`; agent files
declare their own tier in frontmatter; four config settings name tiers for
specific jobs; two lines in `build-level.mjs` hardcode `'haiku'`; and `/sweep`
and `/fix` set nothing at all, so their workers inherit the session model — the
most expensive one. A sweep clearing twenty Ready singletons runs twenty
top-tier workers.

The obvious response is a shared tier resolver that all call sites consult. That
was the design under review, and it did not survive its own premise gate.

Two things had to be established first. `/sweep` and `/fix` are not *forgetting*
to tier — both specs document the fallback deliberately, `model: <undef>, // no
plan size → inherit the session model (top tier; safe)`. Tier is derived from a
plan item's `size`, and a singleton has no plan item. So the gap is a missing
*capability*, not untidiness.

The decisive observation came from re-running the subtraction test against that
corrected framing, which the original case-against had never been tested on.
`/assess`'s rule computes a tier from three inputs: `size`, `kind`, and whether
the touched files are advisory-only-verified spec-prose. For a plan-less seat,
`kind` is trivially derivable and the file class is approximable. **`size` is
not derivable at all** — nobody sized the work.

And a resolver faces the identical deficit. No new component conjures a size for
work nobody sized. The gap is not "no mechanism exists to hold the answer"; it
is "no signal exists to compute the answer from." A resolver would relocate the
guess into a new file, not close it.

## Decision

**Plan-less seats take their tier from declared configuration settings. No
shared tier-resolution component is built.**

`/sweep` Phase-2 workers read `SWEEP_WORKER_MODEL`; `/fix`'s worker reads
`FIX_WORKER_MODEL`; the two `build-level.mjs` machinery seats get their own
named settings. All follow the existing Named-setting convention — declared in
`workflows/scripts/build/build.config.sh`, registered in
`workflows/scripts/config/setting-registry.tsv`, and held to registry-shell
equality by `check-setting-registry.sh`.

**All default to absent, meaning inherit the session model.** Behavior is
byte-identical for anyone who configures nothing. Flipping any default to a
cheaper tier is deferred to Towheads/temperloop#971 behind measurement
preconditions.

Declared settings eliminate the guess rather than relocating it: the operator
states the tier for their own seats instead of a component inferring it from
signals that may not correlate with scope.

## Consequences

**What this buys.** No new component, no new seam, no new shared dependency.
Five independently-failing mechanisms stay independent rather than consolidating
into one shared point of failure for four consumers — a blast-radius trade the
resolver design never stated. The change is additive and the release stays
MINOR, because an adopter who sets nothing sees no behavioral change.

**What it costs.** Tier selection for plan-less seats becomes something an
operator must *choose*, not something the kernel infers. A stranger who never
reads the feature doc never tunes it, and their `/sweep` and `/fix` runs stay on
the session model indefinitely. That is a real adoption cost, accepted
deliberately: an inferred tier would be a guess presented as a decision, and a
wrong guess on a seat whose output is not mechanically gated is exactly what the
tier-by-verification policy (Towheads/foundation#247) exists to prevent.

**What is explicitly not promised.** There is no mechanical guarantee that every
tier decision in the kernel routes through one place — an acceptance clause
claiming so was drafted and dropped as false on the design's own terms, since
the machinery seats are settings rather than resolver calls and nothing prevents
a future call site from hand-picking a tier inline. Tier-site discipline is an
authoring standard with a review backstop. Saying so is preferable to naming a
gate that does not exist.

**Follow-on work.** Towheads/temperloop#971 owns the deferred default flip and
the measurement that would justify it, including the control that matters: a
cheaper tier which triggers retries can lower per-seat spend while raising
whole-job cost, so the delta must be measured including repairs.
