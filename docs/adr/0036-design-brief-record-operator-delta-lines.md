---
title: "0036: The design-brief challenge record gains operator `delta` lines with a date-keyed legacy exemption"
---

## Status

Proposed

## Context

`claude/design-schema.md` § Challenge record defines two stop-line kinds,
`walk` (a coverage-walk stop) and `walkthrough` (a review-lens pass), and
§ Record completeness requires every kernel dimension to carry a `walk`
line before a brief may ratify — enforced by
`workflows/scripts/validate-design-brief.sh`. ADR 0035 removes the walk,
so that rule would deadlock every new brief. Reusing `walkthrough` for the
operator's per-dimension delta approval was reviewed and rejected: its
`source` is a review lens, so a single clustered lens line would satisfy
the operator gate — the gate would fail open.

epic: Towheads/temperloop#1938 — ratified brief
`Designs/temperloop - workshop two-phase interview` (private knowledge store)

## Decision

- Add kind **`delta`** with `source: operator`: one line per dimension,
  written by Phase 2's delta approval. Completeness rule 1 becomes "every
  kernel dimension carries a `delta` line". `walk` and `walkthrough` stay
  parsable.
- Add kind **`interview`**: per-decision lines (`D<n>` in the dim-list
  slot), written per round by `/interview`.
- The record-start marker is written **with** the first stop line, never
  ahead of it; the `facilitator-drafted, not from interview` flag is a line
  *after* the disposition line, since the validator reads the first
  non-blank line under a heading as the disposition.
- **Legacy exemption keyed on the record-start date**: a ratified brief
  whose `challenge-record-start:` date precedes the `delta` grammar's ship
  date (a literal constant in § Record completeness, set in the PR that
  lands it) is exempt from `delta` completeness whatever kinds its record
  carries. Keying on line shape instead ("`walk` present, `delta` absent")
  was tried and failed the first boundary case — a brief with no `walk`
  lines at all, ratified under the old validator.

## Consequences

- The validator's `MISSING-WALK-VERDICT` check retires;
  `MISSING-DELTA-VERDICT` replaces it, with fixtures for the legacy pass,
  the new-grammar pass, the missing-`delta` fail, and the flag line.
- Compatibility is asymmetric: legacy ratified briefs keep validating; a
  new-grammar brief fails an old-pinned validator, so on a shared repo
  every checkout that validates briefs syncs before anyone authors under
  the new grammar. Stated in the CHANGELOG migration line.
- `Designs/temperloop - workshop two-phase interview` is the named
  boundary fixture: ratified 2026-09-12 under the old validator with its
  operator lines recorded outside the parsed section.
