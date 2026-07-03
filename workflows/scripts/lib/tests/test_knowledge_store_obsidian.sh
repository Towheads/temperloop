#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_store_obsidian.sh — the `obsidian`
# backend for the knowledge_store interface (foundation #775, Epic A #762).
# Zero network: sources knowledge_store.sh + knowledge_store_obsidian.sh and
# overrides the `_ks_backend_obsidian_curl` seam to replay canned
# "<body>\n<http_code>" responses (curl's own `-w` convention), exactly like
# workflows/scripts/crash-convergence/tests/test_sentry_adapter.sh overrides
# `_sentry_curl`. No test in this file may reach a real REST endpoint or a
# real vault — every case either drives the mock to a canned response or
# drives it to fail loud (curl transport failure), never a live call.
#
# Every case below calls the PUBLIC ks_read/ks_write/ks_append/ks_list
# functions (never the `_ks_backend_obsidian_*` internals directly) so each
# case simultaneously exercises config-selected dispatch
# (KNOWLEDGE_STORE_BACKEND=obsidian) as well as the obsidian backend itself.
#
# Covers: backend-selection dispatch (env flip plain-files <-> obsidian),
# read (200/404/non-2xx/unreachable), write (default overwrite, --no-clobber
# existing/new, PUT payload correctness), append (POST, create-or-append),
# list (whole-tree recursive walk, prefix scoping, missing-dir empty, mid-walk
# HTTP failure), missing/empty API key file, and doc-id validation
# (exit 2, curl never invoked).
#
# shellcheck disable=SC2329  # _ks_backend_obsidian_curl overrides below ARE
# invoked, indirectly, by sourced ks_* functions -- shellcheck can't see across
# that boundary (same disable used by test_sentry_adapter.sh for _sentry_curl).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-obsidian-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fake REST API key file -- never read by anything but this test's mock path.
KEY_FILE="$TMP/data.json"
printf '{"apiKey":"test-key-123"}\n' > "$KEY_FILE"

export KNOWLEDGE_STORE_ROOT="$TMP/store"          # for the plain-files half of the dispatch test
export KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE="$KEY_FILE"
export KNOWLEDGE_STORE_OBSIDIAN_API_BASE="https://127.0.0.1:27124"

# shellcheck source=/dev/null
source "$LIB/knowledge_store.sh"
# shellcheck source=/dev/null
source "$LIB/knowledge_store_obsidian.sh"

CURL_LOG="$TMP/curl.log"
reset_log() { : > "$CURL_LOG"; }
log_calls() { wc -l < "$CURL_LOG" | tr -d ' '; }

# A mock that fails the test outright if curl is ever invoked -- used for the
# doc-id-validation cases, which must short-circuit on ks__normalize_id
# before any HTTP call is attempted.
_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  fail "unexpected curl call: $1 $2"
}

# --- 1. backend-selection dispatch: env flip plain-files <-> obsidian --------
reset_log
export KNOWLEDGE_STORE_BACKEND=plain-files
printf 'from plain-files\n' | ks_write "Decisions/dispatch" \
  || fail "1: plain-files write should succeed"
got="$(ks_read "Decisions/dispatch")" || fail "1: plain-files read should succeed"
[ "$got" = "from plain-files" ] || fail "1: plain-files content mismatch (got: $got)"
[ "$(log_calls)" -eq 0 ] || fail "1: plain-files backend must never invoke the obsidian curl seam"

_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  printf 'from obsidian\n200'
}
export KNOWLEDGE_STORE_BACKEND=obsidian
got="$(ks_read "Decisions/dispatch")" || fail "1: obsidian read should succeed"
[ "$got" = "from obsidian" ] || fail "1: obsidian content mismatch (got: $got)"
[ "$(log_calls)" -eq 1 ] || fail "1: obsidian backend should have invoked the curl seam exactly once"
echo "PASS: 1 KNOWLEDGE_STORE_BACKEND flip dispatches plain-files vs obsidian correctly"

# From here on, backend stays obsidian.
export KNOWLEDGE_STORE_BACKEND=obsidian

# --- 2. read: 200 -> content on stdout, exact round-trip incl. trailing \n ---
reset_log
_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  printf 'line one\nline two\n\n200'
}
got="$(ks_read "Decisions/foo")" || fail "2: read 200 should succeed"
want="$(printf 'line one\nline two\n')"
[ "$got" = "$want" ] || fail "2: read content mismatch (got: [$got])"
grep -q 'GET .*vault/Decisions/foo\.md$' "$CURL_LOG" || fail "2: expected GET to Decisions/foo.md, got: $(cat "$CURL_LOG")"
echo "PASS: 2 read (200) returns exact content via GET"

# --- 3. read: 404 -> exit 1, nothing on stdout, message on stderr -----------
_ks_backend_obsidian_curl() { printf '\n404'; }
set +e
out="$(ks_read "Decisions/missing" 2>"$TMP/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "3: read 404 should exit 1 (got $rc)"
[ -z "$out" ] || fail "3: read 404 should print nothing to stdout (got: $out)"
grep -qi 'not found' "$TMP/err" || fail "3: read 404 should mention 'not found' on stderr"
echo "PASS: 3 read (404) exits 1 with no stdout and a 'not found' stderr message"

# --- 4. read: non-2xx (500) -> exit 1, HTTP code named on stderr ------------
_ks_backend_obsidian_curl() { printf '{"error":"boom"}\n500'; }
set +e
out="$(ks_read "Decisions/foo" 2>"$TMP/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "4: read 500 should exit 1 (got $rc)"
[ -z "$out" ] || fail "4: read 500 should print nothing to stdout"
grep -q '500' "$TMP/err" || fail "4: read 500 should name the HTTP code on stderr (got: $(cat "$TMP/err"))"
echo "PASS: 4 read (non-2xx) exits 1 and names the HTTP code on stderr"

# --- 5. read: unreachable (curl transport failure) -> exit 1, loud message --
_ks_backend_obsidian_curl() { return 7; }
set +e
out="$(ks_read "Decisions/foo" 2>"$TMP/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "5: read on curl failure should exit 1 (got $rc)"
[ -z "$out" ] || fail "5: unreachable read should print nothing to stdout"
grep -qi 'unreachable' "$TMP/err" || fail "5: unreachable read should say 'unreachable' on stderr (got: $(cat "$TMP/err"))"
echo "PASS: 5 read fails loud (exit 1, 'unreachable' on stderr) when the REST API is unreachable"

# --- 6. write: default overwrite -> PUT with exact payload, exit 0 ----------
reset_log
PUT_PAYLOAD_FILE="$TMP/put_payload_seen"
_ks_backend_obsidian_curl() {
  local method="$1" url="$2" content_file="${3:-}"
  printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
  [ -n "$content_file" ] && cp "$content_file" "$PUT_PAYLOAD_FILE"
  printf '\n204'
}
printf 'new content\n' | ks_write "Decisions/bar" || fail "6: write should succeed"
grep -q '^PUT .*vault/Decisions/bar\.md$' "$CURL_LOG" || fail "6: expected a PUT to Decisions/bar.md, got: $(cat "$CURL_LOG")"
[ "$(cat "$PUT_PAYLOAD_FILE")" = "new content" ] || fail "6: PUT payload mismatch (got: $(cat "$PUT_PAYLOAD_FILE"))"
echo "PASS: 6 write (default) issues a PUT carrying the exact stdin content"

# --- 7. write --no-clobber: existing doc (GET 200) -> exit 3, no PUT issued -
reset_log
_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  printf '\n200'   # pre-flight GET says "already exists"
}
set +e
printf 'should not land\n' | ks_write "Decisions/bar" --no-clobber 2>"$TMP/err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "7: --no-clobber on existing doc should exit 3 (got $rc)"
grep -qi 'clobber' "$TMP/err" || fail "7: --no-clobber refusal should mention 'clobber' on stderr"
! grep -q '^PUT' "$CURL_LOG" || fail "7: --no-clobber must not issue a PUT when the pre-flight GET says the doc exists"
echo "PASS: 7 write --no-clobber on an existing doc exits 3 and never PUTs"

# --- 8. write --no-clobber: new doc (GET 404) -> proceeds to PUT, exit 0 ----
reset_log
_ks_backend_obsidian_curl() {
  local method="$1"
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  if [ "$method" = "GET" ]; then printf '\n404'; else printf '\n204'; fi
}
printf 'brand new\n' | ks_write "Decisions/baz" --no-clobber || fail "8: --no-clobber create should succeed"
grep -q '^GET' "$CURL_LOG" || fail "8: expected a pre-flight GET"
grep -q '^PUT' "$CURL_LOG" || fail "8: expected a PUT after the pre-flight GET 404s"
echo "PASS: 8 write --no-clobber on a new doc pre-flights (GET 404) then PUTs"

# --- 9. append: POST with exact payload, create-or-append, exit 0 ----------
reset_log
POST_PAYLOAD_FILE="$TMP/post_payload_seen"
_ks_backend_obsidian_curl() {
  local method="$1" url="$2" content_file="${3:-}"
  printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
  [ -n "$content_file" ] && cp "$content_file" "$POST_PAYLOAD_FILE"
  printf '\n200'
}
printf 'appended line\n' | ks_append "Scratch/log" || fail "9: append should succeed"
grep -q '^POST .*vault/Scratch/log\.md$' "$CURL_LOG" || fail "9: expected a POST to Scratch/log.md, got: $(cat "$CURL_LOG")"
[ "$(cat "$POST_PAYLOAD_FILE")" = "appended line" ] || fail "9: POST payload mismatch"
echo "PASS: 9 append issues a POST carrying the exact stdin content"

# --- 10. list: whole-tree recursive walk, sorted -----------------------------
JSON_ROOT='{"files":["Decisions/","Scratch/","readme.md","notes.txt"]}'
JSON_DECISIONS='{"files":["foo.md","bar.md","Sub/"]}'
JSON_SUB='{"files":["baz.md"]}'
JSON_SCRATCH='{"files":["log.md"]}'
_ks_backend_obsidian_curl() {
  local url="$2"
  case "$url" in
    */vault/)             printf '%s\n200' "$JSON_ROOT" ;;
    */vault/Decisions/)   printf '%s\n200' "$JSON_DECISIONS" ;;
    */vault/Decisions/Sub/) printf '%s\n200' "$JSON_SUB" ;;
    */vault/Scratch/)     printf '%s\n200' "$JSON_SCRATCH" ;;
    *) printf '\n404' ;;
  esac
}
whole="$(ks_list)" || fail "10: whole-tree list should succeed"
want_whole="$(printf '%s\n' 'Decisions/bar.md' 'Decisions/foo.md' 'Decisions/Sub/baz.md' 'Scratch/log.md' 'readme.md' | sort)"
[ "$whole" = "$want_whole" ] || fail "10: whole-tree list mismatch (got:\n$whole\nwant:\n$want_whole)"
echo "PASS: 10 list recurses the whole tree via per-directory GETs, sorted, .md-only"

# --- 11. list: prefix scoping (recurses under prefix only) ------------------
scoped="$(ks_list "Decisions")" || fail "11: prefix-scoped list should succeed"
want_scoped="$(printf '%s\n' 'Decisions/bar.md' 'Decisions/foo.md' 'Decisions/Sub/baz.md' | sort)"
[ "$scoped" = "$want_scoped" ] || fail "11: prefix-scoped list mismatch (got:\n$scoped\nwant:\n$want_scoped)"
echo "PASS: 11 list scopes recursion to a given prefix"

# --- 12. list: missing prefix directory -> exit 0, nothing printed ---------
out="$(ks_list "NoSuchDir")" || fail "12: list of a missing prefix should exit 0"
[ -z "$out" ] || fail "12: list of a missing prefix should print nothing (got: $out)"
echo "PASS: 12 list on a not-yet-created prefix directory exits 0 and prints nothing"

# --- 13. list: mid-walk HTTP failure -> exit 1 (documented deviation from
#         plain-files' unconditional exit 0) --------------------------------
_ks_backend_obsidian_curl() {
  local url="$2"
  case "$url" in
    */vault/) printf '%s\n200' "$JSON_ROOT" ;;
    */vault/Decisions/) printf 'boom\n500' ;;
    *) printf '\n200' ;;
  esac
}
set +e
out="$(ks_list 2>"$TMP/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "13: mid-walk HTTP failure should exit 1 (got $rc)"
grep -q '500' "$TMP/err" || fail "13: mid-walk failure should name the HTTP code on stderr"
echo "PASS: 13 list fails loud (exit 1) on a mid-walk HTTP error, unlike plain-files"

# --- 14. missing API key file -> exit 1, curl never invoked -----------------
reset_log
_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  fail "14: curl must not be invoked when the API key file is missing"
}
set +e
out="$(KNOWLEDGE_STORE_OBSIDIAN_API_KEY_FILE="$TMP/no-such-key-file.json" ks_read "Decisions/foo" 2>"$TMP/err")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "14: missing key file should exit 1 (got $rc)"
[ -z "$out" ] || fail "14: missing key file should print nothing to stdout"
grep -qi 'key file missing' "$TMP/err" || fail "14: missing key file should say so on stderr (got: $(cat "$TMP/err"))"
[ "$(log_calls)" -eq 0 ] || fail "14: curl must never be invoked when API key resolution fails first"
echo "PASS: 14 a missing REST API key file fails loud (exit 1) before any HTTP call"

# --- 15. doc-id validation still applies; curl never invoked ----------------
reset_log
_ks_backend_obsidian_curl() {
  printf '%s %s\n' "$1" "$2" >> "$CURL_LOG"
  fail "15: curl must not be invoked for an invalid doc-id"
}
set +e
ks_read "" 2>/dev/null; rc_empty=$?
ks_read "/etc/passwd" 2>/dev/null; rc_abs=$?
ks_read "../escape" 2>/dev/null; rc_dotdot=$?
set -e
[ "$rc_empty" -eq 2 ] || fail "15: empty doc-id should exit 2 (got $rc_empty)"
[ "$rc_abs" -eq 2 ] || fail "15: absolute doc-id should exit 2 (got $rc_abs)"
[ "$rc_dotdot" -eq 2 ] || fail "15: leading .. doc-id should exit 2 (got $rc_dotdot)"
[ "$(log_calls)" -eq 0 ] || fail "15: curl must never be invoked when doc-id validation fails first"
echo "PASS: 15 doc-id validation (exit 2) short-circuits before any HTTP call"

echo "ALL PASS: knowledge_store_obsidian.sh (obsidian backend)"
