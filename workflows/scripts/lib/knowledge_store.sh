#!/usr/bin/env bash
#
# knowledge_store.sh — SOURCED library defining foundation's knowledge_store
# interface: the document-I/O seam between callers (hooks, commands, scripts)
# and WHERE structured project notes actually live.
#
# Why this exists (foundation #771, Epic A #762 "kernel split"): every
# hook/command in this repo used to name the operator's Obsidian vault path
# directly, as a hardcoded literal. A stranger's fresh install has no such
# vault, so the open-source kernel needs an interface a plain-files backend
# can satisfy out of the box, with an Obsidian-backed adapter available as an
# opt-in swap.
#
# Scope of THIS file: the interface + root/backend resolution + the
# plain-files backend + its tests. It does NOT implement an Obsidian
# backend — that is a separate sibling-level item. Caller routing (every
# hook/command going through this seam instead of a hardcoded vault path) is
# tracked to completion by temperloop#164/#169 (kernel-literal-scrub).
#
# See knowledge_store.contract.md (same directory) for the full interface
# spec: signatures, semantics, error/exit-code behavior, the root-resolution
# rule, and the backend-registration seam. That file is the one meant to be
# read stand-alone / rendered into public docs; this header is implementation
# commentary.
#
# ── Config: ONE knob for the root, ONE knob for the backend ────────────────
#   KNOWLEDGE_STORE_ROOT     store root directory (absolute path). Default:
#                            ${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge
#                            This is the ONLY place the root is configured —
#                            no second path knob exists anywhere in this file
#                            or its callers.
#   KNOWLEDGE_STORE_BACKEND  backend name, kebab-case. Default: plain-files
#                            (the only backend this file implements). A
#                            backend is a set of `_ks_backend_<name>_<op>`
#                            functions (name with '-' -> '_'); see
#                            ks__dispatch. A future backend (e.g. an Obsidian
#                            adapter) registers by defining its four
#                            `_ks_backend_obsidian_{read,write,append,list}`
#                            functions and being sourced before use — no
#                            change to this file required.
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).
# Every function is safe to call under `set -u` (no reliance on unset globals
# beyond the `: "${VAR:=default}"` seams below, which assign-if-unset).

# ── Root resolution (the ONE seam) ──────────────────────────────────────────
# Prints the resolved store root (no trailing slash). Does not create it —
# callers/backends create directories lazily on write.
ks_root() {
  : "${KNOWLEDGE_STORE_ROOT:=${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge}"
  printf '%s\n' "$KNOWLEDGE_STORE_ROOT"
}

# ── Backend dispatch ─────────────────────────────────────────────────────
: "${KNOWLEDGE_STORE_BACKEND:=plain-files}"

# <op> -> prints the resolved backend function name for the CURRENT
# KNOWLEDGE_STORE_BACKEND. Kebab-case backend names map to snake_case
# function-name segments (plain-files -> plain_files).
ks__backend_fn() {
  local op="$1" backend="${KNOWLEDGE_STORE_BACKEND//-/_}"
  printf '_ks_backend_%s_%s\n' "$backend" "$op"
}

# <op> [args...] -> dispatches to the current backend's implementation of
# <op>, or fails with exit 2 if the backend does not implement it (unknown
# backend name, or a backend missing one of the four required ops).
ks__dispatch() {
  local op="$1"; shift
  local fn; fn="$(ks__backend_fn "$op")"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'knowledge_store: backend "%s" does not implement "%s" (no %s defined)\n' \
      "$KNOWLEDGE_STORE_BACKEND" "$op" "$fn" >&2
    return 2
  fi
  "$fn" "$@"
}

# ── doc-id normalization (shared by every backend) ──────────────────────────
# A doc-id is a relative, '/'-separated path under the store root, naming a
# markdown document. ".md" is appended when absent, so callers may write
# either "Decisions/foo" or "Decisions/foo.md" and reach the same document.
#
# Guards (best-effort, textual — not a full path canonicalization): rejects
# an absolute doc-id, and rejects any doc-id containing a ".." path segment.
# This is enough to keep every backend from ever reading/writing outside
# ks_root; it is NOT a general path-safety library (no symlink resolution,
# no handling of "//" or trailing-dot oddities).
#
# <doc-id> -> prints the normalized id, or returns 2 with a message on stderr.
ks__normalize_id() {
  local id="$1"
  [ -n "$id" ] || { echo "knowledge_store: empty doc-id" >&2; return 2; }
  case "$id" in
    /*)
      printf 'knowledge_store: doc-id must be relative, got absolute path: %s\n' "$id" >&2
      return 2
      ;;
  esac
  case "/$id/" in
    */../*)
      printf 'knowledge_store: doc-id must not contain a ".." segment: %s\n' "$id" >&2
      return 2
      ;;
  esac
  case "$id" in
    *.md) printf '%s\n' "$id" ;;
    *)    printf '%s.md\n' "$id" ;;
  esac
}

# ── Public interface ─────────────────────────────────────────────────────
# ks_read <doc-id>                         -> content on stdout; exit 1 if absent
# ks_write <doc-id> [--no-clobber]          <- content on stdin; full replace
# ks_append <doc-id>                        <- content on stdin; create-or-append
# ks_list [prefix]                          -> one doc-id per line, sorted
# See knowledge_store.contract.md for the authoritative semantics/exit codes.
ks_read()   { ks__dispatch read   "$@"; }
ks_write()  { ks__dispatch write  "$@"; }
ks_append() { ks__dispatch append "$@"; }
ks_list()   { ks__dispatch list   "$@"; }

# ── plain-files backend ─────────────────────────────────────────────────
# Markdown files (optionally carrying a YAML frontmatter block) under
# ks_root. This backend treats document content as opaque bytes — it moves
# content in and out, it does not parse or validate frontmatter. A caller
# that wants frontmatter-aware reads/writes composes that on top (out of
# scope for this seam).

# <doc-id> -> absolute filesystem path (internal helper, not part of the
# public interface — callers use ks_read/ks_write/ks_append/ks_list).
_ks_backend_plain_files_path() {
  local id root
  id="$(ks__normalize_id "$1")" || return $?
  root="$(ks_root)"
  printf '%s/%s\n' "$root" "$id"
}

# <doc-id> -> file content on stdout. Exit 1 (not found) if the document does
# not exist. Exit 2 on a bad doc-id (propagated from ks__normalize_id).
# NOTE: no local in this file may be named `path` (nor `cdpath`/`fpath`/
# `mailpath`). Under zsh those are tied to the colon-array side of the matching
# uppercase env var (`path` <-> `PATH`), so a `local path=…` in a *sourced*
# function rebinds `PATH` for that scope and breaks any later subprocess lookup
# (e.g. `uvx` in the sibling knowledge_search.sh). bash treats `path` as
# ordinary, so it's invisible under bash/CI. Use `doc_path` instead. (temperloop#40)
_ks_backend_plain_files_read() {
  local doc_path
  doc_path="$(_ks_backend_plain_files_path "$1")" || return $?
  if [ ! -f "$doc_path" ]; then
    printf 'knowledge_store: not found: %s\n' "$1" >&2
    return 1
  fi
  cat "$doc_path"
}

# <doc-id> [--no-clobber]  <- content on stdin.
# Full-replace write: creates parent directories as needed, and creates the
# document if absent. By DEFAULT overwrites an existing document (the same
# semantics as `cat > file` / `cp`) — pass --no-clobber to instead fail with
# exit 3 when the document already exists (create-only semantics). Writes
# atomically: content is staged to a sibling temp file and renamed into
# place, so a killed/interrupted write can never leave a half-written
# document at the target path.
_ks_backend_plain_files_write() {
  local id="" no_clobber=0 arg doc_path tmp   # `doc_path` not `path` — zsh PATH tie (temperloop#40)
  for arg in "$@"; do
    case "$arg" in
      --no-clobber) no_clobber=1 ;;
      *) id="$arg" ;;
    esac
  done
  doc_path="$(_ks_backend_plain_files_path "$id")" || return $?
  if [ "$no_clobber" -eq 1 ] && [ -e "$doc_path" ]; then
    printf 'knowledge_store: refusing to clobber existing doc (--no-clobber): %s\n' "$id" >&2
    return 3
  fi
  mkdir -p "$(dirname "$doc_path")" || return 1
  tmp="$(mktemp "${doc_path}.XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$doc_path"
}

# <doc-id>  <- content on stdin.
# Create-or-append: creates parent directories and the document itself if
# absent, otherwise appends to the existing document's end. Not staged
# through a temp file (a plain O_APPEND open) — appends are for incremental
# logs, where "atomic full-file replace" isn't the desired semantic and
# would be needlessly expensive for repeated small appends.
_ks_backend_plain_files_append() {
  local id="$1" doc_path   # `doc_path` not `path` — zsh PATH tie (temperloop#40)
  doc_path="$(_ks_backend_plain_files_path "$id")" || return $?
  mkdir -p "$(dirname "$doc_path")" || return 1
  cat >> "$doc_path"
}

# [prefix] -> one doc-id per line (relative to ks_root, '.md' included),
# sorted, restricted to documents under <prefix> when given. Prints nothing
# (exit 0) if the root, or the prefix subdirectory, does not exist yet.
_ks_backend_plain_files_list() {
  local root scope rel
  root="$(ks_root)"
  [ -d "$root" ] || return 0
  if [ -n "${1:-}" ]; then
    scope="$root/$1"
    rel="$1"
  else
    scope="$root"
    rel="."
  fi
  [ -d "$scope" ] || return 0
  ( cd "$root" && find "$rel" -type f -name '*.md' | sed 's#^\./##' | sort )
}
