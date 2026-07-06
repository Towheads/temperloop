#!/usr/bin/env bash
#
# test_relationship_cache.sh — the cache-relationships item's own suite
# (F#988 Contract, the split wiring board.sh's board_sub_issues /
# board_parent_issue to lib/cache.sh's on-disk issue-cache store). Mirrors
# test_cache_read_dispatch.sh's conventions (same fake_gh.sh replay harness,
# same isolated CACHE_STORE_ROOT/boards.conf-per-test-board setup) but for
# the RELATIONSHIP reads instead of the whole-board item-list read.
#
# Coverage (mirrors the item's acceptance bullets):
#   1. Warm cache: board_sub_issues / board_parent_issue answer with ZERO gh
#      calls (neither board.sh's nor cache.sh's), byte-identical to the live
#      per-issue REST answers on the same fixture data — INCLUDING a CLOSED
#      child (the snapshot carries all states; inversion must not drop it).
#   2. board_blocked_by_open is UNCHANGED — grep-audit proves it has no
#      `_board_cache_store_enabled` arm (still always-live, native issue
#      dependencies are out of this item's scope).
#   3. Degradation: axis on but cache.sh not "sourced" -> exactly one stderr
#      notice, falls back to the live per-issue read, output identical to the
#      axis-off case, for BOTH accessors.
#   4. Axis absent -> inert: live read, zero cache.sh calls, no stderr.
#
# Zero network: overrides both test-injection seams (`_board_gh`, `_cache_gh`)
# independently, like test_cache_read_dispatch.sh.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

REPO="Acme/kernel-relcache-test"   # denylist:allow — generic placeholder org/repo

CACHE_STORE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rel-cache-store-XXXXXX")"
export CACHE_STORE_ROOT
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rel-cache-conf-XXXXXX")"
BOARD_CALLS="$(mktemp "${TMPDIR:-/tmp}/rel-cache-board-calls-XXXXXX")"
CACHE_CALLS="$(mktemp "${TMPDIR:-/tmp}/rel-cache-cache-calls-XXXXXX")"
STDERR_LOG="$(mktemp "${TMPDIR:-/tmp}/rel-cache-stderr-XXXXXX")"
cleanup() {
  chmod -R u+w "$CACHE_STORE_ROOT" 2>/dev/null || true
  rm -rf "$CACHE_STORE_ROOT" "$WORK" "$BOARD_CALLS" "$CACHE_CALLS" "$STDERR_LOG"
}
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Board 60: cache=on (the warm/cached arm under test). Board 61: same repo,
# no cache axis (the live-arm control — same fixture data feeds both).
cat > "$WORK/boards.conf" <<EOF
board.60.repo=$REPO
board.60.cache=on
board.61.repo=$REPO
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"
# shellcheck source=scripts/lib/cache.sh
source "$LIB_DIR/cache.sh"

board_calls() { grep -c '.' "$BOARD_CALLS" 2>/dev/null || true; }
list_calls()  { grep -c 'issues?state=all' "$CACHE_CALLS" 2>/dev/null || true; }
reset_calls() { : >"$BOARD_CALLS"; : >"$CACHE_CALLS"; : >"$STDERR_LOG"; }

# --- fixture: epic #300 has two children — #301 (open), #302 (CLOSED) -------
# The snapshot is the bulk-list REST shape (cache.sh's own storage format):
# parent linkage rides as a NESTED `.parent.number` object (CACHE-STORE.md /
# test_cache_store.sh), NOT the single-issue endpoint's `.parent_issue_url`
# string — the two REST shapes for the same relationship are deliberately
# different, and the cached arm must read the bulk shape.
BULK_ISSUES='[
  {"number":300,"title":"Epic three-hundred","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[]},
  {"number":301,"title":"Open child","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[],
   "parent":{"number":300}},
  {"number":302,"title":"Closed child","state":"closed","updated_at":"2026-06-01T00:00:00Z","body":"","labels":[],
   "parent":{"number":300}},
  {"number":303,"title":"Unrelated singleton","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[]}
]'

_board_gh() {
  echo "gh $*" >>"$BOARD_CALLS"
  case "$1 $2" in
    "api repos/$REPO/issues/300/sub_issues") echo '[{"number":301},{"number":302}]' ;;
    "api repos/$REPO/issues/301")
      echo '{"number":301,"parent_issue_url":"https://api.github.com/repos/'"$REPO"'/issues/300"}' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
_cache_gh() {
  echo "$*" >>"$CACHE_CALLS"
  case "$*" in
    *"issues?state=all"*"--paginate"*) printf '%s' "$BULK_ISSUES" ;;
    *"/comments") echo '[]' ;;
    *) return 1 ;;
  esac
}

# --- 1a. axis ABSENT (board 61): live read, zero cache.sh calls, no stderr --
reset_calls
LIVE_SUB="$(board_sub_issues 61 300)"
LIVE_PARENT="$(board_parent_issue 61 301)"
[ "$(list_calls)" -eq 0 ] || fail "axis-absent must make zero cache.sh calls, got $(list_calls)"
[ ! -s "$STDERR_LOG" ] || fail "axis-absent should emit no stderr, got: $(cat "$STDERR_LOG")"
[ "$LIVE_SUB" = "$(printf '301\n302')" ] || fail "live board_sub_issues wrong: [$LIVE_SUB]"
[ "$LIVE_PARENT" = "300" ] || fail "live board_parent_issue wrong: [$LIVE_PARENT]"
echo "PASS: board.<N>.cache absent is inert for both relationship reads (live, zero cache.sh calls)"

# --- warm the store for board 60 (one bulk fetch) ---------------------------
reset_calls
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG" || fail "setup: cache_refresh_snapshot failed"
[ "$(list_calls)" -eq 1 ] || fail "setup: expected exactly 1 bulk list call to warm the store"

# --- 1b. axis ON + WARM: ZERO gh calls of either kind, byte-parity with live,
# INCLUDING the closed child (#302) --------------------------------------
reset_calls
WARM_SUB="$(board_sub_issues 60 300 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 0 ] || fail "warm board_sub_issues must make zero board.sh gh calls, got $(board_calls): $(cat "$BOARD_CALLS")"
[ "$(list_calls)" -eq 0 ] || fail "warm board_sub_issues must make zero cache.sh gh calls, got $(list_calls)"
[ ! -s "$STDERR_LOG" ] || fail "warm board_sub_issues should be silent, got: $(cat "$STDERR_LOG")"
[ "$WARM_SUB" = "$LIVE_SUB" ] || fail "cached-vs-live parity (sub_issues) failed: cached=[$WARM_SUB] live=[$LIVE_SUB]"
echo "$WARM_SUB" | grep -qx 302 || fail "closed child #302 dropped by cache inversion (snapshot must preserve closed issues)"
echo "PASS: warm board_sub_issues — zero gh calls, byte-parity with live (open+closed children both present)"

reset_calls
WARM_PARENT="$(board_parent_issue 60 301 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 0 ] || fail "warm board_parent_issue must make zero board.sh gh calls, got $(board_calls)"
[ "$(list_calls)" -eq 0 ] || fail "warm board_parent_issue must make zero cache.sh gh calls, got $(list_calls)"
[ ! -s "$STDERR_LOG" ] || fail "warm board_parent_issue should be silent, got: $(cat "$STDERR_LOG")"
[ "$WARM_PARENT" = "$LIVE_PARENT" ] || fail "cached-vs-live parity (parent_issue) failed: cached=[$WARM_PARENT] live=[$LIVE_PARENT]"
echo "PASS: warm board_parent_issue — zero gh calls, byte-parity with live"

# --- 1c. singleton / childless cases also parity-match ----------------------
reset_calls
[ -z "$(board_parent_issue 60 303 2>/dev/null)" ] || fail "singleton #303 must resolve to empty parent (cached arm)"
[ -z "$(board_sub_issues 60 303 2>/dev/null)" ] || fail "childless #303 must resolve to empty sub_issues (cached arm)"
echo "PASS: singleton/childless cases resolve empty on the cached arm"

# --- 2. board_blocked_by_open is UNCHANGED — no cached arm ------------------
BLOCKED_BY_BODY="$(awk '/^board_blocked_by_open\(\) \{/,/^\}/' "$LIB_DIR/board.sh")"
echo "$BLOCKED_BY_BODY" | grep -q '_board_cache_store_enabled' \
  && fail "board_blocked_by_open must NOT have a cached arm (blocked_by stays live, out of this item's scope)"
echo "PASS: board_blocked_by_open has no cached arm (grep-audit — still always-live)"

# --- 3. degradation path — axis on, cache.sh functions NOT in scope ---------
unset -f cache_read cache_dirty cache_refresh_snapshot cache_refresh_details \
         cache_refresh cache_stale cache_clear cache_read_details \
         cache_repo_dir cache_snapshot_file cache_meta_file cache_details_dir \
         cache_details_file
reset_calls
DEGRADED_SUB="$(board_sub_issues 60 300 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 1 ] || fail "degraded board_sub_issues should fall back to exactly 1 live gh call, got $(board_calls)"
[ "$(grep -c . "$STDERR_LOG")" -eq 1 ] || fail "degraded board_sub_issues should emit exactly 1 stderr notice, got: $(cat "$STDERR_LOG")"
grep -q "cache.sh is not sourced" "$STDERR_LOG" || fail "degraded stderr notice missing the documented hint: $(cat "$STDERR_LOG")"
[ "$DEGRADED_SUB" = "$LIVE_SUB" ] || fail "degraded board_sub_issues output must match live: degraded=[$DEGRADED_SUB] live=[$LIVE_SUB]"

reset_calls
DEGRADED_PARENT="$(board_parent_issue 60 301 2>"$STDERR_LOG")"
[ "$(board_calls)" -eq 1 ] || fail "degraded board_parent_issue should fall back to exactly 1 live gh call, got $(board_calls)"
[ "$(grep -c . "$STDERR_LOG")" -eq 1 ] || fail "degraded board_parent_issue should emit exactly 1 stderr notice, got: $(cat "$STDERR_LOG")"
[ "$DEGRADED_PARENT" = "$LIVE_PARENT" ] || fail "degraded board_parent_issue output must match live: degraded=[$DEGRADED_PARENT] live=[$LIVE_PARENT]"
echo "PASS: degradation path (cache.sh not sourced) falls back to live for both accessors, one stderr notice each, output identical to axis-off"

# Restore cache.sh (courtesy, in case a future case is appended to this file).
# shellcheck source=scripts/lib/cache.sh
source "$LIB_DIR/cache.sh"

echo
echo "ALL PASS: test_relationship_cache.sh"
