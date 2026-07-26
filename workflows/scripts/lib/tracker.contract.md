# tracker interface contract

`tracker` is the work-tracking seam between a caller (a pipeline script,
hook, or command) and wherever tracked work items actually live — a GitHub
Projects-v2 board, or a repo's plain Issues. A caller that wants to resolve
an item, read its status/fields, set its status, walk its dependency edges,
or land a new issue on the board does so through this interface — never by
hardcoding a Projects-v2 GraphQL query or a `gh project` invocation for a
particular board. That indirection is what lets one install drive a
Projects-v2 board while another drives an issues-only repo, with **zero
backend branching in callers** — same function name, same signature, backend
selected per-board by config.

Implementation: `workflows/scripts/board/lib/board.sh` (bash, 3.2-compatible)
— there is no separate `tracker.sh`; "tracker" is the seam's conceptual name
and `board.sh` is the one library that implements it. It is a **sourced**
shell library, not an executable — `source .../board/lib/board.sh` to bring
the interface into scope. It sets no shell options; the sourcing script owns
`set -euo pipefail` (or whatever discipline it uses). This doc is the
seam-level contract, symmetric with `knowledge_store.contract.md`; the
issues-only backend's operational deep-dive (label vocabulary, claim lock,
edges, close→Done cascade) lives in the companion
`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`, cross-referenced by section
throughout rather than restated here.

Every board interaction routes through a single indirection seam,
`_board_gh` — `_board_gh() { GH_CALL_OP=... gh "$@"; }` — which is both the
**sole network egress point** and the **fixture-replay test seam** (override
it after sourcing to replay recorded `gh` output for zero-network testing).
This is the direct analogue of `knowledge_store`'s backend-dispatch
indirection: one place every call pipelines through.

## Configuration

The tracker is configured through `boards.conf`, a small key=value file — the
same seam `board_repo` / `board_owner` / `board_project_number` already read.
Unlike `knowledge_store` (one process-wide `KNOWLEDGE_STORE_BACKEND` env
var), the tracker's backend is selected **per board**, because one machine
routinely drives several boards at once. This is a deliberate asymmetry with
`knowledge_store`, noted again under Backend selection below.

Discovery order — the first file literally named `boards.conf` found wins
(see `boards.conf.example`):

1. machine-level: `$XDG_CONFIG_HOME/temperloop/boards.conf`
2. composed-tree consumer-root conf (a vendoring repo's own root)
3. repo-local: `workflows/scripts/board/boards.conf`
4. built-in case maps in `board.sh` (the fallback when no conf entry exists)

The file is parsed with **grep/cut only — never sourced or eval'd** — so it
can register data but never execute code (the security posture, mirroring how
`knowledge_store` documents its config seam). Format is one
`board.<N>.<axis>=<value>` per line. Axes:

| Axis | Value | Meaning |
|---|---|---|
| `repo` | `<owner>/<name>` | repo-owner axis (`gh issue create -R`, REST). The only axis an issues-only board needs. |
| `owner` | `<login>` | project-owner axis (`gh project … --owner`). Projects-v2 only. |
| `project` | `<number>` | Projects-v2 project number. Projects-v2 only. |
| `name` | `<slug>` | board NAME alias → number (`board_resolve_name`). Purely additive. |
| `backend` | `issues` | tracker backend axis (default `projects`; see below). |
| `cache` | `on` | issue-plane read-cache enable (default off; see Caching & egress). |

**Rename-window note (v0.15.0 → removed in v0.19.0, temperloop#165).** The
per-repo state dir and the config namespace renamed `foundation/` →
`temperloop/` (read-old-write-new). A machine-level conf at the legacy
`$XDG_CONFIG_HOME/foundation/boards.conf` is honored during the window; a
fresh install always writes the new path. See `VERSIONING.md § CLI surface`.

## Backend selection

`board_backend <N>` resolves a board number to its backend:

```
board_backend <board#>  ->  "issues" | "projects" (default)
```

The default — no conf entry, or any value other than `issues` — is
`"projects"`, **byte-identical to the pre-issues-only behavior**. Three
properties are worth stating explicitly, because they are the deliberate
asymmetries with `knowledge_store`'s backend seam:

- **The backend set is closed, not an open registration seam.**
  `knowledge_store` lets anyone register a new backend by defining
  `_ks_backend_<name>_<op>` functions and pointing the env var at it. The
  tracker has exactly **two** backends — `projects` and `issues` — both
  implemented inline in `board.sh`; there is no `_tracker_backend_<name>_*`
  extension point. Adding a third backend is a change to `board.sh` itself,
  not a caller-side registration.
- **Selection is per-board config, not a process-wide env var** (see
  Configuration above).
- **The `backend` axis resolves per-key across the conf layers**, unlike the
  whole-file-first-hit-wins `repo`/`owner`/`project` axes: a machine-level
  conf silent on `backend` for a board falls through to a repo-local
  `backend=` line rather than jumping straight to the built-in map (a
  committed repo-local `backend=issues` is what lets a repo declare its own
  backend without every operator's machine conf having to). See
  `board_backend`'s header comment and `boards.conf.example` for the exact
  layering.

There is deliberately **no built-in case-map entry** defaulting a board to
`issues` — the seam is additive-only — with exactly one exception: **board 7,
the kernel's own tracker (the temperloop repo)**, whose issues-only-ness is
baked into `board_backend`'s built-in map because it is a structural fact of
what board 7 *is*, not a per-deployment choice. See ISSUES-ONLY-BACKEND.md
§ The temperloop tracker (board 7). Every other fleet board reaches
`issues` via a committed `boards.conf` entry (ADR 0004 "issues-only default
backend" / ADR 0005 "repo-local conf cutover", under `docs/adr/`).

## Public interface

All functions are named `board_*` and operate over a board number `<N>`.
Grouped by role; each returns non-zero (without mutating) on a bad argument
or unknown board, never a silent wrong result.

**Registry / resolution** (the backend-selection layer):

```
board_repo <N>              ->  "owner/repo"
board_owner <N>             ->  project-owner login          (Projects-v2)
board_project_number <N>    ->  Projects-v2 project number   (Projects-v2)
board_backend <N>           ->  "issues" | "projects"
board_registered_boards     ->  every known board number, ascending
board_resolve_name <name>   ->  board NAME alias -> number
```

**Whole-board / item resolution** (read path):

```
board_resolve <N>              # sets BOARD_ITEMS_JSON, BOARD_PROJECT_ID,
                               #   BOARD_FIELDS_JSON. Whole-board scan; the
                               #   worklist/reconcile/burst path. Fails LOUD
                               #   (non-zero) on a rate-limited/empty read
                               #   rather than leaving accessors on null.
board_resolve_item <N> <issue#>  # single-item resolve; ALWAYS-LIVE (sees
                                 #   Done), never cached — the claim-lock read
                                 #   path. Prefer for touching exactly one item.
board_item_list <N>            ->  item-list JSON on stdout (Projects: GraphQL,
                               #   cached; issues: gh issue list, live)
board_item_id <n> / board_item_title <n> / board_item_milestone <n>
                               #   jq accessors over BOARD_ITEMS_JSON
board_field_id / board_option_id   # Projects-v2 field/option id by NAME
```

**Write path** (status / component / milestone / claim):

```
board_set_status <item-id> <option> [field]   # Projects: item-edit; issues:
                                              #   fnd:status:* label + open/close.
                                              #   arg1 MUST be a PVTI_* item-id.
board_set_component <item-id> <name>          # thin wrapper over set_status
board_stamp <item-id> <text>                  # claim-owner stamp (Projects:
                                              #   Host/Session field; issues:
                                              #   fnd:host/session:<verbatim>)
board_claim_contended <N> <issue#> <stamp>    # cheap pre-write contention check:
                                              #   prints foreign stamp + rc 0 if
                                              #   contended; rc 1 if safe to claim
board_set_milestone <N> <issue#> <title>      # release-phase axis; REST-only,
board_active_milestones <N>                   #   backend-agnostic
board_set_milestone_description <N> <title> <desc>
board_set_number                              # RETIRED (ADR 0006 "Seq retired
                                              #   on issues-only"); fails loud
```

**Edges / relationships** (per-issue REST, backend-agnostic):

```
board_blocked_by_open <N> <issue#>            # read open blocker edges
board_blocked_by_add <N> <issue#> <blocker#>  # add a dependency edge (422 if
                                              #   it exists -> non-zero, not silent)
board_blocked_by_remove <N> <issue#> <blocker#>
board_parent_issue <N> <issue#>               # sub-issue -> parent epic number
board_sub_issues <N> <issue#>                 # parent -> child issue numbers
```

**Creation / capture:**

```
board_add_to_board <N> <issue-url>            # add an existing issue to the board
board_create_many <N> <url1> <num1> …         # batch landing; 3-way return
                                              #   (0/1/2) + BOARD_UNLANDED_ISSUES
board_create_on_board <N> <url> <num>         # single landing
board_capture_item <N> <url> <num>            # single landing; identical return
                                              #   contract across backends
                                              #   (foundation#1226, capture-item
                                              #   return-contract parity)
```

**Cache control:**

```
board_bust_structure [N]     # invalidate the structure cache after a manual
                             #   board edit (field/option create). Structure
                             #   only — the items page has its own short TTL.
```

The consuming scripts routed through this seam — `claim.sh`, `capture.sh`,
`worklist.sh`, `reconcile.sh`, `pipeline-tick.sh`, `pipeline-drive.sh`, and the
`/build` board-mirror — carry **no backend branching**: the backend is
chosen entirely inside these functions by `board_backend`.

## The projects-v2 backend

The original arm: a GitHub Projects-v2 board provisioned, items and their
single-select fields (Status, Component) stamped via `gh project item-edit`,
resolved-by-**name** (field/option ids are never hardcoded — they're resolved
from the cached field list). This is the deprecated-not-removed legacy arm
during the issues-only soak window (ADR 0005; ISSUES-ONLY-BACKEND.md
§ Issues-only is now the default backend). Its GraphQL calls draw on the
shared budget documented under Caching & egress.

## The issues-only backend

No Projects board is ever provisioned or queried. Item CRUD and Status ride
`fnd:`-namespaced GitHub **labels** on the repo's Issues, and **"Done" is the
issue being closed** (it carries no label at all). This is now the default
tracking backend for every board this pipeline drives (ADR 0004). The full
operational contract — the `fnd:*` label vocabulary, the Host/Session claim
lock, parent/child + blocking dependency edges, and the close→Done cascade —
is owned by `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`; this contract
does not restate it. See in particular:

- **§ The label vocabulary** — `fnd:<field-slug>:<value-slug>`; Done = closed
  (the one exception); the unstatused-open-issue edge case.
- **§ Function-level interface parity** — the per-function backend-behavior
  table proving callers need no branching.
- **§ Claim lock (Host/Session-equivalent)** — `fnd:host/session:<host>:<session>`,
  stored **verbatim, never slugged** (a repo-visible hostname exposure the
  doc calls out as intentional — the consent posture, mirroring
  `baseline_snapshot.contract.md`'s).
- **§ Parent/child and dependency edges** and **§ Close→Done cascade**.

## Backend matrix

| Dimension | projects-v2 | issues-only |
|---|---|---|
| Item store | Projects-v2 board items | repo Issues |
| Status | single-select field | `fnd:status:*` label |
| Done | `Done` option | issue **closed** (no label) |
| Component | single-select field | `fnd:component:<slug>` label |
| Claim stamp | Host/Session free-text field | `fnd:host/session:<verbatim>` label |
| Provisioning | a board must exist | none — any repo works |
| API surface | GraphQL (project) + REST (issue) | REST only |
| Rate budget | 5,000-pt/hr GraphQL bucket | 5,000/hr REST bucket (separate) |
| Read caching | structure(24h)+state(90s) cache | live by default; optional issue-cache |
| Seq ordering | — | removed, fails loud (ADR 0006) |
| Selected by | default (or `backend=projects`) | `board.<N>.backend=issues` (board 7 in-code) |

## Caching & egress

**Egress: `gh` is the only network channel** — every call routes through the
single `_board_gh` seam; nothing in `board.sh` opens a socket directly (no
`curl`/`wget`/raw-socket). This mirrors `baseline_snapshot.contract.md`'s
"no egress beyond `gh` itself." The board adapter is **not** among the
producers scanned by the `test-producer-egress` gate (that gate covers the
Epic E value-loop producers); the tracker's egress discipline is the
single-`_board_gh`-seam convention stated here plus the `board-adapter-guard`
PreToolUse hook that steers raw `gh project` calls back onto the adapter.

**Rate budgets differ by backend.** The Projects-v2 arm spends the
**5,000-points/hour GraphQL** budget (guarded by `_board_budget_guard`); the
issues-only arm uses REST's **separate 5,000/hour** bucket and never touches
the GraphQL budget — a distinction that matters when reasoning about which
runs can starve which.

**The structure/state cache split** (Projects-v2 arm), deliberately split
because board *structure* was 56% of board GraphQL:

- **Structure cache** (project id + field/option schema): long TTL
  `BOARD_STRUCTURE_TTL` (default **86400s / 24h**), invalidated only by
  `board_bust_structure` (run it after any manual field/option edit — see the
  board-adapter rule in the process docs).
- **State/items cache** (the item-list page): short TTL `BOARD_CACHE_TTL`
  (default **90s**) plus write-invalidation. `BOARD_CACHE_TTL=0` is the
  master off-switch (fully live, both classes).

**Issues-only read caching** is off by default (every read is live). An
optional on-disk issue-cache store (`board/lib/cache.sh`, enabled per-board
with `board.<N>.cache=on`) can serve the whole-board read with a staleness
bound `CACHE_STORE_TTL` (default **3600s / 1h**, an env var, not a
`boards.conf` axis). The read-dispatch short-circuit that consults it fires
today only for a `backend=issues` board. See ISSUES-ONLY-BACKEND.md § Read
cache staleness bound and `board/lib/CACHE-STORE.md`.

## Non-goals of this seam (deliberately out of scope)

- **No caller-side backend routing.** Callers never branch on
  `board_backend`; if a caller finds itself asking "is this issues-only?",
  that logic belongs inside `board.sh`, not in the caller.
- **No open backend-registration seam.** Unlike `knowledge_store`, the
  backend set is closed (projects / issues). A new backend is a change to
  `board.sh`, not an external plug-in point.
- **No Seq / positional ordering.** Retired with the Projects-v2 numeric
  ordering field (ADR 0006); `board_set_number` fails loud rather than
  emulating it on issues-only.
- **No per-item Projects-v2 fields on the issues-only backend** beyond those
  expressible as `fnd:<field>:<value>` single-select-shaped labels — there is
  no free-form custom-field API on issues.
- **No structural board editing.** Creating a field or adding a single-select
  option is a raw `gh` / `updateProjectV2Field` operation the adapter does
  not wrap (followed by `board_bust_structure`); this seam resolves and
  writes *values*, not *schema*.
