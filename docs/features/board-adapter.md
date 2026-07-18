---
title: Board adapter
slug: board-adapter
---

# Board adapter

`workflows/scripts/board/lib/board.sh` is the single sourced library every
board-touching script (`claim.sh`, `capture.sh`, `worklist.sh`,
`reconcile.sh`, `milestone.sh`, `release.sh`, `pr-enqueue.sh`) uses to talk
to a tracker board. **Issues-only — plain GitHub Issues, no Projects board
ever provisioned — is the default backend** (temperloop#460, ADR 0004): a
GitHub Projects-v2 board is still fully supported (`backend=projects`) and
is what this file originally documented, but it is now the deprecated
legacy arm, kept working through a soak window for any as-yet-unconverted
board (see `workflows/scripts/board/ISSUES-ONLY-BACKEND.md` § Issues-only
is now the default backend for the supersession statement and the removal
timeline, which is a separate follow-on epic, not this feature). This
library is kernel content — the canonical copy this repo carries — synced
byte-for-byte into every consuming repo that runs the same build/sweep
pipeline, so a fix here lands everywhere at once instead of being
re-patched per checkout.

## Problem

Before this library existed, each board-touching script re-implemented the
same board-resolution dance by hand: project view, then field list, then a
paginated item-list read, then an item edit — each one hard-coding the
field-name strings (`"Status"`, `"Host/Session"`) and option names
(`"In Progress"`, `"Backlog"`). Four call sites did this independently, so a
single board rename broke all four, some silently. Worse, GitHub Projects-v2
GraphQL reads are billed against a **shared 5,000-points/hour budget** — the
same bucket every board-reading process on the account draws from — and a
naive implementation re-fetches the whole board's structure (project id,
field/option schema) on every single-item operation. A session firing one
claim or status move per issue in a burst could drain the budget on
structure re-fetches alone, well before it touched the actual item data it
needed.

## How it works

**Resolve by name, one indirection seam.** Every field and option is looked
up by name, never by a hard-coded id, so a field being deleted and
re-created doesn't break the adapter. All network calls route through one
function, `_board_gh`, which is the seam tests override to replay canned
fixtures with zero network traffic.

**Two-tier cache, split on how often each half actually changes.** A single
short TTL used to cover both board *structure* (project id, field/option
schema — effectively invariant between edits) and board *items* (Status,
assignee stamps — mutated constantly), and structure re-fetches turned out
to be the dominant drain: over half of all GraphQL spend on some accounts.
Splitting the TTL fixed that:

- `BOARD_STRUCTURE_TTL` (default 86400s / 24h) — project view + field list.
  Invalidated only by an explicit `board_bust_structure` call after a
  structural edit (a new field, a changed single-select option set), never
  by an ordinary item write.
- `BOARD_CACHE_TTL` (default 90s) — the item-list page. Short because a
  claim or status move must be visible to the next read quickly; held
  correct within the window by write-invalidation (`_board_cache_bust`) so
  a read-after-write inside the same process never serves a stale item.

Setting `BOARD_CACHE_TTL=0` forces both classes fully live (the master
off-switch); `BOARD_STRUCTURE_TTL=0` with the item cache still on forces
just structure live.

**Single-item resolve vs whole-board resolve.** `board_resolve <board>`
fetches project view, field list, and the full item-list page — the heavy
path, appropriate when a caller (e.g. `worklist.sh`) needs to see every
item at once. `board_resolve_item <board> <issue#>` instead issues one
targeted GraphQL query for a single issue's project item and its field
values, reshaped to look identical to a row from the whole-board item list,
so callers don't need to branch on which path resolved the data. It reuses
the SAME structure cache `board_resolve` populates (project id and field
list rarely change between calls), so a long session doing many single-item
claims pays the structure GraphQL cost once, not once per claim — this was
the dominant fix behind the 90s/24h TTL split. `board_resolve_item` never
runs the pre-flight budget guard, because it never triggers the heavy
whole-board read the guard exists to protect against.

**Pre-flight budget guard.** Before a whole-board read that would actually
hit the network (cache disabled, missing, or expired), `_board_budget_guard`
makes one free REST call (`gh api rate_limit`, a separate 5,000/hour bucket
from Projects-v2 GraphQL) to check the remaining GraphQL budget. On a
near-empty budget it aborts with a clear stderr message naming the
remaining points and reset time, rather than letting the heavy read fail
opaquely partway through. On a healthy budget it's silent and adds no
overhead.

**Issues-only backend.** A board can be configured as `backend=issues`: item
CRUD and Status ride plain `fnd:`-namespaced GitHub labels on the repo's
issues instead of Projects-v2 fields, and "Done" is simply the issue being
closed — no Projects board provisioning at all. `board_backend <N>`
resolves which mode a given board number uses; the adapter's own built-in
fallback (no `boards.conf` entry) still resolves to `projects`, unchanged
from before this seam existed, but that fallback is no longer what "the
default" means at the policy level: every board this project's own pipeline
actually drives — all five maintainer repos — is configured `backend=issues`
via a committed `boards.conf` entry, per ADR 0004/0005. One kernel-tracked
board — board 7, the issue tracker for this repo itself — is hard-coded to
the issues-only backend directly in the adapter's built-in map (rather than
via a `boards.conf` entry), because being issues-only is a structural fact
of what that board is, not a per-deployment config choice; it is no longer
the *sole* issues-only board, only the sole one baked into the built-in map
itself (see `ISSUES-ONLY-BACKEND.md`'s § The temperloop tracker for the
full supersession note). Every board-facing function (`board_resolve`,
`board_resolve_item`, `board_stamp`, `board_set_status`, and so on) branches
internally on backend, so a caller written against the Projects-v2 shape
works unchanged against an issues-only board.

A short plain-language rundown of what the `fnd:*` labels actually are —
including that a non-adopting teammate can simply ignore them, the
shared-repo team-decision caveat, and the verbatim-hostname note on the
claim stamp — lives in `ISSUES-ONLY-BACKEND.md`'s § What `fnd:*` labels
mean; that same file's § Pruning GitHub's default labels documents the
(separate, one-time, operator-driven) label-taxonomy prune.

**Claim-lock semantics.** Claiming an item is two ordered writes: a
free-text ownership stamp (`board_stamp`, e.g. `<host>:<session>`) followed
by the observable commit (`board_set_status` to In Progress) — stamp first,
commit last, so a crash between the two leaves a detectable half-claim
rather than a silent double-claim. On the Projects-v2 backend the adapter
never checks before writing: a second claim silently overwrites the first,
and the only backstop is a separate, report-only "foreign claim" sweep in
`reconcile.sh` that never auto-releases anything. On the issues-only
backend the same two calls are reused, but the adapter additionally
**refuses a genuinely contended claim** — an item that is already In
Progress with a *different* existing stamp — because the item is already
resolved by `board_resolve_item` before anything is written, so the check
costs no extra API call. Re-claiming with your own stamp, and adopting an
In-Progress item with no existing stamp (repairing a half-claim), are both
treated as uncontended.

## Integration

Every board-touching script sources this library directly
(`source .../lib/board.sh`) rather than shelling out to raw `gh project` /
Projects GraphQL calls; a `PreToolUse` guard hook prompts on a direct raw
query as a backstop, but sourcing the adapter is what keeps that guard
dormant in practice. Which repo, owner, and Projects project-number a given
board number resolves to (and whether it uses the issues-only backend) is
governed by an optional `boards.conf` file, checked first, falling back to
a built-in case map that keeps a `boards.conf`-less consuming checkout
working identically to before the config seam existed. A structural board
edit (adding a field, changing a single-select's option set) must be
followed by an explicit `board_bust_structure` call, or the new schema can
go unseen by other callers for up to the structure TTL.

## Resource impact

Read traffic against the shared 5,000-points/hour Projects-v2 GraphQL
budget is the resource this adapter exists to protect: the two-tier cache
and the single-item resolve path are both aimed at keeping a normal
session's structure cost near-zero and its item-read cost bounded to one
fetch per 90-second window rather than one per operation. The on-disk cache
files are small, board-number-keyed JSON pages living under the process
temp directory; they age out on their own TTL and are never committed.
Storage growth on the issues-only backend is bounded by the number of
distinct host/session values that have ever claimed something on a given
repo (each becomes a persistent label object), not by claim volume, since
label creation is idempotent.

## Telemetry

The pre-flight budget guard prints a stderr warning naming the remaining
GraphQL points and reset time whenever a heavy whole-board read is about to
run on a low budget, and hard-aborts (no partial read) when the budget is
exhausted and the guard is not explicitly disabled. `reconcile.sh`'s
foreign-claim sweep is the observable surface for claim contention on the
Projects-v2 backend — it reports, on demand, any item whose ownership stamp
doesn't match its expected claimant. Cache behavior itself emits no
standing metric stream; the way to notice a cache-related regression is a
`board:` prefixed stderr line from the budget guard, or an unexpectedly
stale item read that self-heals within one cache TTL window.
