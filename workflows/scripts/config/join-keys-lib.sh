#!/usr/bin/env bash
#
# join-keys-lib.sh — the SHELL loader for the join-key registry
# (workflows/scripts/config/join-keys.tsv, temperloop#1910). This file and
# its Python sibling join_keys.py are the ONLY two places a session id (or
# any other join key the registry declares) is normalized — a caller reads a
# join key by sourcing this file and calling one of its `jk_*` functions,
# never by re-deriving a substring length, a regex, or a case-fold at the
# call site. See join-keys.tsv's own header for the "why a registry, not five
# resolvers" rationale.
#
# ── Status convention ───────────────────────────────────────────────────────
# Every `jk_*` normalize function below returns one of three states via exit
# code, mirroring the registry's own ABSENT_SEMANTICS column (the
# temperloop#1084 "absent is never zero" discipline, generalized to every
# join key):
#   rc 0   OK       — the normalized value is printed on stdout
#   rc 2   ABSENT   — the input was empty, unset, or the JSON literal `null`/
#                     the string "null"; nothing is printed. A caller must
#                     treat this as UNKNOWN, never coerce it into a zero/
#                     empty-string value of its own.
#   rc 1   INVALID  — the input was non-empty but malformed (e.g. a
#                     non-UUID-shaped session id, a non-numeric run id);
#                     nothing is printed on stdout, a reason is printed on
#                     stderr.
# `jk_apply <fn> [args...]` (the bottom of this file) is a uniform dispatcher
# used by this registry's own cross-language agreement test
# (tests/test_join_keys.sh): it prints `STATUS<TAB>VALUE` on stdout (VALUE
# empty for ABSENT/INVALID) so a fixture-driven test can compare this loader's
# output against join_keys.py's line for line without hand-writing a dispatch
# table twice.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching every sibling
# workflows/scripts/config/*.sh file.
#
# This file is SOURCED, never executed directly — it has no CLI of its own
# beyond the `jk_apply` dispatcher, which exists for the agreement test.

_JOIN_KEYS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# join_keys_registry_file -> the join-keys.tsv path (default: sibling
# join-keys.tsv next to this lib; override via JOIN_KEYS_REGISTRY_FILE, the
# same test-seam convention as setting-registry-lib.sh's SETTING_REGISTRY_FILE).
join_keys_registry_file() {
  printf '%s' "${JOIN_KEYS_REGISTRY_FILE:-$_JOIN_KEYS_LIB_DIR/join-keys.tsv}"
}

# _jk_is_absent_literal <raw> -> 0 (true) if <raw> is empty, or the literal
# strings "null" / "NULL" (a JSON null decoded to text by a caller's own `jq
# -r`, which prints the bare word `null` for a JSON null — the shape every
# raw-lake emit site in this repo produces).
_jk_is_absent_literal() {
  case "$1" in
    "" | "null" | "NULL") return 0 ;;
    *) return 1 ;;
  esac
}

# jk_session_full <raw> -> the normalized (lowercased) full session UUID.
jk_session_full() {
  local raw="${1:-}"
  _jk_is_absent_literal "$raw" && return 2
  local lc
  lc="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      printf '%s' "$lc"
      return 0
      ;;
    *)
      echo "join-keys: jk_session_full: not a UUID-shaped session id: $raw" >&2
      return 1
      ;;
  esac
}

# jk_session8 <raw> -> the first 8 characters of jk_session_full's output.
jk_session8() {
  local raw="${1:-}" full rc
  full="$(jk_session_full "$raw")"
  rc=$?
  [ "$rc" -ne 0 ] && return "$rc"
  printf '%s' "${full:0:8}"
}

# jk_host_session_stamp <host> <raw-session-id> -> "<host>:<sess8>".
jk_host_session_stamp() {
  local host="${1:-}" raw="${2:-}" sess8 rc
  if _jk_is_absent_literal "$host"; then
    return 2
  fi
  sess8="$(jk_session8 "$raw")"
  rc=$?
  [ "$rc" -ne 0 ] && return "$rc"
  printf '%s:%s' "$host" "$sess8"
}

# _jk_normalize_int <raw> <label> -> a base-10 integer with no leading zeros
# beyond a bare "0". Shared by jk_run_id and jk_pr_number (both are plain
# non-negative integers with identical normalize rules per the registry).
_jk_normalize_int() {
  local raw="${1:-}" label="$2"
  _jk_is_absent_literal "$raw" && return 2
  case "$raw" in
    0) printf '0'; return 0 ;;
    [1-9]*)
      case "$raw" in
        *[!0-9]*)
          echo "join-keys: $label: not a plain integer: $raw" >&2
          return 1
          ;;
        *)
          printf '%s' "$raw"
          return 0
          ;;
      esac
      ;;
    *)
      echo "join-keys: $label: not a plain integer: $raw" >&2
      return 1
      ;;
  esac
}

# jk_run_id <raw> -> a normalized GitHub Actions run id. "0" is a legal
# value and normalizes to "0" — never conflated with absent (temperloop#1084
# discipline; see join-keys.tsv's run_id row).
jk_run_id() {
  _jk_normalize_int "${1:-}" "jk_run_id"
}

# jk_pr_number <raw> -> a normalized GitHub PR number. Same "0 is a value,
# not absence" discipline as jk_run_id.
jk_pr_number() {
  _jk_normalize_int "${1:-}" "jk_pr_number"
}

# jk_message_id <raw> -> the id trimmed of leading/trailing whitespace,
# otherwise verbatim (opaque, case-sensitive).
jk_message_id() {
  local raw="${1:-}"
  _jk_is_absent_literal "$raw" && return 2
  local trimmed="${raw#"${raw%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [ -z "$trimmed" ]; then
    return 2
  fi
  printf '%s' "$trimmed"
}

# jk_plan_stem <path-or-stem> -> the filename component with a trailing
# `.md` extension and any leading directory path stripped.
jk_plan_stem() {
  local raw="${1:-}"
  _jk_is_absent_literal "$raw" && return 2
  local base
  base="$(basename -- "$raw")"
  case "$base" in
    *.md) base="${base%.md}" ;;
  esac
  if [ -z "$base" ]; then
    return 2
  fi
  printf '%s' "$base"
}

# jk_closes_pattern <issue-number> -> the case-insensitive ERE `pr-linkage.sh`
# tests a PR body against for a bare `Closes #<n>` / `Fixes #<n>` /
# `Resolves #<n>` reference. THE single home for this pattern — pr-linkage.sh
# calls this instead of building the regex inline.
jk_closes_pattern() {
  local issue="${1:-}"
  if [ -z "$issue" ]; then
    echo "join-keys: jk_closes_pattern: issue number required" >&2
    return 1
  fi
  printf '(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#%s\\b' "$issue"
}

# jk_apply <fn> [args...] -> prints "STATUS<TAB>VALUE" for the named jk_*
# function (fn is the bare suffix, e.g. "session_full", not "jk_session_full")
# applied to the given args. STATUS in {ok, absent, invalid}. Used by
# tests/test_join_keys.sh to drive both loaders from one shared fixture list.
jk_apply() {
  local fn="$1"
  shift
  local value rc
  case "$fn" in
    session_full | session8 | run_id | pr_number | message_id | plan_stem | closes_pattern)
      value="$("jk_$fn" "$@" 2>/dev/null)"
      rc=$?
      ;;
    host_session_stamp)
      value="$(jk_host_session_stamp "$@" 2>/dev/null)"
      rc=$?
      ;;
    *)
      echo "join-keys: jk_apply: unknown function: $fn" >&2
      return 1
      ;;
  esac
  case "$rc" in
    0) printf 'ok\t%s\n' "$value" ;;
    2) printf 'absent\t\n' ;;
    *) printf 'invalid\t\n' ;;
  esac
}
