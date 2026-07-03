# Issues-only tracker backend — label/status/milestone contract

foundation #799, split 1/3 of the issues-only tracker adapter (Epic B, kernel
extraction). This is the contract the other two splits build on:

- **split 2/3 (claim/edges/cascade)** — the cross-session claim lock
  (Host/Session equivalent) and the close→Done cascade, for a board that has
  no Projects-v2 `Host/Session` field to stamp.
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
| `board_blocked_by_open` / `board_parent_issue` | **Unchanged, no new code** — same reason (per-issue REST, never Projects). |
| `board_stamp` / `board_set_number` | **Out of scope for this split** (Host/Session claim marker + Seq worklist order — owned by the claim/edges split). On an issues-only board these **fail loud** (return 1, no silent no-op) because `BOARD_FIELDS_JSON` carries no field schema — this is intentional, not a gap to route around. |

The item shape produced by the issues-only reshape:

```json
{"id":"ISSUE_105","content":{"number":105,"title":"…","type":"Issue"},"status":"Ready","component":"Ingest"}
```

— identical keys to the Projects-v2 shape (`id`, `content.number/title/type`,
flattened field values), so every existing jq-based reader of
`BOARD_ITEMS_JSON` works without modification.

## What this split intentionally does NOT do

- **No caching.** The issues-only path is always-live. It draws on REST's own
  5,000/hr budget, not the Projects-v2 GraphQL budget the on-disk cache in
  `lib/board.sh` exists to protect, so the caching machinery is simply not
  needed here. A future perf pass can add it if an issues-only board's volume
  ever makes this the bottleneck.
- **No claim lock / Host/Session.** That's the claim/edges split (2/3).
- **No Seq ordering.** Same — claim/edges split, or a future worklist-ordering
  item; `board_set_number` fails loud rather than guessing a convention.
- **No funnel wiring.** That's the funnel-integration split (3/3).

## Testing

`workflows/scripts/board/tests/test_issues_backend.sh` (run via `make
test-board`) is the fixture-replay suite for everything above: zero network,
sources `lib/board.sh`, overrides its `_board_gh` seam. It also carries the
**config-selection proof** — an unconfigured board's `gh project …` argv is
byte-identical to `test_board_replay.sh`'s pinned Projects-v2 call sequence,
demonstrating the seam is additive-only.
