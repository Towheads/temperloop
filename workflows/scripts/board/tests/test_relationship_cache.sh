#!/usr/bin/env bash
#
# test_relationship_cache.sh — the contract for board.sh's RELATIONSHIP reads
# (board_sub_issues / board_parent_issue) against lib/cache.sh's issue-cache
# store. Mirrors test_cache_read_dispatch.sh's conventions (same fake-gh replay
# harness, same isolated CACHE_STORE_ROOT/boards.conf-per-test-board setup).
#
# ── WHAT THIS FILE NOW ASSERTS, AND WHY IT INVERTED (temperloop#1163) ────────
# It used to assert that a warm cache answers both relationship reads with ZERO
# gh calls. That contract was WRONG, and this suite is why it survived two
# months: its fixture hand-wrote `"parent":{"number":300}` into the snapshot
# rows, and GitHub's bulk issues-list NEVER returns a `parent` key. The fixture
# was strictly more capable than reality, so it exercised — and green-lit — a
# code path production could never take. Measured against real stores: 0 of 911
# rows in one repo's snapshot and 0 of 611 in another's carry `.parent`.
#
# In production the cached arm therefore read a key that was not there and
# returned EMPTY for every issue, silently. Blast radius: build/board-mirror.sh
# counts `board_sub_issues <b> <epic> open | wc -l` and treats 0 as "epic fully
# drained", so with the cache enabled it was armed to CLOSE epics that still had
# open children (verified on a real open epic: live=1 open child, cached=0).
#
# So the contract is now: **relationship reads are LIVE-ONLY**, exactly like
# board_blocked_by_open. Coverage:
#   1. Live-only: with the axis ON and cache.sh sourced, both accessors still
#      make their live per-issue call and return the true answer.
#   2. THE REGRESSION GUARD: with a snapshot built from a REALISTIC bulk-list
#      payload (no `parent` key — only `sub_issues_summary`), the true children
#      are still returned. This is the assertion whose absence let the original
#      defect ship; it fails against the old cached arm and passes now.
#   3. Structural guard: neither function contains a cache_read arm, so a future
#      reintroduction trips here rather than in a silent epic close.
#   4. board_blocked_by_open is unchanged — still no cached arm.
#   5. The state filter [all|open|closed] (temperloop#1119) still works.
#
# NOT a permanent verdict on caching these reads: cache_refresh_details already
# fetches the single-issue payload that carries `parent_issue_url` and discards
# it, so the parent graph is derivable locally at zero extra API cost
# (temperloop#1165). When that lands, this suite gets a cached arm back — with
# a fixture built from the REAL payload shape, not an invented one.
#
# Zero network: overrides both test-injection seams (`_board_gh`, `_cache_gh`).
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

# Board 60: cache=on. Board 61: same repo, no cache axis (the control). Under
# the corrected contract both must behave IDENTICALLY for relationship reads —
# that equivalence is itself the point.
cat > "$WORK/boards.conf" <<EOF
board.60.repo=$REPO
board.60.cache=on
board.61.repo=$REPO
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$LIB_DIR/board.sh"
# shellcheck source=scripts/lib/cache.sh
# shellcheck disable=SC1091
source "$LIB_DIR/cache.sh"

board_calls() { grep -c '.' "$BOARD_CALLS" 2>/dev/null || true; }
list_calls()  { grep -c 'issues?state=all' "$CACHE_CALLS" 2>/dev/null || true; }
reset_calls() { : >"$BOARD_CALLS"; : >"$CACHE_CALLS"; : >"$STDERR_LOG"; }

# --- fixture: epic #300 has two children — #301 (open), #302 (CLOSED) -------
# THE SNAPSHOT SHAPE IS THE POINT. This is the REAL bulk `issues?state=all`
# payload: it carries `sub_issues_summary` (counts) and NO `parent` key. The
# previous version of this fixture invented `"parent":{"number":300}` rows; that
# invention is exactly what let temperloop#1030's broken cached arm pass. Do not
# add a `parent` key here to make a cached arm work — fix the store instead
# (temperloop#1165).
BULK_ISSUES='[
  {"number":300,"title":"Epic three-hundred","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[],
   "sub_issues_summary":{"total":2,"completed":1,"percent_completed":50}},
  {"number":301,"title":"Open child","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[]},
  {"number":302,"title":"Closed child","state":"closed","updated_at":"2026-06-01T00:00:00Z","body":"","labels":[]},
  {"number":303,"title":"Unrelated singleton","state":"open","updated_at":"2026-07-01T00:00:00Z","body":"","labels":[]}
]'

_board_gh() {
  echo "gh $*" >>"$BOARD_CALLS"
  case "$1 $2" in
    # The real /sub_issues endpoint returns full issue objects and DOES carry
    # `.state` — verified live against a known epic. The stub used to omit it,
    # which under-specified the response and would have let a broken live-arm
    # state filter pass (temperloop#1119): with `.state` absent the filter's
    # `.state // "open"` default matched every row, so `open` returned closed
    # children too. Keep these rows shaped like the real payload. (Same class of
    # fixture bug as the invented `parent` key above — that is twice now.)
    "api repos/$REPO/issues/300/sub_issues")
      echo '[{"number":301,"state":"open"},{"number":302,"state":"closed"}]' ;;
    "api repos/$REPO/issues/301")
      echo '{"number":301,"parent_issue_url":"https://api.github.com/repos/'"$REPO"'/issues/300"}' ;;
    "api repos/$REPO/issues/303")
      echo '{"number":303}' ;;
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

# --- 1. axis ABSENT (board 61) — the reference answers ----------------------
reset_calls
LIVE_SUB="$(board_sub_issues 61 300)"
LIVE_PARENT="$(board_parent_issue 61 301)"
[ "$(list_calls)" -eq 0 ] || fail "axis-absent must make zero cache.sh calls, got $(list_calls)"
[ ! -s "$STDERR_LOG" ] || fail "axis-absent should emit no stderr, got: $(cat "$STDERR_LOG")"
[ "$LIVE_SUB" = "$(printf '301\n302')" ] || fail "live board_sub_issues wrong: [$LIVE_SUB]"
[ "$LIVE_PARENT" = "300" ] || fail "live board_parent_issue wrong: [$LIVE_PARENT]"
echo "PASS: 1 axis-absent relationship reads are live and correct (the reference)"

# --- warm the store for board 60 (one bulk fetch) ---------------------------
reset_calls
cache_refresh_snapshot "$REPO" >/dev/null 2>"$STDERR_LOG" || fail "setup: cache_refresh_snapshot failed"
[ "$(list_calls)" -eq 1 ] || fail "setup: expected exactly 1 bulk list call to warm the store"

# --- 2. THE REGRESSION GUARD (temperloop#1163) ------------------------------
# Axis ON, cache.sh sourced, store WARM — against a realistic snapshot. The old
# cached arm returned EMPTY here (it read a `parent` key the payload does not
# have) and this assertion is what it failed. Live-only makes it pass.
reset_calls
WARM_SUB="$(board_sub_issues 60 300 2>"$STDERR_LOG")"
[ -n "$WARM_SUB" ] || fail "REGRESSION (temperloop#1163): board_sub_issues returned EMPTY on a warm cache. \
A cached arm reading a field the bulk payload does not carry is exactly the defect that armed board-mirror.sh \
to close epics with open children."
[ "$WARM_SUB" = "$LIVE_SUB" ] || fail "warm board_sub_issues must equal the live answer: warm=[$WARM_SUB] live=[$LIVE_SUB]"
echo "$WARM_SUB" | grep -qx 302 || fail "closed child #302 missing"
echo "PASS: 2 REGRESSION GUARD — warm cache returns the true children, not empty"

reset_calls
WARM_PARENT="$(board_parent_issue 60 301 2>"$STDERR_LOG")"
[ -n "$WARM_PARENT" ] || fail "REGRESSION (temperloop#1163): board_parent_issue returned EMPTY on a warm cache"
[ "$WARM_PARENT" = "$LIVE_PARENT" ] || fail "warm board_parent_issue must equal live: warm=[$WARM_PARENT] live=[$LIVE_PARENT]"
echo "PASS: 2b REGRESSION GUARD — warm board_parent_issue resolves the true parent"

# --- 3. the epic-close count, which is what the defect actually endangered --
# board-mirror.sh reads exactly this and closes the epic when it is 0.
reset_calls
OPEN_COUNT="$(board_sub_issues 60 300 open | grep -c . || true)"
[ "$OPEN_COUNT" -eq 1 ] || fail "open-child count must be 1 (#301); got $OPEN_COUNT. \
A 0 here is what board-mirror.sh reads as 'epic fully drained'."
echo "PASS: 3 the epic-close open-child count is correct on a warm cache (1, not 0)"

# --- 4. structural guard — no cached arm may be reintroduced silently -------
SUB_BODY="$(awk '/^board_sub_issues\(\) \{/,/^\}/' "$LIB_DIR/board.sh")"
PARENT_BODY="$(awk '/^board_parent_issue\(\) \{/,/^\}/' "$LIB_DIR/board.sh")"
echo "$SUB_BODY" | grep -q 'cache_read' \
  && fail "board_sub_issues must NOT read the snapshot (temperloop#1163) — the bulk payload has no parent linkage. \
See temperloop#1165 for the zero-API-cost path to caching this correctly."
echo "$PARENT_BODY" | grep -q 'cache_read' \
  && fail "board_parent_issue must NOT read the snapshot (temperloop#1163)"
echo "PASS: 4 neither relationship read has a snapshot-reading arm (grep-audit)"

BLOCKED_BY_BODY="$(awk '/^board_blocked_by_open\(\) \{/,/^\}/' "$LIB_DIR/board.sh")"
echo "$BLOCKED_BY_BODY" | grep -q '_board_cache_store_enabled' \
  && fail "board_blocked_by_open must NOT have a cached arm (blocked_by stays live)"
echo "PASS: 4b board_blocked_by_open still has no cached arm"

# --- 5. the state filter (temperloop#1119) still behaves --------------------
# It exists so the epic-close "how many children are still open?" count can be
# asked directly. Default must remain byte-identical to the 2-arg call.
reset_calls
FILTER_ALL_DEFAULT="$(board_sub_issues 60 300)"
FILTER_ALL_EXPLICIT="$(board_sub_issues 60 300 all)"
[ "$FILTER_ALL_DEFAULT" = "$FILTER_ALL_EXPLICIT" ] || \
  fail "explicit 'all' must equal the default: default=[$FILTER_ALL_DEFAULT] explicit=[$FILTER_ALL_EXPLICIT]"
[ "$FILTER_ALL_DEFAULT" = "$LIVE_SUB" ] || \
  fail "default (2-arg) board_sub_issues must be unchanged: got=[$FILTER_ALL_DEFAULT] live=[$LIVE_SUB]"

OPEN_ONLY="$(board_sub_issues 60 300 open)"
CLOSED_ONLY="$(board_sub_issues 60 300 closed)"
[ "$OPEN_ONLY" = "301" ] || fail "state=open must yield only #301, got [$OPEN_ONLY]"
[ "$CLOSED_ONLY" = "302" ] || fail "state=closed must yield only #302, got [$CLOSED_ONLY]"
board_sub_issues 60 300 bogus >/dev/null 2>&1 \
  && fail "an invalid state value must be rejected"
echo "PASS: 5 the [all|open|closed] state filter partitions children correctly and rejects a bad value"

# --- 6. childless / singleton cases ----------------------------------------
[ -z "$(board_parent_issue 60 303 2>/dev/null)" ] || fail "singleton #303 must resolve to an empty parent"
echo "PASS: 6 a singleton resolves to an empty parent"

echo "OK — relationship reads: live-only contract holds, regression guard in place"
