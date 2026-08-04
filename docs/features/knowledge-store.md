---
title: Knowledge store document I/O
slug: knowledge-store
---

## Problem

Without an indirection here, every hook or command that wants to read,
write, or search a structured project note would hardcode a path into one
operator's actual notes store — which breaks immediately on a stranger's
fresh install (no such store exists) and permanently locks the kernel to
one specific storage technology. A caller that wants a document should not
need to know or care whether that document lives in a plain directory of
markdown files or a richer backend.

## How it works

**The backend seam.** `knowledge_store.sh` is a sourced shell library (not
an executable) exposing four operations — `ks_read`, `ks_write`, `ks_append`,
`ks_list` — none of which take a filesystem path directly. Every operation
resolves its target through exactly one function, `ks_root`, which prints
`KNOWLEDGE_STORE_ROOT` (default `${XDG_DATA_HOME:-$HOME/.local/share}/
temperloop/knowledge` — renamed from `foundation/knowledge` in v0.15.0, whose
fallback was removed in v0.19.0) and creates nothing itself. Which implementation
actually moves bytes is selected by `KNOWLEDGE_STORE_BACKEND` (default
`plain-files`): a backend is a set of four functions named
`_ks_backend_<name>_{read,write,append,list}`, where `<name>` is the backend
name with `-` replaced by `_`. Registering a new backend means defining
those four functions and setting the variable — no change to
`knowledge_store.sh` itself. Selecting a backend with no matching functions
defined is a dispatch-time error (exit 2), not a load-time one, since
nothing checks an op is implemented until it's actually called.

The shipped `plain-files` backend stores each document as a markdown file
(optionally with YAML frontmatter it never parses) under `ks_root`, keyed by
a normalized `doc-id`: non-empty, relative (no leading `/`), no `..`
segment, and a trailing `.md` appended if absent — so `Decisions/foo` and
`Decisions/foo.md` name the same document. `ks_write` is a whole-document
replace, staged atomically through a sibling temp file and renamed into
place, so a killed write never leaves a half-written document; `--no-clobber`
gives create-only semantics. `ks_append` is a plain append-mode open
(non-atomic by design — its use case is incremental logs, not whole-file
replace) and is sufficient on its own to create a new document. `ks_list`
is read-only and never creates the root, even for a prefix that doesn't
exist yet.

**Corpus pinning.** A search surface is layered on the same corpus, never a
separate one: `ks_search` always targets `ks_root` — there is no
independent search-corpus root setting anywhere in this seam. `issue-corpus.sh`
renders a board's cached issues into the store via `ks_write` and then
chains a `ks_search_reindex`, so the searchable corpus and the read/write
corpus are structurally the same directory by construction, not by
convention. The search path runs a **pinned** `basic-memory` CLI —
`uvx --from basic-memory==<version>`, never a bare `basic-memory` that could
silently pick up an unpinned or system install — with the version fixed by
`KNOWLEDGE_SEARCH_BM_VERSION` (default `0.22.1`, the spike-verified pin) and
`auto_update: false`, so an upgrade is always a deliberate version bump, not
a background drift. It runs inside an isolated `HOME` with
`semantic_embedding_cache_dir` pinned inside that isolated home — never
inside `ks_root` — so embedding-model cache writes can never land inside,
or require write access to, the corpus itself (safe even against a
read-only corpus).

**Sync (optional backend capability — EXPERIMENTAL).** `ks_sync`
(`init <remote-url>` / `push` / `pull` / `status`) is git-backed, **manual**
replication of the plain-files store: the store directory itself becomes a
git repo with one remote (`origin`, private by default — the store is
personal working notes), so a second environment can `init` against the
operator's remote and `pull` the real store. It is a *capability*, not a
universal op: a backend that cannot implement it (the `obsidian` backend
never consults `KNOWLEDGE_STORE_ROOT`, so a git-under-root sync has no
meaning there) degrades to exit 3 with a
`skipped — sync unavailable for backend <name>` notice — the same legible
availability-probe pattern as `ks_search`, never a silent no-op. Every sync
op routes through the `ks_` dispatch (no caller shells `git -C` at the
store root directly), it is never wired into a scheduled or background job,
and the store — including its `.git` and remote config — is user data
`temperloop uninstall` keeps intact. Experimental scope: single-tenant per
`$HOME` (see **Limitations** below — sync replicates the whole root, with no
notion of partitions) and
single-writer (pull is `--ff-only`; a diverged store is handed back to the
operator). The thin entry `workflows/scripts/lib/knowledge_sync.sh` is
deliberately absent from the stranger-facing CLI reference, keeping the
`temperloop sync` promotion decision open.

**Agent-plane vs. script-plane routing.** This seam is the script-plane
document-I/O path (hooks, commands, scripts). A live agent session instead
stays on Obsidian's own MCP tools whenever the configured store root
actually *is* an Obsidian vault — independent of whatever
`KNOWLEDGE_STORE_BACKEND` is configured — so the two planes can diverge if
misconfigured. `doctor.sh`'s (`bash workflows/scripts/install/doctor.sh`)
knowledge-store root check exists specifically to catch that split — but not
by deriving an independent "vault root" signal (an earlier version compared
`ks_root` against a value that was itself derived from `ks_root`, so its
mismatch branch could never fire). It instead resolves `ks_root()` from two
INDEPENDENT starting points and fails loudly when they disagree: plane A
(script-plane) sources `build.config.sh` — which directly sources the
rung-3 machine conf — then `knowledge_store.sh`; plane B (bare-env) sources
`knowledge_store.sh` ALONE, exactly as a bare hook (e.g.
`session-start-drain.sh`) or a launchd agent does, exercising `ks_root()`'s
own `_ks_machine_conf_root || _ks_default_root` fallback. A live agent
session's Obsidian MCP vault tracks plane A in practice (both derive from
the same machine-conf-configured root), so a plane A/B mismatch is a real
signal that the two planes would silently write into different corpora.

## Limitations — read this if you work across more than one client

**One `$HOME` is one store, and the store is single-tenant.** There is
exactly one `ks_root` per `$HOME`, and everything in it lives in one flat
corpus. Notes are conventionally named `<project> - <title>.md`, but that
is **only a filename convention** — nothing enforces it, and the store's
read/write/list/sync operations do not know it exists.

**What that means concretely for a multi-engagement user.** If you run one
machine account across several clients, every client's notes sit in the same
store. `ks_list` enumerates all of them, `ks_sync` replicates all of them to
one remote, and — the sharpest edge — **a semantic search does not respect
the filename convention by default**: a query typed while you are working on
client B can rank and return client A's confidential decision notes. That is
structural, not a bug you can avoid by being careful with your queries.

**Two ways to handle it — pick deliberately:**

1. **A separate `$HOME` (and therefore a separate store root) per
   engagement.** This is the only **hard** boundary, and it is the
   recommendation when the notes are genuinely confidential to a client.
   Nothing in one engagement's store is reachable from another's: not
   search, not `ks_list`, not sync. The cost is real — no shared
   cross-project notes, and per-engagement setup.
2. **A partition-scoped search**, if one store is worth the convenience.
   Set `KNOWLEDGE_SEARCH_PARTITION=<client>` (or pass
   `ks_search … --partition <client>`) and search returns only documents
   whose `doc_id` proves membership in that partition — either
   `Decisions/<client> - <title>.md` (the filename convention) or
   `<client>/…` (a top-level project directory). Anything belonging to
   another partition, and anything the store cannot attribute at all, is
   **absent** from the results. The scope fails **closed**: an unrecognised
   or empty scope argument is an error (exit 2), never a silent widening
   back to the whole corpus, and the degraded lexical-fallback path is
   filtered too.

**Know what option 2 does *not* give you.** It scopes **search only**. The
documents still share one directory: `ks_read` can still read another
project's note if you know its `doc_id`, `ks_list` still enumerates the
whole root, and `ks_sync` still pushes every project's notes to one remote.
It reduces *accidental* exposure through search — the dominant, hard-to-
avoid failure — but it is **not** at-rest isolation. If you need that,
option 1 is the answer.

Full contract, including the exact membership rules and the fail-closed
guarantees: `workflows/scripts/lib/knowledge_store.contract.md` § Project
partition — scoped search.

## Integration

Consumes: `KNOWLEDGE_STORE_ROOT` / `KNOWLEDGE_STORE_BACKEND` /
`KNOWLEDGE_SEARCH_BM_VERSION` environment (or their config-file defaults),
and, for the search path, a locally installed `uvx`. `issue-corpus.sh`
consumes the board issue-cache store's on-disk contract (`cache.sh`'s
`snapshot.jsonl` / `details/<n>.json` / `meta.json`) directly — it never
sources `board.sh` — so the knowledge-store stack carries no dependency on
the board toolkit being loaded. Consumed by: any hook/command migrated onto
this seam instead of a hardcoded vault path (the kernel-literal-scrub
effort), `doctor.sh`'s root-agreement guard, and
`install-claude-md.sh`'s rendered "Knowledge store routing" section.

## Resource impact

Storage: the `plain-files` backend writes one markdown file per document
under `KNOWLEDGE_STORE_ROOT`; cost scales linearly with corpus size, and
this seam performs no retention or garbage collection on its own. Runtime:
`ks_read`/`ks_write`/`ks_append`/`ks_list` are direct filesystem operations,
sub-millisecond each; the search path additionally spawns one pinned `uvx`
subprocess per query or reindex — the only process-spawn cost in this seam.
API/network budget: zero for ordinary read/write/append/list. The search
subprocess itself runs fully local once its pinned package is cached; the
only network touch is `uvx`'s one-time fetch of the pinned `basic-memory`
version.

## Telemetry

The `knowledge-search-fallback` stream (one of the frozen telemetry
record shapes named in `claude/presentation-plane.md`'s kernel table)
records when a search falls back to a degraded path. `doctor.sh`'s
"Knowledge-store root check" and "Cache-store state" sections are the
direct-observation surface for backend/root drift — run `bash
workflows/scripts/install/doctor.sh` and read `OK` / `MISMATCH` /
`SKIPPED` per check.
