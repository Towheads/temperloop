#!/usr/bin/env bash
#
# Interleaved race test: an explicit `/assess` override racing a live
# `/sweep` pool admission over the SAME epic member does not double-drive it
# (epic #1847 Produces #5, item assess-refusal-guard, temperloop#1854).
#
# This is deliberately NOT a re-run of either side's own precondition tests
# (test_assess_operational_refusal.sh covers the refusal predicate;
# test_sweep_epic_admission.sh covers the admission predicate). Both of
# those are pure, stateless combinators — each answers "would I proceed?"
# against a SNAPSHOT, and a snapshot both actors read at the same moment
# says yes to BOTH of them simultaneously (the TOCTOU window: two probes,
# each individually correct against stale state, both green-lighting the
# same underlying issue). This test proves the two probes passing
# concurrently is NOT what prevents a double-drive — the actual belt is
# board.sh's claim-first mutual exclusion (board_claim_contended, the same
# primitive claim.sh and any /build- or /sweep-driven claim already uses):
# whichever actor's claim (Host/Session stamp + Status->In Progress) COMMITS
# first wins; the second actor's OWN claim attempt, checked against the
# now-updated board state, is refused before any write.
#
# Zero network: sources claim.sh (execute-guard suppresses the auto-run),
# overrides board_resolve_item + the board.sh `_board_gh` seam exactly as
# test_claim.sh does — but where test_claim.sh resets the fixture per case,
# this test keeps ONE shared, mutable board state across two sequential
# claim_main invocations, so the second invocation's read reflects the
# first invocation's write (the interleaving under test).
#
# shellcheck disable=SC2034
set -euo pipefail

export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SCRIPTS_DIR="$(cd "$HERE/../../board" && pwd)"
BUILD_SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

export SUBSET_HOST_LABEL="testhost"
unset TMUX || true
unset CMUX_WORKSPACE_ID || true
BOARD_CACHE_DIR="$(mktemp -d)"; export BOARD_CACHE_DIR
CLAIMS_LOG_DIR="$(mktemp -d)"; export CLAIMS_RAW_DIR="$CLAIMS_LOG_DIR"

cleanup() { rm -rf "$BOARD_CACHE_DIR" "$CLAIMS_LOG_DIR" "${STATE_FILE:-}" "${EDITS:-}"; }
trap cleanup EXIT

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# --- Step 1: both probes pass independently against the SAME stale snapshot --
# The member issue (#9001) is Ready, unclaimed. Neither probe knows about the
# other actor's concurrent intent — this is the window the claim step must
# close, not the probes themselves.
REFUSAL_OUT="$(printf '%s' '{"pipeline_drive_invoked":false,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":false,"override":true}' \
  | "$BUILD_SCRIPTS_DIR/assess-operational-refusal.sh" -)"
[ "$(printf '%s' "$REFUSAL_OUT" | jq -r '.refuse')" = "false" ] \
  || fail "setup: assess's own probe should proceed (override) against the stale snapshot, got: $REFUSAL_OUT"

ADMISSION_OUT="$(printf '%s' '{"setting_enabled":true,"reader_helpers_available":true,"epic_reads_available":true,"epic_work_class":"Operational","any_foundational_in_group":false,"mixed_class_group":false,"live_plan_note":false,"epic_mid_build":false,"edges_considered_marker":true}' \
  | "$BUILD_SCRIPTS_DIR/sweep-epic-admission.sh" -)"
[ "$(printf '%s' "$ADMISSION_OUT" | jq -r '.admit')" = "true" ] \
  || fail "setup: sweep's own probe should admit against the stale snapshot, got: $ADMISSION_OUT"

echo "PASS: setup — both /assess's override probe and /sweep's admission probe independently proceed against the same stale (unclaimed) snapshot"

# --- Step 2: source claim.sh, THEN install a SHARED, mutable board fixture --
# Order is load-bearing (mirrors test_claim.sh): claim.sh sources board.sh,
# which DEFINES board_resolve_item — so the override below must come AFTER
# the source, or board.sh's real definition (a live `gh` call) clobbers it.
# shellcheck source=/dev/null
source "$BOARD_SCRIPTS_DIR/claim.sh"

# Shared board state lives in a FILE, not a shell variable — run_claim below
# runs claim_main inside a subshell (so a `set -e` abort in the fail-safe path
# exits the subshell, not this test, matching test_claim.sh's own run_claim),
# and a subshell's variable writes never escape back to the parent. A write
# committed by _board_gh (itself invoked from inside that subshell) has to
# reach the NEXT invocation's read, so it goes through this file instead —
# the actual persistence primitive under test is the board API's, not a shell
# variable's, so a file is the truer stand-in anyway.
STATE_FILE="$(mktemp)"
printf 'Ready\n\n' >"$STATE_FILE"   # line1=status, line2=host/session stamp
item_status()  { sed -n '1p' "$STATE_FILE"; }
item_hostsession() { sed -n '2p' "$STATE_FILE"; }
EDITS=""

board_resolve_item() {
  local st hs
  st="$(item_status)"; hs="$(item_hostsession)"
  BOARD_PROJECT_ID=""
  BOARD_FIELDS_JSON='{"fields":[]}'
  BOARD_ITEMS_JSON="{\"items\":[{\"id\":\"ISSUE_${issue}\",\"content\":{\"number\":${issue},\"title\":\"Test epic member\"},\"status\":\"${st}\",\"host/Session\":\"${hs}\"}]}"
  BOARD_CURRENT="$1"
}

# _board_gh is the SAME seam test_claim.sh stubs, with writes committed to
# STATE_FILE (not a shell variable — see the note above) so the second
# claim_main invocation's board_resolve_item call above reflects the first
# invocation's committed writes — the actual interleaving under test.
_board_gh() {
  case "$1 $2" in
    "api repos/Towheads/foundation/issues/${issue}")
      local st hs labels=""
      st="$(item_status)"; hs="$(item_hostsession)"
      [ -n "$hs" ] && labels="{\"name\":\"fnd:host/session:$hs\"}"
      if [ "$st" = "In Progress" ]; then
        [ -n "$labels" ] && labels="$labels,"
        labels="${labels}{\"name\":\"fnd:status:in-progress\"}"
      elif [ "$st" = "Ready" ]; then
        [ -n "$labels" ] && labels="$labels,"
        labels="${labels}{\"name\":\"fnd:status:ready\"}"
      fi
      printf '{"state":"open","title":"Test epic member","labels":[%s]}' "$labels"
      return 0 ;;
    "label create") return 0 ;;
    "issue edit")
      local a mark="" want=0
      for a in "$@"; do
        if [ "$want" = 1 ]; then
          case "$a" in
            fnd:host/session:*) mark="hostsession:${a#fnd:host/session:}" ;;
            fnd:status:*)       mark="status:${a#fnd:status:}" ;;
          esac
          want=0; continue
        fi
        [ "$a" = "--add-label" ] && want=1
      done
      if [ -n "$mark" ]; then
        printf '%s\n' "$mark" >>"$EDITS"
        # COMMIT the write to STATE_FILE — this is what makes the second
        # actor's later read see the first actor's claim.
        case "$mark" in
          hostsession:*) printf '%s\n%s\n' "$(item_status)" "${mark#hostsession:}" >"$STATE_FILE" ;;
          status:in-progress) printf 'In Progress\n%s\n' "$(item_hostsession)" >"$STATE_FILE" ;;
        esac
      fi
      return 0 ;;
    "issue reopen" | "issue close") return 0 ;;
  esac
  echo "test _board_gh: unexpected call '$*'" >&2
  return 3
}

run_claim() {  # $1 = fake session id for the stamp
  EDITS="$(mktemp)"
  set +e
  ( set -e; CLAUDE_CODE_SESSION_ID="$1" claim_main ) >/dev/null 2>&1
  RC=$?
  set -e
}

# --- Step 3: sweep's live admission claims the member FIRST ------------------
issue=9001; PROJECT_NUMBER=4
SWEEP_SESSION="aaaaaaaa-0000-0000-0000-000000000001"
run_claim "$SWEEP_SESSION"
[ "$RC" -eq 0 ] || fail "sweep's claim (first) should succeed, RC=$RC"$'\n'"$(cat "$EDITS")"
[ "$(item_status)" = "In Progress" ] || fail "sweep's claim should have flipped the item to In Progress, got: $(item_status)"
[ "$(item_hostsession)" = "testhost:${SWEEP_SESSION:0:8}" ] \
  || fail "sweep's claim should have stamped its own host/session, got: $(item_hostsession)"
echo "PASS: sweep's live pool admission claims the member first (In Progress, stamped testhost:${SWEEP_SESSION:0:8})"

# --- Step 4: assess's override, racing in, attempts its OWN claim on the -----
# SAME member — must be refused BEFORE any write (board_claim_contended),
# even though its earlier probe (Step 1 above) had already independently
# green-lit proceeding.
ASSESS_SESSION="bbbbbbbb-0000-0000-0000-000000000002"
run_claim "$ASSESS_SESSION"
[ "$RC" -ne 0 ] || fail "assess's racing claim (second) must be refused, RC=$RC"
[ ! -s "$EDITS" ] || fail "assess's racing claim must issue ZERO writes once contended"$'\n'"$(cat "$EDITS")"
[ "$(item_hostsession)" = "testhost:${SWEEP_SESSION:0:8}" ] \
  || fail "the member's stamp must still read sweep's — assess's refused claim must not have overwritten it, got: $(item_hostsession)"
echo "PASS: assess's override, racing in second, is refused by claim-first (board_claim_contended) — zero writes, sweep's claim stands"
echo "PASS: the member was driven by exactly ONE actor (sweep) — no double-drive, despite both probes independently proceeding"

echo
echo "PASS: assess-override vs sweep-admission interleaved race — claim-first parks the losing side"
