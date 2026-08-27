#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/assess-operational-refusal.sh — the
# deterministic `/assess` Step 1 mutual-exclusion guard predicate (epic
# #1847 Produces #5, item assess-refusal-guard, temperloop#1854).
#
# Entirely OFFLINE: synthetic JSON fixtures on disk, zero `gh` calls, zero
# board reads (mirrors test_sweep_epic_admission.sh's convention).
#
# Covers:
#   1. pipeline_drive_invoked=true -> ALWAYS proceeds (pipeline-drive-carve-out),
#      even with the setting on, epic_work_class=Operational, and no
#      Foundational label anywhere — the carve-out that keeps the
#      un-rewired autonomous router from refusing itself in a loop. This is
#      the "pipeline-invoked pass-through" fixture the acceptance criterion
#      names.
#   2. setting_enabled=false -> proceeds (setting-off), regardless of class.
#   3. epic_work_class != "Operational" -> proceeds (not-operational-epic).
#   4. any_foundational_in_group=true -> proceeds (foundational-wins), even
#      with epic_work_class=Operational.
#   5. The refusal case itself: setting on, not pipeline-drive-invoked,
#      Operational, no Foundational anywhere, no override -> REFUSED
#      (operational-admitted-elsewhere). This is the "fixture test for
#      refusal" the acceptance criterion names.
#   6. override=true on an otherwise-refusing input -> proceeds (override),
#      override_logged=true.
#   7. override=true on an ALREADY-proceeding input (e.g. setting off) is
#      inert -> override_logged stays false (nothing to override).
#   8. Precedence: pipeline_drive_invoked wins over an explicit override=false
#      AND over every other admit-unfavorable field simultaneously — proves
#      branch 1 is checked first, not merely reachable.
#   9. (see below) an all-absent input falls back to the pre-guard proceed
#      default.
#  10. pipeline_drive_invoked=true with EVERY other field absent (assess.md
#      Step 1's reordered guard: item 1 detects pipeline-drive-invoked
#      before item 2's label read even runs, so on this path the read is
#      never attempted — a skipped read and a failed one look identical
#      here) -> still proceeds (pipeline-drive-carve-out). Round-4
#      escalation HIGH finding 1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../assess-operational-refusal.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

run() {  # $1 = json fixture -> sets $REFUSE $REASON $OVERRIDE_LOGGED
  local out
  out="$(printf '%s' "$1" | "$SCRIPT" -)"
  REFUSE="$(printf '%s' "$out" | jq -r '.refuse')"
  REASON="$(printf '%s' "$out" | jq -r '.reason')"
  OVERRIDE_LOGGED="$(printf '%s' "$out" | jq -r '.override_logged')"
}

# --- case 1: pipeline-drive-invoked pass-through (the carve-out) -------------
run '{"pipeline_drive_invoked":true,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":false,"override":false}'
[ "$REFUSE" = "false" ] || fail "case1: pipeline-drive-invoked must proceed, got refuse=$REFUSE"
[ "$REASON" = "pipeline-drive-carve-out" ] || fail "case1: expected reason pipeline-drive-carve-out, got $REASON"
echo "PASS: case 1 pipeline-drive-invoked always proceeds, even Operational+setting-on"

# --- case 2: setting off ------------------------------------------------------
run '{"pipeline_drive_invoked":false,"setting_enabled":false,"epic_work_class":"Operational","any_foundational_in_group":false,"override":false}'
[ "$REFUSE" = "false" ] || fail "case2: setting-off must proceed, got refuse=$REFUSE"
[ "$REASON" = "setting-off" ] || fail "case2: expected reason setting-off, got $REASON"
echo "PASS: case 2 setting-off proceeds regardless of class"

# --- case 3: Foundational epic ------------------------------------------------
run '{"pipeline_drive_invoked":false,"setting_enabled":true,"epic_work_class":"Foundational","any_foundational_in_group":false,"override":false}'
[ "$REFUSE" = "false" ] || fail "case3: Foundational epic must proceed, got refuse=$REFUSE"
[ "$REASON" = "not-operational-epic" ] || fail "case3: expected reason not-operational-epic, got $REASON"
echo "PASS: case 3 non-Operational epic proceeds"

# --- case 4: Foundational-wins in a mixed group -------------------------------
run '{"pipeline_drive_invoked":false,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":true,"override":false}'
[ "$REFUSE" = "false" ] || fail "case4: Foundational-wins must proceed, got refuse=$REFUSE"
[ "$REASON" = "foundational-wins" ] || fail "case4: expected reason foundational-wins, got $REASON"
echo "PASS: case 4 Foundational-anywhere-in-group wins over Operational"

# --- case 5: the refusal case itself ------------------------------------------
run '{"pipeline_drive_invoked":false,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":false,"override":false}'
[ "$REFUSE" = "true" ] || fail "case5: expected refusal, got refuse=$REFUSE"
[ "$REASON" = "operational-admitted-elsewhere" ] || fail "case5: expected reason operational-admitted-elsewhere, got $REASON"
[ "$OVERRIDE_LOGGED" = "false" ] || fail "case5: no override was given — override_logged must be false"
echo "PASS: case 5 refuses an Operational epic with the setting on, attended, no override"

# --- case 6: explicit override on an otherwise-refusing input ----------------
run '{"pipeline_drive_invoked":false,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":false,"override":true}'
[ "$REFUSE" = "false" ] || fail "case6: override must proceed, got refuse=$REFUSE"
[ "$REASON" = "override" ] || fail "case6: expected reason override, got $REASON"
[ "$OVERRIDE_LOGGED" = "true" ] || fail "case6: override_logged must be true when the override actually changed the outcome"
echo "PASS: case 6 explicit override proceeds and is flagged for logging"

# --- case 7: override is inert when nothing needed overriding ----------------
run '{"pipeline_drive_invoked":false,"setting_enabled":false,"epic_work_class":"Operational","any_foundational_in_group":false,"override":true}'
[ "$REFUSE" = "false" ] || fail "case7: setting-off must proceed regardless of override, got refuse=$REFUSE"
[ "$REASON" = "setting-off" ] || fail "case7: expected reason setting-off (not override), got $REASON"
[ "$OVERRIDE_LOGGED" = "false" ] || fail "case7: override_logged must stay false — there was nothing to override"
echo "PASS: case 7 a redundant override is never logged as an override"

# --- case 8: precedence — pipeline-drive wins over every other field ---------
run '{"pipeline_drive_invoked":true,"setting_enabled":true,"epic_work_class":"Operational","any_foundational_in_group":false,"override":false}'
[ "$REFUSE" = "false" ] || fail "case8: pipeline-drive-invoked must win first, got refuse=$REFUSE"
[ "$REASON" = "pipeline-drive-carve-out" ] || fail "case8: expected reason pipeline-drive-carve-out first in precedence, got $REASON"
echo "PASS: case 8 pipeline-drive-invoked is checked before every other branch"

# --- absent-field defaults: proceed (this guard's default is the OLD /assess
# behavior, unlike sweep-epic-admission.sh's refuse-on-absent) ---------------
run '{}'
[ "$REFUSE" = "false" ] || fail "case9: an all-absent input must proceed (safe default is the pre-#1854 behavior), got refuse=$REFUSE"
[ "$REASON" = "setting-off" ] || fail "case9: expected reason setting-off on an absent setting_enabled, got $REASON"
echo "PASS: case 9 an all-absent input falls back to the pre-guard default (proceed)"

# --- case 10: pipeline-invoked with a SKIPPED/FAILED label read (the
# reordered assess.md Step 1: item 1 detects pipeline-drive-invoked BEFORE
# any read, so on this path setting_enabled/epic_work_class/
# any_foundational_in_group are never resolved at all — they arrive
# genuinely absent from the input, not merely false. This is the
# script-level analog of "a pipeline-invoked run with a FAILING label read
# must still pass through" (round-4 escalation, HIGH finding 1): a failed
# read and a skipped read are indistinguishable at this script's input
# boundary — both mean these fields are never populated. -----------------
run '{"pipeline_drive_invoked":true}'
[ "$REFUSE" = "false" ] || fail "case10: pipeline-drive-invoked with no other reads must still proceed, got refuse=$REFUSE"
[ "$REASON" = "pipeline-drive-carve-out" ] || fail "case10: expected reason pipeline-drive-carve-out, got $REASON"
echo "PASS: case 10 pipeline-drive-invoked proceeds even when every other read was skipped/failed (the reordered Step 1)"

echo
echo "PASS: all assess-operational-refusal.sh predicate assertions passed"
