#!/usr/bin/env bash
#
# Tests for board.sh's blocked_by WRITE helpers (foundation#1221) — the write
# counterpart the adapter was missing: board_blocked_by_add /
# board_blocked_by_remove. Before this, a native `blocked_by` dependency-edge
# write had to bypass the adapter via raw REST, against the "all board
# reads/writes go through the adapter" rule.
#
# Replays the `_board_gh` seam like test_blocked_by.sh / test_board_replay.sh —
# no network, no PATH shim. The mock does two jobs:
#   1. a GET on `repos/.../issues/<n>` (the db-id resolution) returns an id
#      DERIVED from <n> (id = <n>*1000), so an assertion can prove the writer
#      resolved the BLOCKER's number (not the issue's) into the POST payload;
#   2. any `--method POST|DELETE` call is RECORDED verbatim so an assertion can
#      check the method, path, and issue_id the writer actually sent.
#
# The `_board_gh` overrides are invoked indirectly (the library calls
# `_board_gh`, which this test redefines) and are redefined mid-file per case,
# so shellcheck's "never invoked" / "unreachable" checks are false positives.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }

CAP="$(mktemp -d "${TMPDIR:-/tmp}/bbw.XXXXXX")"
cleanup() { rm -rf "$CAP"; }
trap cleanup EXIT

# The default mock: GET → id derived from the requested issue number; write →
# record the full arg string. Records into $CAP/calls (reset per case).
_board_gh() {
  local all="$*" n
  case "$all" in
    *"--method "*)
      printf '%s\n' "$all" >> "$CAP/calls"
      return 0 ;;
    *)
      n="${all##*/issues/}"; n="${n%% *}"; n="${n%%/*}"
      case "$n" in '' | *[!0-9]*) printf '{}'; return 0 ;; esac
      printf '{"id": %s000, "number": %s}' "$n" "$n"
      return 0 ;;
  esac
}

reset() { : > "$CAP/calls"; }

# --- 1. add: resolves the BLOCKER's db id, POSTs the collection endpoint ------
reset
board_blocked_by_add 3 42 99 || fail "add: expected exit 0 on a clean write"
line="$(cat "$CAP/calls")"
case "$line" in
  *"--method POST"*) ;;
  *) fail "add: expected a POST, got [$line]" ;;
esac
case "$line" in
  *"/issues/42/dependencies/blocked_by "*) ;;   # trailing space = collection, no id in path
  *) fail "add: POST path must target issue 42's blocked_by collection, got [$line]" ;;
esac
case "$line" in
  *"-F issue_id=99000"*) ;;   # -F (not -f) sends a JSON INTEGER, which the deps API keys by;
                              # 99*1000 proves it resolved the BLOCKER (#99), not #42. The -F is
                              # asserted verbatim so a -F→-f regression (string issue_id) fails here.
  *) fail "add: POST must carry the BLOCKER's db id as an -F integer (-F issue_id=99000), got [$line]" ;;
esac
ok "add → POST issue 42's blocked_by collection with the blocker's db id"

# --- 2. remove: DELETEs the id-keyed endpoint --------------------------------
reset
board_blocked_by_remove 3 42 99 || fail "remove: expected exit 0 on a clean delete"
line="$(cat "$CAP/calls")"
case "$line" in
  *"--method DELETE"*) ;;
  *) fail "remove: expected a DELETE, got [$line]" ;;
esac
case "$line" in
  *"/issues/42/dependencies/blocked_by/99000"*) ;;   # path ends in the blocker db id
  *) fail "remove: DELETE path must end in the blocker db id (.../blocked_by/99000), got [$line]" ;;
esac
ok "remove → DELETE issue 42's blocked_by edge keyed by the blocker db id"

# --- 3. arg guards: no write on bad input ------------------------------------
reset
if board_blocked_by_add 3 42 2>/dev/null;    then fail "add: missing <blocker#> must be rejected"; fi
if board_blocked_by_add 3 abc 99 2>/dev/null; then fail "add: non-numeric <issue#> must be rejected"; fi
if board_blocked_by_add 3 42 "" 2>/dev/null;  then fail "add: empty <blocker#> must be rejected"; fi
if board_blocked_by_remove 3 2>/dev/null;     then fail "remove: too few args must be rejected"; fi
[ ! -s "$CAP/calls" ] || fail "arg guards: a rejected call must issue NO write (calls: [$(cat "$CAP/calls")])"
ok "bad args → rejected non-zero, no write issued"

# --- 4. unresolvable blocker: no write, non-zero -----------------------------
# Redefine the mock so the db-id GET returns no id (issue not found).
_board_gh() {
  local all="$*"
  case "$all" in
    *"--method "*) printf '%s\n' "$all" >> "$CAP/calls"; return 0 ;;
    *) printf '{}'; return 0 ;;   # no .id
  esac
}
reset
if board_blocked_by_add 3 42 99 2>/dev/null;    then fail "add: an unresolvable blocker id must fail non-zero"; fi
[ ! -s "$CAP/calls" ] || fail "unresolvable blocker: must NOT POST (calls: [$(cat "$CAP/calls")])"
if board_blocked_by_remove 3 42 99 2>/dev/null; then fail "remove: an unresolvable blocker id must fail non-zero"; fi
[ ! -s "$CAP/calls" ] || fail "unresolvable blocker: must NOT DELETE (calls: [$(cat "$CAP/calls")])"
ok "unresolvable blocker → non-zero, no write issued"

echo "ALL PASS: test_blocked_by_write.sh ($pass cases)"
