#!/usr/bin/env bash
# record.sh — machine-scoped testbed artifact record (temperloop#1117 Produces
# 4, temperloop#1227).
#
# LIBRARY ONLY. This file is the append-only record every `temperloop
# testbed` run writes to as it creates artifacts (repo, mirror push, copied
# issues), and that teardown / promotion later read. No CLI exists yet —
# `temperloop testbed`, its teardown leg, and `/promote` (later items in this
# epic) are the callers; this item ships the sourceable helpers + schema
# alone, exactly as `workflows/scripts/install/manifest.sh` did for the
# install manifest (temperloop#261).
#
# WHY A SEPARATE FILE FROM install-manifest.json (manifest.sh's own header,
# lines 20-33, restated here so this file's scope is self-contained):
# install-manifest.json is MACHINE-scoped (XDG state) and records
# install/uninstall's filesystem side effects (files/symlinks under $HOME and
# ~/.local/bin) with a backup/restore contract. THIS record is also
# MACHINE-scoped, but a completely different subject: artifacts a `testbed`
# run creates OUTSIDE this machine (a GitHub repository, a mirror push,
# copied issues) that teardown deletes rather than restores — there is
# nothing to back up or roll back to, only something to enumerate and
# remove. The two manifests are never merged and never cross-read; they
# happen to share a state root only because both are XDG-scoped, not because
# they share a schema.
#
# WHY NOT `.temperloop/testbed.json` (repo-tree-scoped, the epic's own
# Produces-4 prose default before this item's acceptance criteria
# overrode it): `bin/subcommands/eject.sh` deletes the whole `.temperloop/`
# directory on a clean exit, and the CI round trip that exercises this path
# (`.github/workflows/install-tier2.yml`, re-scoped to
# `testbed -> init -> eject` by a later item in this epic) runs `eject`
# BETWEEN a testbed's creation and its teardown. A record that lived inside
# `.temperloop/` would be destroyed by that very eject before teardown ever
# got to read it — the artifact would survive on GitHub with no local trace
# to remove it by. Machine-scoped XDG state is the only location eject's
# blast radius does not reach.
#
# ── On-disk location ────────────────────────────────────────────────────
#   ${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/testbed-record.json
#
# XDG_STATE_HOME is the same generic OS/XDG passthrough manifest.sh's header
# already documents (see that file's header for the setting-registry
# cross-reference) — this file introduces no new tunable setting either.
#
# ── Schema (schema_version: 1) ──────────────────────────────────────────
#   {
#     "schema_version": 1,
#     "testbeds": {
#       "<owner>/<name>": [
#         {
#           "id": "<opaque, unique within this file>",
#           "created_at": "<ISO 8601 UTC>",
#           "testbed_repo": "<owner>/<name>",
#           "source_kind": "mirror-from-repo" | "materialize-from-seed",
#           "source_repo": "<owner>/<name>" | null,
#           "promotable": true | false,
#           "artifacts": {
#             "repo_created": true | false,
#             "mirror_pushed": true | false,
#             "issues_copied": true | false
#           }
#         },
#         ...
#       ],
#       ...
#     }
#   }
#
#   schema_version   integer. This record's OWN format version — same
#                    contract-surface rules as manifest.sh's schema_version
#                    (VERSIONING.md's "Machine-surface install manifest,
#                    specifically" note applies here too, generalized to
#                    "machine-surface record").
#   testbeds         object keyed by the CREATED TESTBED's own "owner/name"
#                    (as `git remote get-url origin` resolves inside that
#                    testbed checkout) — NOT the source repo's owner/name.
#                    This is what lets a consumer running inside a testbed
#                    checkout resolve its own entry with zero filesystem
#                    scan: read its own origin, key straight in. The value
#                    at each key is a LIST, never a single slot — running
#                    `temperloop testbed` a second time from the same
#                    original checkout (or twice concurrently) never orphans
#                    an already-recorded entry's teardown reference, even in
#                    the unlikely event both runs resolve the same key.
#   .id              opaque string, unique within this file. Callers pass
#                    this back to testbed_record_mark_step /
#                    testbed_record_get / testbed_record_remove to address
#                    one specific list entry without disturbing siblings at
#                    the same key.
#   .created_at      ISO 8601 UTC timestamp, set once at
#                    testbed_record_add() time. Never rewritten.
#   .testbed_repo    redundant with the containing key, carried onto the
#                    entry itself so a flattened enumeration
#                    (testbed_record_flat) is self-describing without the
#                    caller having to walk `.testbeds`' keys separately —
#                    this is what keeps a killed-partway run's artifact
#                    "enumerable" even by a caller that doesn't already know
#                    which key to look under.
#   .source_kind     "mirror-from-repo" | "materialize-from-seed" — the two
#                    source-provider seam implementations (temperloop#1117
#                    Produces 2). Set once at testbed_record_add() time.
#   .source_repo     "<owner>/<name>" for a mirror-from-repo testbed; null
#                    for materialize-from-seed (no repository owned by this
#                    project exists at any point, so there is nothing to
#                    name).
#   .promotable      boolean. false for materialize-from-seed (no original
#                    to promote to — Produces 6 refuses promotion keyed on
#                    this exact field, read two levels later by
#                    `/promote`'s promote-spec-and-tree-push step).
#   .artifacts       three independent boolean step flags, each flipped
#                    true (and the whole file flushed atomically) the
#                    instant its step completes — never batched, never
#                    flipped in advance of the step actually happening:
#                      repo_created    the testbed repository itself exists
#                      mirror_pushed   the source's full history has been
#                                      mirror-pushed into it
#                      issues_copied   the bounded open-issue carry-over has
#                                      completed
#                    A run killed between steps leaves an entry whose
#                    artifacts map shows exactly how far it got — enumerable
#                    and removable by teardown, never a silent orphan.
#
# ── Read-compatibility stance ────────────────────────────────────────────
# TESTBED_RECORD_READABLE_SCHEMA_VERSIONS lists every schema_version this
# build knows how to parse, exactly mirroring
# manifest.sh:196-224/MANIFEST_READABLE_SCHEMA_VERSIONS. testbed_record_load()
# checks the on-disk schema_version against that list: a KNOWN version is
# read and returned; an UNKNOWN version (newer than this code, or
# malformed/missing) causes testbed_record_load() to REFUSE — it prints the
# exact version it found (or "unknown") and the set it can read, to stderr,
# and returns non-zero. It never silently guesses or truncates.
#
# ── Public functions ─────────────────────────────────────────────────────
#   testbed_record_state_dir                        -> prints the state root dir
#   testbed_record_file                              -> prints the record path
#   testbed_record_schema_version                    -> prints this build's writer schema_version
#   testbed_record_load                              -> prints the current record JSON (compat-checked)
#   testbed_record_list <owner/name>                 -> prints the JSON array of entries at that key (possibly [])
#   testbed_record_all                               -> prints the whole `.testbeds` object
#   testbed_record_flat                              -> prints a flat JSON array of every entry, across every key
#   testbed_record_get <owner/name> <id>             -> prints the entry JSON, or nothing (rc != 0) if absent
#   testbed_record_add <owner/name> <source_kind> <source_repo-or-empty> <promotable:true|false>
#                                                     -> appends a new entry with artifacts.repo_created=true
#                                                        (creation IS the repo-created mutating step), flushes
#                                                        atomically, prints the new entry's id to stdout
#   testbed_record_mark_step <owner/name> <id> <step> -> step in {repo_created,mirror_pushed,issues_copied};
#                                                        sets that flag true, flushes atomically (idempotent)
#   testbed_record_remove <owner/name> <id>          -> deletes that one entry (no-op if absent); drops the
#                                                        key entirely once its list is empty
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/record.sh"
#   id="$(testbed_record_add "me/my-eval-testbed" "mirror-from-repo" "me/my-real-repo" true)"
#   ... push mirror ...
#   testbed_record_mark_step "me/my-eval-testbed" "$id" mirror_pushed
#   ... copy issues ...
#   testbed_record_mark_step "me/my-eval-testbed" "$id" issues_copied
#   ... later, teardown ...
#   testbed_record_remove "me/my-eval-testbed" "$id"
#
# Dependencies: bash (3.2+), jq. No network. No global shell-option changes
# (no `set -e`/`set -u` at file scope) — same posture as manifest.sh, since a
# sourced library must not silently change its caller's shell options.
#
# shellcheck shell=bash

# Guard against double-sourcing (mirrors manifest.sh).
if [[ "${_TEMPERLOOP_TESTBED_RECORD_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_TESTBED_RECORD_SH_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
TESTBED_RECORD_SCHEMA_VERSION=1
TESTBED_RECORD_READABLE_SCHEMA_VERSIONS="1"

# ---------------------------------------------------------------------------
# testbed_record_state_dir / testbed_record_file
# ---------------------------------------------------------------------------
testbed_record_state_dir() {
  printf '%s/temperloop' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

testbed_record_file() {
  printf '%s/testbed-record.json' "$(testbed_record_state_dir)"
}

testbed_record_schema_version() {
  printf '%s' "$TESTBED_RECORD_SCHEMA_VERSION"
}

# ---------------------------------------------------------------------------
# _testbed_record_require_jq — internal dependency check, called from
# testbed_record_load (every other public function routes through
# testbed_record_load first, so a missing jq is caught in exactly one place).
# ---------------------------------------------------------------------------
_testbed_record_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "record.sh: jq not found on PATH — required for testbed-record read/write" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# testbed_record_load
#
# Prints the current record JSON to stdout. If no record file exists yet,
# prints a fresh empty skeleton (schema_version=current, testbeds={}) — this
# is the normal state before any testbed has ever been created, not an
# error. If a file exists, it MUST be valid JSON with a schema_version this
# build recognises (TESTBED_RECORD_READABLE_SCHEMA_VERSIONS); otherwise this
# refuses legibly (mirrors manifest.sh:196-224) and returns 1 with nothing
# on stdout.
# ---------------------------------------------------------------------------
testbed_record_load() {
  _testbed_record_require_jq || return 1

  local file
  file="$(testbed_record_file)"

  if [[ ! -f "$file" ]]; then
    printf '{"schema_version":%s,"testbeds":{}}\n' "$TESTBED_RECORD_SCHEMA_VERSION"
    return 0
  fi

  local json version
  if ! json="$(jq -e '.' "$file" 2>/dev/null)"; then
    echo "record.sh: $file is not valid JSON — refusing to read (fix or remove by hand)" >&2
    return 1
  fi

  version="$(jq -r '.schema_version // "unknown"' <<<"$json")"
  case " $TESTBED_RECORD_READABLE_SCHEMA_VERSIONS " in
    *" $version "*) ;;
    *)
      echo "record.sh: $file has schema_version=$version, which this build of record.sh does not know how to read (readable: $TESTBED_RECORD_READABLE_SCHEMA_VERSIONS) — refusing to guess; upgrade temperloop before running testbed/teardown/promote against this record" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$json"
}

# ---------------------------------------------------------------------------
# _testbed_record_write <json> — atomic write of the full record document
# (mirrors manifest.sh's _manifest_write).
# ---------------------------------------------------------------------------
_testbed_record_write() {
  local json="$1" file dir tmp
  file="$(testbed_record_file)"
  dir="$(dirname "$file")"

  if ! mkdir -p "$dir"; then
    echo "record.sh: could not create $dir" >&2
    return 1
  fi
  tmp="$(mktemp "${dir}/.testbed-record.XXXXXX")" || {
    echo "record.sh: mktemp failed in $dir" >&2
    return 1
  }
  if ! printf '%s\n' "$json" | jq '.' >"$tmp" 2>/dev/null; then
    printf '%s' "$json" >"$tmp"
  fi
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# _testbed_record_validate_owner_name <owner/name> — internal. Exactly one
# "/", non-empty on both sides. Returns 0/1; prints nothing (callers print
# their own contextual error).
# ---------------------------------------------------------------------------
_testbed_record_validate_owner_name() {
  local v="$1"
  case "$v" in
    */*)
      local owner="${v%%/*}" rest="${v#*/}"
      [[ -n "$owner" && -n "$rest" && "$rest" != */* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _testbed_record_new_id — internal. Prints an id unique within this file's
# lifetime: UTC timestamp + pid + $RANDOM. No external uuid dependency.
# ---------------------------------------------------------------------------
_testbed_record_new_id() {
  printf '%s-%s-%04x' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$RANDOM"
}

# ---------------------------------------------------------------------------
# testbed_record_list <owner/name>
#
# Prints the JSON array of entries recorded at <owner/name> — `[]` if the
# key has no entries (never an error; an unrecorded key is simply empty).
# ---------------------------------------------------------------------------
testbed_record_list() {
  local key="$1" json
  if [[ -z "$key" ]]; then
    echo "testbed_record_list: owner/name argument required" >&2
    return 2
  fi
  json="$(testbed_record_load)" || return 1
  jq -c --arg k "$key" '.testbeds[$k] // []' <<<"$json"
}

# ---------------------------------------------------------------------------
# testbed_record_all — prints the whole `.testbeds` object (every key, every
# entry), unflattened.
# ---------------------------------------------------------------------------
testbed_record_all() {
  local json
  json="$(testbed_record_load)" || return 1
  jq -c '.testbeds' <<<"$json"
}

# ---------------------------------------------------------------------------
# testbed_record_flat — prints a flat JSON array of every entry across every
# key (each entry already carries its own .testbed_repo field, so this is
# self-describing without a separate key lookup). This is the enumeration a
# teardown sweep or a doctor-style check reaches for when it doesn't already
# know which owner/name to look under.
# ---------------------------------------------------------------------------
testbed_record_flat() {
  local json
  json="$(testbed_record_load)" || return 1
  jq -c '[.testbeds[] | .[]]' <<<"$json"
}

# ---------------------------------------------------------------------------
# testbed_record_get <owner/name> <id>
#
# Prints the entry JSON for <id> at <owner/name>, or prints nothing and
# returns non-zero if absent — a strict lookup, never inferred or
# namespace-matched (mirrors manifest_get_path_entry).
# ---------------------------------------------------------------------------
testbed_record_get() {
  local key="$1" id="$2" json
  if [[ -z "$key" || -z "$id" ]]; then
    echo "testbed_record_get: owner/name and id arguments required" >&2
    return 2
  fi
  json="$(testbed_record_load)" || return 1
  jq -ce --arg k "$key" --arg i "$id" \
    '(.testbeds[$k] // []) | map(select(.id == $i)) | .[0] // empty' \
    <<<"$json"
}

# ---------------------------------------------------------------------------
# testbed_record_add <owner/name> <source_kind> <source_repo-or-empty> <promotable>
#
# Appends a new entry to <owner/name>'s list (creating the key if absent).
# The entry is created with artifacts.repo_created already true — creating
# the record IS the repo-created mutating step, so there is never a moment
# where an entry exists with no artifact yet true. mirror_pushed and
# issues_copied start false; a caller flips each independently via
# testbed_record_mark_step as that step actually completes.
#
# <source_kind> must be "mirror-from-repo" or "materialize-from-seed".
# <source_repo-or-empty> must be "owner/name" for mirror-from-repo, or the
# empty string for materialize-from-seed (recorded as JSON null).
# <promotable> must be the literal string "true" or "false".
#
# Prints the new entry's id to stdout on success. Returns non-zero (nothing
# printed) on any validation failure or write error.
# ---------------------------------------------------------------------------
testbed_record_add() {
  local key="$1" source_kind="$2" source_repo="$3" promotable="$4"

  if [[ -z "$key" ]]; then
    echo "testbed_record_add: owner/name argument required" >&2
    return 2
  fi
  if ! _testbed_record_validate_owner_name "$key"; then
    echo "testbed_record_add: owner/name must be exactly \"<owner>/<name>\": $key" >&2
    return 2
  fi
  case "$source_kind" in
    mirror-from-repo | materialize-from-seed) ;;
    *)
      echo "testbed_record_add: source_kind must be mirror-from-repo or materialize-from-seed, got: $source_kind" >&2
      return 2
      ;;
  esac
  case "$promotable" in
    true | false) ;;
    *)
      echo "testbed_record_add: promotable must be true or false, got: $promotable" >&2
      return 2
      ;;
  esac
  if [[ -n "$source_repo" ]] && ! _testbed_record_validate_owner_name "$source_repo"; then
    echo "testbed_record_add: source_repo must be empty or exactly \"<owner>/<name>\": $source_repo" >&2
    return 2
  fi

  local id created_at json new_json
  id="$(_testbed_record_new_id)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  json="$(testbed_record_load)" || return 1
  new_json="$(jq \
    --arg k "$key" \
    --arg id "$id" \
    --arg created_at "$created_at" \
    --arg source_kind "$source_kind" \
    --arg source_repo "$source_repo" \
    --argjson promotable "$promotable" \
    '.testbeds[$k] = ((.testbeds[$k] // []) + [{
        id: $id,
        created_at: $created_at,
        testbed_repo: $k,
        source_kind: $source_kind,
        source_repo: (if $source_repo == "" then null else $source_repo end),
        promotable: $promotable,
        artifacts: { repo_created: true, mirror_pushed: false, issues_copied: false }
      }])' \
    <<<"$json")" || return 1

  if ! _testbed_record_write "$new_json"; then
    echo "testbed_record_add: recording ${key} (${id}) failed" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

# ---------------------------------------------------------------------------
# testbed_record_mark_step <owner/name> <id> <step>
#
# Sets artifacts.<step> = true for the matching entry and flushes
# atomically. <step> must be one of repo_created, mirror_pushed,
# issues_copied. Idempotent — marking an already-true step again is a
# successful no-op write. Returns non-zero if <owner/name>/<id> has no
# matching entry (never silently creates one).
# ---------------------------------------------------------------------------
testbed_record_mark_step() {
  local key="$1" id="$2" step="$3"

  if [[ -z "$key" || -z "$id" || -z "$step" ]]; then
    echo "testbed_record_mark_step: owner/name, id, and step arguments required" >&2
    return 2
  fi
  case "$step" in
    repo_created | mirror_pushed | issues_copied) ;;
    *)
      echo "testbed_record_mark_step: step must be repo_created, mirror_pushed, or issues_copied, got: $step" >&2
      return 2
      ;;
  esac

  if ! testbed_record_get "$key" "$id" >/dev/null 2>&1; then
    echo "testbed_record_mark_step: no entry ${id} recorded at ${key}" >&2
    return 1
  fi

  local json new_json
  json="$(testbed_record_load)" || return 1
  new_json="$(jq \
    --arg k "$key" \
    --arg id "$id" \
    --arg step "$step" \
    '.testbeds[$k] = (.testbeds[$k] | map(if .id == $id then .artifacts[$step] = true else . end))' \
    <<<"$json")" || return 1

  if ! _testbed_record_write "$new_json"; then
    echo "testbed_record_mark_step: recording ${key} (${id}) step ${step} failed" >&2
    return 1
  fi
  echo "  → ${key} (${id}) ${step} recorded"
}

# ---------------------------------------------------------------------------
# testbed_record_remove <owner/name> <id>
#
# Deletes the one matching entry from <owner/name>'s list. No-op (rc 0) if
# no entry matches — mirrors manifest_remove_path_entry's unconditional,
# error-free delete semantics. Once a key's list becomes empty, the key
# itself is dropped (keeps the record from accumulating empty-array
# tombstones for every teardown that ever ran).
# ---------------------------------------------------------------------------
testbed_record_remove() {
  local key="$1" id="$2"

  if [[ -z "$key" || -z "$id" ]]; then
    echo "testbed_record_remove: owner/name and id arguments required" >&2
    return 2
  fi

  local json new_json
  json="$(testbed_record_load)" || return 1
  new_json="$(jq \
    --arg k "$key" \
    --arg id "$id" \
    '.testbeds[$k] = ((.testbeds[$k] // []) | map(select(.id != $id)))
     | if (.testbeds[$k] | length) == 0 then .testbeds |= del(.[$k]) else . end' \
    <<<"$json")" || return 1

  _testbed_record_write "$new_json"
}
