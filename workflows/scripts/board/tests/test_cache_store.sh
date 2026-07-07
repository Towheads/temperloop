#!/usr/bin/env bash
#
# Tests for cache.sh — the canonical-layer issue-cache store (F#988 Contract).
# Zero network: overrides the `_cache_gh` seam (mirroring test_board_cache.sh's
# `_board_gh` override) to log every call's argv and replay canned REST
# payloads, then drives the public cache_* functions.
#
# Coverage (mirrors the item's acceptance bullets 1-5; bullet 6 — shellcheck +
# `make test-board` green — is verified by the harness, not asserted here):
#   1. cache_refresh_snapshot: bulk paginated REST list, PR rows filtered,
#      closed issues included, parent/sub_issues_summary linkage preserved,
#      zero per-issue calls, zero GraphQL, multi-page merge.
#   2. cache_refresh_details: delta fetch by updated_at — new/changed issues
#      cost one comments call each; an unchanged snapshot costs zero.
#   3. Staleness contract: fresh serves cache (zero calls); stale/dirty
#      triggers refresh; a live-fetch failure returns rc1 + one stderr
#      notice + no data; a persist failure falls through to serving the
#      live fetch directly + exactly one stderr notice, snapshot on disk
#      left untouched (never corrupted).
#   4. CACHE-STORE.md exists and documents schema_version; a real refresh
#      stamps the same schema_version into meta.json.
#   5. board.sh sourced ALONE (no cache.sh) still works standalone; cache.sh
#      sourced ALONE (no board.sh) rejects a bare board-number cleanly;
#      kernel-manifest.txt coverage (the board/* catch-all) already covers
#      both new files with zero manifest edit needed.
#
# The `_cache_gh` override is invoked indirectly (the library calls
# `_cache_gh`, which this test redefines) — shellcheck's "never invoked"
# check is a false positive for it, as with test_board_cache.sh's `_board_gh`.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

# Fictitious owner/repo (never the real org — kernel personal-token denylist,
# mirroring test_issues_backend.sh's "Acme/kernel-test" convention).
REPO="Acme/kernel-cache-test"

# Isolated store root so we never touch a real ~/.cache.
CACHE_STORE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cache-store-test-XXXXXX")"
export CACHE_STORE_ROOT
CALLS="$(mktemp "${TMPDIR:-/tmp}/cache-store-calls-XXXXXX")"
STDERR_LOG="$(mktemp "${TMPDIR:-/tmp}/cache-store-stderr-XXXXXX")"
cleanup() {
  chmod -R u+w "$CACHE_STORE_ROOT" 2>/dev/null || true
  rm -rf "$CACHE_STORE_ROOT" "$CALLS" "$STDERR_LOG"
}
trap cleanup EXIT

# shellcheck source=scripts/lib/cache.sh
source "$LIB_DIR/cache.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- fixtures ---------------------------------------------------------------
PAGE1='[
  {"number":1,"title":"Issue one","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"body one","labels":[],
   "parent":{"number":10,"title":"Epic ten"},
   "sub_issues_summary":{"total":2,"completed":1}},
  {"number":2,"title":"Issue two (closed)","state":"closed","updated_at":"2026-06-01T00:00:00Z","body":"body two","labels":[]},
  {"number":3,"title":"A pull request","state":"open","updated_at":"2026-07-02T00:00:00Z","body":"pr body","pull_request":{"url":"https://api.github.com/repos/x/y/pulls/3"},"labels":[]}
]'
PAGE2='[
  {"number":4,"title":"Issue four","state":"open","updated_at":"2026-07-03T00:00:00Z","body":"body four","labels":[]}
]'

FAIL_LIST=0
FAIL_COMMENTS=0
MULTI_PAGE=0

_cache_gh() {
  echo "$*" >>"$CALLS"
  case "$*" in
    *"issues?state=all"*"--paginate"*)
      [ "$FAIL_LIST" = "1" ] && return 1
      printf '%s' "$PAGE1"
      [ "$MULTI_PAGE" = "1" ] && printf '%s' "$PAGE2"
      return 0
      ;;
    *"/comments")
      [ "$FAIL_COMMENTS" = "1" ] && return 1
      echo '[{"id":1,"body":"a comment"}]'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

reset() {
  : >"$CALLS"
  : >"$STDERR_LOG"
  rm -rf "${CACHE_STORE_ROOT:?}"/issues
  FAIL_LIST=0
  FAIL_COMMENTS=0
  MULTI_PAGE=0
}

list_calls() { grep -c 'issues?state=all' "$CALLS" 2>/dev/null || true; }
comment_calls() { grep -c '/comments$' "$CALLS" 2>/dev/null || true; }
graphql_calls() { grep -ci 'graphql' "$CALLS" 2>/dev/null || true; }
stderr_lines() { grep -c 'cache.sh:' "$STDERR_LOG" 2>/dev/null || true; }

# --- 1. cache_refresh_snapshot: filter PRs, keep closed, preserve parent ---
reset
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG"
snap="$(cache_snapshot_file "$REPO")"
[ -f "$snap" ] || fail "snapshot.jsonl not written"
case "$snap" in
  "$CACHE_STORE_ROOT"/issues/Acme-kernel-cache-test/snapshot.jsonl) : ;;
  *) fail "snapshot path wrong: $snap" ;;
esac
n_lines="$(wc -l <"$snap" | tr -d ' ')"
[ "$n_lines" -eq 2 ] || fail "expected 2 non-PR issues in snapshot, got $n_lines"
grep -q '"number":3' "$snap" && fail "PR row (#3) leaked into snapshot"
grep -q '"number":2' "$snap" || fail "closed issue (#2) missing from snapshot"
parent_n="$(jq -c 'select(.number==1) | .parent.number' "$snap")"
[ "$parent_n" = "10" ] || fail "parent linkage not preserved (got '$parent_n')"
summary_total="$(jq -c 'select(.number==1) | .sub_issues_summary.total' "$snap")"
[ "$summary_total" = "2" ] || fail "sub_issues_summary not preserved"
[ "$(list_calls)" -eq 1 ] || fail "expected exactly 1 list call, got $(list_calls)"
[ "$(comment_calls)" -eq 0 ] || fail "snapshot refresh must issue zero per-issue calls"
[ "$(graphql_calls)" -eq 0 ] || fail "snapshot refresh must issue zero GraphQL calls"
meta="$(cache_meta_file "$REPO")"
[ -f "$meta" ] || fail "meta.json not written"
[ "$(jq -r '.schema_version' "$meta")" = "1" ] || fail "meta.json schema_version wrong"
[ "$(jq -r '.repo' "$meta")" = "$REPO" ] || fail "meta.json repo field wrong"

# --- 1b. multi-page merge --------------------------------------------------
reset
MULTI_PAGE=1
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG"
snap="$(cache_snapshot_file "$REPO")"
n_lines="$(wc -l <"$snap" | tr -d ' ')"
[ "$n_lines" -eq 3 ] || fail "multi-page merge: expected 3 non-PR issues across 2 pages, got $n_lines"
grep -q '"number":4' "$snap" || fail "page-2 issue (#4) missing after merge"

# --- 2. cache_refresh_details: delta by updated_at -------------------------
reset
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG"
: >"$CALLS"
cache_refresh_details "$REPO" >/dev/null 2>>"$STDERR_LOG"
[ "$(comment_calls)" -eq 2 ] || fail "expected 2 comment calls (issues #1,#2 both new), got $(comment_calls)"
d1="$(cache_details_file "$REPO" 1)"
[ -f "$d1" ] || fail "details/1.json not written"
[ "$(jq -r '.schema_version' "$d1")" = "1" ] || fail "details schema_version wrong"
[ "$(jq -r '.updatedAt' "$d1")" = "2026-07-01T00:00:00Z" ] || fail "details updatedAt not stamped from snapshot row"
[ "$(jq -r '.body' "$d1")" = "body one" ] || fail "details body not copied from snapshot row"
[ "$(jq -r '.comments | length' "$d1")" = "1" ] || fail "details comments not fetched"

# unchanged snapshot -> zero calls on a second details refresh
: >"$CALLS"
cache_refresh_details "$REPO" >/dev/null 2>>"$STDERR_LOG"
[ "$(comment_calls)" -eq 0 ] || fail "unchanged issues must cost zero detail calls on re-refresh, got $(comment_calls)"

# --- 3. staleness contract --------------------------------------------------
reset
CACHE_STORE_TTL=3600
export CACHE_STORE_TTL
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG"
cache_stale "$REPO" && fail "just-refreshed store reported stale"

: >"$CALLS"
out1="$(cache_read "$REPO" 2>"$STDERR_LOG")"
[ "$(list_calls)" -eq 0 ] || fail "fresh cache_read must cost zero gh calls, got $(list_calls)"
[ -n "$out1" ] || fail "fresh cache_read returned no data"

# cache_dirty forces the next read to refresh, even though not naturally stale
cache_dirty "$REPO"
cache_stale "$REPO" || fail "cache_dirty did not force staleness"
: >"$CALLS"
cache_read "$REPO" >/dev/null 2>"$STDERR_LOG"
[ "$(list_calls)" -eq 1 ] || fail "dirtied cache_read should trigger exactly one refresh, got $(list_calls)"

# live fetch itself fails, no cache at all -> rc1, no data, one stderr notice
reset
FAIL_LIST=1
if out="$(cache_read "$REPO" 2>"$STDERR_LOG")"; then
  fail "cache_read should fail when the live fetch fails and no cache exists"
fi
[ -z "${out:-}" ] || fail "failed cache_read must not emit any data"
[ "$(stderr_lines)" -eq 1 ] || fail "expected exactly 1 stderr notice on live-fetch failure, got $(stderr_lines)"
[ ! -f "$(cache_snapshot_file "$REPO")" ] || fail "a failed refresh must not write a snapshot file"

# fetch succeeds but persist fails -> falls through to live data, one notice,
# on-disk snapshot left untouched (never corrupted)
reset
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG"
before_hash="$(shasum "$(cache_snapshot_file "$REPO")" | awk '{print $1}')"
cache_dirty "$REPO"
repo_dir="$(cache_repo_dir "$REPO")"
chmod -w "$repo_dir"
: >"$CALLS"
: >"$STDERR_LOG"
out="$(cache_read "$REPO" 2>"$STDERR_LOG")"
chmod u+w "$repo_dir"
[ -n "$out" ] || fail "persist-failure fallback must still return the live-fetched data"
echo "$out" | grep -q '"number":1' || fail "persist-failure fallback data missing expected issue"
[ "$(stderr_lines)" -eq 1 ] || fail "expected exactly 1 stderr notice on persist failure, got $(stderr_lines)"
grep -q "falling through to a live" "$STDERR_LOG" || fail "persist-failure notice text missing"
after_hash="$(shasum "$(cache_snapshot_file "$REPO")" | awk '{print $1}')"
[ "$before_hash" = "$after_hash" ] || fail "on-disk snapshot must be left untouched when persist fails"

# --- 4. CACHE-STORE.md + schema_version marker -----------------------------
[ -f "$LIB_DIR/CACHE-STORE.md" ] || fail "CACHE-STORE.md missing"
grep -q "schema_version" "$LIB_DIR/CACHE-STORE.md" || fail "CACHE-STORE.md does not document schema_version"
grep -q "snapshot.jsonl" "$LIB_DIR/CACHE-STORE.md" || fail "CACHE-STORE.md does not document snapshot.jsonl"

# --- 5. self-containment: board.sh alone; cache.sh alone; manifest --------
# board.sh sourced WITHOUT cache.sh still works standalone (fresh subshell) —
# resolves board 7's owner/repo cleanly. The exact org/repo value is real-org
# content (kernel personal-token denylist) so this only asserts the SHAPE
# (non-empty, "owner/repo"), never the literal string.
board_repo_out="$(bash -c '
  source "'"$LIB_DIR"'/board.sh"
  board_repo 7
')"
case "$board_repo_out" in
  ?*/?*) : ;;
  *) fail "board.sh is no longer self-contained without cache.sh (board_repo 7 gave '$board_repo_out')" ;;
esac

# cache.sh sourced WITHOUT board.sh rejects a bare board number cleanly.
standalone_err="$(mktemp "${TMPDIR:-/tmp}/cache-standalone-err-XXXXXX")"
if bash -c '
  source "'"$LIB_DIR"'/cache.sh"
  cache_repo_dir 4
' >/dev/null 2>"$standalone_err"; then
  fail "cache.sh should reject a bare board number when board.sh is not sourced"
fi
grep -q "board_repo() is not available" "$standalone_err" \
  || fail "cache.sh standalone-failure message missing the documented hint"
rm -f "$standalone_err"

echo "test_cache_store.sh: all checks passed"
