#!/usr/bin/env bash
#
# test_findings_integrity.sh — CI tests for findings_integrity.py
# (foundation#1576: verify a drain run's self-reported findings emission
# actually landed, and fail a mismatched self-report).
#
# Seeds a throwaway root with a findings-*.jsonl stream and asserts:
#   1. A self-report matching the actual landed rows exits 0 and prints
#      FINDINGS_INTEGRITY_OK.
#   2. A self-report with a mismatched count exits 1 and prints the literal
#      token FINDINGS_EMITTED_MISMATCH.
#   3. A "processed transcript" (self-reports >=1 decision) whose session
#      landed ZERO rows is flagged as a mismatch — distinguishing it from a
#      genuinely-empty transcript.
#   4. A session that self-reports {"accepted":0,"rejected":0} AND landed
#      zero rows is NOT flagged — legitimate "nothing to extract" passes.
#   5. Rejections (accepted:false) count as landed rows, not as missing —
#      a self-report of rejected=N matches N accepted:false rows.
#   6. Malformed JSON lines in the stream are skipped, not fatal.
#   7. Multiple sessions, one matching and one diverging → only the
#      diverging one is named in the mismatch output; exit 1 overall.
#   8. Bad input (malformed self-report JSON, missing required key) exits 2,
#      distinct from the exit-1 corroboration-failure code.
#   9. --self-report-file reads the same shape from a file.
#
# Usage: bash workflows/scripts/drain/tests/test_findings_integrity.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/findings_integrity.py"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find [$needle] in [$haystack]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "did NOT expect to find [$needle] in [$haystack]" ;;
    *) ok "$name" ;;
  esac
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else fail_test "$name" "got [$got] want [$want]"; fi
}

seed_root() {
  # $1 = root dir. Seeds a two-session findings stream:
  #   sess-match:    1 accepted decision, landed  (1 row, accepted:true)
  #   sess-mismatch: self-reports 2 accepted, only 1 landed
  #   sess-zero:     self-reports 1 accepted + 1 rejected, ZERO rows landed
  #   sess-empty:    self-reports 0/0, ZERO rows landed (legit "nothing")
  #   sess-rejects:  self-reports rejected=2, 2 accepted:false rows landed
  local root="$1"
  mkdir -p "$root/meta/data/raw"
  cat > "$root/meta/data/raw/findings-2026-06.jsonl" <<'JSONL'
{"schema_version":"2","ts":"2026-06-01T00:00:00Z","session_id":"sess-match","project":"p","method":"drain-lexicon","sub_method":"tell","finding_type":"decision","finding_ref":"Decisions/x.md","accepted":true,"subject_model":null,"analyst_model":null}
{"schema_version":"2","ts":"2026-06-01T00:00:01Z","session_id":"sess-mismatch","project":"p","method":"drain-lexicon","sub_method":"tell","finding_type":"decision","finding_ref":"Decisions/y.md","accepted":true,"subject_model":null,"analyst_model":null}
{"schema_version":"2","ts":"2026-06-01T00:00:02Z","session_id":"sess-rejects","project":"p","method":"drain-lexicon","sub_method":"tell","finding_type":"friction","finding_ref":"Context/f.md","accepted":false,"subject_model":null,"analyst_model":null}
{ this is not valid json
{"schema_version":"2","ts":"2026-06-01T00:00:03Z","session_id":"sess-rejects","project":"p","method":"drain-lexicon","sub_method":"tell","finding_type":"friction","finding_ref":"Context/f.md","accepted":false,"subject_model":null,"analyst_model":null}
JSONL
}

echo "--- test 1: matching self-report -> exit 0, FINDINGS_INTEGRITY_OK ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-match": {"accepted": 1, "rejected": 0}}' 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 on match"
assert_contains "$out" "FINDINGS_INTEGRITY_OK" "prints OK token"
assert_not_contains "$out" "FINDINGS_EMITTED_MISMATCH" "no mismatch token on match"
rm -rf "$ROOT"

echo "--- test 2: mismatched count -> exit 1, FINDINGS_EMITTED_MISMATCH ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-mismatch": {"accepted": 2, "rejected": 0}}' 2>&1)"; rc=$?
assert_eq "$rc" "1" "exit 1 on mismatch"
assert_contains "$out" "FINDINGS_EMITTED_MISMATCH" "prints mismatch token"
assert_contains "$out" "sess-mismatch" "names the diverging session"
rm -rf "$ROOT"

echo "--- test 3: processed transcript, zero rows landed -> flagged ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-zero": {"accepted": 1, "rejected": 1}}' 2>&1)"; rc=$?
assert_eq "$rc" "1" "exit 1 on processed-but-zero-landed"
assert_contains "$out" "FINDINGS_EMITTED_MISMATCH" "prints mismatch token"
assert_contains "$out" "processed transcript, zero rows landed" "tags the zero-landed case explicitly"
rm -rf "$ROOT"

echo "--- test 4: genuinely-empty transcript (0/0 self-report, 0 landed) -> NOT flagged ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-empty": {"accepted": 0, "rejected": 0}}' 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 — legitimate nothing-to-extract passes"
assert_contains "$out" "FINDINGS_INTEGRITY_OK" "prints OK token"
rm -rf "$ROOT"

echo "--- test 5: rejections (accepted:false) count as landed rows ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-rejects": {"accepted": 0, "rejected": 2}}' 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 — 2 accepted:false rows satisfy rejected=2"
assert_contains "$out" "2 rejected" "OK summary reports the 2 rejected rows"
rm -rf "$ROOT"

echo "--- test 6: malformed JSON line in stream is skipped, not fatal ---"
# (already exercised implicitly above via the seeded bad line; confirm explicitly)
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-match": {"accepted": 1, "rejected": 0}}' 2>&1)"; rc=$?
assert_eq "$rc" "0" "malformed line does not crash the check"
rm -rf "$ROOT"

echo "--- test 7: multiple sessions, one match one mismatch -> only the mismatch is named ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-match": {"accepted": 1, "rejected": 0}, "sess-mismatch": {"accepted": 2, "rejected": 0}}' 2>&1)"; rc=$?
assert_eq "$rc" "1" "exit 1 — overall failure when any session diverges"
assert_contains "$out" "sess-mismatch" "names the diverging session"
assert_not_contains "$out" "session sess-match " "does not name the matching session as a divergence"
rm -rf "$ROOT"

echo "--- test 8: bad input exits 2 (distinct from exit-1 corroboration failure) ---"
ROOT="$(mktemp -d)"; mkdir -p "$ROOT/meta/data/raw"
out8a="$(python3 "$SCRIPT" "$ROOT" --self-report 'not json' 2>&1)"; rc8a=$?
assert_eq "$rc8a" "2" "malformed self-report JSON -> exit 2"
assert_contains "$out8a" "ERROR" "malformed-JSON error message printed"
out8b="$(python3 "$SCRIPT" "$ROOT" --self-report '{"sess-x": {"accepted": 1}}' 2>&1)"; rc8b=$?
assert_eq "$rc8b" "2" "missing required 'rejected' key -> exit 2"
assert_contains "$out8b" "rejected" "missing-key error names the missing field"
rm -rf "$ROOT"

echo "--- test 9: --self-report-file reads the same shape from a file ---"
ROOT="$(mktemp -d)"; seed_root "$ROOT"
REPORT_FILE="$(mktemp)"
printf '%s' '{"sess-match": {"accepted": 1, "rejected": 0}}' > "$REPORT_FILE"
out="$(python3 "$SCRIPT" "$ROOT" --self-report-file "$REPORT_FILE" 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 via --self-report-file"
assert_contains "$out" "FINDINGS_INTEGRITY_OK" "prints OK token via file input"
rm -rf "$ROOT" "$REPORT_FILE"

echo "---"
echo "pass: $pass | fail: $fail"
[ "$fail" -eq 0 ] || { echo "test_findings_integrity: FAIL"; exit 1; }
echo "test_findings_integrity: OK"
