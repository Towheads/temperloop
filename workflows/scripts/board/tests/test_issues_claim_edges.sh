#!/usr/bin/env bash
#
# Tests for the issues-only backend's claim/edges/cascade surface (foundation
# #800, split 2/3 of the issues-only tracker adapter — builds on split 1/3's
# test_issues_backend.sh). See sibling workflows/scripts/board/ISSUES-ONLY-BACKEND.md
# § Claim lock / § Parent/child and dependency edges / § Close→Done cascade for
# the full contract this suite pins.
#
# Zero network: sources board.sh (and claim.sh, for the end-to-end cases),
# overrides the `_board_gh` seam to replay canned/stateful JSON, drives the
# public functions directly.
#
# Coverage:
#   1. board_stamp on ISSUE_* — write (label create + add), verbatim (no
#      lowercasing) round-trip through the "host/Session" flattened key,
#      clear (empty text removes the label, adds nothing).
#   2. board_claim_contended — contended / self-reclaim / half-claim-adoption
#      / unclaimed cases on an issues-only board, replayed again on a
#      Projects-v2 board (BOARD_ITEMS_JSON is shaped identically by both
#      backends, so the same jq logic applies without a backend branch).
#   3. board_sub_issues — child issue numbers via the native sub-issues REST
#      endpoint, empty when none.
#   4. claim.sh end-to-end against a fake issues-only repo: happy-path claim
#      (label swap + stamp), refused contended claim (NO writes at all), and
#      adoption of an unstamped In-Progress item.
#
# The `_board_gh` overrides are invoked indirectly (the library/claim.sh call
# `_board_gh`, which this test redefines) and are redefined mid-file per case —
# shellcheck's "never invoked"/"unreachable" checks are false positives here,
# as in the sibling replay suites.
# shellcheck disable=SC2317,SC2329,SC2034
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"

# shellcheck source=scripts/tests/fixtures/fake_gh.sh
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issues-claim-edges-conf-XXXXXX")"
CALLS="$(mktemp "${TMPDIR:-/tmp}/issues-claim-edges-calls-XXXXXX")"
cleanup() { rm -rf "$WORK" "$CALLS"; }
trap cleanup EXIT

# Board 21 = a SECOND issues-only board (distinct from test_issues_backend.sh's
# board 20, so the two suites never collide if ever run in the same process).
# Board 3 stays unconfigured (default Projects-v2 backend) for the "always
# safe" cross-backend proof. Generic placeholder org/repo — no personal token.
cat > "$WORK/boards.conf" <<'EOF'
board.21.repo=Acme/kernel-edges-test
board.21.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"
export BOARD_CACHE_TTL=0
export BOARD_BUDGET_GUARD_THRESHOLD=0

REPO="Acme/kernel-edges-test"

# =============================================================================
# 1. board_stamp on ISSUE_* — write / verbatim round-trip / clear
# =============================================================================

FAKE_STATE="open"
FAKE_LABELS=""
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/$REPO/issues/200")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":200,"title":"claim target","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --remove-label) FAKE_LABELS="$(printf '%s\n' $FAKE_LABELS | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label)    FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
BOARD_CURRENT=21

# Deliberately mixed-case host + session, to prove the stamp is stored
# VERBATIM (never slugged/lowercased) — a real hostname/session can carry
# uppercase, and lowercasing would corrupt the foreign-host comparison.
STAMP="Mini-2:AbCd1234"

: >"$CALLS"
board_stamp "ISSUE_200" "Host/Session" "$STAMP" || fail "board_stamp (issues-only) should succeed"
grep -q -- "--add-label fnd:host/session:$STAMP" "$CALLS" \
  || fail "expected the verbatim (unslugged) Host/Session label added: $(cat "$CALLS")"
grep -q '^gh project' "$CALLS" && fail "board_stamp (issues-only) must never call gh project"
[ "$FAKE_LABELS" = " fnd:host/session:$STAMP" ] || fail "label state wrong after stamp: '$FAKE_LABELS'"
echo "PASS: board_stamp (issues-only) writes a verbatim fnd:host/session:* label, no Projects call"

# Round-trip: resolving the issue now must surface the SAME stamp text, exact
# case, under the flattened "host/Session" key (the key reconcile.sh/worklist.sh
# already read on the Projects-v2 path).
board_resolve_item 21 200
GOT_STAMP="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[0]["host/Session"] // "MISSING"')"
[ "$GOT_STAMP" = "$STAMP" ] || fail "stamp did not round-trip verbatim: expected '$STAMP', got '$GOT_STAMP'"
echo "PASS: a Host/Session stamp round-trips VERBATIM (no lowercasing) through the flattened host/Session key"

# Re-stamping with the SAME value is a no-op at the gh-call level (no
# duplicate add) — mirrors board_set_status's re-set idempotence.
: >"$CALLS"
board_stamp "ISSUE_200" "Host/Session" "$STAMP" || fail "re-stamping the same value should succeed"
grep -q -- '--add-label' "$CALLS" && fail "re-stamping the identical value must not re-add the label: $(cat "$CALLS")"
echo "PASS: re-stamping the identical Host/Session value is a no-op (no duplicate label add)"

# Clear: empty text removes the label, adds nothing (mirrors the Projects-v2
# --clear semantics, foundation #259 — build's epic park-back relies on this).
: >"$CALLS"
board_stamp "ISSUE_200" "Host/Session" "" || fail "board_stamp clear (issues-only) should succeed"
grep -q -- "--remove-label fnd:host/session:$STAMP" "$CALLS" \
  || fail "expected the stamp label removed on clear: $(cat "$CALLS")"
grep -q -- '--add-label' "$CALLS" && fail "a clear must not add any label: $(cat "$CALLS")"
[ "$FAKE_LABELS" = "" ] || fail "label state should be empty after clear, got: '$FAKE_LABELS'"
echo "PASS: board_stamp('') clears the Host/Session label without adding anything"

# =============================================================================
# 2. board_claim_contended
# =============================================================================

items_json() {  # $1=status $2=stamp -> one-item BOARD_ITEMS_JSON
  jq -nc --arg st "$1" --arg hs "$2" \
    '{"items":[{"id":"ISSUE_300","content":{"number":300,"title":"t"}}
      + (if $st != "" then {status:$st} else {} end)
      + (if $hs != "" then {"host/Session":$hs} else {} end)]}'
}

# 2a. not In Progress at all -> not contended, regardless of any stamp present.
BOARD_ITEMS_JSON="$(items_json "Ready" "otherhost:aaaaaaaa")"
if board_claim_contended 21 300 "myhost:bbbbbbbb" >/dev/null; then
  fail "a Ready item must never be contended"
fi
echo "PASS: board_claim_contended — a non-In-Progress item is never contended"

# 2b. In Progress, NO existing stamp -> not contended (half-claim adoption,
# the #103 failure-mode repair — claim writes unconditionally here).
BOARD_ITEMS_JSON="$(items_json "In Progress" "")"
if board_claim_contended 21 300 "myhost:bbbbbbbb" >/dev/null; then
  fail "an unstamped In-Progress item must be adoptable, not contended"
fi
echo "PASS: board_claim_contended — an unstamped In-Progress item is adoptable (not contended)"

# 2c. In Progress, SAME stamp -> not contended (idempotent self-reclaim).
BOARD_ITEMS_JSON="$(items_json "In Progress" "myhost:bbbbbbbb")"
if board_claim_contended 21 300 "myhost:bbbbbbbb" >/dev/null; then
  fail "re-claiming with your OWN stamp must not be contended"
fi
echo "PASS: board_claim_contended — re-claiming your own stamp is not contended (idempotent)"

# 2d. In Progress, DIFFERENT stamp -> CONTENDED; prints the foreign stamp.
BOARD_ITEMS_JSON="$(items_json "In Progress" "otherhost:aaaaaaaa")"
OUT="$(board_claim_contended 21 300 "myhost:bbbbbbbb")" || fail "expected board_claim_contended to report contended (rc 0)"
[ "$OUT" = "otherhost:aaaaaaaa" ] || fail "expected the foreign stamp printed, got: '$OUT'"
echo "PASS: board_claim_contended — a DIFFERENT stamp on an In-Progress item IS contended, foreign stamp printed"

# 2e. Projects-v2 board (board 3, unconfigured => default backend) — the SAME
# contention check now applies: a foreign stamp on an In-Progress item IS
# contended, exactly mirroring 2d. board_claim_contended takes no backend
# branch, so this proves the jq logic is driven purely by BOARD_ITEMS_JSON's
# shape (identical on both backends), not by _board_is_issues_only.
BOARD_ITEMS_JSON="$(items_json "In Progress" "otherhost:aaaaaaaa")"
OUT="$(board_claim_contended 3 300 "myhost:bbbbbbbb")" \
  || fail "a Projects-v2 board must ALSO detect a foreign-stamped In-Progress item as contended"
[ "$OUT" = "otherhost:aaaaaaaa" ] || fail "expected the foreign stamp printed on a Projects-v2 board, got: '$OUT'"
echo "PASS: board_claim_contended — a foreign stamp IS contended on a Projects-v2 board too (parity with issues-only)"

# 2f. Projects-v2 board, In Progress + SAME stamp -> not contended (idempotent
# self-reclaim, same as 2c) — proves the safe cases carry over too, not just
# the contended one.
BOARD_ITEMS_JSON="$(items_json "In Progress" "myhost:bbbbbbbb")"
if board_claim_contended 3 300 "myhost:bbbbbbbb" >/dev/null; then
  fail "re-claiming your OWN stamp on a Projects-v2 board must not be contended"
fi
echo "PASS: board_claim_contended — self-reclaim is not contended on a Projects-v2 board (parity with issues-only)"

# 2g. Projects-v2 board, In Progress + NO existing stamp -> not contended
# (half-claim adoption, same as 2b) on a Projects-v2 board too.
BOARD_ITEMS_JSON="$(items_json "In Progress" "")"
if board_claim_contended 3 300 "myhost:bbbbbbbb" >/dev/null; then
  fail "an unstamped In-Progress item on a Projects-v2 board must be adoptable, not contended"
fi
echo "PASS: board_claim_contended — half-claim adoption is not contended on a Projects-v2 board (parity with issues-only)"

# =============================================================================
# 3. board_sub_issues — child issue numbers (backend-agnostic, like its
#    board_parent_issue / board_blocked_by_open siblings)
# =============================================================================

_board_gh() {
  cat <<'JSON'
[
  { "number": 401, "title": "child A" },
  { "number": 402, "title": "child B" }
]
JSON
}
OUT="$(board_sub_issues 21 145)"
[ "$OUT" = "401
402" ] || fail "expected both children (401,402), got: [$OUT]"
echo "PASS: board_sub_issues prints child issue numbers, one per line"

_board_gh() { echo '[]'; }
OUT="$(board_sub_issues 21 149)"
[ -z "$OUT" ] || fail "a childless issue must print nothing, got: [$OUT]"
echo "PASS: board_sub_issues prints nothing for a childless issue"

# =============================================================================
# 4. claim.sh end-to-end against a fake issues-only repo
# =============================================================================

export SUBSET_HOST_LABEL="myhost"
unset TMUX || true
unset CMUX_WORKSPACE_ID || true
BOARD_CACHE_DIR="$(mktemp -d)"; export BOARD_CACHE_DIR
CLAIMS_LOG_DIR="$(mktemp -d)"; export CLAIMS_RAW_DIR="$CLAIMS_LOG_DIR"
export CLAUDE_CODE_SESSION_ID="bbbbbbbb-1111-2222-3333-444444444444"   # -> myhost:bbbbbbbb

# shellcheck source=scripts/claim.sh
source "$SCRIPTS_DIR/claim.sh"

# Stateful fake modeling ONE fake repo's issue state across a claim_main call:
# tracks open/closed + fnd: labels the same way test_issues_backend.sh's
# board_set_status case (case 6) and test_issues_claim_edges.sh's own §1 do.
# Re-defined here (after the §1/§3 overrides above) as the ONE override in
# effect for every §4 sub-case; each sub-case resets FAKE_STATE/FAKE_LABELS
# before calling run_claim.
CLAIM_ISSUE_NUM=0
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/$REPO/issues/$CLAIM_ISSUE_NUM")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":%s,"title":"claim target","state":"%s","labels":%s}' \
        "$CLAIM_ISSUE_NUM" "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --remove-label) FAKE_LABELS="$(printf '%s\n' $FAKE_LABELS | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label)    FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "issue close")  FAKE_STATE="closed" ;;
    "issue reopen") FAKE_STATE="open" ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

run_claim() {  # $1=issue
  issue="$1"; PROJECT_NUMBER=21; CLAIM_ISSUE_NUM="$1"
  : >"$CALLS"
  set +e
  ( set -e; claim_main ) >"$WORK/out.log" 2>&1
  RC=$?
  set -e
}

# --- 4a. happy path: an unclaimed (Ready) issue gets claimed -----------------
FAKE_STATE="open"; FAKE_LABELS="fnd:status:ready"
run_claim 500
[ "$RC" -eq 0 ] || fail "4a: happy-path claim should succeed (RC=$RC)\n$(cat "$WORK/out.log")\n$(cat "$CALLS")"
grep -q -- '--remove-label fnd:status:ready' "$CALLS" || fail "4a: expected the Ready label removed"
grep -q -- '--add-label fnd:status:in-progress' "$CALLS" || fail "4a: expected the In Progress label added"
grep -q -- '--add-label fnd:host/session:myhost:bbbbbbbb' "$CALLS" || fail "4a: expected the Host/Session stamp label added"
[ "$FAKE_STATE" = "open" ] || fail "4a: issue should stay open (In Progress, not Done)"
echo "PASS: 4a claim.sh (issues-only) happy path — status label swapped + Host/Session stamped"

# --- 4b. contended: a DIFFERENT session already holds the claim --------------
# claim.sh must refuse (non-zero) and issue ZERO writes — not even a partial
# label change — because the contention check runs BEFORE any write, using
# only the already-resolved read.
FAKE_STATE="open"; FAKE_LABELS="fnd:status:in-progress fnd:host/session:otherhost:aaaaaaaa"
run_claim 501
[ "$RC" -ne 0 ] || fail "4b: a contended claim must be refused (RC=$RC)"
grep -qi "refused" "$WORK/out.log" || fail "4b: expected a refusal message, got:\n$(cat "$WORK/out.log")"
grep -q "otherhost:aaaaaaaa" "$WORK/out.log" || fail "4b: refusal message should name the foreign stamp:\n$(cat "$WORK/out.log")"
GH_CALL_COUNT="$(grep -c '^gh ' "$CALLS" || true)"
[ "$GH_CALL_COUNT" -eq 1 ] || fail "4b: expected exactly ONE gh call (the read), got $GH_CALL_COUNT:\n$(cat "$CALLS")"
grep -q '^gh api' "$CALLS" || fail "4b: the one call must be the read, not a write:\n$(cat "$CALLS")"
grep -q '^gh issue edit\|^gh issue close\|^gh issue reopen' "$CALLS" \
  && fail "4b: a contended claim must issue ZERO writes:\n$(cat "$CALLS")"
[ "$FAKE_LABELS" = "fnd:status:in-progress fnd:host/session:otherhost:aaaaaaaa" ] \
  || fail "4b: label state must be untouched after a refused claim: '$FAKE_LABELS'"
echo "PASS: 4b claim.sh (issues-only) refuses a contended claim with ZERO writes, names the foreign stamp"

# --- 4c. adoption: In Progress but unstamped (half-claim repair) -------------
FAKE_STATE="open"; FAKE_LABELS="fnd:status:in-progress"
run_claim 502
[ "$RC" -eq 0 ] || fail "4c: adoption of an unstamped In-Progress item should succeed (RC=$RC)\n$(cat "$WORK/out.log")"
grep -q -- '--add-label fnd:host/session:myhost:bbbbbbbb' "$CALLS" || fail "4c: expected the adoption stamp added"
echo "PASS: 4c claim.sh (issues-only) adopts (stamps) an unstamped In-Progress item, same as the Projects-v2 path"

echo
echo "ALL PASS: test_issues_claim_edges.sh"
