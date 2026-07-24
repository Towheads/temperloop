#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/decision-notify.sh — the blocking-now halt
# → operator-phone reach routing artifact of /build (foundation#863).
#
# The production reach (the harness `PushNotification` tool) is orchestrator-side
# and not scriptable, so what THIS unit tests is the piece that CAN fail
# silently: the routing decision (which severities reach the operator) and the
# emission contract (stdout line + the optional scriptable channel). The
# acceptance criteria map one-to-one onto the cases below:
#   - a simulated design-fork halt emits a notification .......... blocking-now → notify
#   - the modal (risky-set) merge-gate path does too ............. blocking-now → notify
#   - no notification on timed gates ............................ batch-at-gate → skip (exit 10)
#   - no notification on non-blocking questions ................. batch-at-ritual → skip (exit 10)
# The BUILD_DECISION_NOTIFY_CMD seam is exercised as a marker-writer so the test
# can OBSERVE the emission (present on a blocking-now halt, absent on a batch
# severity) without a real phone channel — the same test-injection shape
# combined-tree-precheck.sh uses for COMBINED_TREE_SUITE_CMD.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../decision-notify.sh"

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "PASS: $1"; pass=$((pass + 1)); }

# Run the script, capturing stdout, exit code, and (via a marker file) whether
# the BUILD_DECISION_NOTIFY_CMD channel fired. Sets: OUT, RC, MARKER.
run() {
  local severity="$1" summary="$2" set_cmd="${3:-yes}"
  local mk; mk="$(mktemp "${TMPDIR:-/tmp}/dn-marker.XXXXXX")"; rm -f "$mk"
  local rc=0
  if [ "$set_cmd" = "yes" ]; then
    OUT="$(BUILD_DECISION_NOTIFY_CMD="printf %s > $mk" bash "$SCRIPT" "$severity" "$summary" 2>/dev/null)" || rc=$?
  else
    OUT="$(bash "$SCRIPT" "$severity" "$summary" 2>/dev/null)" || rc=$?
  fi
  RC=$rc
  if [ -f "$mk" ]; then MARKER="$(cat "$mk")"; else MARKER=""; fi
  rm -f "$mk"
}

# 1. design-fork halt → notify (stdout carries the summary, exit 0, channel fired)
run blocking-now "temperloop /build halted — design-fork on gate-precheck needs your decision"
[ "$RC" -eq 0 ]                                          || fail "design-fork: expected exit 0, got $RC"
[ -n "$OUT" ]                                            || fail "design-fork: expected stdout summary, got empty"
[ "$MARKER" = "temperloop /build halted — design-fork on gate-precheck needs your decision" ] \
  || fail "design-fork: BUILD_DECISION_NOTIFY_CMD channel did not receive the summary (got [$MARKER])"
ok "design-fork halt → notify (exit 0, stdout + scriptable channel both emit)"

# 2. modal risky-set merge gate → notify (same severity, same reach)
run blocking-now "temperloop /build halted — risky-set merge gate needs your approval"
[ "$RC" -eq 0 ] && [ -n "$OUT" ] && [ -n "$MARKER" ] \
  || fail "modal merge gate: expected notify (exit 0, stdout, channel), got rc=$RC out=[$OUT] marker=[$MARKER]"
ok "modal risky-set merge gate → notify"

# 3. timed gate (batch-at-gate) → NO notification (exit 10, nothing emitted)
run batch-at-gate "a non-blocking gate-elapse default — must NOT reach the phone"
[ "$RC" -eq 10 ]                                         || fail "batch-at-gate: expected exit 10, got $RC"
[ -z "$OUT" ]                                            || fail "batch-at-gate: expected no stdout, got [$OUT]"
[ -z "$MARKER" ]                                         || fail "batch-at-gate: scriptable channel fired but must not (got [$MARKER])"
ok "timed gate (batch-at-gate) → no notification (exit 10, silent)"

# 4. non-blocking question (batch-at-ritual) → NO notification
run batch-at-ritual "an unattended pending-decisions default — must NOT reach the phone"
[ "$RC" -eq 10 ] && [ -z "$OUT" ] && [ -z "$MARKER" ] \
  || fail "batch-at-ritual: expected silent skip (exit 10), got rc=$RC out=[$OUT] marker=[$MARKER]"
ok "non-blocking question (batch-at-ritual) → no notification (exit 10, silent)"

# 5. unknown severity → usage error (closed enum, never a silent skip)
run "totally-made-up" "x"
[ "$RC" -eq 2 ]                                          || fail "unknown severity: expected exit 2, got $RC"
[ -z "$MARKER" ]                                         || fail "unknown severity: channel must not fire (got [$MARKER])"
ok "unknown severity → usage error (exit 2), channel silent"

# 6. missing summary arg → usage error
RC=0; bash "$SCRIPT" blocking-now >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ]                                          || fail "missing summary: expected exit 2, got $RC"
ok "missing summary arg → usage error (exit 2)"

# 7. empty summary → usage error
RC=0; bash "$SCRIPT" blocking-now "" >/dev/null 2>&1 || RC=$?
[ "$RC" -eq 2 ]                                          || fail "empty summary: expected exit 2, got $RC"
ok "empty summary → usage error (exit 2)"

# 8. blocking-now with NO scriptable channel set → still emits on stdout
#    (the universal PushNotification path works with zero operator config)
run blocking-now "no scriptable channel configured — stdout must still carry it" "no"
[ "$RC" -eq 0 ] && [ -n "$OUT" ]                         || fail "no channel: expected exit 0 + stdout, got rc=$RC out=[$OUT]"
[ -z "$MARKER" ]                                         || fail "no channel: marker must be empty when cmd unset (got [$MARKER])"
ok "blocking-now with no BUILD_DECISION_NOTIFY_CMD → stdout still emits (exit 0)"

# 9. summary longer than PushNotification's 200-char cap → truncated to 200
LONG="$(printf 'x%.0s' $(seq 1 250))"
run blocking-now "$LONG"
[ "${#OUT}" -eq 200 ]                                    || fail "truncation: expected 200-char stdout, got ${#OUT}"
ok "over-cap summary → truncated to 200 chars"

# 10. fail-open — a failing scriptable channel never aborts the gate
RC=0
OUT="$(BUILD_DECISION_NOTIFY_CMD="false" bash "$SCRIPT" blocking-now "channel fails, gate proceeds" 2>/dev/null)" || RC=$?
[ "$RC" -eq 0 ] && [ -n "$OUT" ] \
  || fail "fail-open: a failing BUILD_DECISION_NOTIFY_CMD must not abort (got rc=$RC out=[$OUT])"
ok "failing scriptable channel → fail-open (exit 0, stdout still emits)"

# 11. a chatty scriptable channel must NOT leak its stdout into the relayed line
#     (the marker-writer cases above redirect to a file, so they can't see this)
RC=0
OUT="$(BUILD_DECISION_NOTIFY_CMD='echo CHANNEL_RECEIPT_NOISE' bash "$SCRIPT" blocking-now "clean summary line" 2>/dev/null)" || RC=$?
[ "$RC" -eq 0 ]                                          || fail "channel-stdout isolation: expected exit 0, got $RC"
[ "$OUT" = "clean summary line" ] \
  || fail "channel-stdout isolation: channel noise leaked into the relayed line (got [$OUT])"
ok "chatty scriptable channel → stdout isolated (relayed line is exactly the summary)"

# 12. over-cap MULTIBYTE summary → truncated, length invariant holds under any
#     locale (char-count on UTF-8, byte-count on C — both ≤ cap), no crash
MB="$(printf '\xe2\x80\x94%.0s' $(seq 1 250))"   # 250 em-dashes (U+2014, 3 bytes each)
run blocking-now "$MB"
[ "$RC" -eq 0 ]                                          || fail "multibyte truncation: expected exit 0, got $RC"
[ "${#OUT}" -le 200 ]                                    || fail "multibyte truncation: expected ≤200, got ${#OUT}"
[ -n "$OUT" ]                                            || fail "multibyte truncation: expected non-empty output"
ok "over-cap multibyte summary → truncated to ≤200 (no crash, locale-agnostic invariant)"

echo "ALL PASS: test_decision_notify.sh ($pass cases)"
