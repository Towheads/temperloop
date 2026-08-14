# tracker interface contract

`tracker` is the work-tracking seam between a caller (a pipeline script,
hook, or command) and wherever tracked work items actually live — a repo's
plain Issues. A caller that wants to resolve an item, read its status/fields,
set its status, walk its dependency edges, or land a new issue on the board
does so through this interface — never by hardcoding a `gh issue` invocation
or a REST path for a particular board. That indirection is what keeps
per-board identity (which repo, which owner) in one registry instead of
smeared across callers.

**One backend (ADR 0004).** The tracker formerly had two arms — a GitHub
Projects-v2 board (GraphQL) and issues-only (REST) — selected per board by
config. The Projects-v2 arm was deprecated in v0.15.0 and **removed** in the
BREAKING release after v0.25.0 (epic temperloop#524). Issues-only is now the
only backend: the tracking flow issues no GraphQL call and depends on no paid
or org-level GitHub feature. The `backend` config axis survives for exactly
one purpose — refusing a stale `backend=projects` line rather than silently
reinterpreting it (see Backend selection below).

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
same seam `board_repo` / `board_owner` already read.
Unlike `knowledge_store` (one process-wide `KNOWLEDGE_STORE_BACKEND` env
var), the tracker's per-board config carries **per-board identity** (repo, owner,
name), because one machine routinely drives several boards at once.

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
| `owner` | `<login>` | board-owner login. Distinct from the repo-owner above (#330); a board with a `repo=` line but no resolvable `owner=` fails LOUD rather than borrowing this checkout's own org (temperloop#798). |
| `name` | `<slug>` | board NAME alias → number (`board_resolve_name`). Purely additive. |
| `backend` | `issues` | vestigial. `issues` is a no-op; `projects` HARD-FAILS (see Backend selection). |
| `cache` | `on` | issue-plane read-cache enable (default off; see Caching & egress). |

**Rename note (window CLOSED in v0.19.0, temperloop#165).** The per-repo
state dir and the config namespace renamed `foundation/` → `temperloop/`. A
machine-level conf at the legacy `$XDG_CONFIG_HOME/foundation/boards.conf`
was honored through the window and is **no longer read**: `board.sh` (and
`make doctor`) now NAME such a file on stderr instead, so a machine whose only
conf sits at the legacy path is told why its boards look unconfigured rather
than silently falling through to the built-in maps. See `VERSIONING.md § CLI
surface`.

## Backend selection

`board_backend <N>` no longer *selects* anything — there is one backend:

```
board_backend <board#>  ->  "issues"   (rc 0, unconditionally)
                        ->  rc 1 + stderr, on an explicit backend=projects
```

**The one job it has left: refuse a stale `backend=projects` line.** A
`boards.conf` entry reading `backend=projects` returns **non-zero** with a
one-line error naming ADR 0004 and the migration path. It is never silently
resolved to `issues`.

That refusal is load-bearing, not cosmetic. A stale `backend=projects` line
expresses a real operator intent this build cannot honour, and quietly
reinterpreting it would move that board's state onto a different substrate
with no signal at all — which is exactly the failure **temperloop#908**
recorded, where a silently reverted cutover put four boards on the wrong path
and was found only by hand. Every public entry point (`board_resolve`,
`board_resolve_item`, `board_item_list`, `board_create_many`) propagates the
non-zero rather than proceeding, so the operation stops instead of writing to
an unintended substrate.

There is **no configuration path back** to Projects-v2. An adopter who wants
it forks `board.sh`. Migration for anyone still on the old arm: check out
v0.25.0, run its `migrate-board-to-issues.sh` (deleted in this release, per
ADR 0004's ordering pin), delete the `backend=projects` line, then pull.

Two properties remain worth stating, as deliberate asymmetries with
`knowledge_store`'s backend seam:

- **The backend set is closed, not an open registration seam.**
  `knowledge_store` lets anyone register a new backend by defining
  `_ks_backend_<name>_<op>` functions and pointing the env var at it. The
  tracker has exactly **one** backend, implemented inline in `board.sh`;
  there is no `_tracker_backend_<name>_*` extension point. Adding a backend
  is a change to `board.sh` itself, not a caller-side registration.
- **Per-board config, not a process-wide env var** (see Configuration above)
  — a machine routinely drives several boards at once.

**Superseded:** this section previously documented the built-in case map as
*additive-only*, with an unconfigured board resolving `"projects"` and **board
7 the sole in-code issues-only exception**. ADR 0005 § Decision and
§ Consequences recorded that this language survives the migration epic and is
"superseded only by the follow-on removal epic, which retires the Projects
defaults explicitly". This is that removal. Board 7 is no longer an exception
to anything — every board is issues-only, and board 7's only special-casing is
its `board_repo()` built-in-map entry. See ISSUES-ONLY-BACKEND.md § Selecting
the backend.

## Public interface

All functions are named `board_*` and operate over a board number `<N>`.
Grouped by role; each returns non-zero (without mutating) on a bad argument
or unknown board, never a silent wrong result.

**Registry / resolution** (the backend-selection layer):

```
board_repo <N>              ->  "owner/repo"
board_owner <N>             ->  board-owner login (fails loud if repo= is set
                            #     without a resolvable owner= — temperloop#798)
board_backend <N>           ->  "issues"; rc 1 on a stale backend=projects
board_registered_boards     ->  every known board number, ascending
board_resolve_name <name>   ->  board NAME alias -> number
```

**Whole-board / item resolution** (read path):

```
board_resolve <N>              # sets BOARD_ITEMS_JSON. Whole-board scan; the
                               #   worklist/reconcile/burst path. Fails LOUD
                               #   (non-zero) on a rate-limited/empty read
                               #   rather than leaving accessors on null.
                               #   Also sets BOARD_PROJECT_ID="" and
                               #   BOARD_FIELDS_JSON='{"fields":[]}' — VESTIGIAL
                               #   (no project node, no field schema), kept at
                               #   their documented empty values so a caller
                               #   reading them under `set -u` is unchanged
                               #   (temperloop#602).
board_resolve_item <N> <issue#>  # single-item resolve; ALWAYS-LIVE (sees
                                 #   Done), never cached — the claim-lock read
                                 #   path. Prefer for touching exactly one item.
board_item_list <N>            ->  item-list JSON on stdout (gh issue list,
                               #   live; optionally served by the issue-cache
                               #   store — see Caching & egress)
board_item_id <n> / board_item_title <n> / board_item_milestone <n>
                               #   jq accessors over BOARD_ITEMS_JSON
```

**Write path** (status / component / milestone / claim):

```
board_set_status <item-id> <option> [field]   # fnd:status:* label + open/close
                                              #   (Done = closed, no label).
                                              #   arg1 MUST be an ISSUE_<n>
                                              #   item-id; a PVTI_* id is
                                              #   REJECTED loud (ADR 0004).
board_close_done <N> <issue#>                 # Done from ANY state (open/closed/
                                              #   already-Done); no prior resolve
                                              #   needed; idempotent
board_set_component <item-id> <name>          # thin wrapper over set_status
board_stamp <item-id> <text>                  # claim-owner stamp
                                              #   (fnd:host/session:<verbatim>;
                                              #   empty text CLEARS it)
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
board_sub_issues <N> <issue#> [all|open|closed]  # parent -> child issue
                                              #   numbers; state filter,
                                              #   defaults to `all`
board_add_sub_issue <N> <parent#> <child#>    # link a native sub-issue (4xx if
                                              #   it exists -> non-zero, not silent)
board_remove_sub_issue <N> <parent#> <child#>
```

**Creation / capture:**

```
board_create_many <N> <url1> <num1> …         # batch landing; 3-way return
                                              #   (0/1/2) + BOARD_UNLANDED_ISSUES
board_create_on_board <N> <url> <num>         # single landing
board_capture_item <N> <url> <num>            # single landing; identical return
                                              #   contract across backends
                                              #   (foundation#1226, capture-item
                                              #   return-contract parity)
```

**Cache control:** none. `board_bust_structure` was removed with the
Projects-v2 structure cache it invalidated (ADR 0004). There is no adapter-owned
cache to bust: the whole-board read is live, and the optional issue-corpus store
is invalidated by `cache.sh`'s own `cache_dirty`/`cache_clear` (write-through
after every successful mutation — see Caching & egress).

**Removed with the Projects-v2 arm** (ADR 0004), listed so a caller that still
references one gets a name to grep rather than a silent `command not found`:
`board_project_number`, `board_field_id`, `board_option_id`,
`board_add_to_board`, `board_bust_structure`, and the internals
`_board_budget_guard`, `_board_cached_read`, `_board_cache_file`,
`_board_cache_bust`, `_board_cache_patch_*`, `_board_item_list_argv`,
`_board_item_list_fresh`, `_board_drop_pr_cards`. Settings `BOARD_CACHE_TTL`,
`BOARD_STRUCTURE_TTL`, `BOARD_CACHE_DIR`, `BOARD_ITEM_QUERY`,
`BOARD_BUDGET_GUARD*`, and `BOARD_CREATE_INDEX_RETRIES` went with them.

The consuming scripts routed through this seam — `claim.sh`, `capture.sh`,
`worklist.sh`, `reconcile.sh`, `pipeline-tick.sh`, `pipeline-drive.sh`, and the
`/build` board-mirror — carry **no backend branching**, which is now trivially
true: there is one backend.

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

One backend; the former `projects-v2` column is kept only as the historical
"what this replaced", so a reader migrating an old install can map the concepts.

| Dimension | issues-only (the only backend) | former projects-v2 (REMOVED, ADR 0004) |
|---|---|---|
| Item store | repo Issues | Projects-v2 board items |
| Item id | `ISSUE_<issue#>` | `PVTI_*` (now rejected loud) |
| Status | `fnd:status:*` label | single-select field |
| Done | issue **closed** (no label) | `Done` option |
| Component | `fnd:component:<slug>` label | single-select field |
| Claim stamp | `fnd:host/session:<verbatim>` label | Host/Session free-text field |
| Provisioning | none — any repo works | a board must exist |
| API surface | REST only | GraphQL (project) + REST (issue) |
| Rate budget | 5,000/hr REST bucket | 5,000-pt/hr GraphQL bucket |
| Read caching | live by default; optional issue-corpus store | structure(24h)+state(90s) cache |
| Seq ordering | removed, fails loud (ADR 0006) | numeric `Seq` field |
| Selected by | nothing — it is the only backend | `backend=projects` (now HARD-FAILS) |

## Caching & egress

**Egress: `gh` is the only network channel** — every call routes through the
single `_board_gh` seam; nothing in `board.sh` opens a socket directly (no
`curl`/`wget`/raw-socket). This mirrors `baseline_snapshot.contract.md`'s
"no egress beyond `gh` itself." The board adapter is **not** among the
producers scanned by the `test-producer-egress` gate (that gate covers the
Epic E value-loop producers); the tracker's egress discipline is the
single-`_board_gh`-seam convention stated here.

**One rate budget.** Every tracker call is REST, on its **5,000/hour** bucket.
The Projects-v2 **5,000-points/hour GraphQL** budget — and `_board_budget_guard`,
the pre-flight guard that warned or aborted on a near-empty one — no longer
apply: nothing in the tracking flow spends GraphQL points (ADR 0004). The
former structure(24h)/state(90s) cache split existed purely to relieve that
budget and was removed with it; `board.sh` now owns **no cache of its own**.

**Read caching** is off by default (every read is live). An
optional on-disk issue-cache store (`board/lib/cache.sh`, enabled per-board
with `board.<N>.cache=on`) can serve the whole-board read with a staleness
bound `CACHE_STORE_TTL` (default **3600s / 1h**, an env var, not a
`boards.conf` axis). It is now the ONLY cache in front of any board read. See
ISSUES-ONLY-BACKEND.md § Read cache staleness bound and
`board/lib/CACHE-STORE.md`.

## Non-goals of this seam (deliberately out of scope)

- **No caller-side backend routing.** Callers never branch on
  `board_backend`; if a caller finds itself asking "is this issues-only?",
  that logic belongs inside `board.sh`, not in the caller.
- **No open backend-registration seam.** Unlike `knowledge_store`, the
  backend set is closed — one backend, issues-only. A new backend is a change
  to `board.sh`, not an external plug-in point.
- **No Seq / positional ordering.** Retired with the Projects-v2 numeric
  ordering field (ADR 0006); `board_set_number` fails loud rather than
  emulating it on issues-only.
- **No per-item custom fields** beyond those expressible as
  `fnd:<field>:<value>` single-select-shaped labels — there is no free-form
  custom-field API on issues.
- **No structural board editing**, and nothing left to edit: with Projects-v2
  removed there is no field/option schema. This seam writes *values* (labels,
  milestones, edges), never *schema*.
- **No path back to Projects-v2.** Removed, not hidden behind a flag — a
  `backend=projects` conf line fails loud (see Backend selection). An adopter
  who needs it forks `board.sh`.
