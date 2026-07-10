#!/usr/bin/env bash
#
# knowledge_store_obsidian.sh — the `obsidian` backend for the knowledge_store
# interface (foundation #775, Epic A #762 "kernel split"). Implements the same
# four document-I/O operations as the `plain-files` backend in
# knowledge_store.sh, backed by the Obsidian Local REST API instead of the
# filesystem, so a caller can point `KNOWLEDGE_STORE_BACKEND=obsidian` at a
# real vault with zero change to call sites.
#
# This is a SEPARATE file from knowledge_store.sh on purpose — the backend
# registration seam documented in knowledge_store.contract.md says a new
# backend requires "no change to knowledge_store.sh itself", only that its
# four `_ks_backend_<name>_*` functions be defined and sourced before use.
# Source this file AFTER knowledge_store.sh, then set
# KNOWLEDGE_STORE_BACKEND=obsidian:
#
#   source knowledge_store.sh
#   source knowledge_store_obsidian.sh
#   KNOWLEDGE_STORE_BACKEND=obsidian
#   ks_read "Decisions/foo"   # -> GET against the REST API
#
# REST conventions reused verbatim from claude/hooks/session-start-drain.sh
# and workflows/scripts/build/plan.sh (_plan_vault_write): base URL
# https://127.0.0.1:27124, bearer token read from the Local REST API plugin's
# own data.json, `curl -s -k` (self-signed local cert, so -k is required and
# safe — the endpoint never leaves loopback), and per-path-segment `jq @uri`
# encoding (a raw space in a vault path breaks curl's URL parser — foundation
# #364).
#
# Root mapping (see knowledge_store.contract.md "The obsidian backend" for
# the authoritative version): KNOWLEDGE_STORE_ROOT is NOT consulted by this
# backend. The vault IS the root — a normalized doc-id (e.g.
# "Decisions/foo.md") is used directly as the REST API's vault-relative path
# ("/vault/Decisions/foo.md"). `ks_root` still exists and still resolves the
# filesystem knob, but that value is meaningless for this backend; do not
# call it to build obsidian paths.
#
# Test seam: every HTTP call routes through `_ks_backend_obsidian_curl` — a
# SINGLE indirection point (mirrors `_sentry_curl` in sentry-adapter.sh and
# `_plan_vault_write` in plan.sh) that tests override after sourcing to
# replay canned "<body>\n<http_code>" responses, exactly like curl's own
# `-w '\n%{http_code}'` output, with zero real network. See
# tests/test_knowledge_store_obsidian.sh.
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).

: "${KNOWLEDGE_STORE_OBSIDIAN_API_BASE:=https://127.0.0.1:27124}"
# Default key-file path is DERIVED from `ks_root` (knowledge_store.sh, sourced
# before this file per this header's own requirement above) — the plugin's
# fixed on-disk layout under whatever directory KNOWLEDGE_STORE_ROOT already
# names, rather than a second, independently-hardcoded vault-path literal
# that could silently drift from it (temperloop#189 kernel-literal-scrub; this
# is also what doctor.sh's check_knowledge_root split-brain guard now derives
# the "expected" side from, see that script).
: "${KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE:=$(ks_root)/.obsidian/plugins/obsidian-local-rest-api/data.json}"

# --- HTTP seam ---------------------------------------------------------------
# <method> <url> [content-file] <api-key>
# Prints the response body, then a newline, then the HTTP status code as the
# final line (curl's own `-w '\n%{http_code}'` convention — split with
# `${resp##*$'\n'}` / `${resp%$'\n'"$code"}`, same as sentry-adapter.sh).
# When content-file is non-empty, sends it as the request body (PUT/POST);
# otherwise a bodyless request (GET). Override this after sourcing to stub
# HTTP in tests.
_ks_backend_obsidian_curl() {
  local method="$1" url="$2" content_file="${3:-}" api_key="$4"
  if [ -n "$content_file" ]; then
    curl -s -k -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $api_key" \
      -H 'Content-Type: text/markdown' \
      --data-binary "@$content_file" \
      "$url"
  else
    curl -s -k -w '\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $api_key" \
      "$url"
  fi
}

# -> the bearer token on stdout, or exit 1 with a message on stderr. Read
# fresh on every call (mirrors plan.sh's _plan_vault_write) rather than
# cached — the key file is small and local-disk, and re-reading means a
# rotated key is picked up without re-sourcing.
_ks_obsidian_api_key() {
  local key_file="$KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE" key
  if [ ! -f "$key_file" ]; then
    printf 'knowledge_store(obsidian): REST API key file missing: %s\n' "$key_file" >&2
    return 1
  fi
  key="$(jq -r '.apiKey // empty' "$key_file" 2>/dev/null)"
  if [ -z "$key" ]; then
    printf 'knowledge_store(obsidian): could not read apiKey from %s\n' "$key_file" >&2
    return 1
  fi
  printf '%s\n' "$key"
}

# <vault-rel-path> [--dir] -> full REST API URL on stdout, with each path
# segment percent-encoded (jq's @uri) but '/' separators preserved. An empty
# vault-rel-path is the vault root. --dir appends the trailing slash the
# Local REST API requires to address a directory (vs a file) endpoint.
_ks_obsidian_url() {
  local relpath="$1" mode="${2:-}" encoded base
  base="$KNOWLEDGE_STORE_OBSIDIAN_API_BASE"
  if [ -n "$relpath" ]; then
    encoded="$(printf '%s' "$relpath" | jq -sRr 'split("/") | map(@uri) | join("/")')" || {
      printf 'knowledge_store(obsidian): failed to URL-encode path: %s\n' "$relpath" >&2
      return 1
    }
  else
    encoded=""
  fi
  if [ "$mode" = "--dir" ]; then
    if [ -n "$encoded" ]; then
      printf '%s/vault/%s/\n' "$base" "$encoded"
    else
      printf '%s/vault/\n' "$base"
    fi
  else
    printf '%s/vault/%s\n' "$base" "$encoded"
  fi
}

# Common "curl transport failed / no response" message, used by every op.
_ks_obsidian_unreachable_msg() {
  printf 'knowledge_store(obsidian): REST API unreachable at %s\n' "$KNOWLEDGE_STORE_OBSIDIAN_API_BASE" >&2
}

# --- obsidian backend ---------------------------------------------------------

# <doc-id> -> document content on stdout via GET. Exit 1 (not found) on 404,
# and also exit 1 (loud failure, per contract) on any other non-2xx response
# or an unreachable REST API — this backend widens ks_read's exit-1 bucket
# from plain-files' "not found only" to "not found OR retrieval failed"
# (mirrors ks_write's pre-existing "other I/O failure" exit-1 bucket); the
# specific cause is always on stderr. Exit 2 on a bad doc-id, unchanged.
_ks_backend_obsidian_read() {
  local id url api_key resp code body
  id="$(ks__normalize_id "$1")" || return $?
  api_key="$(_ks_obsidian_api_key)" || return 1
  url="$(_ks_obsidian_url "$id")" || return 1
  resp="$(_ks_backend_obsidian_curl GET "$url" "" "$api_key")" || {
    _ks_obsidian_unreachable_msg
    return 1
  }
  code="${resp##*$'\n'}"
  body="${resp%$'\n'"$code"}"
  case "$code" in
    200) printf '%s' "$body" ;;
    404)
      printf 'knowledge_store(obsidian): not found: %s\n' "$1" >&2
      return 1
      ;;
    000|"")
      _ks_obsidian_unreachable_msg
      return 1
      ;;
    *)
      printf 'knowledge_store(obsidian): REST API read of %s failed (HTTP %s)\n' "$1" "$code" >&2
      return 1
      ;;
  esac
}

# <doc-id> [--no-clobber]  <- content on stdin.
# PUT is a whole-file replace (create-or-overwrite), matching ks_write's
# default semantics exactly and Obsidian's own PUT behavior (creates any
# missing parent folders). The REST API has no native create-only verb, so
# --no-clobber is emulated with a pre-flight GET existence check before the
# PUT: exit 3 (untouched) if that GET returns 200, proceed to PUT if 404.
# This is a check-then-act race (TOCTOU) under concurrent writers — no worse
# than the interface's own documented "no locking" guarantee (see contract's
# plain-files section), but worth naming: two concurrent --no-clobber writers
# to the same doc-id can both pass the pre-flight GET and both PUT.
_ks_backend_obsidian_write() {
  local id="" no_clobber=0 arg url api_key resp code tmp
  for arg in "$@"; do
    case "$arg" in
      --no-clobber) no_clobber=1 ;;
      *) id="$arg" ;;
    esac
  done
  id="$(ks__normalize_id "$id")" || return $?
  api_key="$(_ks_obsidian_api_key)" || return 1
  url="$(_ks_obsidian_url "$id")" || return 1

  tmp="$(mktemp "${TMPDIR:-/tmp}/ks-obsidian-write-XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [ "$no_clobber" -eq 1 ]; then
    resp="$(_ks_backend_obsidian_curl GET "$url" "" "$api_key")" || {
      rm -f "$tmp"
      _ks_obsidian_unreachable_msg
      return 1
    }
    code="${resp##*$'\n'}"
    case "$code" in
      200)
        rm -f "$tmp"
        printf 'knowledge_store(obsidian): refusing to clobber existing doc (--no-clobber): %s\n' "$id" >&2
        return 3
        ;;
      404) : ;; # does not exist yet -- proceed to create
      000|"")
        rm -f "$tmp"
        _ks_obsidian_unreachable_msg
        return 1
        ;;
      *)
        rm -f "$tmp"
        printf 'knowledge_store(obsidian): REST API existence check for %s failed (HTTP %s)\n' "$id" "$code" >&2
        return 1
        ;;
    esac
  fi

  resp="$(_ks_backend_obsidian_curl PUT "$url" "$tmp" "$api_key")" || {
    rm -f "$tmp"
    _ks_obsidian_unreachable_msg
    return 1
  }
  rm -f "$tmp"
  code="${resp##*$'\n'}"
  case "$code" in
    200|204) return 0 ;;
    000|"")
      _ks_obsidian_unreachable_msg
      return 1
      ;;
    *)
      printf 'knowledge_store(obsidian): REST API write to %s failed (HTTP %s)\n' "$id" "$code" >&2
      return 1
      ;;
  esac
}

# <doc-id>  <- content on stdin. POST appends to the document (Local REST API
# semantics: creates the document, and any missing parent folders, if
# absent), matching ks_append's create-or-append contract exactly.
_ks_backend_obsidian_append() {
  local id url api_key resp code tmp
  id="$(ks__normalize_id "$1")" || return $?
  api_key="$(_ks_obsidian_api_key)" || return 1
  url="$(_ks_obsidian_url "$id")" || return 1

  tmp="$(mktemp "${TMPDIR:-/tmp}/ks-obsidian-append-XXXXXX")" || return 1
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  resp="$(_ks_backend_obsidian_curl POST "$url" "$tmp" "$api_key")" || {
    rm -f "$tmp"
    _ks_obsidian_unreachable_msg
    return 1
  }
  rm -f "$tmp"
  code="${resp##*$'\n'}"
  case "$code" in
    200|204) return 0 ;;
    000|"")
      _ks_obsidian_unreachable_msg
      return 1
      ;;
    *)
      printf 'knowledge_store(obsidian): REST API append to %s failed (HTTP %s)\n' "$id" "$code" >&2
      return 1
      ;;
  esac
}

# [prefix] -> one doc-id per line, sorted, '.md' files only, recursing into
# subfolders. The Local REST API has no recursive-listing endpoint, only a
# per-directory GET returning {"files": [...]} (subfolder entries end in
# '/'), so this walks the tree breadth-first with one GET per directory.
#
# Exit 0 with nothing printed when the root/prefix directory itself 404s
# (does not exist yet) -- matches the plain-files contract. UNLIKE
# plain-files, this can also fail loud (exit 1) if the REST API is
# unreachable or errors mid-walk -- plain-files' "always exit 0" guarantee is
# a local-filesystem property this network-backed backend cannot uphold; see
# knowledge_store.contract.md "The obsidian backend" for this documented
# deviation. `prefix` is not doc-id-normalized (no .md-append, no
# traversal guard) -- same as the plain-files backend, it is a plain relative
# directory segment, not a doc-id.
_ks_backend_obsidian_list() {
  local prefix="${1:-}" api_key url resp code body cur entry full
  prefix="${prefix%/}"
  api_key="$(_ks_obsidian_api_key)" || return 1

  local -a queue out
  queue=("$prefix")
  out=()

  while [ "${#queue[@]}" -gt 0 ]; do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")

    url="$(_ks_obsidian_url "$cur" --dir)" || return 1
    resp="$(_ks_backend_obsidian_curl GET "$url" "" "$api_key")" || {
      _ks_obsidian_unreachable_msg
      return 1
    }
    code="${resp##*$'\n'}"
    body="${resp%$'\n'"$code"}"

    case "$code" in
      200) : ;;
      404)
        if [ "$cur" = "$prefix" ]; then
          continue
        fi
        printf 'knowledge_store(obsidian): directory disappeared mid-listing: %s\n' "$cur" >&2
        return 1
        ;;
      000|"")
        _ks_obsidian_unreachable_msg
        return 1
        ;;
      *)
        printf 'knowledge_store(obsidian): REST API list of %s failed (HTTP %s)\n' "$cur" "$code" >&2
        return 1
        ;;
    esac

    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      if [ -z "$cur" ]; then
        full="$entry"
      else
        full="$cur/$entry"
      fi
      case "$entry" in
        */) queue+=("${full%/}") ;;
        *.md) out+=("$full") ;;
        *) : ;;
      esac
    done < <(printf '%s' "$body" | jq -r '.files[]?' 2>/dev/null)
  done

  if [ "${#out[@]}" -gt 0 ]; then
    printf '%s\n' "${out[@]}" | sort
  fi
}
