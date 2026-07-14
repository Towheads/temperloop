#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/unclaim.sh — the board-status half of undoing
# claim.sh (In Progress → Ready). Zero network: we SOURCE unclaim.sh (its execute-
# guard suppresses the auto-run when sourced), override board_resolve_item to inject
# a canned board (so no GraphQL), and override board.sh's `_board_gh` seam to RECORD
# every `project item-edit`. Each case sets $issue / $PROJECT_NUMBER, drives
# unclaim_main, and asserts which Status edit (if any) was issued.
#
# The properties under test (#1157):
#   1) In Progress → Ready — exactly one Status edit, to the Ready option, is issued.
#   2) already Ready       — NO edit (idempotent no-op; the current-status guard).
#   3) Done                — NO edit (idempotent no-op).
#   4) foreign-stamped In Progress → STILL released — the DELIBERATE divergence from
#      claim.sh's contended-refusal: unclaim releases regardless of the owner stamp
#      (a stranded claim was stamped by a now-dead session, so an owner check would
#      refuse the exact case this exists for).
#   5) issue not on the board → NO edit (idempotent no-op).
#
# The board_resolve_item override sets BOARD_* globals that unclaim.sh / board.sh
# accessors read in OTHER functions — shellcheck can't see that cross-function use,
# so silence SC2034 file-wide (mirrors test_claim.sh). CI excludes tests/ from
# shellcheck anyway; this keeps a whole-tree local run clean.
# shellcheck disable=SC2034
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
export SUBSET_HOST_LABEL="testhost"
# Keep cache busts off the real cache dir.
BOARD_CACHE_DIR="$(mktemp -d)"; export BOARD_CACHE_DIR

# shellcheck source=scripts/unclaim.sh
source "$SCRIPTS_DIR/unclaim.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# Canned board state — board_option_id/board_item_id read these. Field NAMES must
# match board.sh's BOARD_FIELD_* / BOARD_OPT_* constants.
FIELDS_JSON='{"fields":[
  {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_inprogress","name":"In Progress"},{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"}]},
  {"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}
]}'
ITEM_STATUS="In Progress"   # per-case: starting Status of the item
ITEM_HOSTSESSION=""         # per-case: starting Host/Session stamp
ITEM_ON_BOARD=1             # per-case: 0 → resolve returns no matching item (off-board)
EDITS=""                    # per-case: temp file recording "<field-id> <option-id>" per edit

# Inject a canned single-item board without any GraphQL — unclaim_main calls this
# instead of the real one. Sets the SAME globals the real board_resolve_item does.
board_resolve_item() {
  BOARD_PROJECT_ID="PVT_TEST"
  BOARD_FIELDS_JSON="$FIELDS_JSON"
  if [ "$ITEM_ON_BOARD" = 1 ]; then
    BOARD_ITEMS_JSON="{\"items\":[{\"id\":\"PVTI_item\",\"content\":{\"number\":${issue},\"title\":\"Test item\"},\"status\":\"${ITEM_STATUS}\",\"host/Session\":\"${ITEM_HOSTSESSION}\"}]}"
  else
    BOARD_ITEMS_JSON='{"items":[]}'
  fi
  BOARD_CURRENT="$1"
}

# Override the board write seam: record the --field-id AND --single-select-option-id
# of every item-edit to $EDITS (one "<fid> <oid>" line per call, in order).
# board_set_status is the only caller here, via `project item-edit`.
_board_gh() {
  if [ "$1 $2" = "project item-edit" ]; then
    local fid="" oid="" want="" a
    for a in "$@"; do
      case "$want" in fid) fid="$a"; want="" ;; oid) oid="$a"; want="" ;; esac
      case "$a" in --field-id) want=fid ;; --single-select-option-id) want=oid ;; esac
    done
    printf '%s %s\n' "$fid" "$oid" >>"$EDITS"
    return 0
  fi
  echo "test _board_gh: unexpected call '$*'" >&2
  return 3
}

# Drive unclaim_main in a SUBSHELL so a `set -e` abort exits the subshell, not this
# test. $EDITS is a file, so the override's records survive the subshell.
run_unclaim() {
  EDITS="$(mktemp)"
  set +e
  ( set -e; unclaim_main ) >/dev/null 2>&1
  RC=$?
  set -e
}

# --- case 1: In Progress → Ready ----------------------------------------------
# One Status edit, to the Ready option (opt_ready), is issued; unclaim_main succeeds.
issue=201; PROJECT_NUMBER=4
ITEM_STATUS="In Progress"; ITEM_HOSTSESSION=""; ITEM_ON_BOARD=1
run_unclaim
[ "$RC" -eq 0 ] || fail "case1: unclaim_main should have succeeded (RC=$RC)\n$(cat "$EDITS")"
[ "$(wc -l <"$EDITS" | tr -d ' ')" = "1" ] \
  || fail "case1: expected exactly one item-edit\n$(cat "$EDITS")"
grep -qx "PVTSSF_status opt_ready" "$EDITS" \
  || fail "case1: expected a Status→Ready edit (PVTSSF_status opt_ready)\n$(cat "$EDITS")"
echo "PASS: case 1 In Progress → Ready issues one Status→Ready edit"

# --- case 2: already Ready → no-op --------------------------------------------
issue=202; PROJECT_NUMBER=4
ITEM_STATUS="Ready"; ITEM_HOSTSESSION=""; ITEM_ON_BOARD=1
run_unclaim
[ "$RC" -eq 0 ] || fail "case2: a no-op must still succeed (RC=$RC)"
[ ! -s "$EDITS" ] || fail "case2: an already-Ready item must issue ZERO edits\n$(cat "$EDITS")"
echo "PASS: case 2 already-Ready item is an idempotent no-op (zero edits)"

# --- case 3: Done → no-op -----------------------------------------------------
issue=203; PROJECT_NUMBER=4
ITEM_STATUS="Done"; ITEM_HOSTSESSION=""; ITEM_ON_BOARD=1
run_unclaim
[ "$RC" -eq 0 ] || fail "case3: a no-op must still succeed (RC=$RC)"
[ ! -s "$EDITS" ] || fail "case3: a Done item must issue ZERO edits\n$(cat "$EDITS")"
echo "PASS: case 3 Done item is an idempotent no-op (zero edits)"

# --- case 4: foreign-stamped In Progress → STILL released ---------------------
# The deliberate divergence from claim.sh: unclaim releases regardless of who owns
# the stamp (a stranded claim was stamped by a dead session).
issue=204; PROJECT_NUMBER=4
ITEM_STATUS="In Progress"; ITEM_HOSTSESSION="otherhost:aaaaaaaa"; ITEM_ON_BOARD=1
run_unclaim
[ "$RC" -eq 0 ] || fail "case4: a foreign-stamped release must succeed (RC=$RC)\n$(cat "$EDITS")"
grep -qx "PVTSSF_status opt_ready" "$EDITS" \
  || fail "case4: a foreign-stamped In-Progress item must STILL be released to Ready\n$(cat "$EDITS")"
echo "PASS: case 4 foreign-stamped In-Progress item is released regardless of owner"

# --- case 5: issue not on the board → no-op -----------------------------------
issue=205; PROJECT_NUMBER=4
ITEM_STATUS="In Progress"; ITEM_HOSTSESSION=""; ITEM_ON_BOARD=0
run_unclaim
[ "$RC" -eq 0 ] || fail "case5: an off-board issue must be a no-op success (RC=$RC)"
[ ! -s "$EDITS" ] || fail "case5: an off-board issue must issue ZERO edits\n$(cat "$EDITS")"
echo "PASS: case 5 an issue not on the board is an idempotent no-op (zero edits)"

echo "ALL unclaim.sh tests passed"
