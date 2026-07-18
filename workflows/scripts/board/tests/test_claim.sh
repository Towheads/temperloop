#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/claim.sh. Zero network: we SOURCE claim.sh
# (its execute-guard suppresses the auto-run when sourced), override
# board_resolve_item to inject a canned board (so no GraphQL), and override the
# board.sh `_board_gh` seam to RECORD every `project item-edit` (and optionally
# FAIL the Host/Session stamp edit). Each case sets $issue / $PROJECT_NUMBER,
# drives claim_main, and asserts which item-edits were issued and IN WHAT ORDER.
#
# The property under test is #135's fix: the claim stamps Host/Session FIRST and
# flips Status→In Progress LAST, so a stamp failure leaves the item Ready (no
# ownerless In-Progress lock), never status-flipped-but-unstamped.
#
# Covered:
#   1) stamp failure is fail-safe — the Status/In-Progress edit is NEVER issued.
#   2) happy path ordering      — Host/Session edit precedes the Status edit.
#   3) adoption                 — re-claiming an unstamped In-Progress item stamps
#                                 it and succeeds (no owner-conflict guard).
#   4) contended refusal        — a foreign-stamped In-Progress item on a
#                                 Projects-v2 board is refused BEFORE any write
#                                 (the board_claim_contended pre-check, extended
#                                 from issues-only to Projects-v2).
#   5) claims log emit (F#728)  — a claim appends a JSONL record to CLAIMS_RAW_DIR
#                                 whose session_id is the RAW full session UUID,
#                                 NOT the truncated host:sess8 board stamp.
#
# The board_resolve_item override sets BOARD_* globals (and cases set PROJECT_NUMBER)
# that claim.sh / board.sh accessors read in OTHER functions — shellcheck can't see
# that cross-function use, so silence SC2034 file-wide (cf. lib/board.sh:32; the
# directive must precede the first command to apply to the whole file). CI excludes
# tests/ from shellcheck anyway; this keeps a whole-tree local run clean.
# shellcheck disable=SC2034
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Pin host so the stamp is deterministic; neutralize every terminal-marker surface
# so claim_main's step 3 is a guaranteed no-op (claim_marker_set self-guards per
# surface). TMUX for the tmux branch; CMUX_WORKSPACE_ID for the cmux branch (GH
# #348) — the suite itself may run inside a cmux session, and without this unset
# the marker block would shell out to the real cmux CLI.
export SUBSET_HOST_LABEL="testhost"
unset TMUX || true
unset CMUX_WORKSPACE_ID || true
# Keep cache busts off the real cache dir.
BOARD_CACHE_DIR="$(mktemp -d)"; export BOARD_CACHE_DIR
# Keep the claims-log emit (F#728) off the REAL raw lake (CLAIMS_RAW_DIR_DEFAULT
# points at $HOME/dev/foundation/meta/data/raw — the actual checkout, not this
# worktree) for every case, not just the one that inspects it.
CLAIMS_LOG_DIR="$(mktemp -d)"; export CLAIMS_RAW_DIR="$CLAIMS_LOG_DIR"

# shellcheck source=scripts/claim.sh
source "$SCRIPTS_DIR/claim.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# Canned board state — board_field_id/board_option_id/board_item_id read these.
# Field NAMES must match board.sh's BOARD_FIELD_* / BOARD_OPT_* constants.
FIELDS_JSON='{"fields":[
  {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_inprogress","name":"In Progress"},{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"}]},
  {"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}
]}'
ITEM_STATUS="Ready"        # per-case: starting Status of the item
ITEM_HOSTSESSION=""        # per-case: starting Host/Session stamp
FAIL_STAMP=0               # per-case: when 1, the Host/Session item-edit returns non-zero
EDITS=""                   # per-case: temp file recording each edit's --field-id

# Inject a canned single-item board without any GraphQL — claim_main calls this
# instead of the real one. Sets the SAME globals the real board_resolve_item does.
board_resolve_item() {
  BOARD_PROJECT_ID="PVT_TEST"
  BOARD_FIELDS_JSON="$FIELDS_JSON"
  BOARD_ITEMS_JSON="{\"items\":[{\"id\":\"PVTI_item\",\"content\":{\"number\":${issue},\"title\":\"Test item\"},\"status\":\"${ITEM_STATUS}\",\"host/Session\":\"${ITEM_HOSTSESSION}\"}]}"
  BOARD_CURRENT="$1"
}

# Override the board write seam: record the --field-id of every item-edit to
# $EDITS (one per line, in call order), and fail the Host/Session edit when armed.
# board_set_status / board_stamp are the only callers, each via `project item-edit`.
_board_gh() {
  if [ "$1 $2" = "project item-edit" ]; then
    local fid="" want_fid=0 a
    for a in "$@"; do
      if [ "$want_fid" = 1 ]; then fid="$a"; want_fid=0; continue; fi
      [ "$a" = "--field-id" ] && want_fid=1
    done
    printf '%s\n' "$fid" >>"$EDITS"
    if [ "$FAIL_STAMP" = 1 ] && [ "$fid" = "PVTF_hostsession" ]; then
      return 1
    fi
    return 0
  fi
  echo "test _board_gh: unexpected call '$*'" >&2
  return 3
}

# Drive claim_main in a SUBSHELL so a `set -e` abort (the fail-safe path) exits the
# subshell, not this test. $EDITS is a file, so the override's records survive the
# subshell. The subshell re-arms `set -e` EXPLICITLY: a subshell used as the left
# operand of `||` inherits set-e *suppression*, which would mask the very abort we
# test for — so we isolate the parent with `set +e` and force set -e inside.
run_claim() {
  EDITS="$(mktemp)"
  set +e
  ( set -e; claim_main ) >/dev/null 2>&1
  RC=$?
  set -e
}

# --- case 1: stamp failure is fail-safe ---------------------------------------
# The Host/Session edit fails; the Status/In-Progress edit must NEVER be issued,
# so the item is left Ready (no ownerless In-Progress lock — the #135 fix).
issue=123; PROJECT_NUMBER=4
ITEM_STATUS="Ready"; ITEM_HOSTSESSION=""; FAIL_STAMP=1
run_claim
[ "$RC" -ne 0 ] || fail "case1: claim_main should have failed on the stamp error (RC=$RC)\n$(cat "$EDITS")"
grep -qx "PVTF_hostsession" "$EDITS" \
  || fail "case1: expected a Host/Session stamp attempt\n$(cat "$EDITS")"
grep -qx "PVTSSF_status" "$EDITS" \
  && fail "case1: Status/In-Progress edit was issued — lock flipped despite stamp failure\n$(cat "$EDITS")"
echo "PASS: case 1 stamp failure leaves the item Ready (Status edit never issued)"

# --- case 2: happy path ordering ----------------------------------------------
# Both edits issue, Host/Session BEFORE Status (stamp-first, commit-last).
issue=124; PROJECT_NUMBER=4
ITEM_STATUS="Ready"; ITEM_HOSTSESSION=""; FAIL_STAMP=0
run_claim
[ "$RC" -eq 0 ] || fail "case2: claim_main should have succeeded (RC=$RC)\n$(cat "$EDITS")"
[ "$(sed -n '1p' "$EDITS")" = "PVTF_hostsession" ] \
  || fail "case2: first edit must be the Host/Session stamp\n$(cat "$EDITS")"
[ "$(sed -n '2p' "$EDITS")" = "PVTSSF_status" ] \
  || fail "case2: second edit must be the Status flip\n$(cat "$EDITS")"
echo "PASS: case 2 happy path stamps before it flips status"

# --- case 3: adoption of an unstamped In-Progress item ------------------------
# Re-claiming an item already In Progress but with no owner stamp must stamp it
# and succeed (claim writes unconditionally — repairs a half-claim like #103).
issue=103; PROJECT_NUMBER=4
ITEM_STATUS="In Progress"; ITEM_HOSTSESSION=""; FAIL_STAMP=0
run_claim
[ "$RC" -eq 0 ] || fail "case3: re-claim should succeed (RC=$RC)\n$(cat "$EDITS")"
grep -qx "PVTF_hostsession" "$EDITS" \
  || fail "case3: adoption must issue the Host/Session stamp\n$(cat "$EDITS")"
echo "PASS: case 3 adoption stamps an unstamped In-Progress item"

# --- case 4: contended claim refused on a Projects-v2 board -------------------
# The item is In Progress and stamped to a DIFFERENT host:session. claim_main
# must refuse (non-zero) BEFORE issuing any item-edit — this is the
# board_claim_contended pre-check (originally issues-only-only, foundation
# #800) now also firing on the Projects-v2 path it used to silently skip.
issue=127; PROJECT_NUMBER=4
ITEM_STATUS="In Progress"; ITEM_HOSTSESSION="otherhost:aaaaaaaa"; FAIL_STAMP=0
run_claim
[ "$RC" -ne 0 ] || fail "case4: a contended claim on a Projects-v2 board must be refused (RC=$RC)"
[ ! -s "$EDITS" ] || fail "case4: a contended claim must issue ZERO writes\n$(cat "$EDITS")"
echo "PASS: case 4 contended claim refused on a Projects-v2 board, zero writes issued"

# --- case 5: claims log emit (F#728) ------------------------------------------
# A successful claim appends one JSONL record to CLAIMS_RAW_DIR/claims-YYYY-MM.jsonl
# whose session_id is the RAW, FULL $CLAUDE_CODE_SESSION_ID UUID — NOT the
# truncated `host:sess8` board stamp (`testhost:c33dce41`). The cost rollup joins
# on session_id[:8], so shipping the host-prefixed stamp here would join as
# `testhost:c3` garbage and silently break attribution — this is the regression
# this case guards against.
FAKE_SESSION="c33dce41-b7e1-48a9-8b61-c38e4202f01d"
issue=126; PROJECT_NUMBER=4
ITEM_STATUS="Ready"; ITEM_HOSTSESSION=""; FAIL_STAMP=0
CLAUDE_CODE_SESSION_ID="$FAKE_SESSION" run_claim
[ "$RC" -eq 0 ] || fail "case5: claim_main should have succeeded (RC=$RC)\n$(cat "$EDITS")"

claims_month="$(date -u +%Y-%m)"
claims_file="$CLAIMS_LOG_DIR/claims-$claims_month.jsonl"
[ -f "$claims_file" ] || fail "case5: expected a claims log file at $claims_file"

rec="$(grep -F "\"issue\":126" "$claims_file" | tail -n1)"
[ -n "$rec" ] || fail "case5: no claims-log record found for issue 126\n$(cat "$claims_file")"

rec_session="$(printf '%s' "$rec" | jq -r '.session_id')"
[ "$rec_session" = "$FAKE_SESSION" ] \
  || fail "case5: session_id must be the RAW full UUID ($FAKE_SESSION), got '$rec_session'\n$rec"
case "$rec_session" in
  testhost:*) fail "case5: session_id is the truncated host:sess8 board stamp, not the raw UUID\n$rec" ;;
esac
[ "$(printf '%s' "$rec" | jq -r '.board')" = "4" ] \
  || fail "case5: board must be the numeric PROJECT_NUMBER (4)\n$rec"
[ "$(printf '%s' "$rec" | jq -r '.item_id')" = "PVTI_item" ] \
  || fail "case5: item_id must be the resolved board item id\n$rec"
echo "PASS: case 5 claims log emits the raw session UUID (not the host:sess8 stamp)"

echo
echo "PASS: all claim.sh atomicity assertions passed"
