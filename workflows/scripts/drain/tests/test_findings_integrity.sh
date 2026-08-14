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
# --check-subject-model mode (foundation#1584, SUBJECT_MODEL_MISSING):
#  10. subject_model=null + archived stub WITH a model: line -> flagged.
#  11. subject_model=null + archived stub WITHOUT a model: line -> NOT
#      flagged (the single most important case — a false positive here is
#      worse than no guard at all).
#  12. subject_model=null + no archived stub at all -> NOT flagged (can't
#      corroborate either way).
#  13. subject_model already populated -> never inspected, even if the stub
#      exists and carries a (necessarily different) model.
#  14. A gzip-cold archived stub (`*.md.gz`) WITH a model: line is still
#      resolved and flags exactly like the plain-`.md` case.
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

# ---------------------------------------------------------------------------
# --check-subject-model mode (foundation#1584, SUBJECT_MODEL_MISSING)
# ---------------------------------------------------------------------------
#
# Session ids below are full-shaped (>=8 chars) so id8 truncation (the real
# archiver convention, session_id[:8]) behaves exactly as it does in
# production. Archive filenames follow the real
# `<date>-<time>-<project>-<id8>.md[.gz]` convention.

seed_subject_model_root() {
  # $1 = root dir. Seeds a findings stream with four subject_model=null
  # records plus one already-populated control record, and an archive dir
  # with stubs covering: has-model, no-model, gzip'd has-model, and no stub
  # at all (session "eeeeeeee..." has NO matching archive file).
  local root="$1"
  mkdir -p "$root/meta/data/raw" "$root/meta/sessions/archive"
  cat > "$root/meta/data/raw/findings-2026-06.jsonl" <<'JSONL'
{"schema_version":"2","ts":"2026-06-01T00:00:00Z","session_id":"aaaaaaaa-1111-2222-3333-444444444444","project":"p","method":"drain-model-skim","sub_method":null,"finding_type":"defect","finding_ref":"#100","accepted":true,"subject_model":null,"analyst_model":"claude-opus-4-8"}
{"schema_version":"2","ts":"2026-06-01T00:00:01Z","session_id":"bbbbbbbb-1111-2222-3333-444444444444","project":"p","method":"drain-model-skim","sub_method":null,"finding_type":"defect","finding_ref":"#101","accepted":true,"subject_model":null,"analyst_model":"claude-opus-4-8"}
{"schema_version":"2","ts":"2026-06-01T00:00:02Z","session_id":"cccccccc-1111-2222-3333-444444444444","project":"p","method":"drain-model-skim","sub_method":null,"finding_type":"defect","finding_ref":"#102","accepted":true,"subject_model":null,"analyst_model":"claude-opus-4-8"}
{"schema_version":"2","ts":"2026-06-01T00:00:03Z","session_id":"eeeeeeee-1111-2222-3333-444444444444","project":"p","method":"drain-model-skim","sub_method":null,"finding_type":"defect","finding_ref":"#103","accepted":true,"subject_model":null,"analyst_model":"claude-opus-4-8"}
{"schema_version":"2","ts":"2026-06-01T00:00:04Z","session_id":"dddddddd-1111-2222-3333-444444444444","project":"p","method":"drain-lexicon","sub_method":"tell","finding_type":"decision","finding_ref":"Decisions/z.md","accepted":true,"subject_model":"claude-sonnet-5","analyst_model":"claude-opus-4-8"}
JSONL

  # aaaaaaaa: stub WITH a model: line -> should be flagged.
  cat > "$root/meta/sessions/archive/2026-06-01-1000-p-aaaaaaaa.md" <<'STUB'
---
date: 2026-06-01
time: "1000"
project: p
session_id: aaaaaaaa-1111-2222-3333-444444444444
model: claude-sonnet-5
---

# Session — p (2026-06-01 1000)
STUB

  # bbbbbbbb: stub WITHOUT a model: line -> must NOT be flagged.
  cat > "$root/meta/sessions/archive/2026-06-01-1100-p-bbbbbbbb.md" <<'STUB'
---
date: 2026-06-01
time: "1100"
project: p
session_id: bbbbbbbb-1111-2222-3333-444444444444
---

# Session — p (2026-06-01 1100)
STUB

  # dddddddd: stub WITH a model: line, but its finding record already has a
  # non-null subject_model -> must never even be inspected.
  cat > "$root/meta/sessions/archive/2026-06-01-1200-p-dddddddd.md" <<'STUB'
---
date: 2026-06-01
time: "1200"
project: p
session_id: dddddddd-1111-2222-3333-444444444444
model: claude-sonnet-5
---

# Session — p (2026-06-01 1200)
STUB

  # cccccccc: gzip'd stub (cold retention) WITH a model: line -> flagged too.
  local tmp_stub
  tmp_stub="$(mktemp)"
  cat > "$tmp_stub" <<'STUB'
---
date: 2026-06-01
time: "1300"
project: p
session_id: cccccccc-1111-2222-3333-444444444444
model: claude-opus-4-8
---

# Session — p (2026-06-01 1300)
STUB
  gzip -c "$tmp_stub" > "$root/meta/sessions/archive/2026-06-01-1300-p-cccccccc.md.gz"
  rm -f "$tmp_stub"

  # eeeeeeee: no archive file at all -> can't corroborate, must NOT be flagged.
}

echo "--- test 10: subject_model=null + stub WITH model: -> SUBJECT_MODEL_MISSING ---"
ROOT="$(mktemp -d)"; seed_subject_model_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --check-subject-model 2>&1)"; rc=$?
assert_eq "$rc" "1" "exit 1 when a modeled stub's record landed subject_model=null"
assert_contains "$out" "SUBJECT_MODEL_MISSING" "prints the SUBJECT_MODEL_MISSING token"
assert_contains "$out" "aaaaaaaa-1111-2222-3333-444444444444" "names the flagged session"
rm -rf "$ROOT"

echo "--- test 11: subject_model=null + stub WITHOUT model: -> NOT flagged (false-positive guard) ---"
ROOT="$(mktemp -d)"; mkdir -p "$ROOT/meta/data/raw" "$ROOT/meta/sessions/archive"
cat > "$ROOT/meta/data/raw/findings-2026-06.jsonl" <<'JSONL'
{"schema_version":"2","ts":"2026-06-01T00:00:00Z","session_id":"bbbbbbbb-1111-2222-3333-444444444444","project":"p","method":"drain-model-skim","sub_method":null,"finding_type":"defect","finding_ref":"#101","accepted":true,"subject_model":null,"analyst_model":"claude-opus-4-8"}
JSONL
cat > "$ROOT/meta/sessions/archive/2026-06-01-1100-p-bbbbbbbb.md" <<'STUB'
---
date: 2026-06-01
time: "1100"
project: p
session_id: bbbbbbbb-1111-2222-3333-444444444444
---

# Session — p (2026-06-01 1100)
STUB
out="$(python3 "$SCRIPT" "$ROOT" --check-subject-model 2>&1)"; rc=$?
assert_eq "$rc" "0" "exit 0 — a legitimately-modelless stub is never flagged"
assert_contains "$out" "SUBJECT_MODEL_OK" "prints the OK token"
assert_not_contains "$out" "SUBJECT_MODEL_MISSING" "no mismatch token for a genuinely-modelless stub"
rm -rf "$ROOT"

echo "--- test 12: subject_model=null + no archived stub at all -> NOT flagged ---"
ROOT="$(mktemp -d)"; seed_subject_model_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --check-subject-model 2>&1)"; rc=$?
assert_not_contains "$out" "eeeeeeee-1111-2222-3333-444444444444" "session with no archived stub is never flagged"
rm -rf "$ROOT"

echo "--- test 13: subject_model already populated -> never inspected ---"
ROOT="$(mktemp -d)"; seed_subject_model_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --check-subject-model 2>&1)"; rc=$?
assert_not_contains "$out" "dddddddd-1111-2222-3333-444444444444" "a record with a populated subject_model is skipped even though its stub carries a model:"
rm -rf "$ROOT"

echo "--- test 14: gzip'd cold stub WITH model: -> still flagged ---"
ROOT="$(mktemp -d)"; seed_subject_model_root "$ROOT"
out="$(python3 "$SCRIPT" "$ROOT" --check-subject-model 2>&1)"; rc=$?
assert_contains "$out" "cccccccc-1111-2222-3333-444444444444" "gzip'd archived stub is decompressed and its model: field found"
rm -rf "$ROOT"

echo "---"
echo "pass: $pass | fail: $fail"
[ "$fail" -eq 0 ] || { echo "test_findings_integrity: FAIL"; exit 1; }
echo "test_findings_integrity: OK"
