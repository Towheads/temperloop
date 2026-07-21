---
title: "0011: /fix driver and issue-state resolution (resolve, reattach)"
---

## Status

Accepted

## Context

epic: temperloop#627

The pipeline had two board-scale drivers — `/build` (drains an approved
plan's dependency levels) and `/sweep` (drains a board's Ready
**singletons**, issues triage left ungrouped) — but no **targeted**
driver: a way to say "fix issue #N" (or a bare description) and have the
pipeline take exactly that one item to merged, without either scanning a
whole level or a whole singleton pool. Operators reached for `/sweep` or a
one-off manual sequence for this, which either dragged in unrelated
Ready items or hand-rolled the claim/adopt/CI/merge sequence each time —
including the failure modes a shared driver should prevent: stealing a
claim another session already holds, or opening a duplicate PR for an
issue that already has one in flight.

A single-issue driver needs to answer "what state is this issue actually
in, and what should happen next?" before it can act — is it already
claimed elsewhere, does an open PR already exist for it, is it already
closed, is it a fresh unclaimed issue? That state-resolution logic did
not exist as a reusable seam: the closest analog, `funnel-tick.sh`'s
`tick_board`, computes an equivalent classification but has it welded
inline to its tick loop (drive caps, per-tick counters, phase ordering —
see funnel-tick.sh lines ~1057–1249), so it cannot be called directly by
a single-issue probe without dragging tick-loop concerns along or risking
a refactor of a tested hot path (`tests/test_funnel_tick.sh`, 1146 lines).

An L0 spike (temperloop#634) settled the three open seams this decision
depends on against ground-truth reads of `funnel-tick.sh`,
`funnel-drive.sh`, and `claude/workflows/build-level.mjs` on `origin/main` —
recorded in the vault at `Decisions/temperloop - fix-driver
state-resolution seams (spike verdict)` (including a **CORRECTION**
section, applied at the start of the L2 build, that revises the original
`reattach` seam call — see § Decision below). This ADR records the
resulting decisions; all of it is already implemented and merged under
epic #627.

## Decision

**`/fix` is the targeted single-item peer to `/build` and `/sweep`.** It
takes one named target — an issue number or a free-text description — and
drives exactly that item to merged: claim it (never stealing a live claim
held by another session/host), adopt an existing open PR for it if one is
already in flight (never opening a duplicate), or start fresh work if
none exists. It is implemented as `claude/commands/fix.md`.

**State resolution is extracted into a reusable component,
`workflows/scripts/build/issue-state.sh`, with two subcommands:**

- **`resolve`** — issue ref in, structured route verdict out. Routes:
  `question-first` (a `needs-clarification` label is present),
  `claimed-elsewhere` (In Progress under a different host/session),
  `adopt` (an open linked PR is recoverable, or the issue carries the
  `funnel-merge-pending` label), `already-done` (issue closed), `fresh`
  (open, unclaimed, none of the above), and `ambiguous` (multiple open
  linked PRs found — `resolve` surfaces this rather than silently
  picking one, unlike funnel-tick's tick loop, which takes the first).
- **`reattach`** — open PR in, `{ready|not-ready, reason}` verdict out.
  It **never merges**; the caller (`/fix`, or any other adopter) owns the
  merge decision.

**Convergence with `funnel-tick.sh` is a shared classification
VOCABULARY, not a shared classifier library.** A shared lib was
considered and rejected: `funnel-tick.sh`'s routing decision is inline in
its tick loop, not factored into a reusable `classify_and_route(item)` —
extracting one would either drag tick-loop concerns (drive caps, per-tick
counters, phase ordering) into a single-issue probe that does not share
them, or require a risky refactor of a tested hot path for no benefit to
either caller. Instead, `resolve` sources the funnel's
`workflows/scripts/build/build.config.sh` `FUNNEL_*` label knobs
(`FUNNEL_ESCALATED_LABEL`, `FUNNEL_MERGE_PENDING_LABEL`, and the rest) and
re-implements the label checks it needs as thin, direct predicates over
those same literal strings (`needs-clarification`, `spike`, `decision`,
`funnel-merge-pending`, `funnel-escalated`) — `funnel-tick.sh` is a
driver, not a cleanly sourceable library, so `resolve` does not source it
directly. A **subset-lint test**,
`workflows/scripts/build/tests/test_issue_state_label_subset.sh`, asserts
`resolve`'s label-constant set is a subset of funnel-tick's, mechanically
preventing a parallel taxonomy from drifting in. (`resolve`'s own
`route:` names are its own surface and are not required to be a subset —
only the label-constant set is.)

**`reattach` is a bash spine-composition, not a `build-level.mjs`
mode.** The original spike verdict called for a new `mode:"reattach"`
entry in `claude/workflows/build-level.mjs`, reusing its `ciPollLoop` and
inline `pr.sh rebase` call. That call was corrected before the L2 build
started (recorded as a CORRECTION in the spike-verdict note):
`build-level.mjs` is a Workflow-**runtime** module — it closes over
injected `agent()`/`parallel()`/`log()` globals and ends in a top-level
`return await buildLevel()` — so it is neither `import()`-able nor
runnable outside that runtime, and a bash `issue-state.sh` cannot drive
it. The reuse target was never `ciPollLoop` itself; it was the spine
*scripts* `ciPollLoop` orchestrates. `reattach` therefore composes those
scripts directly in bash: `gh pr view` for liveness/mergeability,
`ci-poll.sh --sha <sha>` for the CI poll loop carrying the #254 SHA-pin
guard, and `pr.sh rebase` for the stale-base rebase when needed — the
same reuse-without-re-encoding outcome the original verdict wanted,
reached without touching `build-level.mjs` or its runtime dependency.

**`lib/pr-linkage.sh` is the single home for the open-PR-by-`Closes`-
linkage probe.** Ground truth found exactly two existing copies —
`funnel-tick.sh`'s `open_pr_for_issue` and `funnel-drive.sh`'s
`_open_pr_for_issue` — byte-identical in their `jq` body-match logic but
differing in fixture/test-double seams. `workflows/scripts/build/lib/pr-linkage.sh`
exports one `open_pr_for_issue`, parameterized to serve both existing
call shapes, as the single home for **new** callers (`resolve` sources
it; it ships no third inline copy). The two existing funnel copies are
**knowingly retained** rather than retired in this epic — retiring them
means editing the funnel hot path (`funnel-tick.sh` + its 1146-line
harness, `funnel-drive.sh` + its own tests) for no L1 benefit, and doing
so was out of scope for landing `resolve`. Their retirement is folded
into the existing adoption issue **#628** rather than left implicit.

**Later adopters, and the reuse-not-duplicate constraint.** `resolve` and
`reattach` are built as reusable components precisely so other single-
issue-state consumers converge on them instead of re-deriving the same
classification or reattach logic independently. The identified adopters
— `/sweep`'s per-issue claim/adopt decision, `/build`'s re-attach path
when resuming a parked item, funnel resume, and the funnel's own
open-PR-linkage-copy retirement (folding `funnel-tick.sh` /
`funnel-drive.sh` onto `lib/pr-linkage.sh`) — are all tracked under the
existing adoption issue **#628**. The constraint each adopter must honor
is reuse, not reimplementation: a new call site that needs "what state is
this issue in" or "is this PR ready to merge" calls `issue-state.sh
resolve`/`reattach`, it does not write a parallel classifier or a fourth
`open_pr_for_issue` copy.

## Consequences

- The pipeline gains a targeted single-item driver (`/fix`) filling the
  gap between epic-scale (`/build`) and singleton-pool-scale (`/sweep`)
  work, without an operator hand-rolling claim/adopt/merge sequencing.
- `issue-state.sh resolve`/`reattach` become the one reusable seam for
  "what state is this issue in" and "is this PR ready to merge" — a
  contract other drivers (#628's adopters) build against rather than
  reimplement.
- Convergence with `funnel-tick.sh` is enforced mechanically (the subset-
  lint test) rather than by convention, so the label taxonomy cannot
  silently fork even though the classifier logic itself deliberately does
  not converge.
- Two known duplicate copies of the open-PR-linkage probe remain in
  `funnel-tick.sh` and `funnel-drive.sh` post-this-epic — an accepted,
  explicitly tracked gap (#628), not an oversight ("knowingly retained"
  is a documented trade-off, not silent debt).
- `reattach`'s reuse of the CI-poll/SHA-pin/rebase spine lives entirely in
  bash (`ci-poll.sh`, `pr.sh`), so it stays reachable from a plain
  `issue-state.sh reattach --help` CLI invocation and carries no
  Workflow-runtime dependency — a deliberate scope boundary versus
  `build-level.mjs`, which remains the runtime `/fix` uses for the L3
  merge drive itself (a separate step from `reattach`'s revalidation).
- Follow-on adoption work (#628) is scoped but not yet built as of this
  ADR: `/sweep`, `/build` re-attach, funnel resume, and the funnel-copy
  retirement all still call their own pre-existing logic until they are
  migrated onto `issue-state.sh`.
