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
#                            ${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge
#                            (renamed from .../foundation/knowledge in
#                            v0.15.0, temperloop#165 — an EXISTING store at
#                            the legacy default is still found through the
#                            rename window; see _ks_default_root below.
#                            Legacy fallback removed in v0.17.0.)
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
# Default-root probe for the temperloop#165 rename window (v0.15.0,
# read-old-write-new): the default namespace moved from
# .../foundation/knowledge to .../temperloop/knowledge. When
# KNOWLEDGE_STORE_ROOT is unset, prefer the NEW default; when nothing exists
# there but an EXISTING store sits at the legacy default, resolve to the
# legacy store (one NOTE line per process — the `:=` seam in ks_root below
# runs this at most once) so a pre-rename install keeps finding its notes.
# The legacy fallback is removed in v0.17.0 (VERSIONING.md pre-1.0 window;
# the v0.15.0 CHANGELOG BREAKING entry carries the migration note).
# TEMPERLOOP_LEGACY_WINDOW_CLOSED is a TEST/SIMULATION-ONLY seam (never set
# in production use; same registry-exempt status as BUILD_QUOTA_NOW): =1
# simulates the post-v0.17.0 removal — the legacy store is then named
# loudly and the NEW default used, never a silent miss.
_ks_default_root() {
  local new_root old_root
  new_root="${XDG_DATA_HOME:-$HOME/.local/share}/temperloop/knowledge"
  old_root="${XDG_DATA_HOME:-$HOME/.local/share}/foundation/knowledge"
  if [ ! -d "$new_root" ] && [ -d "$old_root" ]; then
    if [ "${TEMPERLOOP_LEGACY_WINDOW_CLOSED:-0}" = "1" ]; then # knob:exempt — test/simulation-only seam
      printf 'knowledge_store: NOTE — a legacy store exists at %s but the legacy default-root fallback was removed in v0.17.0; the default root is now %s. Move the store (mv "%s" "%s") or set KNOWLEDGE_STORE_ROOT.\n' \
        "$old_root" "$new_root" "$old_root" "$new_root" >&2
    else
      printf 'knowledge_store: NOTE — using legacy store root %s (default moved to %s in v0.15.0; legacy fallback removed in v0.17.0 — move the store or set KNOWLEDGE_STORE_ROOT).\n' \
        "$old_root" "$new_root" >&2
      printf '%s\n' "$old_root"
      return 0
    fi
  fi
  printf '%s\n' "$new_root"
}

# Prints the resolved store root (no trailing slash). Does not create it —
# callers/backends create directories lazily on write.
ks_root() {
  : "${KNOWLEDGE_STORE_ROOT:=$(_ks_default_root)}"
  printf '%s\n' "$KNOWLEDGE_STORE_ROOT"
}

# ── Backend dispatch ─────────────────────────────────────────────────────
: "${KNOWLEDGE_STORE_BACKEND:=plain-files}"

# ── Agent-plane transport matcher seam (temperloop#236, Epic #226 capture
# point 2: "agent-plane read telemetry") ───────────────────────────────────
# Space-separated list of shell `case`-glob patterns naming which PostToolUse
# `tool_name` values the agent-plane read-telemetry hook
# (claude/hooks/ks-agent-read-log.sh) treats as knowledge-store MCP calls —
# the transport-layer counterpart to KNOWLEDGE_STORE_BACKEND just above
# (that knob selects the SCRIPT-plane backend; this one tells the
# AGENT-plane hook which MCP tool namespaces count as "reading the
# knowledge store" today).
#
# ONE seam to update at the planned `mcp__obsidian__*` EOL cutover
# (F#946/#947): appending ` mcp__basic-memory__*` here is the entire
# change — no hook edit required. Kept as a plain space-separated glob list
# (not JSON/YAML) so it stays a single `${VAR:=...}` shell literal that a
# machine-readable lint (the telemetry-coverage lint named in the epic's
# Contract) can parse with a trivial `for pat in $VAR` loop — the same shape
# as every other space-separated knob in this tree (e.g. FUNNEL_DRIVEN_PATHS
# in build.config.sh).
: "${KNOWLEDGE_READ_LOG_AGENT_MATCHERS:=mcp__obsidian* mcp__obsidian-builtin*}"

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
  ks__read_log_emit script "$op" "${1:-}"
  "$fn" "$@"
}

# ── Read-log telemetry (temperloop#229, Epic #226 "script-plane read
# telemetry") ───────────────────────────────────────────────────────────
# One normalized line per dispatched op — read/write/append/list from THIS
# file's ks__dispatch, plus "search" from knowledge_search.sh's ks_search
# entrypoint (that file sources this one first, per the contract, so
# ks__read_log_emit is already in scope there — no duplicate implementation).
# The log lives OUTSIDE the knowledge store on purpose: a doc-store-internal
# log would churn the search index and create a self-observation loop (the
# store logging reads of its own read-log).
#
# Line format (fields joined by " · ", one event per line):
#
#   <timestamp> · <session-id> · <plane> · <op> · <doc-path-or-query>
#
#   timestamp           UTC, `date -u +%Y-%m-%dT%H:%M:%SZ` — matches this
#                        repo's other raw-lake emitters (claim.sh/capture.sh).
#   session-id           $CLAUDE_CODE_SESSION_ID, or literal "-" when unset.
#                        A single-char placeholder (rather than an empty
#                        field) keeps the field COUNT/shape stable even when
#                        the value is missing — unlike this repo's JSONL
#                        raw-lake records, a plain " · "-joined text line has
#                        no key names to anchor a reader on, so an empty
#                        field between two separators is easy to miscount.
#   plane                caller's plane. Always "script" for every call in
#                        this file and knowledge_search.sh (both are
#                        script-plane callers of the seam) — an agent-plane
#                        hook is a LATER, separate item per the epic
#                        contract, and will call ks__read_log_emit with
#                        plane="agent" rather than get a new knob here.
#   op                   read | write | append | list | search | sync
#                        (sync — the optional capability, temperloop#430 —
#                        carries its SUB-op, e.g. "push", in the
#                        doc-path-or-query field)
#   doc-path-or-query    the dispatched doc-id (read/write/append/list) or
#                        the search query (ks_search) — sanitized (newlines/
#                        tabs -> single spaces) so one event is always
#                        exactly one line.
#
# This is a STABLE contract other telemetry items are documented to consume
# (agent-plane hook, SessionEnd one-liner, /tidy tally) — do not change the
# field order/count/separator without updating every consumer.
#
# Knob: KNOWLEDGE_READ_LOG (path). ONE override point for the log's
# location, same "one knob" shape as KNOWLEDGE_STORE_ROOT above. Default
# follows the XDG state-dir convention (this is runtime/operational log
# output, not user data — XDG_STATE_HOME is the correct base per the XDG
# base-directory spec, distinct from KNOWLEDGE_STORE_ROOT's XDG_DATA_HOME).
_ks_read_log_path() {
  : "${KNOWLEDGE_READ_LOG:=${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log}"
  printf '%s\n' "$KNOWLEDGE_READ_LOG"
}

# <plane> <op> <doc-path-or-query> -> appends one normalized read-log line.
# NEVER fails the caller: every failure mode (mkdir, append) is swallowed
# and WARNed to stderr, mirroring claim.sh/capture.sh's raw-lake emit
# guards — read-log telemetry must never be the reason a real
# ks_read/ks_write/ks_append/ks_list/ks_search call fails (fail-open, always
# returns 0).
ks__read_log_emit() {
  local plane="$1" op="$2" doc="$3" log ts sess clean log_dir
  log="$(_ks_read_log_path)"
  log_dir="$(dirname "$log")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sess="${CLAUDE_CODE_SESSION_ID:--}"
  clean="$(printf '%s' "$doc" | tr '\t\n' '  ')"
  if ! mkdir -p "$log_dir" 2>/dev/null; then
    printf 'knowledge_store: WARN read-log dir unavailable: %s (dispatch unaffected)\n' "$log_dir" >&2
    return 0
  fi
  # \xc2\xb7 is the UTF-8 encoding of U+00B7 MIDDLE DOT ("·"), written as a
  # printf escape rather than the literal glyph so the separator survives a
  # non-UTF-8-aware editor/diff/grep untouched — a byte pinned exactly, since
  # every consumer of this log greps/splits on it.
  printf '%s \xc2\xb7 %s \xc2\xb7 %s \xc2\xb7 %s \xc2\xb7 %s\n' "$ts" "$sess" "$plane" "$op" "$clean" >>"$log" 2>/dev/null \
    || printf 'knowledge_store: WARN failed to append read-log record to %s (dispatch unaffected)\n' "$log" >&2
  return 0
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
# ks_sync <sub-op> [args...]                -> OPTIONAL backend capability
#                                              (init/push/pull/status); exit 3
#                                              "skipped —" when the backend
#                                              does not implement it
# ks_sync_available                          -> exit 0/3 probe, no stdout
# See knowledge_store.contract.md for the authoritative semantics/exit codes.
ks_read()   { ks__dispatch read   "$@"; }
ks_write()  { ks__dispatch write  "$@"; }
ks_append() { ks__dispatch append "$@"; }
ks_list()   { ks__dispatch list   "$@"; }

# ── Sync — OPTIONAL backend capability (temperloop#430, ADR 0003) ──────────
# Unlike read/write/append/list (universal ops every backend must implement),
# sync is a store-level capability only coherent for a backend whose store is
# a directory under ks_root (plain-files: a git repo AT the root). A backend
# that cannot implement it — e.g. `obsidian`, which never consults
# KNOWLEDGE_STORE_ROOT at all (the vault root IS the store root, so a
# git-under-root sync has no meaning there) — degrades to the legible exit-3
# "skipped —" pattern knowledge_search.sh established: never a silent no-op,
# never a hard failure. MANUAL invocation only, by contract: no caller of
# this seam may run ks_sync from a scheduled/background job (launchd, cron,
# a watcher); it is an operator-invoked action, like `git push` itself.

# Availability probe (mirrors ks_search_available's exit-0/exit-3 shape).
# Two layers, both legible:
#   1. capability: the current backend defines a `sync` op at all — if not,
#      the exact "skipped — sync unavailable for backend <name>" notice
#      (stderr) + exit 3.
#   2. tooling: the backend may additionally define a `sync_available` op
#      probing its required subprocess tooling (plain-files: git on PATH),
#      dispatched through the same ks__backend_fn naming seam; its own exit
#      3 + "skipped —" notice propagates.
# Exit 0 = ready; exit 3 = unavailable (notice on stderr, never stdout).
ks_sync_available() {
  local fn avail_fn
  fn="$(ks__backend_fn sync)"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    printf 'skipped — sync unavailable for backend %s\n' "$KNOWLEDGE_STORE_BACKEND" >&2
    return 3
  fi
  avail_fn="$(ks__backend_fn sync_available)"
  if declare -F "$avail_fn" >/dev/null 2>&1; then
    "$avail_fn" || return $?
  fi
  return 0
}

# <sub-op> [args...] — the ONE sanctioned entry for every sync operation.
# ALL sync ops route through this dispatch: no caller may shell
# `git -C "$(ks_root)"` directly — under a backend that never consults
# KNOWLEDGE_STORE_ROOT (obsidian) that back-channel would "sync" a directory
# that is not the store at all. Gated on the availability probe first, so an
# incapable backend yields exit 3 (skip), never the generic exit-2 dispatch
# error reserved for a missing UNIVERSAL op.
ks_sync() {
  ks_sync_available || return $?
  ks__dispatch sync "$@"
}

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

# ── plain-files sync (git-backed, manual-only) — temperloop#430, ADR 0003 ──
# EXPERIMENTAL. The store directory itself becomes a git repository
# (`$(ks_root)/.git`) with one remote, `origin`, pointing at an
# operator-provided URL — PRIVATE by default (the store is personal working
# notes; the documented worked example creates the remote with
# `gh repo create ... --private`). Single-tenant per $HOME: one flat store
# root, one remote — per-project partition is deferred (temperloop#418).
# Single-writer assumption: no merge-conflict story beyond git's own; `pull`
# is --ff-only and a diverged store is handed back to the operator to
# resolve with git directly (fail loud, exit 4 — never an auto-merge).
#
# Sub-op exit codes (mirrors knowledge_search.sh's shape):
#   0 — success
#   2 — invalid usage (unknown sub-op, missing <remote-url>)
#   3 — unavailable (via the ks_sync_available gate / sync_available probe)
#   4 — sync-operation failure (git failed: not initialized, no remote,
#       non-fast-forward pull, rejected push) — cause on stderr

# Tooling probe (layer 2 of ks_sync_available): git on PATH. Same
# "skipped —" prefix contract as knowledge_search's uvx probe.
_ks_backend_plain_files_sync_available() {
  command -v git >/dev/null 2>&1 && return 0
  echo "skipped — sync unavailable for backend plain-files: git not found on PATH" >&2
  return 3
}

# Guard: the store root must carry its OWN .git. Without this, a store dir
# that happens to sit inside some enclosing git repo would let `git -C`
# operate on that OUTER repo — the exact cross-repo damage this refuses.
_ks_backend_plain_files_sync__require_repo() {
  local root="$1"
  if [ ! -d "$root/.git" ]; then
    printf 'knowledge_store: sync not initialized for %s — run: ks_sync init <remote-url>\n' "$root" >&2
    return 4
  fi
  return 0
}

# init <remote-url> — make the store a git repo (if not one already) and
# point remote `origin` at <remote-url> (add or update). Idempotent. Never
# clones/pulls by itself — a second environment inits against the operator's
# existing remote and then runs `ks_sync pull` to receive the store.
_ks_backend_plain_files_sync__init() {
  local remote_url="${1:-}" root
  if [ -z "$remote_url" ]; then
    echo "knowledge_store: usage: ks_sync init <remote-url>" >&2
    return 2
  fi
  root="$(ks_root)"
  mkdir -p "$root" || return 4
  if [ ! -d "$root/.git" ]; then
    git -C "$root" init -q || return 4
    # Deterministic branch name, independent of the host's
    # init.defaultBranch (harmless on the unborn HEAD a fresh init has).
    git -C "$root" symbolic-ref HEAD refs/heads/main || return 4
  fi
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" remote set-url origin "$remote_url" || return 4
  else
    git -C "$root" remote add origin "$remote_url" || return 4
  fi
  printf 'knowledge_store: sync initialized — store %s, remote origin -> %s\n' \
    "$root" "$remote_url"
}

# push [-m <msg>] — stage everything, commit (only if there are changes),
# push the current branch to origin. Commit identity: the operator's own
# git identity (config or GIT_COMMITTER_* env) when present; a neutral
# knowledge-store-sync fallback otherwise (a fresh CI/sandbox HOME has
# neither, and an identity error here would be pure friction). The -c
# fallback never overrides a real identity — env vars outrank injected
# config in git's own precedence, and it is only injected when user.email
# resolves to nothing.
_ks_backend_plain_files_sync__push() {
  local msg="" root branch
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--message)
        msg="${2:?knowledge_store: ks_sync push -m requires a value}"
        shift 2
        ;;
      *)
        printf 'knowledge_store: unknown ks_sync push argument: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done
  [ -n "$msg" ] || msg="knowledge-store sync: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  root="$(ks_root)"
  _ks_backend_plain_files_sync__require_repo "$root" || return $?
  if ! git -C "$root" remote get-url origin >/dev/null 2>&1; then
    printf 'knowledge_store: sync has no remote for %s — run: ks_sync init <remote-url>\n' "$root" >&2
    return 4
  fi
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" || branch=main
  git -C "$root" add -A || return 4
  if [ -n "$(git -C "$root" status --porcelain)" ]; then
    if git -C "$root" config user.email >/dev/null 2>&1; then
      git -C "$root" commit -q -m "$msg" || return 4
    else
      git -C "$root" -c user.name="knowledge-store-sync" \
                     -c user.email="knowledge-store-sync@localhost" \
                     commit -q -m "$msg" || return 4
    fi
  fi
  if ! git -C "$root" rev-parse --verify -q HEAD >/dev/null; then
    echo "knowledge_store: nothing to push (store has no commits yet)"
    return 0
  fi
  git -C "$root" push -q -u origin "$branch" || {
    printf 'knowledge_store: sync push to origin failed (see git output above)\n' >&2
    return 4
  }
  printf 'knowledge_store: sync pushed %s -> origin\n' "$branch"
}

# pull — fast-forward-only pull of the current branch from origin. On a
# freshly-init'ed store (unborn HEAD) this receives the operator's real
# store from the remote — the second-environment bootstrap path. A diverged
# store fails loud (exit 4); resolving it is a deliberate operator action
# with git directly, never an auto-merge here.
_ks_backend_plain_files_sync__pull() {
  local root branch
  root="$(ks_root)"
  _ks_backend_plain_files_sync__require_repo "$root" || return $?
  if ! git -C "$root" remote get-url origin >/dev/null 2>&1; then
    printf 'knowledge_store: sync has no remote for %s — run: ks_sync init <remote-url>\n' "$root" >&2
    return 4
  fi
  branch="$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null)" || branch=main
  git -C "$root" pull -q --ff-only origin "$branch" || {
    printf 'knowledge_store: sync pull failed (diverged store? resolve with git in %s)\n' "$root" >&2
    return 4
  }
  printf 'knowledge_store: sync pulled origin/%s\n' "$branch"
}

# status — read-only summary (store, remote, branch, unsynced change count).
# Always exit 0 when it can answer, including the legible "not initialized"
# answer — status is a probe, not a gate.
_ks_backend_plain_files_sync__status() {
  local root dirty
  root="$(ks_root)"
  if [ ! -d "$root/.git" ]; then
    printf 'sync: not initialized (no git repo at %s) — run: ks_sync init <remote-url>\n' "$root"
    return 0
  fi
  printf 'store:  %s\n' "$root"
  printf 'remote: %s\n' \
    "$(git -C "$root" remote get-url origin 2>/dev/null || echo '(none — run: ks_sync init <remote-url>)')"
  printf 'branch: %s\n' \
    "$(git -C "$root" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
  dirty="$(git -C "$root" status --porcelain | wc -l | tr -d ' ')"
  printf 'unsynced changes: %s path(s)\n' "$dirty"
}

# The backend's sync op — sub-op router (dispatch target of ks__dispatch).
_ks_backend_plain_files_sync() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    init)   _ks_backend_plain_files_sync__init   "$@" ;;
    push)   _ks_backend_plain_files_sync__push   "$@" ;;
    pull)   _ks_backend_plain_files_sync__pull   "$@" ;;
    status) _ks_backend_plain_files_sync__status "$@" ;;
    *)
      echo "knowledge_store: usage: ks_sync <init <remote-url>|push [-m <msg>]|pull|status>" >&2
      return 2
      ;;
  esac
}
