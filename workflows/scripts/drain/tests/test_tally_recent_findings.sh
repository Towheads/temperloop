#!/usr/bin/env bash
#
# test_tally_recent_findings.sh — CI tests for tally_recent_findings.py.
#
# Seeds a throwaway root with a findings-*.jsonl stream and asserts the tally:
#   1. counts accepted findings by type within the trailing window;
#   2. excludes non-accepted and out-of-window records;
#   3. --days widens the window to include older records;
#   4. an empty / absent findings dir prints nothing, exit 0;
#   5. malformed JSON lines are skipped, not fatal.
#
# Usage: bash workflows/scripts/drain/tests/test_tally_recent_findings.sh
# Exit 0 = all pass, exit 1 = one or more failures.

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/drain/tally_recent_findings.py"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then ok "$name"; else fail_test "$name" "got [$got] want [$want]"; fi
}

# Seed a root with a findings stream: recent accepted feedback×2 + pattern×1,
# a recent NON-accepted feedback (excluded), and an OLD accepted mistake (100d,
# outside the 14d window). Timestamps are computed relative to now by python.
ROOT="$(mktemp -d)"
mkdir -p "$ROOT/meta/data/raw"
python3 - "$ROOT" <<'PY'
import json, os, sys
from datetime import datetime, timezone, timedelta
root = sys.argv[1]
now = datetime.now(timezone.utc)
recent = (now - timedelta(days=2)).isoformat().replace("+00:00", "Z")
old = (now - timedelta(days=100)).isoformat().replace("+00:00", "Z")
rows = [
    {"accepted": True,  "ts": recent, "finding_type": "feedback"},
    {"accepted": True,  "ts": recent, "finding_type": "feedback"},
    {"accepted": True,  "ts": recent, "finding_type": "pattern"},
    {"accepted": False, "ts": recent, "finding_type": "feedback"},   # non-accepted → excluded
    {"accepted": True,  "ts": old,    "finding_type": "mistake"},    # out of 14d window
]
with open(os.path.join(root, "meta/data/raw/findings-test.jsonl"), "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
    f.write("{ this is not valid json\n")   # malformed line → must be skipped
PY

echo "--- test 1: default 14d window ---"
out="$(python3 "$SCRIPT" "$ROOT" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "exit 0"; else fail_test "exit" "got $rc"; fi
assert_eq "$out" "$(printf 'feedback\t2\npattern\t1')" "counts recent accepted, excludes non-accepted + old + malformed"

echo "--- test 2: --days 365 includes the old mistake ---"
out2="$(python3 "$SCRIPT" "$ROOT" --days 365 2>/dev/null)"
assert_eq "$out2" "$(printf 'feedback\t2\nmistake\t1\npattern\t1')" "widened window includes old record"

echo "--- test 3: empty findings dir → empty, exit 0 ---"
EMPTY="$(mktemp -d)"; mkdir -p "$EMPTY/meta/data/raw"
out3="$(python3 "$SCRIPT" "$EMPTY" 2>/dev/null)"; rc3=$?
if [ "$rc3" -eq 0 ] && [ -z "$out3" ]; then ok "empty tally, exit 0"; else fail_test "empty" "rc=$rc3 out=[$out3]"; fi

rm -rf "$ROOT" "$EMPTY"

echo "---"
echo "pass: $pass | fail: $fail"
[ "$fail" -eq 0 ] || { echo "test_tally_recent_findings: FAIL"; exit 1; }
echo "test_tally_recent_findings: OK"
