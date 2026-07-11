# knowledge_store interface contract

`knowledge_store` is the document-I/O seam between a caller (a script, hook,
or command) and wherever structured project notes actually live. A caller
that wants to read, write, append to, or list a note does so through this
interface — never by hardcoding a filesystem path to a particular vault or
tool. That indirection is what lets a fresh install default to a plain
markdown directory while a different install points the same calls at a
different backend (e.g. an Obsidian vault), with zero changes to callers.

Implementation: `knowledge_store.sh` (same directory). It is a **sourced**
shell library, not an executable — `source knowledge_store.sh` to bring the
interface into scope. It sets no shell options; the sourcing script owns
`set -euo pipefail` (or whatever discipline it uses).

## Configuration

Exactly one environment variable selects the store root, and one selects the
backend. There is no second path knob — every operation resolves its target
location through `ks_root` (directly or via a backend's own call to it).

| Variable | Default | Meaning |
|---|---|---|
| `KNOWLEDGE_STORE_ROOT` | `${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge` | Absolute path to the store root. |
| `KNOWLEDGE_STORE_BACKEND` | `plain-files` | Backend name (kebab-case). Selects which backend's functions the interface dispatches to. |

The default root follows the XDG base-directory convention: it is a
per-user data directory, not tied to any particular git checkout, so a
plain-files store survives independent of which repo clone is active and
does not risk being accidentally committed inside a project tree.

### `ks_root`

```
ks_root
```

Prints the resolved store root (no trailing slash) to stdout. Always
succeeds. Does not create the directory — that happens lazily, on the first
write, inside a backend.

## Backend registration seam

A backend is a set of four functions named `_ks_backend_<name>_<op>`, where
`<name>` is `KNOWLEDGE_STORE_BACKEND` with every `-` replaced by `_`, and
`<op>` is one of `read`, `write`, `append`, `list`:

```
_ks_backend_<name>_read    <doc-id>
_ks_backend_<name>_write   <doc-id> [--no-clobber]     # content on stdin
_ks_backend_<name>_append  <doc-id>                    # content on stdin
_ks_backend_<name>_list    [prefix]
```

To register a new backend: define those four functions (matching the
semantics below), make sure they're sourced/available before first use, and
set `KNOWLEDGE_STORE_BACKEND` to `<name>` (with `_` written back as `-`,
e.g. a function prefix of `_ks_backend_obsidian_*` is selected by
`KNOWLEDGE_STORE_BACKEND=obsidian`). No change to `knowledge_store.sh`
itself is required. Selecting a backend with no matching functions defined
is a dispatch-time error (exit 2), not a load-time error — nothing checks
that every op is implemented until it's actually called.

This file documents one backend, `plain-files` (the default), fully.

## Public interface

All four operations are shell functions exported by `knowledge_store.sh`
once sourced. None of them take content as a positional argument; `write`
and `append` read content from **stdin**. `doc-id` is a caller-chosen
relative identifier for a document (see "doc-id normalization" below) — not
a raw filesystem path.

### `ks_read <doc-id>`

Prints the document's full content to stdout.

- **Exit 0** — found; content on stdout.
- **Exit 1** — not found; nothing on stdout, a message on stderr.
- **Exit 2** — invalid `doc-id` (see normalization rules); nothing on
  stdout, a message on stderr.

### `ks_write <doc-id> [--no-clobber]`

Reads content from stdin and writes it as the document's full, sole
content — a **replace**, not a merge. Creates parent directories as
needed. Creates the document if absent.

- **Default (no `--no-clobber`)**: if the document already exists, it is
  overwritten (same semantics as `cat > file`). The write is performed
  atomically — content is staged to a sibling temp file, then renamed into
  place — so a killed or interrupted write can never leave a half-written
  document at the target path; a reader either sees the old content in
  full or the new content in full, never a mix.
- **`--no-clobber`**: refuses to touch an existing document — used for
  create-only semantics.

Exit codes:
- **Exit 0** — written (created or overwritten).
- **Exit 2** — invalid `doc-id`.
- **Exit 3** — `--no-clobber` given and the document already exists;
  nothing written.
- **Exit 1** — other I/O failure (e.g. parent directory not creatable).

### `ks_append <doc-id>`

Reads content from stdin and appends it to the end of the document. Creates
parent directories and the document itself if absent (so `ks_append` alone
is sufficient to start a new document — no separate "create" call exists).

Not staged through a temp file: this is a plain append-mode open, chosen
because append's use case is incremental logs where "atomic whole-file
replace" is the wrong cost/semantic for a call that may run many times
against the same document.

- **Exit 0** — appended (document created if it did not exist).
- **Exit 2** — invalid `doc-id`.
- **Exit 1** — other I/O failure.

### `ks_list [prefix]`

Prints one `doc-id` per line, sorted, for every document under the store
root — or, when `prefix` is given, every document under
`<root>/<prefix>`. `prefix` is a plain relative path segment, not a glob.

- **Exit 0** — always, even when the root (or the prefix subdirectory)
  does not exist yet; in that case nothing is printed. Listing is
  read-only and never creates the root.

## doc-id normalization

Every operation normalizes its `doc-id` the same way before touching
storage:

1. Must be non-empty.
2. Must be a **relative** path (no leading `/`).
3. Must not contain a `..` path segment (guards against escaping the store
   root).
4. A trailing `.md` is appended if not already present — so `Decisions/foo`
   and `Decisions/foo.md` name the same document.

A `doc-id` failing rules 1–3 is a validation error: every operation returns
exit 2 without touching storage. This is a **best-effort textual guard**,
not a full path canonicalization library — it does not resolve symlinks,
collapse repeated slashes, or handle every path-traversal trick; it is
enough to keep the plain-files backend (and any well-behaved future
backend) from writing outside the resolved root under normal use.

## The `plain-files` backend

Stores each document as a markdown file — optionally carrying a YAML
frontmatter block at its top — under `ks_root`. The relative filesystem
path of a document IS its `doc-id` (after normalization).

The backend treats document content as **opaque bytes**: it moves content
in and out via `read`/`write`/`append`, and does not parse, validate, or
otherwise interpret any YAML frontmatter a caller chooses to put at the top
of a document's content. Frontmatter-aware operations (e.g. "read just the
`status:` field") are out of this seam's scope — a caller that needs that
composes it on top of `ks_read`.

No locking is implemented — the atomic-rename write and O_APPEND append
are each individually safe against a torn write, but there is no
cross-process mutual exclusion between concurrent writers to the same
`doc-id`. Concurrent use should serialize at a level above this interface
(e.g. a caller-owned lock file) if that matters for a given caller.

## The `obsidian` backend

Implementation: `knowledge_store_obsidian.sh` (same directory), a **separate
file from `knowledge_store.sh`** — per the registration seam above, no
change to `knowledge_store.sh` is required to add a backend. Source it
*after* `knowledge_store.sh`, then set `KNOWLEDGE_STORE_BACKEND=obsidian`:

```
source knowledge_store.sh
source knowledge_store_obsidian.sh
KNOWLEDGE_STORE_BACKEND=obsidian
ks_read "Decisions/foo"
```

Stores each document as a note in an Obsidian vault, via the [Obsidian
Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api)
plugin — the same API foundation's hooks already use (see
`claude/hooks/session-start-drain.sh` and `workflows/scripts/build/plan.sh`
for the established base-URL/auth/TLS conventions this backend reuses
verbatim, rather than inventing new plumbing).

**Root mapping: the vault itself is the root, not `KNOWLEDGE_STORE_ROOT`.**
This is the one deliberate deviation from the "ONE knob for the root"
framing at the top of this file — `KNOWLEDGE_STORE_ROOT` is a *filesystem*
path knob and is simply not consulted by this backend. A normalized
`doc-id` (e.g. `Decisions/foo.md`) is used directly as the REST API's
vault-relative path (`/vault/Decisions/foo.md`); `ks_root` still resolves
to its filesystem default/override but that value is meaningless for this
backend and must not be used to build obsidian paths. There is no
sub-vault "store root" concept — every doc-id addresses a path relative to
the vault's own root.

Additional config, specific to this backend (beyond the two universal
knobs):

| Variable | Default | Meaning |
|---|---|---|
| `KNOWLEDGE_STORE_OBSIDIAN_API_BASE` | `https://127.0.0.1:27124` | Obsidian Local REST API base URL. |
| `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` | `$(ks_root)/.obsidian/plugins/obsidian-local-rest-api/data.json` (derived from `KNOWLEDGE_STORE_ROOT`, not a second literal) | Path to the plugin's own key file (`.apiKey` field is the bearer token). |

Op-to-REST mapping:

| Op | HTTP | Notes |
|---|---|---|
| `ks_read` | `GET /vault/<path>` | Body is the document content verbatim. |
| `ks_write` | `PUT /vault/<path>` | Whole-file replace; Obsidian creates missing parent folders. |
| `ks_write --no-clobber` | `GET` then `PUT` | The REST API has no native create-only verb, so `--no-clobber` is **emulated** with a pre-flight `GET`: exit 3 (untouched) if it returns 200, otherwise proceed to `PUT`. This is a check-then-act race under concurrent writers — no worse than this seam's documented "no locking" guarantee, but worth naming explicitly: two concurrent `--no-clobber` writers to the same `doc-id` can both pass the pre-flight check and both `PUT`. |
| `ks_append` | `POST /vault/<path>` | Local REST API POST semantics are already create-or-append, matching this op exactly. |
| `ks_list [prefix]` | `GET /vault/<dir>/` (recursive) | The REST API has no recursive-listing endpoint, only a per-directory `GET` returning `{"files":[...]}` (subfolder entries end in `/`); this backend walks the tree breadth-first, one request per directory, filtering to `*.md` entries. |

Error-mode deviations from the plain-files table above (both driven by the
same principle: an unreachable/erroring REST API must fail loud, mirroring
how `plan.sh`'s `_plan_vault_write` treats an unreachable REST endpoint —
never a silent no-op):

- **`ks_read`'s exit-1 bucket widens.** Plain-files' exit 1 means "not
  found" only. This backend's exit 1 covers "not found" (404) **or** any
  other non-2xx response, **or** the REST API being unreachable — the same
  "other I/O failure" bucket `ks_write`/`ks_append` already define, now
  also covering `ks_read`. The specific cause is always on stderr; exit 2
  (invalid doc-id) is unchanged and still checked before any HTTP call.
- **`ks_list`'s "always exit 0" guarantee does not hold.** Plain-files'
  `ks_list` never fails (a local `[ -d ... ]` check can't really fail). A
  network-backed backend can: an unreachable REST API or a non-2xx
  response mid-walk causes this backend's `ks_list` to fail loud (exit 1).
  The "root/prefix directory does not exist yet → exit 0, nothing printed"
  behavior is preserved for the one case that maps cleanly (a 404 on the
  requested root/prefix directory itself).

No locking, same as plain-files (see above) — plus the `--no-clobber`
race noted in the table.

## Backend matrix

| | `plain-files` (default) | `obsidian` |
|---|---|---|
| Selected by | `KNOWLEDGE_STORE_BACKEND=plain-files` (or unset) | `KNOWLEDGE_STORE_BACKEND=obsidian` |
| Implementation file | `knowledge_store.sh` | `knowledge_store_obsidian.sh` (separate file, sourced additionally) |
| Storage | Markdown files under `ks_root` (`KNOWLEDGE_STORE_ROOT`, filesystem) | Notes in an Obsidian vault, via the Local REST API |
| Root semantics | `KNOWLEDGE_STORE_ROOT` names the store root directory | `KNOWLEDGE_STORE_ROOT` is **not consulted**; the vault root IS the store root |
| Extra config | none | `KNOWLEDGE_STORE_OBSIDIAN_API_BASE`, `KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE` |
| Network dependency | none | requires the Local REST API plugin reachable + authenticated |
| `ks_read` exit 1 | not found only | not found, OR any other read failure (incl. unreachable) |
| `ks_write --no-clobber` | atomic filesystem check (`[ -e "$path" ]`) | emulated via pre-flight `GET` (TOCTOU race under concurrent writers) |
| `ks_list` exit code | always 0 | 0 when the target dir 404s; **1** on any other failure mid-walk |
| Locking | none | none (plus the `--no-clobber` pre-flight race) |

## Read-log telemetry (script plane)

`knowledge_store.sh` also implements `ks__read_log_emit <plane> <op>
<doc-path-or-query>` (temperloop#229, Epic #226 "script-plane read
telemetry") — every `ks__dispatch` call (so every `ks_read`/`ks_write`/
`ks_append`/`ks_list`, for every backend) and `knowledge_search.sh`'s
`ks_search` entrypoint append one normalized line to a log kept deliberately
**outside** the store itself (no embed churn from the log becoming a
document the search index has to chew on, no self-observation loop). Line
shape, fields joined by `" · "`:

```
<timestamp> · <session-id> · <plane> · <op> · <doc-path-or-query>
```

- `timestamp` — UTC, `date -u +%Y-%m-%dT%H:%M:%SZ`.
- `session-id` — `$CLAUDE_CODE_SESSION_ID`, or `-` when unset.
- `plane` — `script` for every call in `knowledge_store.sh` /
  `knowledge_search.sh`; a later agent-plane hook calls the same emit
  function with `plane=agent` rather than getting a new knob.
- `op` — `read` | `write` | `append` | `list` | `search`.
- `doc-path-or-query` — the dispatched doc-id, or the `ks_search` query,
  newline/tab-sanitized to a single line.

Config: `KNOWLEDGE_READ_LOG` (path), default
`${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log` — the
ONE override point for the log's location. Logging is fail-open: a write
failure (log dir uncreatable, disk full, etc.) is WARNed to stderr and never
propagates into the wrapped `ks_*` call's own exit code.

This line format is a stable contract — later telemetry items (an
agent-plane hook, a SessionEnd one-liner, a `/tidy` tally) are documented to
consume it as-is; changing the field order/count/separator means updating
every consumer.

## Non-goals of this seam (deliberately out of scope)

- **No caller routing (this file's own scope).** This file defines the
  interface and both backends (`plain-files`, `obsidian`) — it does not
  itself route any hook, command, or script through the interface.
  Routing callers over (so no hook/command names an operator's vault path
  as a hardcoded literal) is sibling-level work tracked to completion by
  temperloop#164/#169 (kernel-literal-scrub).
- **No frontmatter parsing/query API.** See above.
- **No search.** `ks_list` enumerates by path/prefix only; it does not
  grep content or rank relevance.

## knowledge_search

`knowledge_search` (foundation #776, Epic A #762 "kernel split") is the
concept-level (semantic/hybrid) retrieval seam layered on top of
`knowledge_store`. Where `ks_list` enumerates documents by path/prefix,
`ks_search` ranks documents by relevance to a natural-language query.

Implementation: `knowledge_search.sh` (same directory), a second **sourced**
shell library — `source knowledge_search.sh` after `source knowledge_store.sh`
(it calls `ks_root`, so `knowledge_store.sh` must already be sourced). It
sets no shell options of its own.

### Corpus binding — no independent path knob

`ks_search`'s corpus is **always** the store's resolved root, `ks_root`
(defined by `knowledge_store.sh`). There is no `KNOWLEDGE_SEARCH_ROOT` or
equivalent — this is a deliberate split-brain guard: a search index that
could be pointed somewhere other than the document store would silently
drift from what `ks_read`/`ks_write`/`ks_list` actually see. Whatever
backend `KNOWLEDGE_STORE_BACKEND` resolves documents to, `ks_search` reads
back that same root from disk.

### Public interface

```
ks_search <query> [--limit N]     -> ranked results, JSON Lines on stdout
ks_search_reindex [--full]        -> rebuild the backend's index for ks_root
ks_search_available               -> exit 0/3 probe, no stdout
```

`ks_search` prints one JSON object per line (JSON Lines, not a single JSON
array), ranked highest-relevance first:

```json
{"doc_id": "Decisions/foo.md", "title": "Foo", "score": 1.23, "snippet": "…matched excerpt…"}
```

`doc_id` is the same relative-path identifier `knowledge_store` uses, so a
result can be handed straight to `ks_read <doc_id>`.

Exit codes (both `ks_search` and `ks_search_reindex`):

| Exit | Meaning |
|---|---|
| 0 | Success. For `ks_search`, this includes a legitimate **zero-result** match — an empty JSONL stream with exit 0 is a real "no matches," never confused with "backend unavailable." |
| 2 | Invalid usage (empty query, or `KNOWLEDGE_SEARCH_BACKEND` names a backend with no matching functions defined). |
| 3 | Backend unavailable ("skipped"). The backend's required subprocess tooling is not on `PATH`. A message beginning `skipped — knowledge_search unavailable` is printed to stderr; **nothing is ever printed to stdout** in this case. This is the legible-degradation contract: a caller must never mistake "backend not installed" for "searched and found nothing." |
| 4 | Backend error: the subprocess ran but exited non-zero, or its output could not be parsed into the expected shape. |

`ks_search_available` runs the same availability check `ks_search` and
`ks_search_reindex` use internally, standalone, so a caller can probe
before calling either (exit 0 = ready, exit 3 = the same "skipped —"
notice on stderr, no stdout either way).

### Backend registration seam

Mirrors `knowledge_store`'s: `KNOWLEDGE_SEARCH_BACKEND` (kebab-case,
default `basic-memory`) selects a set of `_ks_search_backend_<name>_<op>`
functions, `<op>` ∈ `search`, `reindex`, `available`. This file implements
one backend, `basic-memory`, fully.

### The `basic-memory` backend (spike verdict, F#776, 2026-07-02)

The Phase-0 spike selected [basic-memory](https://github.com/basicmachines-co/basic-memory)
v0.22.1 as the kernel default search backend (over a thin-indexer
fallback). It runs **strictly as an external CLI subprocess** — never
imported or vendored in this repo's source — because basic-memory is
licensed AGPL-3.0 and this repo is not. See "AGPL boundary" below.

The adapter's required posture, every point implemented in
`knowledge_search.sh`:

1. **`disable_permalinks: true`** in `config.json` **and**
   `BASIC_MEMORY_DISABLE_PERMALINKS=true` in the subprocess environment
   (belt and suspenders — `_ks_bm_run`).
2. The full no-mutation config set, written **before** the first index:
   `ensure_frontmatter_on_sync: false`, `format_on_save: false`,
   `update_permalinks_on_move: false`, `kebab_filenames: false`.
3. **`sync_changes: false`** — the watcher is never run (sidesteps upstream
   basic-memory #1016 and watcher-side mutation). Sync is always an
   explicit `ks_search_reindex` call (a post-pull hook / cron entry point),
   never a background daemon.
4. The adapter **never runs `basic-memory mcp`** (sidesteps upstream
   #1017). Every call is `basic-memory tool ...` / `basic-memory project
   ...` / `basic-memory reindex ...` — CLI-only, JSON-shaped stdout parsed
   by `jq`.
5. **`auto_update: false`**; the version is pinned in every invocation via
   `uvx --from basic-memory==0.22.1 basic-memory ...`
   (`KNOWLEDGE_SEARCH_BM_VERSION`, default `0.22.1`). Upgrading the pin is
   a deliberate adapter change, not silent drift.
6. **Isolated state**: a dedicated `HOME` for the `basic-memory` subprocess
   (`KNOWLEDGE_SEARCH_BM_HOME`, default
   `${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home`),
   so `~/.basic-memory/{config.json,memory.db}` under that isolated HOME is
   adapter-owned and never touches Travis's real home directory.
   `semantic_embedding_cache_dir` is pinned inside it too (confirmed live:
   the fastembed model download lands under the pinned cache dir, not the
   machine's shared HF cache).
7. **`semantic_embedding_model: bge-small-en-v1.5`** kept as the default
   explicitly (avoids upstream #1023's non-bge normalization bug).
8. **CI caching guidance**: cache `memory.db` and the fastembed model cache
   (`semantic_embedding_cache_dir`) as build artifacts across CI runs.
   Approximate cost, from basic-memory's own documentation: a cold rebuild
   runs ~23 min per 1k dense notes; an incremental `reindex` (the default,
   no `--full`) runs 2-3 min; `reindex` is safe to re-invoke on a CI-timeout
   retry — it resumes rather than restarting.
9. **Project registration via the CLI only**: `basic-memory project add
   <name> <path>` — never by editing `config.json`'s `projects` map
   directly (config-only edits to that map are not honored in 0.22.1;
   confirmed live). `project add` is idempotent — a repeat call against an
   already-registered project prints "already exists" and exits 0 — so
   `ks_search`/`ks_search_reindex` call it unconditionally on every
   invocation rather than tracking registration state separately.

All nine points were verified against the real 0.22.1 CLI during adapter
authoring (network-available session, 2026-07-02): a 3-note temp corpus was
registered, indexed, and queried via `basic-memory tool search-notes
--hybrid`, confirming the config-merge behavior (a `config.json` holding
only the override keys above is merged with the tool's own defaults — no
need to restate its full schema), the clean stdout/stderr split (progress
and model-download chatter go to stderr; `tool search-notes` stdout is pure
JSON), and the cache-dir pinning. See `.build-verification.md` in the
adapter's worktree for the full transcript.

### Legible degradation

When `uvx` is not on `PATH`, `ks_search`/`ks_search_reindex`/
`ks_search_available` all return exit 3 with `skipped — knowledge_search
unavailable: uvx not found on PATH` on stderr and **print nothing to
stdout**. A caller that pipes `ks_search` output into further processing
without checking the exit code would see an empty stream either way (zero
matches vs. unavailable) — checking the exit code is required to
distinguish them; this is why the contract calls out exit 3 as a distinct,
documented code rather than folding it into the zero-results case.

### AGPL boundary

basic-memory is AGPL-3.0. This repo holds no AGPL-3.0 code and must not —
so the adapter's only contact with basic-memory is spawning it as a
subprocess (`uvx --from basic-memory==<pin> basic-memory ...`) and reading
its stdout. No basic-memory source is vendored, no Python import of
`basic_memory` exists anywhere in this repo, and no build/dependency
manifest here declares it as a package dependency (it is fetched
on-demand, per-invocation, by `uvx` — never installed into this repo's own
environment). `workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh`
enforces this mechanically: it fails if a vendored `basic-memory`/
`basic_memory` path appears in the tracked tree, if a Python `import
basic_memory` appears anywhere, or if any shell invocation of the
`basic-memory` binary bypasses the `uvx` subprocess boundary.

### Obsidian-mode note

When `KNOWLEDGE_STORE_BACKEND=obsidian` (the sibling Obsidian document-I/O
backend), **agent-plane** semantic search — a Claude session querying its
own project's notes — stays on Obsidian's own `search_vault_smart` (MCP),
per this repo's `CLAUDE.md` ("Search by idea, not keyword"). `ks_search` is
a separate, **script-plane / headless** path: it works with no Obsidian
app or GUI running, no MCP server, and no dependency on Claude Code's
session context — its own `basic-memory` project is pointed at the same
`ks_root` an Obsidian-backend store resolves to, so a script or hook can
query the corpus without an agent in the loop at all. The two do not
share an index; a caller inside an active Claude session with vault access
should still prefer `search_vault_smart` for vault-aware ranking, ambient
context, and citation-friendly results.

### Non-goals of this seam (search)

- **No search over non-store content.** `ks_search`'s corpus is exactly
  `ks_root`'s documents — it does not index code, board issues, or
  anything outside the knowledge store.
- **No live-watch indexing.** Point 3 above — indexing is always an
  explicit `ks_search_reindex` call.
- **No caller routing.** Like the document-I/O interface, no existing
  hook/command in this repo calls `ks_search` yet; that is later,
  sibling-level work.
