#!/usr/bin/env bash
#
# Tests for board.sh's sub-issue WRITE helpers (temperloop#1188, re-cut from
# foundation#1287) — the write counterpart the adapter was missing:
# board_add_sub_issue / board_remove_sub_issue. Before this, a native
# sub-issue link/unlink had to bypass the adapter via raw REST — the last
# sanctioned raw-gh-api hole in the linkage axis, alongside blocked_by
# (temperloop#1221). Shape follows test_blocked_by_write.sh, the pinned
# precedent for this item.
#
# Replays the `_board_gh` seam like test_blocked_by_write.sh / test_board_replay.sh —
# no network, no PATH shim. The mock does two jobs:
#   1. a GET on `repos/.../issues/<n>` (the db-id resolution) returns an id
#      DERIVED from <n> (id = <n>*1000), so an assertion can prove the writer
#      resolved the CHILD's number (not the parent's) into the request;
#   2. any `--method POST|DELETE` call is RECORDED verbatim so an assertion can
#      check the method, path, and sub_issue_id the writer actually sent.
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
# shellcheck disable=SC1091
source "$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }

CAP="$(mktemp -d "${TMPDIR:-/tmp}/siw.XXXXXX")"
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

# --- 1. add: resolves the CHILD's db id, POSTs the collection endpoint -------
reset
board_add_sub_issue 3 42 99 || fail "add: expected exit 0 on a clean write"
line="$(cat "$CAP/calls")"
case "$line" in
  *"--method POST"*) ;;
  *) fail "add: expected a POST, got [$line]" ;;
esac
case "$line" in
  *"/issues/42/sub_issues "*) ;;   # trailing space = collection, no id in path
  *) fail "add: POST path must target parent 42's sub_issues collection, got [$line]" ;;
esac
case "$line" in
  *"-F sub_issue_id=99000"*) ;;   # -F (not -f) sends a JSON INTEGER;
                                   # 99*1000 proves it resolved the CHILD (#99), not #42.
                                   # The -F is asserted verbatim so a -F->-f regression
                                   # (string sub_issue_id) fails here.
  *) fail "add: POST must carry the CHILD's db id as an -F integer (-F sub_issue_id=99000), got [$line]" ;;
esac
ok "add → POST parent 42's sub_issues collection with the child's db id"

# --- 2. remove: DELETEs the SINGULAR endpoint, id in the body ---------------
reset
board_remove_sub_issue 3 42 99 || fail "remove: expected exit 0 on a clean delete"
line="$(cat "$CAP/calls")"
case "$line" in
  *"--method DELETE"*) ;;
  *) fail "remove: expected a DELETE, got [$line]" ;;
esac
case "$line" in
  *"/issues/42/sub_issue "*) ;;   # SINGULAR endpoint (unlike blocked_by, id is NOT in the path)
  *) fail "remove: DELETE path must target the singular .../sub_issue endpoint, got [$line]" ;;
esac
case "$line" in
  *"-F sub_issue_id=99000"*) ;;   # the child db id rides the request BODY, not the path
  *) fail "remove: DELETE must carry the CHILD's db id as -F sub_issue_id=99000 in the body, got [$line]" ;;
esac
ok "remove → DELETE parent 42's singular sub_issue endpoint with the child's db id in the body"

# --- 3. arg guards: no write on bad input ------------------------------------
reset
if board_add_sub_issue 3 42 2>/dev/null;    then fail "add: missing <child#> must be rejected"; fi
if board_add_sub_issue 3 abc 99 2>/dev/null; then fail "add: non-numeric <parent#> must be rejected"; fi
if board_add_sub_issue 3 42 "" 2>/dev/null;  then fail "add: empty <child#> must be rejected"; fi
if board_remove_sub_issue 3 42 2>/dev/null;  then fail "remove: too few args must be rejected"; fi
[ ! -s "$CAP/calls" ] || fail "arg guards: a rejected call must issue NO write (calls: [$(cat "$CAP/calls")])"
ok "bad args → rejected non-zero, no write issued"

# --- 4. unresolvable child: no write, non-zero -------------------------------
# Redefine the mock so the db-id GET returns no id (issue not found).
_board_gh() {
  local all="$*"
  case "$all" in
    *"--method "*) printf '%s\n' "$all" >> "$CAP/calls"; return 0 ;;
    *) printf '{}'; return 0 ;;   # no .id
  esac
}
reset
if board_add_sub_issue 3 42 99 2>/dev/null;    then fail "add: an unresolvable child id must fail non-zero"; fi
[ ! -s "$CAP/calls" ] || fail "unresolvable child: must NOT POST (calls: [$(cat "$CAP/calls")])"
if board_remove_sub_issue 3 42 99 2>/dev/null; then fail "remove: an unresolvable child id must fail non-zero"; fi
[ ! -s "$CAP/calls" ] || fail "unresolvable child: must NOT DELETE (calls: [$(cat "$CAP/calls")])"
ok "unresolvable child → non-zero, no write issued"

echo "ALL PASS: test_sub_issue_write.sh ($pass cases)"
