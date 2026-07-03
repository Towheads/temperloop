#!/usr/bin/env bash
#
# knowledge_search.sh — SOURCED library defining foundation's knowledge_search
# surface: concept-level (semantic/hybrid) retrieval over the knowledge_store's
# corpus (F#776, Epic A #762 "kernel split: seams in place — ZERO behavior
# change").
#
# Companion to knowledge_store.sh (same directory, document I/O). This file
# adds a SEARCH surface bound to the SAME corpus: ks_search's target is
# always ks_root (knowledge_store.sh) — there is NO independent search-corpus
# path knob. A search index that could point somewhere other than the
# document store would silently drift from it (split-brain guard).
#
# Backend selected by the Phase-0 spike verdict (foundation #776, completed
# 2026-07-02): basic-memory v0.22.1
# (https://github.com/basicmachines-co/basic-memory), run STRICTLY as an
# external CLI subprocess over argv/stdout — never imported or vendored,
# because basic-memory is AGPL-3.0 and this repo is not. See the "AGPL
# boundary" note below and workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh.
#
# See knowledge_store.contract.md's "## knowledge_search" section (appended
# after the existing document-I/O sections, which are owned by a sibling
# item — this file does not touch backend dispatch for ks_read/ks_write/
# ks_append/ks_list) for the full interface spec and the spike verdict's
# required adapter posture (numbered points 1-9), reproduced as inline
# comments next to the code that implements each one below.
#
# This file is SOURCED — it sets no shell options (the caller owns
# set -euo). Depends on: knowledge_store.sh (ks_root — source it first),
# jq (reshaping basic-memory's JSON into this file's JSONL output).
#
# ── Config knobs ─────────────────────────────────────────────────────────
#   KNOWLEDGE_SEARCH_BACKEND     backend name, kebab-case. Default:
#                                basic-memory (the only backend this file
#                                implements; the plain-files knowledge_store
#                                backend has no search backend of its own —
#                                see "Obsidian-mode note" in the contract for
#                                how an obsidian-backend store still reaches
#                                this same basic-memory search backend, or
#                                stays on Obsidian's own search_vault_smart
#                                at the agent plane).
#   KNOWLEDGE_SEARCH_BM_HOME     isolated $HOME for the basic-memory
#                                subprocess (point 6: its own
#                                ~/.basic-memory/{config.json,memory.db}
#                                lives here — adapter-owned state, never
#                                Travis's real $HOME). Default:
#                                ${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home
#   KNOWLEDGE_SEARCH_BM_PROJECT  the basic-memory project name bound to
#                                ks_root. Default: foundation-knowledge
#   KNOWLEDGE_SEARCH_BM_VERSION  pinned basic-memory version (point 5) passed
#                                to `uvx --from basic-memory==<version>`.
#                                Default: 0.22.1 (the spike-verdict pin —
#                                upgrades are a deliberate adapter change to
#                                this default, not silent drift).
#
# NOT a corpus-root knob: ks_search always targets ks_root (knowledge_store.sh)
# — there is no KNOWLEDGE_SEARCH_ROOT or equivalent.

# ── Public interface ────────────────────────────────────────────────────
# ks_search <query> [--limit N]   -> ranked results, JSON Lines on stdout:
#                                    one {"doc_id","title","score","snippet"}
#                                    object per line, already ranked by the
#                                    backend (highest relevance first).
# ks_search_reindex [--full]      -> rebuilds the search backend's index for
#                                    ks_root's corpus. Never runs as a
#                                    background watcher (point 3) — this is
#                                    always an explicit, one-shot call (a
#                                    post-pull hook / cron entry point).
# ks_search_available             -> exit 0 if the selected backend's
#                                    required tooling is present, exit 3
#                                    otherwise. Lets a caller probe before
#                                    calling ks_search if it wants to avoid
#                                    the stderr notice.
#
# Exit codes (both ks_search and ks_search_reindex):
#   0 — success. For ks_search, this includes a legitimate ZERO-result
#       match — an empty JSONL stream on stdout with exit 0 is a real "no
#       matches", never confused with "backend unavailable".
#   2 — invalid usage (empty query, dispatch to an unregistered backend).
#   3 — backend unavailable ("skipped"): the backend's required subprocess
#       tooling (uvx) is not on PATH. A message beginning
#       "skipped — knowledge_search unavailable" is printed to stderr;
#       NOTHING is ever printed to stdout in this case — legible
#       degradation, never a silent empty result.
#   4 — backend error: the subprocess ran but exited non-zero, or its
#       output could not be parsed as the expected JSON shape.
ks_search() {
  local query="${1:-}"
  if [ -z "$query" ]; then
    echo "knowledge_search: usage: ks_search <query> [--limit N]" >&2
    return 2
  fi
  shift || true
  ks_search__dispatch search "$query" "$@"
}

ks_search_reindex() {
  ks_search__dispatch reindex "$@"
}

ks_search_available() {
  ks_search__dispatch available "$@"
}

# ── Backend dispatch (mirrors knowledge_store.sh's ks__dispatch shape) ────
: "${KNOWLEDGE_SEARCH_BACKEND:=basic-memory}"

ks_search__backend_fn() {
  local op="$1" backend="${KNOWLEDGE_SEARCH_BACKEND//-/_}"
  printf '_ks_search_backend_%s_%s\n' "$backend" "$op"
}

ks_search__dispatch() {
  local op="$1"; shift
  local fn; fn="$(ks_search__backend_fn "$op")"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'knowledge_search: backend "%s" does not implement "%s" (no %s defined)\n' \
      "$KNOWLEDGE_SEARCH_BACKEND" "$op" "$fn" >&2
    return 2
  fi
  "$fn" "$@"
}

# ── basic-memory backend ──────────────────────────────────────────────────
# Every function below either assembles the posture (config/env) or shells
# out to the pinned `uvx --from basic-memory==<version> basic-memory ...`
# CLI. Nothing here imports or vendors any basic-memory source — the ONLY
# way this file talks to basic-memory is via `uvx` as a subprocess (points
# 4 and 5). Confirmed against the real 0.22.1 CLI (network-available
# adapter-authoring session, 2026-07-02): `project add` is idempotent
# (prints "already exists" and exits 0 on a repeat call), a config.json
# holding ONLY the override keys below is merged with the tool's own
# pydantic defaults (no need to restate the full schema), and
# `tool search-notes --hybrid` prints clean JSON on stdout with all
# progress/model-download chatter on stderr.

: "${KNOWLEDGE_SEARCH_BM_PROJECT:=foundation-knowledge}"
: "${KNOWLEDGE_SEARCH_BM_VERSION:=0.22.1}"

# point 6: dedicated HOME for the bm subprocess, under XDG_STATE_HOME.
_ks_bm_home() {
  : "${KNOWLEDGE_SEARCH_BM_HOME:=${XDG_STATE_HOME:-$HOME/.local/state}/foundation/basic-memory-home}"
  printf '%s\n' "$KNOWLEDGE_SEARCH_BM_HOME"
}

_ks_bm_config_dir()  { printf '%s/.basic-memory\n' "$(_ks_bm_home)"; }
_ks_bm_config_path() { printf '%s/config.json\n' "$(_ks_bm_config_dir)"; }
# point 6 (cont'd): semantic_embedding_cache_dir pinned inside the isolated
# home, not the machine's shared HF/fastembed cache.
_ks_bm_cache_dir()   { printf '%s/embedding-cache\n' "$(_ks_bm_home)"; }

# point 1: uvx/basic-memory presence is the sole availability gate — bm
# itself is fetched on demand by uvx, so "installed" here means "uvx is on
# PATH", not "basic-memory is pre-installed". This IS the dispatch target
# for the public "available" op (ks_search_available calls this directly,
# by the `_ks_search_backend_<name>_<op>` naming convention) — exit 0 when
# ready, exit 3 with the "skipped —" stderr notice when not, so a caller
# gets the same legible-degradation signal whether it probes explicitly via
# ks_search_available or hits it implicitly via ks_search/ks_search_reindex.
_ks_search_backend_basic_memory_available() {
  command -v uvx >/dev/null 2>&1 && return 0
  echo "skipped — knowledge_search unavailable: uvx not found on PATH" >&2
  return 3
}

# Writes config.json BEFORE the first index (point 2), and only if absent —
# this state dir is adapter-owned (point 6), so an existing file is trusted
# to already carry our posture; we never clobber a config a prior run wrote.
# Maps every spike-verdict posture point:
#   point 1 — disable_permalinks: true            (+ env var, see _ks_bm_run)
#   point 2 — ensure_frontmatter_on_sync: false, format_on_save: false,
#             update_permalinks_on_move: false, kebab_filenames: false
#   point 3 — sync_changes: false (the watcher is never enabled)
#   point 5 — auto_update: false (upgrades are a deliberate version-pin bump)
#   point 6 — semantic_embedding_cache_dir pinned inside the isolated home
#   point 7 — semantic_embedding_model: bge-small-en-v1.5 (the default —
#             pinned explicitly here so it can never drift to a non-bge
#             model and reintroduce upstream #1023's normalization bug)
_ks_bm_ensure_config() {
  local dir path cache
  dir="$(_ks_bm_config_dir)"
  path="$(_ks_bm_config_path)"
  cache="$(_ks_bm_cache_dir)"
  [ -f "$path" ] && return 0
  mkdir -p "$dir" "$cache" || return 1
  cat > "$path" <<JSON
{
  "disable_permalinks": true,
  "ensure_frontmatter_on_sync": false,
  "format_on_save": false,
  "update_permalinks_on_move": false,
  "kebab_filenames": false,
  "sync_changes": false,
  "auto_update": false,
  "semantic_embedding_model": "bge-small-en-v1.5",
  "semantic_embedding_cache_dir": "$cache"
}
JSON
}

# Runs the pinned basic-memory CLI as a subprocess (points 4 and 5): isolated
# HOME (point 6) + the belt-and-suspenders env var (point 1, on top of the
# config.json key of the same name) + the version pin (point 5). This is the
# ONLY place in this file that invokes the `basic-memory` binary, and it is
# always via `uvx --from basic-memory==<pin>` — never a bare `basic-memory`
# that could silently pick up an unpinned/system install, and NEVER the
# `mcp` subcommand (point 4 — sidesteps upstream #1017).
_ks_bm_run() {
  HOME="$(_ks_bm_home)" \
  BASIC_MEMORY_DISABLE_PERMALINKS=true \
  uvx --from "basic-memory==${KNOWLEDGE_SEARCH_BM_VERSION}" basic-memory "$@"
}

# point 9: project registration via the CLI only — config-only edits to the
# `projects` map are not honored in 0.22.1. `project add` is idempotent
# (confirmed against the real CLI), so this is safe to call on every
# search/reindex without a separate "is it already registered" check.
_ks_bm_project_add() {
  local name="$1" path="$2"
  _ks_bm_run project add "$name" "$path" >/dev/null 2>&1
}

# <query> [--limit N] -> JSONL results on stdout (see exit-code contract on
# ks_search above).
_ks_search_backend_basic_memory_search() {
  local query="$1"; shift
  local limit=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --limit) limit="${2:?knowledge_search: --limit requires a value}"; shift 2 ;;
      *) shift ;;
    esac
  done

  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project raw rc=0
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"
  _ks_bm_project_add "$project" "$root" || {
    echo "knowledge_search: basic-memory project registration failed" >&2
    return 4
  }

  # `|| rc=$?` (not a bare trailing `$?` read) so a failing command
  # substitution doesn't trip the CALLER's `set -e` before rc is captured —
  # this file is sourced into scripts that own that option.
  raw="$(_ks_bm_run tool search-notes "$query" --hybrid --project "$project" --page-size "$limit" 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    echo "knowledge_search: basic-memory search-notes failed (exit $rc)" >&2
    return 4
  fi

  printf '%s' "$raw" | jq -c '.results[]? | {doc_id: .file_path, title: .title, score: .score, snippet: (.matched_chunk // .content // "")}' \
    || { echo "knowledge_search: could not parse basic-memory search output" >&2; return 4; }
}

# [--full] -> rebuilds the index for ks_root's project. Always explicit
# (point 3) — no caller of this file ever starts a watcher. basic-memory's
# own reindex is resumable on timeout re-invocation (contract-documented
# CI caching guidance), so this is safe to call repeatedly.
_ks_search_backend_basic_memory_reindex() {
  local full=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --full) full=1; shift ;;
      *) shift ;;
    esac
  done

  _ks_search_backend_basic_memory_available || return $?
  _ks_bm_ensure_config || {
    echo "knowledge_search: could not write basic-memory config" >&2
    return 4
  }

  local root project
  root="$(ks_root)"
  project="$KNOWLEDGE_SEARCH_BM_PROJECT"
  _ks_bm_project_add "$project" "$root" || {
    echo "knowledge_search: basic-memory project registration failed" >&2
    return 4
  }

  if [ "$full" -eq 1 ]; then
    _ks_bm_run reindex --full --project "$project" || {
      echo "knowledge_search: basic-memory reindex failed" >&2
      return 4
    }
  else
    _ks_bm_run reindex --project "$project" || {
      echo "knowledge_search: basic-memory reindex failed" >&2
      return 4
    }
  fi
}

# Note: ks_search_available dispatches op "available" straight to
# _ks_search_backend_basic_memory_available (defined above) — same function
# used internally as the availability gate for search/reindex, exposed
# standalone so a caller can probe without touching stdout at all.
