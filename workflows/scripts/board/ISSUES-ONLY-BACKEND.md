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
{"id":"ISSUE_105","content":{"number":105,"title":"…","type":"Issue"},"status":"Ready","component":"Ingest","labels":["fnd:status:ready","spike"]}
```

— identical keys to the Projects-v2 shape (`id`, `content.number/title/type`,
flattened field values, **and `labels`** — see § Funnel integration below),
so every existing jq-based reader of `BOARD_ITEMS_JSON` works without
modification.

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

## Funnel integration (foundation #801, split 3/3)

The final split: wiring `funnel-tick.sh` to drive an issues-only repo, and
proving it via a dual-adapter test suite. `funnel-tick.sh` itself needed
**zero backend branching** — it already only ever touches `BOARD_ITEMS_JSON`
through `board.sh`'s public accessors — but its Ready-item classification
(`classify_item`, `needs_clarification`, `funnel_escalated`, `pending_merge`)
reads a Ready item's **raw GitHub labels** directly (`spike`, `Foundational`,
`needs-clarification`, `funnel-escalated`, `funnel-merge-pending` — every one
of them a PLAIN label, never `fnd:`-namespaced). That is the "D3 seam": the
funnel's Ready-item read depends on `BOARD_ITEMS_JSON` carrying a `labels`
key, not just `status`/`component`.

**The gap split 1/3 left (now fixed).** The Projects-v2 path always had this
for free — `gh project item-list --format json`'s own default output already
carries a top-level `labels` array for Issue content, and `board_item_list` /
`_board_item_list_fresh` pass it through completely unreshaped (they only
strip PR cards and control characters). The issues-only `issue_item()` jq
def, by contrast, extracted ONLY the `fnd:`-prefixed labels into
`status`/`component`/`host/Session` and silently dropped every other label —
so a live funnel-tick against an issues-only board could never see `spike` /
`Foundational` / `needs-clarification`, and every Ready item would
misclassify as a fresh Operational `kind:code` drive (worse: probing for an
open PR via `gh pr list`, a step that must never fire in a SAFE-tier-only
scenario). Fixed by adding a `labels: $labels` passthrough to `issue_item()`
— the raw, UNFILTERED label list (the `fnd:` bookkeeping labels stay in it
too; harmless, since an equality check like `. == "spike"` never matches
`"fnd:status:ready"`). This makes the issues-only item shape a structural
match for the Projects-v2 one on this key, the same way it already was for
`status`/`component`/`host/Session`.

**What "SAFE-TIER" means here.** funnel-drive.sh's rung-5b executor
auto-runs only route-*/drain-*/a `kind:spike` drive — never a merge
(foundation #604's SAFE/MERGING tier split). A full safe-tier tick therefore
never needs to open a PR, so proving it against an issues-only repo needs no
merge-capable adapter surface at all — only the read path (`board_resolve` /
`board_item_list`) plus the plain-REST reads `funnel-tick.sh` already made
directly (`gh issue list --search …`, `gh issue view --json assignees`),
which were already backend-agnostic (per-issue/per-search REST, no Projects
call either way).

## The temperloop tracker (board 7, foundation #808)

The kernel-vs-overlay routing rule (CLAUDE.kernel.md § Kernel vs overlay
routing rule) needed a concrete board number before it could be *followed*
mechanically rather than just stated in prose — the global glossary used to
say the kernel tracker "has no `--board N` because it is issues-only today".
Being issues-only was never actually a reason it needed no number (an
issues-only board only needs the `repo` axis, same as any other — see above);
this split (F#808, Guard #3 of the routing rule, epic B) gives the adapter a
real handle: **board 7**, registered directly in `lib/board.sh`'s
`board_repo()` and `board_backend()` built-in maps (`repo` → the
temperloop repo; `backend` → `"issues"`), the SAME place boards 3-6
already carry their real, org-qualified repo values.

Not a committed `boards.conf` entry — deliberately. A real, org-qualified
`repo` value is exactly the class of literal this checkout's own
personal-token-denylist (`workflows/scripts/kernel/personal-token-denylist.tsv`)
forbids inside the kernel-vendored tree, with ONE sanctioned exception:
`board_repo()`'s own built-in case map, already carrying boards 3-6's real
values behind a trailing `# denylist:allow` marker for exactly this reason
(a `boards.conf`-less consumer must still resolve a real repo — see
§ Selecting the backend, above). Board 7 follows that SAME precedent rather
than inventing a second one: its case line in `board_repo()` carries the
same marker, and `board_backend()` gets one narrowly-scoped case (`7 →
"issues"`) as the sole, deliberate, permanent exception to that function's
general "no board defaults to issues in-code" rule — board 7's issues-only-
ness is a structural fact of what board 7 IS, not a per-deployment config
choice a `boards.conf` should carry. A per-machine/per-repo `boards.conf`
can still override board 7's `repo`/`backend` (checked FIRST, same
discovery order as any other board) exactly as it could for boards 3-6 —
this only hard-codes the DEFAULT a `boards.conf`-less consumer sees.
`test_boards_conf.sh`'s built-in-fallback assertions cover board 7 the same
way they already cover boards 3-6.

### `capture.sh --repo kernel` / `--repo ambiguous`

`capture.sh` gained a `--repo` flag — a conscious-routing peer to `--board`,
documented in the script's own header — rather than requiring every caller
to memorize board 7:

- `--repo kernel` — routes to board 7 outright (overrides `--board`). Use
  when the capture IS kernel-domain machinery (board adapter, build/sweep
  spine, install/doctor, quality gates — the "stranger test" the routing
  rule names).
- `--repo ambiguous` — routes to the SAME board 7, for the routing rule's
  **ambiguity clause**: "Ambiguous foundation-domain captures default to
  kernel. When a new rule is genuinely unclear which side it belongs on,
  but it concerns foundation's own pipeline machinery … route it to
  kernel" (CLAUDE.kernel.md § Kernel vs overlay routing rule). This is
  intentionally a DISTINCT spelling from `kernel`, purely for provenance:
  `--repo ambiguous` appends a note to the filed issue's body recording
  that the route was a DEFAULT, not a deliberate classification, so a
  human triaging the kernel tracker can see at a glance which issues were
  auto-routed and re-file with `--board 4` if the default guessed wrong.

No interactive TTY prompt is implemented for the ambiguous case — the issue
contract treats a disambiguation prompt as optional; the required part
(satisfied here) is that the DEFAULT and its rationale are documented, both
in `capture.sh`'s own header comment and in this section, and that the
default behavior is exercised by a test (`test_capture.sh`'s `--repo
kernel`/`--repo ambiguous` full-flow section, see § Testing below). A
capture with NEITHER `--board` nor `--repo` is unaffected — it still goes to
board 3 (stageFind) exactly as before; the ambiguity default only applies
when the caller opts into it via `--repo ambiguous`, because capture.sh has
no way to infer "this is foundation-domain" on its own from a bare title.

## Testing

`workflows/scripts/board/tests/test_issues_backend.sh` (run via `make
test-board`) is the fixture-replay suite for the split-1/3 (#799) surface:
zero network, sources `lib/board.sh`, overrides its `_board_gh` seam. It also
carries the **config-selection proof** — an unconfigured board's `gh project
…` argv is byte-identical to `test_board_replay.sh`'s pinned Projects-v2 call
sequence, demonstrating the seam is additive-only. Its case 3 also pins the
`labels` passthrough (#801).

`workflows/scripts/board/tests/test_issues_claim_edges.sh` (also run via
`make test-board`) is the split-2/3 (#800) suite: `board_stamp` on `ISSUE_*`
(write, clear, round-trip through the `"host/Session"` flattened key),
`board_claim_contended` (contended / self-reclaim / half-claim-adoption /
unclaimed / Projects-v2-always-safe cases), `board_sub_issues`, and
`claim.sh`'s end-to-end contention refusal against a fake issues-only repo
(mirrors `test_claim.sh`'s replay style, but for the `ISSUE_*` path).

`workflows/scripts/board/tests/test_board_dual_adapter.sh` (registered as its
own `make test-board-dual-adapter` gate — see `scripts/quality-gates.sh`) is
the split-3/3 (#801) suite: it runs `funnel-tick.sh` LIVE (not
`--dry-run --fixture`, which bypasses `board.sh` entirely and so can never
catch a reshape gap like the one above) against the SAME scenario twice — once
with the board configured `backend=projects`, once `backend=issues` — and
asserts both the full SAFE-TIER action set (drain-answer, drain-clarification,
a `kind:spike` drive-ready, route-foundational, route-already-assigned) and
byte-for-byte cross-arm parity of the resulting tick plan. It also asserts,
directly against the recorded `gh` call log, that no PR/merge/write-capable
call ever fires in either arm — the structural proof of "no merges."

`workflows/scripts/board/tests/test_boards_conf.sh` § 6 (foundation #808)
pins `board_repo 7` / `board_backend 7`'s built-in-map defaults (mirroring
its existing boards-3-6 fallback assertions in § 1) and that a repo-local
`boards.conf` can still override board 7 like any other board.
`workflows/scripts/board/tests/test_capture.sh`'s `--repo kernel`/`--repo
ambiguous` full-flow section drives `capture.sh` as a real subprocess against
a bespoke fake `gh` (the shared `fixtures/fake_gh.sh` is Projects-v2 shaped
and doesn't understand the issues-only backend's REST verbs). To keep this
NON-exempt test file free of the real org literal (only `board_repo()`'s own
case line — see above — is a sanctioned exception), the test overrides board
7's `repo` to a placeholder via a scoped `boards.conf` (the same override
mechanism a real consumer would use), then pins: `gh issue create` targets
that repo; no `gh project …` call is ever made; the `fnd:status:backlog`
label is both ensured (`gh label create`) and applied (`gh issue edit
--add-label`); and `--repo ambiguous`'s filed issue body carries the
documented ambiguity-default provenance note verbatim.
