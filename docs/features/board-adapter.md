---
title: Board adapter
slug: board-adapter
---

# Board adapter

`workflows/scripts/board/lib/board.sh` is the single sourced library every
board-touching script (`claim.sh`, `capture.sh`, `worklist.sh`,
`reconcile.sh`, `milestone.sh`, `release.sh`, `pr-enqueue.sh`) uses to talk
to a tracker board. There is **one backend: issues-only** — plain GitHub
Issues, read and written over REST, with no Projects board ever
provisioned. `fnd:`-namespaced labels carry item state, and "Done" is
simply the issue being closed. The former Projects-v2/GraphQL arm was
deprecated by ADR 0004 and **removed outright** in the Projects-v2 removal
release (epic temperloop#524); see
`workflows/scripts/board/ISSUES-ONLY-BACKEND.md` for the backend's own
reference. This library is kernel content — the canonical copy this repo
carries — synced byte-for-byte into every consuming repo that runs the same
build/sweep pipeline, so a fix here lands everywhere at once instead of
being re-patched per checkout.

Because the adapter speaks one backend, it needs no paid plan, no org, and
no Projects-v2 access: a stranger with `gh auth login` against a personal
repo has everything the pipeline requires.

## Problem

Before this library existed, each board-touching script re-implemented the
same board-resolution dance by hand: fetch the items, then read the state,
then edit — each one hard-coding the field-name strings (`"Status"`,
`"Host/Session"`) and option names (`"In Progress"`, `"Backlog"`). Four
call sites did this independently, so a single board rename broke all four,
some silently. The adapter exists so that resolution lives in exactly one
place, and so a caller never has to know how item state is physically
stored.

## How it works

**Resolve by name, one indirection seam.** Every field and option is looked
up by name, never by a hard-coded id, so a field being deleted and
re-created doesn't break the adapter. All network calls route through one
function, `_board_gh`, which is the seam tests override to replay canned
fixtures with zero network traffic.

**Item state rides labels.** Item CRUD and Status ride `fnd:`-namespaced
GitHub labels on the repo's issues; the claim stamp is a
`fnd:host/session:*` label, and Status is a `fnd:status:*` label. Done is
defined as the issue being **closed with no** `fnd:status:*` label, which
is why the adapter's own Done write — which strips the residual status
label and the claim stamp — is the primary mechanism for reaching Done,
not a redundant backstop. Labels are created lazily at point of use
(`_board_issues_ensure_label`), so nothing has to be pre-provisioned.

A short plain-language rundown of what the `fnd:*` labels actually are —
including that a non-adopting teammate can simply ignore them, the
shared-repo team-decision caveat, and the verbatim-hostname note on the
claim stamp — lives in `ISSUES-ONLY-BACKEND.md`'s § What `fnd:*` labels
mean; that same file's § Pruning GitHub's default labels documents the
(separate, one-time, operator-driven) label-taxonomy prune.

**Single-item resolve vs whole-board resolve.** `board_resolve <board>`
fetches the full item list — the heavy path, appropriate when a caller
(e.g. `worklist.sh`) needs to see every item at once.
`board_resolve_item <board> <issue#>` instead reads a single issue,
reshaped to look identical to a row from the whole-board item list, so
callers don't need to branch on which path resolved the data. Prefer the
single-item path for a single-item operation: both are live reads, so the
whole-board page is strictly more expensive with nothing extra to show for
it.

**Reads are live.** Every board read is a real REST call at the moment it
is issued — there is no cross-process cache in front of it. The one
optional exception is the per-board issue-corpus store (`lib/cache.sh`,
enabled with `board.<N>.cache=on` in `boards.conf` by a caller that has
sourced it): a durable, cross-session store of the full issue corpus that a
corpus renderer or pipeline driver can read without hitting GitHub at all.
It is the only cache in front of a board read. Callers that fire per-item
operations in a burst should therefore resolve the board **once** and reuse
the result, rather than re-resolving per item.

**Claim-lock semantics.** Claiming an item is two ordered writes: a
free-text ownership stamp (`board_stamp`, e.g. `<host>:<session>`) followed
by the observable commit (`board_set_status` to In Progress) — stamp first,
commit last, so a crash between the two leaves a detectable half-claim
rather than a silent double-claim. The adapter **refuses a genuinely
contended claim** — an item that is already In Progress with a *different*
existing stamp — because the item is already resolved by
`board_resolve_item` before anything is written, so the check costs no
extra API call. Re-claiming with your own stamp, and adopting an
In-Progress item with no existing stamp (repairing a half-claim), are both
treated as uncontended.

## Integration

Every board-touching script sources this library directly
(`source .../lib/board.sh`) rather than reimplementing issue reads and
label writes at the call site. Which repo and owner a given board number
resolves to is governed by an optional `boards.conf` file, checked first,
falling back to a built-in case map that keeps a `boards.conf`-less
consuming checkout working identically to before the config seam existed.

`board_backend <N>` still exists, but it now always answers `issues`. Its
only remaining job is to **refuse** a stale `board.<N>.backend=projects`
line left in an operator's `boards.conf`: rather than silently resolving it
to the issues path — which would quietly do something other than what the
line asks for — it exits non-zero and names the migration path. Every
board-facing function propagates that refusal rather than swallowing it.
There is **no configuration path back to Projects-v2**; an adopter who
wants one forks `board.sh`.

## Resource impact

Board traffic lands on REST's shared **5,000 requests/hour** bucket — the
same bucket CI-check polling and ordinary issue/PR porcelain draw from,
since the removal of the Projects-v2 arm collapsed what used to be two
independently-metered surfaces into one. The practical consequence is that
a drain now has to be fixed at its source — fewer calls, coarser polling,
or the issue-corpus store — because there is no second bucket left to move
a noisy caller onto as a relief valve. `docs/failure-modes/02-rest-budget-exhaustion.md`
is the worked example of exactly this trap. Storage growth is bounded by
the number of distinct host/session values that have ever claimed something
on a given repo (each becomes a persistent label object), not by claim
volume, since label creation is idempotent.

## Telemetry

`reconcile.sh`'s foreign-claim sweep is the observable surface for claim
contention — it reports, on demand, any item whose ownership stamp doesn't
match its expected claimant, and never auto-releases anything.
`reconcile.sh --status` and `--labels --apply` are the sweep for closes
that bypassed the adapter and so left a residual `fnd:status:*` label
behind. Call volume itself is observable through the `gh` call logger
(`docs/features/gh-perf.md`), which is where a board-read regression shows
up as a rising REST call count rather than as a functional failure.
