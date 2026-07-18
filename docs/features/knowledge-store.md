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
foundation/knowledge`) and creates nothing itself. Which implementation
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
independent search-corpus root knob anywhere in this seam. `issue-corpus.sh`
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
`$HOME` (per-project partition is deferred — temperloop#418) and
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
knowledge-store root check exists
specifically to catch that split: it derives the Obsidian MCP vault root
mechanically (from the Local REST API plugin's fixed on-disk config path)
and compares it against `ks_root`, failing loudly on a mismatch rather than
letting the two planes silently write into different corpora.

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
