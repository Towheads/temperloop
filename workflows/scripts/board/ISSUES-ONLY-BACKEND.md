# Issues-only tracker backend — label/status/milestone contract

foundation #799, split 1/3 of the issues-only tracker adapter (Epic B, kernel
extraction). This is the contract the other two splits build on:

- **split 2/3 (claim/edges/cascade, foundation #800 — IMPLEMENTED)** — the
  cross-session claim lock (Host/Session equivalent), parent/child + blocking
  dependency edges, and the close→Done cascade, for a board that has no
  Projects-v2 fields to stamp. See § Claim lock, § Parent/child and
  dependency edges, and § Close→Done cascade below.
- **split 3/3 (funnel integration)** — wiring `funnel-tick.sh` /
  `funnel-drive.sh` to drive an issues-only repo.

Both consume the vocabulary and function-level interface below. **Do not
invent a second label scheme or a second set of adapter functions** — extend
this one (subtraction over mechanism).

## What "issues-only" means

A board is either **Projects-v2-backed** (the default — a GitHub Projects
board provisioned, everything in `lib/board.sh`'s pre-#799 code path) or
**issues-only**: no Projects board is ever provisioned or queried. Item CRUD
and Status ride plain `fnd:`-namespaced GitHub **labels** on the repo's
Issues, and "Done" is simply **the issue being closed**. Milestone intake
(release-phase axis) is unaffected either way — see below.

## Selecting the backend

A new **fourth `boards.conf` axis**, a peer to `repo` / `owner` / `project`
(same discovery order, same grep/cut-only parsing — see
`boards.conf.example`):

```
board.<N>.repo=<owner>/<repo>
board.<N>.backend=issues
```

`board_backend <N>` resolves it; default (no conf entry, or any value other
than `issues`) is `"projects"` — **byte-identical to the pre-#799 behavior**.
An issues-only board only needs the `repo` axis; `owner` / `project` are
Projects-v2-specific and simply never read on this path. There is
deliberately **no built-in case-map entry** defaulting any board number to
`issues` — the seam is additive-only, proven in
`tests/test_issues_backend.sh`'s config-selection case (an unconfigured board
still emits the exact `gh project …` argv `test_board_replay.sh` pins).

## The `fnd:` label vocabulary

| Label | Field | Meaning |
|---|---|---|
| `fnd:status:backlog` | Status | mirrors Projects' `Backlog` option |
| `fnd:status:ready` | Status | mirrors Projects' `Ready` option |
| `fnd:status:in-progress` | Status | mirrors Projects' `In Progress` option |
| *(none — issue is closed)* | Status | mirrors Projects' `Done` option |
| `fnd:component:<slug>` | Component | mirrors the board-native `Component` single-select |

General rule: a label is `fnd:<field-slug>:<value-slug>`, where `<field-slug>`
is the field name lowercased with spaces→hyphens (`Status`→`status`,
`Component`→`component`) and `<value-slug>` is the option name slugged the
same way (`"In Progress"`→`in-progress`). This is generic over any future
single-select-shaped field — no new plumbing needed to add one, just start
writing `fnd:<new-field-slug>:*` labels.

**Done is the one exception.** It carries **no label at all** — closing the
issue *is* the Done signal. Moving an item to Done strips any residual
`fnd:status:*` label and closes the issue; moving it *off* Done (to any other
status) reopens the issue and writes the new label. A read of a **closed**
issue always reports `status: "Done"` regardless of what labels remain on it
(defensive against stale labels from before this convention, or a manual
close). An **open** issue with no `fnd:status:*` label reads as unstatused
(no `.status` key) — distinct from Done.

At most one `fnd:status:*` label and one `fnd:component:*` label are present
on an issue at a time (single-select emulation): a status/component write
removes every other label sharing its prefix before/without re-adding the
target, and re-setting the already-current value is a no-op at the gh-call
level (no duplicate add, no needless close/reopen).

**Round-trip fidelity:** a value's *display form* is reconstructed from its
slug by title-casing each hyphen-separated word (`in-progress` → `In
Progress`). This is exact for the built-in Status vocabulary above. For a
`Component` value, whatever slug you write is what you get back
title-cased — pick component slugs you're happy to see re-title-cased (e.g.
`fnd:component:ingest` round-trips as `"Ingest"`; a slug with an
internally-capitalized display form, e.g. an acronym, will NOT round-trip
exactly — this is a known, accepted limitation of the generic slug/unslug
convention, not a bug).

## Function-level interface parity

Every adapter function a caller already uses works **unchanged** — same
name, same signature, same return semantics — selected purely by
`board_backend`. A consuming script (claim.sh, capture.sh, worklist.sh,
board-mirror.sh, funnel-tick.sh, …) needs **zero branching** on backend.

| Function | Issues-only behavior |
|---|---|
| `board_resolve <board#>` | No `gh project view/field-list`; `BOARD_ITEMS_JSON` = every OPEN issue reshaped (see below); `BOARD_PROJECT_ID=""`, `BOARD_FIELDS_JSON='{"fields":[]}'`. |
| `board_resolve_item <board#> <issue#>` | Single `gh api repos/<repo>/issues/<n>` read (always-live, sees Done too — unlike the whole-board read, which excludes closed issues the same way `-status:Done` excludes them on the Projects path). |
| `board_item_list <board#>` | `gh issue list -R <repo> --state open --json number,title,labels`, reshaped. Live only — no on-disk cache (REST's separate 5,000/hr bucket, not the Projects-v2 GraphQL budget the cache layer protects). |
| `board_item_id` / `board_item_title` | Unchanged — generic jq over `BOARD_ITEMS_JSON`, which carries the same shape either way. |
| `board_set_status <item-id> <option> [field]` | `item-id` is `ISSUE_<n>` (the issues-only counterpart to `PVTI_*`). Writes/removes `fnd:` labels + drives open/closed for Status; no Projects call. |
| `board_set_component <item-id> <name>` | Thin wrapper over `board_set_status`, unchanged. |
| `board_create_many` / `board_create_on_board` / `board_capture_item` | No `gh project item-add`, no index-lag retry (a label write is synchronous REST). Landing a fresh issue collapses to labeling it Backlog. |
| `board_active_milestones` / `board_set_milestone` / `board_set_milestone_description` | **Unchanged, no new code** — these were already REST-only (`repos/<repo>/milestones…`) and backend-agnostic before this split. Milestone intake (the `<!-- triage:active -->` marker convention) works identically on an issues-only board. |
| `board_blocked_by_open` / `board_parent_issue` | **Unchanged, no new code** — same reason (per-issue REST, never Projects). Backend-agnostic for free: works identically on a Projects-v2 or issues-only board. |
| `board_sub_issues` (NEW, #800) | Read-side counterpart to `board_parent_issue` — child issue numbers via GitHub's native sub-issues REST endpoint. Same shape as its siblings: per-issue REST, always live, backend-agnostic. See § Parent/child and dependency edges. |
| `board_stamp` (#800 — now IMPLEMENTED) | `ISSUE_n` routes to a free-text `fnd:host/session:<verbatim-text>` label (single label of that prefix kept at a time; empty text clears). See § Claim lock. |
| `board_claim_contended` (NEW, #800) | Issues-only-only pre-check: is `<issue#>` already In Progress under a DIFFERENT Host/Session stamp? See § Claim lock. Always reports "not contended" on a Projects-v2 board (zero behavior change there). |
| `board_set_number` | **Still out of scope** — Seq/worklist ordering is deferred to a future worklist-ordering item, not owned by the claim/edges split. On an issues-only board this still **fails loud** (return 1, no silent no-op) because `BOARD_FIELDS_JSON` carries no field schema — intentional, not a gap to route around. |

The item shape produced by the issues-only reshape:

```json
{"id":"ISSUE_105","content":{"number":105,"title":"…","type":"Issue"},"status":"Ready","component":"Ingest"}
```

— identical keys to the Projects-v2 shape (`id`, `content.number/title/type`,
flattened field values), so every existing jq-based reader of
`BOARD_ITEMS_JSON` works without modification.

## What split 1/3 (#799) intentionally did not do

- **No caching.** The issues-only path is always-live. It draws on REST's own
  5,000/hr budget, not the Projects-v2 GraphQL budget the on-disk cache in
  `lib/board.sh` exists to protect, so the caching machinery is simply not
  needed here. A future perf pass can add it if an issues-only board's volume
  ever makes this the bottleneck.
- ~~No claim lock / Host/Session.~~ **Filled in by #800** — see § Claim lock.
- ~~No parent/child or dependency edges.~~ **Filled in by #800** (mostly for
  free — see § Parent/child and dependency edges) — see that section.
- **No Seq ordering.** Still deferred — a future worklist-ordering item, not
  claim/edges; `board_set_number` fails loud rather than guessing a
  convention.
- **No funnel wiring.** That's the funnel-integration split (3/3).

## Claim lock (Host/Session-equivalent, foundation #800)

The Projects-v2 path's cross-session lock is two ordered writes to a
project item: `board_stamp` (owner metadata, "Host/Session" free-text field)
then `board_set_status` (the observable commit, Status → In Progress) — see
`claim.sh`'s own header comment for the stamp-first/commit-last safety
ordering (foundation #103/#135). **Notably, the Projects-v2 path never checks
before writing** — a second claim silently overwrites the first; the only
backstop is `reconcile.sh`'s separate, report-only "foreign claim" sweep
(never auto-releases).

The issues-only backend reuses the exact same two calls unchanged
(`board_stamp` / `board_set_status`, now both implemented for `ISSUE_*`) but
additionally REFUSES a genuinely contended claim, because the check is cheap
here (the item is already resolved by `board_resolve_item` before `claim.sh`
writes anything — no extra `gh` call):

- **Storage.** The stamp (`"<host>:<session8>"`, e.g. `mini:c33dce41`) is
  written as a single `fnd:host/session:<verbatim-text>` label — the ONE
  exception to the general `fnd:<field-slug>:<value-slug>` single-select
  convention: the value is stored **verbatim, never slugged**. Slugging
  lowercases, which would corrupt a mixed-case hostname and silently break
  the foreign-host comparison below. At most one label of this prefix is
  kept at a time (same single-value-per-field mechanics as Status/Component);
  an empty stamp clears the label (mirrors the Projects-v2 `--clear`
  semantics, foundation #259 — this is what makes build's epic park-back
  stamp-clear work here too). Read back, the value surfaces under the flattened
  key `"host/Session"` — the SAME key `reconcile.sh` / `worklist.sh` already
  read on the Projects-v2 path, so neither needed a single line of
  backend-branching to work against an issues-only board.
- **Growth.** Distinct stamp VALUES accumulate as distinct repo-level label
  objects over the tracker's lifetime (there is no safe "still referenced
  elsewhere" check before a `gh label delete`, since the same host:session
  commonly claims several issues). Growth is bounded by the number of
  distinct sessions that have ever claimed something on this repo, not by the
  number of claims (`gh label create` is idempotent/memoized) — accepted as
  cosmetic for realistic tracker volume.
- **Contention check.** `board_claim_contended <board> <issue#> <new-stamp>`
  (new function) reads the already-resolved item: CONTENDED iff the issue is
  currently In Progress AND carries an existing stamp that is present and
  DIFFERENT from `<new-stamp>`. Two cases are deliberately NOT contended,
  matching the Projects-v2 adoption behavior `test_claim.sh` case 3 pins:
  re-claiming with your OWN stamp (idempotent), and adopting an In-Progress
  item with NO existing stamp (repairing a half-claim, the #103 failure
  mode). `claim.sh` calls this once, right after resolving the item and
  before writing anything; on a contended result it prints who holds the
  claim and refuses (non-zero, no writes) rather than silently overwriting.
  On a Projects-v2 board this always reports "not contended" — the
  historical silent-overwrite behavior is completely unchanged there.
- **Release stays local-only, unchanged.** `release.sh` never touched the
  board on either backend — it only clears the terminal marker — so it needed
  no changes here.

## Parent/child and dependency edges (foundation #800)

Both relationships ride GitHub-native, per-issue REST endpoints that work on
a **plain issue with no Projects board provisioned at all** — so almost
everything here was already backend-agnostic before this split touched it:

- **Parent** — `board_parent_issue <board> <issue#>` (pre-existing, foundation
  #159, unchanged) resolves a sub-issue's parent epic from
  `.parent_issue_url`. Empty output = a directly-workable singleton (or an
  epic itself, which has no parent of its own).
- **Children** — `board_sub_issues <board> <issue#>` (NEW) is the read-side
  counterpart: `repos/<repo>/issues/<n>/sub_issues`, one child issue number
  per line. Same per-issue REST, always-live, backend-agnostic shape as its
  sibling.
- **Blocking dependencies** — `board_blocked_by_open <board> <issue#>`
  (pre-existing, unchanged) already reads GitHub's native issue
  *dependencies* relationship (`repos/<repo>/issues/<n>/dependencies/blocked_by`)
  — a first-class GitHub relationship, entirely separate from Status/labels/
  sub-issues, that was **already representable and readable on a plain issue
  with zero adapter code needed for this split**. No body-marker or
  label-based dependency scheme was invented (there was nothing to invent) —
  this is the "simplest faithful mechanism" the item description anticipated
  might be needed; it turned out to already exist.

All three functions gate on candidate items only (never the whole board) —
same caveat as every per-issue REST accessor in this file.

## Close→Done cascade (foundation #800)

On a Projects-v2 board, GH #340's "close→Done" automation is a real, async
GitHub-side workflow: closing an issue triggers the board's built-in
automation to move the linked project *item*'s Status to Done, which
`_board_cache_bust`/the 90s items-cache TTL eventually observes (foundation
#589's accepted residual staleness gap).

On an issues-only board there is no such automation, and **none is needed**:
"Done" is not a separate field that has to be kept in sync with "closed" — it
IS closed, by construction (`issue_item`'s jq reshape reports
`status: "Done"` for any closed issue regardless of labels; `board_set_status
… Done` closes the issue directly, no automation round-trip). Concretely,
what the GH #340 cascade does on Projects-v2 that this backend does NOT need:

- **No async lag.** A Projects-v2 close→Done is eventually-consistent (the
  automation fires, then the cache TTL catches up); an issues-only close is
  the SAME REST write board_set_status already made — the read-after-write is
  synchronous, not cache-dependent (this path has no cache at all, see
  above).
- **No separate "board card" to move.** There is no project item distinct
  from the issue to keep in sync — reading `.state` (open/closed) on the
  issue itself IS reading its board Status.
- **No stale-Done detection needed** the way `reconcile.sh`'s Projects-v2
  logic needs it (a card that says Ready/In-Progress but is actually
  closed) — a closed issue on this backend can never report anything but
  Done, by the jq reshape's own precedence (`if $state == "closed" then
  {status:"Done"}` is checked FIRST, before any label).

## Testing

`workflows/scripts/board/tests/test_issues_backend.sh` (run via `make
test-board`) is the fixture-replay suite for the split-1/3 (#799) surface:
zero network, sources `lib/board.sh`, overrides its `_board_gh` seam. It also
carries the **config-selection proof** — an unconfigured board's `gh project
…` argv is byte-identical to `test_board_replay.sh`'s pinned Projects-v2 call
sequence, demonstrating the seam is additive-only.

`workflows/scripts/board/tests/test_issues_claim_edges.sh` (also run via
`make test-board`) is the split-2/3 (#800) suite: `board_stamp` on `ISSUE_*`
(write, clear, round-trip through the `"host/Session"` flattened key),
`board_claim_contended` (contended / self-reclaim / half-claim-adoption /
unclaimed / Projects-v2-always-safe cases), `board_sub_issues`, and
`claim.sh`'s end-to-end contention refusal against a fake issues-only repo
(mirrors `test_claim.sh`'s replay style, but for the `ISSUE_*` path).
