#!/usr/bin/env bash
# manifest.sh — machine-surface install manifest library (temperloop#261,
# ADR K164 D7 "install manifest" amendment).
#
# LIBRARY ONLY. This file defines the seam between a future `temperloop
# install` and `temperloop uninstall` subcommand: install calls
# manifest_backup_and_record() for every path it writes; uninstall calls
# manifest_restore_from_record() for every path it wants to undo. Neither
# CLI exists yet — this item ships the sourceable helpers + schema alone.
#
# WHY A SEPARATE MANIFEST FROM links_enumerate() (links.sh, same directory):
# links_enumerate() describes DESIRED state ("what should exist after
# install") — it is recomputed fresh every run and carries no memory of what
# a PAST install run actually did. It cannot tell "this path was created by
# us" from "this path already existed and install is about to replace it",
# and settings.json / the composed CLAUDE.md carry no on-disk ownership
# marker. This manifest is the DID-state record links_enumerate() has no way
# to keep: one entry per path install has touched, INCLUDING an explicit,
# never-derived backup location for anything install replaced.
#
# WHY A SEPARATE MANIFEST FROM .temperloop/config (bin/subcommands/eject.sh,
# bin/subcommands/init.sh): .temperloop/config is REPO-TREE-scoped (lives
# inside a target repo's working copy, committed on a proposal branch) and
# has a SOLE-WRITER contract (init.sh is documented as the only writer;
# eject.sh is the only reader for revert purposes). This manifest is
# MACHINE-scoped (XDG state, outside any git tree) and records a completely
# different class of side effect (files/symlinks under $HOME and
# ~/.local/bin, not GitHub API state like labels/required-checks/boards).
# The two manifests are never merged, never cross-read, and use different
# on-disk formats by design — see D7's own note in
# `Decisions/temperloop - Configuration & installation architecture (K164)`:
# "kept as a *separate* manifest; .temperloop/config is repo-tree-scoped
# with a sole-writer contract, don't overload it."
#
# ── On-disk location ────────────────────────────────────────────────────
#   ${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/install-manifest.json
#   ${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/backups/<path>
#
# XDG_STATE_HOME itself is a generic OS/XDG passthrough var with no
# project-specific override point of its own (see the "Inclusion rule" in
# workflows/scripts/config/knob-registry.tsv's header, and its explicit
# listing in check-knob-registry.sh's KNOB_REGISTRY_GENERIC_ALLOWLIST) — so
# this file introduces NO new tunable knob; a caller who wants a different
# state root just sets XDG_STATE_HOME, same as any other XDG-respecting
# tool. Tests point HOME/XDG_STATE_HOME at a throwaway tmpdir; there is no
# separate override seam.
#
# ── Schema (schema_version: 1) ──────────────────────────────────────────
#   {
#     "schema_version": 1,
#     "paths": {
#       "<absolute-path>": {
#         "state": "created" | "preexisting",
#         "backup_path": "<absolute-path>" | null
#       },
#       ...
#     }
#   }
#
#   schema_version   integer. The manifest's OWN format version — bumped
#                    per VERSIONING.md's contract-surface rules (a field
#                    reshape is breaking; a new field is additive; a
#                    semantics-only change is minor). See VERSIONING.md's
#                    "Machine-surface install manifest, specifically" note.
#   paths            object keyed by absolute path. A path with NO entry
#                    here is INVISIBLE to every reader in this library —
#                    manifest_get_path_entry / manifest_has_path /
#                    manifest_restore_from_record never infer, guess, or
#                    namespace-match; uninstall must never touch a path
#                    install didn't itself record (mirrors eject.sh's own
#                    "nothing is inferred by namespace grep" discipline).
#   .state           "created"     — the path did not exist before install
#                                    touched it. Nothing to restore on
#                                    uninstall beyond removing it.
#                    "preexisting" — something was already at this path
#                                    before install replaced it. The
#                                    original was copied to .backup_path
#                                    before being overwritten.
#   .backup_path     EXPLICIT, RECORDED field — the exact backup location
#                    written at record time. NEVER derived/recomputed by a
#                    reader from the source path (e.g. by re-running the
#                    same encoding function) — restore always reads this
#                    field, so a future change to how backups are named
#                    never breaks restoring an OLDER manifest's entries.
#                    null when .state == "created" (nothing was backed up).
#
# ── Read-compatibility stance (D7: "the manifest outlives the code that
# wrote it") ────────────────────────────────────────────────────────────
# MANIFEST_READABLE_SCHEMA_VERSIONS lists every schema_version this build of
# manifest.sh knows how to parse. manifest_load() checks the on-disk
# schema_version against that list: a KNOWN version is read and returned; an
# UNKNOWN version (newer than this code, or malformed/missing) causes
# manifest_load() to REFUSE — it prints the exact version it found (or
# "unknown") and the set it can read, to stderr, and returns non-zero. It
# never silently guesses or truncates. When a future schema bump needs an
# in-memory upgrade path (e.g. schema_version 1 -> 2 renames a field), that
# transform is added INSIDE manifest_load() keyed on the version read, and
# the new version is appended to MANIFEST_READABLE_SCHEMA_VERSIONS in the
# same change — this header is the place that transform gets documented.
#
# ── Re-install convergence (lib invariant) ─────────────────────────────
# manifest_backup_and_record() is idempotent per path: calling it again for
# a path ALREADY present in the manifest is a no-op (no duplicate entry, no
# second backup — a second backup of an already-installed path would
# overwrite the ORIGINAL preexisting backup with the now-managed file's
# content, which is exactly the corruption this guards against). Re-running
# an install is therefore always safe to re-run against a manifest that
# already reflects a prior run.
#
# ── Marker-stamp helper ──────────────────────────────────────────────────
# manifest_marker_line / manifest_has_marker embed and detect a
# machine-readable ownership marker line (MANIFEST_MARKER_TAG) inside a
# generated REAL file (settings.json-like composers can't rely on `-L`/
# readlink the way a managed symlink can). This is a SECONDARY check only —
# the manifest itself (state + backup_path) is authoritative for
# install/uninstall; the marker is a defense-in-depth signal a composer can
# embed so a human or a doctor-style check can recognize "this file is
# temperloop-managed" even without reading the manifest.
#
# ── Public functions ─────────────────────────────────────────────────────
#   manifest_state_dir                         -> prints the state root dir
#   manifest_file                              -> prints the manifest path
#   manifest_backup_dir                        -> prints the backups root
#   manifest_schema_version                    -> prints this build's writer schema_version
#   manifest_load                              -> prints the current manifest JSON (compat-checked)
#   manifest_has_path <path>                   -> rc 0 iff <path> has an entry
#   manifest_get_path_entry <path>             -> prints the entry JSON, or nothing (rc != 0) if absent
#   manifest_remove_path_entry <path>          -> deletes <path>'s entry (no-op if absent)
#   manifest_backup_and_record <path>          -> install-side: back up + record (idempotent)
#   manifest_restore_from_record <path>        -> uninstall-side: restore/remove + un-record
#   manifest_marker_line [<comment-prefix>]    -> prints an embeddable ownership marker line
#   manifest_has_marker <file>                 -> rc 0 iff <file> contains the marker
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/manifest.sh"
#   manifest_backup_and_record "$HOME/.zshrc"
#   ...
#   manifest_restore_from_record "$HOME/.zshrc"
#
# Dependencies: bash (3.2+), jq. No network. No global shell-option changes
# (no `set -e`/`set -u` at file scope) — same posture as links.sh, since a
# sourced library must not silently change its caller's shell options.
#
# shellcheck shell=bash

# Guard against double-sourcing (mirrors links.sh).
if [[ "${_TEMPERLOOP_MANIFEST_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_MANIFEST_SH_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MANIFEST_SCHEMA_VERSION=1
MANIFEST_READABLE_SCHEMA_VERSIONS="1"
MANIFEST_MARKER_TAG="temperloop-managed"

# ---------------------------------------------------------------------------
# manifest_state_dir / manifest_file / manifest_backup_dir
# ---------------------------------------------------------------------------
manifest_state_dir() {
  printf '%s/temperloop' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

manifest_file() {
  printf '%s/install-manifest.json' "$(manifest_state_dir)"
}

manifest_backup_dir() {
  printf '%s/backups' "$(manifest_state_dir)"
}

manifest_schema_version() {
  printf '%s' "$MANIFEST_SCHEMA_VERSION"
}

# ---------------------------------------------------------------------------
# _manifest_require_jq — internal dependency check, called from manifest_load
# (every other public function routes through manifest_load first, so a
# missing jq is caught in exactly one place).
# ---------------------------------------------------------------------------
_manifest_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "manifest.sh: jq not found on PATH — required for manifest read/write" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# manifest_load
#
# Prints the current manifest JSON to stdout. If no manifest file exists
# yet, prints a fresh empty skeleton (schema_version=current, paths={}) —
# this is the normal first-install state, not an error. If a file exists,
# it MUST be valid JSON with a schema_version this build recognises
# (MANIFEST_READABLE_SCHEMA_VERSIONS); otherwise this refuses legibly (see
# the header's "Read-compatibility stance") and returns 1 with nothing on
# stdout.
# ---------------------------------------------------------------------------
manifest_load() {
  _manifest_require_jq || return 1

  local file
  file="$(manifest_file)"

  if [[ ! -f "$file" ]]; then
    printf '{"schema_version":%s,"paths":{}}\n' "$MANIFEST_SCHEMA_VERSION"
    return 0
  fi

  local json version
  if ! json="$(jq -e '.' "$file" 2>/dev/null)"; then
    echo "manifest.sh: $file is not valid JSON — refusing to read (fix or remove by hand)" >&2
    return 1
  fi

  version="$(jq -r '.schema_version // "unknown"' <<<"$json")"
  case " $MANIFEST_READABLE_SCHEMA_VERSIONS " in
    *" $version "*) ;;
    *)
      echo "manifest.sh: $file has schema_version=$version, which this build of manifest.sh does not know how to read (readable: $MANIFEST_READABLE_SCHEMA_VERSIONS) — refusing to guess; upgrade temperloop before running install/uninstall against this manifest" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
# _manifest_write <json> — atomic write of the full manifest document.
# ---------------------------------------------------------------------------
_manifest_write() {
  local json="$1" file dir tmp
  file="$(manifest_file)"
  dir="$(dirname "$file")"

  if ! mkdir -p "$dir"; then
    echo "manifest.sh: could not create $dir" >&2
    return 1
  fi
  tmp="$(mktemp "${dir}/.manifest.XXXXXX")" || {
    echo "manifest.sh: mktemp failed in $dir" >&2
    return 1
  }
  if ! printf '%s\n' "$json" | jq '.' >"$tmp" 2>/dev/null; then
    printf '%s' "$json" >"$tmp"
  fi
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# manifest_has_path <path> — rc 0 iff <path> has a recorded entry.
# ---------------------------------------------------------------------------
manifest_has_path() {
  local path="$1" json
  json="$(manifest_load)" || return 1
  jq -e --arg p "$path" '(.paths[$p] // null) != null' <<<"$json" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# manifest_get_path_entry <path>
#
# Prints the entry JSON ({"state":...,"backup_path":...}) for <path>, or
# prints nothing and returns non-zero if <path> has no entry — a path
# absent from the manifest is invisible; this is the read primitive that
# guarantees it (never namespace-matched, never inferred).
# ---------------------------------------------------------------------------
manifest_get_path_entry() {
  local path="$1" json
  json="$(manifest_load)" || return 1
  jq -ce --arg p "$path" '.paths[$p] // empty' <<<"$json"
}

# ---------------------------------------------------------------------------
# manifest_remove_path_entry <path> — deletes <path>'s entry. No-op (rc 0)
# if <path> has no entry.
# ---------------------------------------------------------------------------
manifest_remove_path_entry() {
  local path="$1" json new_json
  json="$(manifest_load)" || return 1
  new_json="$(jq --arg p "$path" 'del(.paths[$p])' <<<"$json")" || return 1
  _manifest_write "$new_json"
}

# ---------------------------------------------------------------------------
# _manifest_set_entry <path> <state> <backup_path-or-empty> — internal
# writer. Records/overwrites <path>'s entry unconditionally; callers that
# need re-install convergence semantics (idempotent, no duplicate, no
# spurious re-backup) go through manifest_backup_and_record instead, which
# checks manifest_has_path first.
# ---------------------------------------------------------------------------
_manifest_set_entry() {
  local path="$1" state="$2" backup_path="$3" json new_json
  json="$(manifest_load)" || return 1
  new_json="$(jq --arg p "$path" --arg s "$state" --arg b "$backup_path" \
    '.paths[$p] = {state: $s, backup_path: (if $b == "" then null else $b end)}' \
    <<<"$json")" || return 1
  _manifest_write "$new_json"
}

# ---------------------------------------------------------------------------
# manifest_backup_and_record <path>
#
# INSTALL-SIDE helper. Call this immediately BEFORE writing/replacing
# <path> (a symlink, a real file, anything install is about to manage):
#
#   - If <path> is ALREADY recorded in the manifest: no-op (idempotent
#     re-install convergence — no duplicate entry, no second backup of an
#     already-managed path).
#   - Else if <path> currently exists on disk (file, symlink — dangling or
#     not): the existing content/symlink is copied to a backup path under
#     manifest_backup_dir (mirroring <path>'s own absolute path under that
#     root), and an entry {state:"preexisting", backup_path:<that path>} is
#     recorded.
#   - Else (nothing at <path> yet): an entry {state:"created",
#     backup_path:null} is recorded — nothing to back up.
#
# <path> must be absolute. Prints a one-line status (mirrors links.sh's
# links_apply_symlink idiom). Returns non-zero on any I/O failure — never
# partially records (the manifest write happens only after a successful
# backup copy).
# ---------------------------------------------------------------------------
manifest_backup_and_record() {
  local path="$1"

  if [[ -z "$path" ]]; then
    echo "manifest_backup_and_record: path argument required" >&2
    return 2
  fi
  case "$path" in
    /*) ;;
    *)
      echo "manifest_backup_and_record: path must be absolute: $path" >&2
      return 2
      ;;
  esac

  if manifest_has_path "$path"; then
    echo "  = ${path} already recorded — no re-backup (idempotent re-install)"
    return 0
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    local backup_dir backup_path
    backup_dir="$(manifest_backup_dir)"
    backup_path="${backup_dir}${path}"
    if ! mkdir -p "$(dirname "$backup_path")"; then
      echo "manifest_backup_and_record: could not create backup directory for ${path}" >&2
      return 1
    fi
    if ! cp -pPR "$path" "$backup_path"; then
      echo "manifest_backup_and_record: backup of ${path} failed" >&2
      return 1
    fi
    if ! _manifest_set_entry "$path" "preexisting" "$backup_path"; then
      echo "manifest_backup_and_record: recording ${path} failed after backup" >&2
      return 1
    fi
    echo "  → ${path} backed up to ${backup_path}, recorded (preexisting)"
  else
    if ! _manifest_set_entry "$path" "created" ""; then
      echo "manifest_backup_and_record: recording ${path} failed" >&2
      return 1
    fi
    echo "  → ${path} recorded (created)"
  fi
}

# ---------------------------------------------------------------------------
# manifest_restore_from_record <path>
#
# UNINSTALL-SIDE helper. Reads <path>'s manifest entry and undoes it:
#
#   - No entry for <path>: no-op (rc 0) — a path the manifest doesn't know
#     about is NEVER touched, no matter how plausible its name looks.
#   - state == "created": <path> is removed (rm -rf), then the entry is
#     deleted.
#   - state == "preexisting": the recorded backup_path is copied back onto
#     <path> (overwriting whatever install left there), the backup file is
#     removed, then the entry is deleted. If backup_path is empty/missing
#     on disk, this REFUSES (returns 1) rather than deleting <path> with
#     nothing to restore it from — a data-integrity guard, not a silent
#     best-effort.
#
# Prints a one-line status. <path> must be absolute.
# ---------------------------------------------------------------------------
manifest_restore_from_record() {
  local path="$1"

  if [[ -z "$path" ]]; then
    echo "manifest_restore_from_record: path argument required" >&2
    return 2
  fi
  case "$path" in
    /*) ;;
    *)
      echo "manifest_restore_from_record: path must be absolute: $path" >&2
      return 2
      ;;
  esac

  local entry
  if ! entry="$(manifest_get_path_entry "$path")"; then
    echo "  (no manifest record for ${path} — leaving untouched)"
    return 0
  fi

  local state backup_path
  state="$(jq -r '.state' <<<"$entry")"
  backup_path="$(jq -r '.backup_path // empty' <<<"$entry")"

  case "$state" in
    created)
      rm -rf -- "$path"
      manifest_remove_path_entry "$path"
      echo "  → ${path} removed (was created by install)"
      ;;
    preexisting)
      if [[ -z "$backup_path" || ( ! -e "$backup_path" && ! -L "$backup_path" ) ]]; then
        echo "manifest_restore_from_record: ${path} is recorded preexisting but backup '${backup_path}' is missing — refusing to touch ${path}" >&2
        return 1
      fi
      rm -rf -- "$path"
      if ! cp -pPR "$backup_path" "$path"; then
        echo "manifest_restore_from_record: restoring ${path} from ${backup_path} failed" >&2
        return 1
      fi
      rm -rf -- "$backup_path"
      manifest_remove_path_entry "$path"
      echo "  → ${path} restored from backup (was preexisting before install)"
      ;;
    *)
      echo "manifest_restore_from_record: ${path} has unknown recorded state '${state}' — refusing to touch" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# manifest_marker_line [<comment-prefix>]
#
# Prints one machine-readable ownership marker line for a composer to embed
# in a generated real file (e.g. a settings.json-like managed real file).
# <comment-prefix> defaults to "#"; pass something else (e.g. "//") for a
# composer whose target format needs a different comment syntax.
# ---------------------------------------------------------------------------
manifest_marker_line() {
  local prefix="${1:-#}"
  printf '%s %s: generated by temperloop install — do not hand-edit (see temperloop uninstall)\n' \
    "$prefix" "$MANIFEST_MARKER_TAG"
}

# ---------------------------------------------------------------------------
# manifest_has_marker <file> — rc 0 iff <file> contains the marker tag.
# ---------------------------------------------------------------------------
manifest_has_marker() {
  local file="$1"
  [[ -f "$file" ]] && grep -q "$MANIFEST_MARKER_TAG" "$file" 2>/dev/null
}
