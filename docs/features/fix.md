---
title: Fix
slug: fix
---

# Fix

## Problem

Sometimes you know exactly what you want fixed — a single issue number, or
a fix you can describe in one sentence — and you want it driven all the way
to merged without standing up an epic, writing a plan note, or draining a
whole board's worth of ungrouped work to get to it. The existing execution
paths don't fit that shape: one drives a decomposed epic through a
structured plan, the other drains a board's entire pool of ungrouped Ready
issues sequentially. Neither is "just make *this one thing* go." Without a
targeted front door, a single named fix either gets bundled into
ceremony it doesn't need, or waits in a pool behind unrelated work. `/fix`
exists to take one named target — an issue or a description — and carry it
to a terminal outcome, and nothing else.

## How it works

`/fix` is a thin driver that composes the pieces the other execution paths
already own; it does not re-implement claiming, worktrees, PR creation, CI
polling, or merging. For a target given as a description rather than an
issue number, it first mints an issue safely: it echoes the repository it
resolved and asks the operator to confirm it before writing anything,
probes for a plausible duplicate and asks rather than silently creating a
second issue, and scans the composed issue body against the same
personal-token denylist that guards outbound kernel content — because a new
issue is public content in a repository that may be open source.

With an issue in hand, `/fix` runs a read-only state probe *before any
mutation* and routes on its verdict. The probe reads ground-truth state —
is the issue open or already closed, does it carry an open question, is it
claimed by another live session, does it already have an open linked pull
request, or is it fresh, unclaimed work. Each verdict maps to exactly one
action: fresh work is claimed (claim-first, before any investigation) and
driven through the same single-item build mechanics the singleton-drain
path uses; an issue that already has one open pull request is *adopted* —
its existing PR is revalidated and merged rather than a duplicate opened;
an issue with an open question surfaces that question instead of driving;
an issue claimed elsewhere is reported and left alone, never stolen; a
closed issue is reported as already done; and an issue with more than one
open PR asks the operator which to adopt rather than guessing.

Every run ends at a terminal disposition — merged and closed, a spike
verdict-closed with a comment, parked on an open question, or a reported
no-op — never at "a PR was opened." Because the kernel repository is
hand-driven, the merge is always modal: `/fix` surfaces exactly one merge
confirmation for explicit operator approval, and it will not drive a draft
or another author's actively-worked PR past that gate without naming that
state in the prompt. A target too large for a single fix — one that is
itself an epic, or describes work spanning several parallel sub-units or
dependency levels — is refused and redirected to the design-and-decompose
path instead.

## Integration

`/fix` reuses the shared single-issue state probe and PR-revalidation
helper built for this driver, the same per-issue build mechanics the
singleton-drain path invokes as a one-item unit, and the same worktree
lifecycle, board adapter, PR, and CI-poll spine every other execution path
depends on — there is no parallel implementation of any of them. Its merge
approval routes through the same operator-decision seam the epic-execution
path uses for its gates. On any terminal disposition of an adopted or
funnel-touched target it clears stale routing labels so the item does not
re-surface to the recommender or the autonomous funnel as still-stuck. It
is a slash command, live only once installed to the running Claude Code
configuration — a change to its spec is inert until redeployed.

## Resource impact

The state probe is a single cheap read per run, deliberately run before any
mutation so a run that will not proceed (already-done, claimed-elsewhere)
spends nothing further. `/fix` drives exactly one target, so there is no
pool scan and no fan-out; the one build invocation runs in a fresh,
isolated process whose context is discarded on return. The adopt path opens
no new pull request at all — it revalidates and merges the existing one —
which avoids the duplicate-PR and duplicate-CI cost a naive re-drive would
incur.

## Telemetry

Each run appends one JSON-lines record to the same append-only, monthly-
rotated raw command-run telemetry stream the other pipeline commands write
to, carrying the single item processed and whether it merged, resolved as a
verdict, or parked. As elsewhere in the pipeline, the record's absence for a
run that should have executed is itself the observable failure signal.
