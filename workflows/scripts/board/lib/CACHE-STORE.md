# cache.sh — canonical-layer issue-cache store

Sibling doc to `cache.sh` (F#988 Contract, epic "canonical-item cache layer").
This is the schema/contract note a later consumer (a corpus renderer, a
funnel driver, anything that wants to read "every issue in this repo" without
re-paying GitHub every time) reads to know what's on disk and what it means.

## Why this exists, and how it differs from board.sh's own cache

`board.sh` already has a read cache (`BOARD_CACHE_TTL` / `_board_cached_read`
— see its header comment), but that one is narrow: in-memory-per-process-class
relief for the Projects-v2 GraphQL budget, keyed on a single board's active
(non-Done) item-list page, living in `$TMPDIR` with a short TTL.

`cache.sh` is a different, broader thing: a **backend-agnostic, durable,
cross-session store of the full issue corpus** for a repo — every issue,
open and closed, with its body, parent linkage, and comments — hoisted above
board.sh's backend dispatch so it serves a Projects-v2 board and an
issues-only board identically (both are just "issues in repo X" underneath).
It rides the REST issues-list bucket exclusively, **never** GraphQL, so it
never competes with the Projects-v2 budget board.sh's own cache protects.

## Design seam: board number OR explicit repo

Every public function's first argument is either:
- an **"owner/repo" string** (contains a `/`) — used verbatim. This is the
  fully standalone path: `cache.sh` never sources `board.sh` and has zero
  hard dependency on it.
- a **bare board number** (e.g. `4`) — resolved via `board_repo()`, which
  must already be in scope (i.e. the caller sourced `board.sh` first, in the
  same shell, before sourcing `cache.sh`). If `board_repo` isn't defined,
  `cache.sh` fails loud with a one-line stderr hint rather than guessing.

This keeps the composition direction one-way: `cache.sh` may be layered on
top of `board.sh`, but `board.sh`'s own sync/vendor set stays self-contained
— a consumer checkout that sources only `board.sh` is completely unaffected
by `cache.sh` existing at all.

## On-disk layout

```
${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}/issues/<owner>-<repo>/
  snapshot.jsonl        # one JSON object per line — the RAW REST issue row
                        # (GitHub's `gh api repos/<r>/issues` shape), PR rows
                        # filtered out, ALL states (open + closed) included.
                        # Parent linkage (`.parent`, `.sub_issues_summary`,
                        # present on the bulk REST payload as of 2026-07)
                        # rides through unmodified — this store does no
                        # reshaping, so any field GitHub adds to the issues
                        # REST payload is preserved for free.
  meta.json             # { "schema_version": 1, "repo": "owner/repo",
                        #   "last_refresh": <unix epoch of last successful
                        #   snapshot persist> }
  details/
    <issue-number>.json  # { "schema_version": 1, "number": <n>,
                        #   "updatedAt": "<snapshot row's updated_at>",
                        #   "body": "<issue body>",
                        #   "comments": [ <raw REST comment objects> ] }
```

`<owner>-<repo>` is the repo slug: `owner/repo` with `/` replaced by `-`
(`_cache_repo_slug`).

### schema_version

`CACHE_STORE_SCHEMA_VERSION` (currently `1`, a constant in `cache.sh`) is
stamped into every `meta.json` and every `details/<n>.json` this lib writes.
Bump it — and add a dated note here describing what changed and whether a
prior-version store needs `cache_clear` before re-use — before altering
either file's shape in a way an existing on-disk store wouldn't already
satisfy. `snapshot.jsonl` rows are raw GitHub REST payloads and are not
independently versioned; the store-level `schema_version` in `meta.json`
covers the snapshot file's *presence/location* contract, not its row shape
(that's GitHub's REST contract, not ours).

## API surface

Path accessors (no I/O, no gh calls):
- `cache_repo_dir <board|owner/repo>` → the per-repo store directory
- `cache_snapshot_file <board|owner/repo>` → `.../snapshot.jsonl`
- `cache_meta_file <board|owner/repo>` → `.../meta.json`
- `cache_details_dir <board|owner/repo>` → `.../details`
- `cache_details_file <board|owner/repo> <issue#>` → `.../details/<n>.json`

Refresh (write side):
- `cache_refresh_snapshot <board|owner/repo>` — one paginated REST list
  (`gh api repos/<r>/issues?state=all`, `--paginate`), PR rows filtered,
  written to `snapshot.jsonl` + `meta.json`. Zero per-issue calls, zero
  GraphQL. rc 0 persisted; rc 1 the live fetch itself failed (nothing to
  serve); rc 2 the fetch succeeded but the on-disk write failed.
- `cache_refresh_details <board|owner/repo>` — walks the current snapshot;
  for each issue whose `details/<n>.json` is missing or whose stored
  `updatedAt` differs from the snapshot row's `updated_at`, fetches
  `issues/<n>/comments` (one REST call) and writes the details file (body is
  copied from the snapshot row — no extra call needed for it). An unchanged
  issue costs zero calls.
- `cache_refresh <board|owner/repo>` — the above two in sequence.

Staleness + invalidation:
- `cache_stale <board|owner/repo>` — rc 0 (true) if no meta, unparseable
  meta, or age ≥ `CACHE_STORE_TTL` (default 3600s); rc 1 (false) otherwise.
- `cache_dirty <board|owner/repo>` — soft invalidation: zeroes
  `last_refresh` so the next `cache_read` refreshes regardless of age.
  No-op if no store exists yet (already maximally stale).
- `cache_clear <board|owner/repo>` — hard invalidation: deletes the entire
  per-repo store (snapshot + meta + every cached detail file).

Read (consumer-facing):
- `cache_read <board|owner/repo>` — the staleness-aware entrypoint. See
  "Degradation contract" below.
- `cache_read_details <board|owner/repo> <issue#>` — pure accessor for
  whatever `details/<n>.json` currently holds; not staleness-aware itself
  (call `cache_refresh_details` first for a guaranteed-fresh read).

## Tuning knobs (ENV VARS only — no boards.conf axis)

- `CACHE_STORE_ROOT` — store root (default `${XDG_CACHE_HOME:-$HOME/.cache}/temperloop`)
- `CACHE_STORE_TTL` — max-stale window in seconds (default `3600`)

Deliberately environment-only for this item: a later item adds the
per-board `board.<N>.cache` *enable/disable* axis to `boards.conf` (a
different concern — whether a board uses this store at all — from these
tuning knobs, which govern the store's own behavior once in use).

## Degradation contract

`cache_read`'s fallback chain, in order:

1. **Fresh + parseable cache exists** → served straight from disk, **zero**
   `gh` calls.
2. **Miss, stale, or unparseable (parse failure)** → triggers exactly one
   refresh attempt (one live REST fetch):
   - **the live fetch itself fails** (rate limit, auth, network) → print one
     stderr notice, return rc 1 with no stdout. Never fabricate or serve
     corrupt data.
   - **the fetch succeeds but persisting to disk fails** (permissions, full
     disk) → print one stderr notice, and serve the just-fetched data
     directly (uncached, "live") rather than failing the caller over a
     storage problem it doesn't need to care about.
   - **both succeed** → snapshot is persisted, `cache_refresh_details` runs
     best-effort (its own per-issue failures don't block the read — an
     individual issue's details simply stay whatever they were before), and
     the fresh snapshot is served.

`cache_dirty` is the lever a write-through caller uses: after mutating an
issue live (e.g. via `board.sh`'s `board_set_status`), call `cache_dirty` so
the next `cache_read` doesn't serve a pre-write snapshot for the remainder of
the TTL window. Rollback for the whole mechanism is a config flip — set
`CACHE_STORE_TTL=0` and never call the refresh functions, or simply don't
source `cache.sh` at all; nothing else in the toolkit depends on it existing.

## Invariants carried over from the epic contract

- `board_resolve_item` (board.sh) stays always-live — this store never
  substitutes for it and is never consulted by the claim-lock path.
- Writes are write-through GitHub; this store is read-side only. A mutator
  calls `cache_dirty` after writing, it never writes issue state itself.
