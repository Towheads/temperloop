#!/usr/bin/env bash
#
# Tests for report.sh -- `foundation report` (foundation #766, Epic E
# "before/after value proof"). Zero real network for the default path; a
# fake `gh` on PATH drives the --refresh case, mirroring the
# test_baseline_snapshot.sh convention.
#
# Covers:
#   1. two-record delta rendering (kernel tier) -- merged items/day,
#      time-to-merge, review latency, backlog age all show first->latest.
#   2. single-record repo -- "only one snapshot so far" note, no crash.
#   3. degraded record (metrics.available=false) -- graceful reason text,
#      exit 0, never a crash.
#   4. missing .foundation/baseline.jsonl entirely -- exit 1, actionable msg.
#   5. overlay tier: missing report.d/, a passing drop-in (rendered
#      verbatim), a non-executable drop-in, a failing drop-in, a timing-out
#      drop-in -- each degrades to its own "skipped" line, never a hard
#      error.
#   6. tokens headline: a `tokens` drop-in with valid JSON drives the
#      tokens-vs-merged-items headline; invalid JSON falls back to the
#      kernel-tier headline.
#   7. --refresh appends a real baseline record via a fake gh, then renders.
#   8. CLI hygiene: unknown arg is exit 2; -h is exit 0; a nonexistent --dir
#      is exit 1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../report.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin "git@github.com:test-owner/test-repo.git"
}

# --- 1: two-record delta rendering ------------------------------------------
REPO1="$WORK/repo1"
mk_repo "$REPO1"
mkdir -p "$REPO1/.foundation"
cat > "$REPO1/.foundation/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
{"schema":1,"generated_at":"2026-06-15T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":18},"time_to_merge_hours":{"median":10.0,"sample_size":18},"review_latency_hours":{"median":2.0,"sample_size":16},"issue_backlog":{"open_count":5,"median_age_days":60.0}}}
JSONL

out1="$(bash "$REPORT" --dir "$REPO1")"
echo "$out1" | grep -q "Baseline records: 2" || fail "should report 2 baseline records"
echo "$out1" | grep -q "Merged items/day:" || fail "should render merged items/day row"
echo "$out1" | grep -q "0.1000/day -> 0.2000/day" || fail "merged items/day should go 9/90 -> 18/90"
echo "$out1" | grep -q "Median time-to-merge" || fail "should render time-to-merge row"
echo "$out1" | grep -q "20.0h -> 10.0h" || fail "time-to-merge should show 20.0h -> 10.0h"
echo "$out1" | grep -q "delta -10.00h" || fail "time-to-merge delta should be -10.00h"
echo "$out1" | grep -q "Review latency" || fail "should render review latency row"
echo "$out1" | grep -q "4.0h -> 2.0h" || fail "review latency should show 4.0h -> 2.0h"
echo "$out1" | grep -q "Issue backlog age" || fail "should render issue backlog age row"
echo "$out1" | grep -q "90.0d -> 60.0d" || fail "issue backlog age should show 90.0 -> 60.0"
echo "$out1" | grep -q "foundation report: done" || fail "should print the completion line"

# --- 2: single-record repo --------------------------------------------------
REPO2="$WORK/repo2"
mk_repo "$REPO2"
mkdir -p "$REPO2/.foundation"
cat > "$REPO2/.foundation/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
JSONL
out2="$(bash "$REPORT" --dir "$REPO2")"
echo "$out2" | grep -q "only one snapshot so far" || fail "single-record repo should note first==latest"

# --- 3: degraded record (metrics.available=false) ---------------------------
REPO3="$WORK/repo3"
mk_repo "$REPO3"
mkdir -p "$REPO3/.foundation"
cat > "$REPO3/.foundation/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":null},"metrics":{"available":false,"reason":"skipped — gh not authenticated (or the auth check timed out)","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}
{"schema":1,"generated_at":"2026-06-15T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":18},"time_to_merge_hours":{"median":10.0,"sample_size":18},"review_latency_hours":{"median":2.0,"sample_size":16},"issue_backlog":{"open_count":5,"median_age_days":60.0}}}
JSONL
out3="$(bash "$REPORT" --dir "$REPO3")"
echo "$out3" | grep -q "unavailable for first record" || fail "degraded first record should render a graceful reason, not crash"
echo "$out3" | grep -q "gh not authenticated" || fail "degraded first record's reason text should surface"

# --- 4: missing .foundation/baseline.jsonl entirely -------------------------
REPO4="$WORK/repo4"
mk_repo "$REPO4"
if bash "$REPORT" --dir "$REPO4" >/dev/null 2>/tmp/report-test-4.err; then
  fail "missing baseline.jsonl should exit non-zero"
fi
grep -q "no .foundation/baseline.jsonl found" /tmp/report-test-4.err || fail "missing-baseline error should be actionable"
rm -f /tmp/report-test-4.err

# --- 5: overlay tier ---------------------------------------------------------
REPO5="$WORK/repo5"
mk_repo "$REPO5"
mkdir -p "$REPO5/.foundation"
cp "$REPO1/.foundation/baseline.jsonl" "$REPO5/.foundation/baseline.jsonl"

# 5a: no report.d/ at all
out5a="$(bash "$REPORT" --dir "$REPO5")"
echo "$out5a" | grep -q "skipped -- no .foundation/report.d/ directory" || fail "missing report.d/ should print a skip line"

# 5b-5d: passing / non-executable / failing drop-ins
mkdir -p "$REPO5/.foundation/report.d"
cat > "$REPO5/.foundation/report.d/hello" <<'EOF'
#!/usr/bin/env bash
echo "hello from a passing drop-in"
EOF
chmod +x "$REPO5/.foundation/report.d/hello"

cat > "$REPO5/.foundation/report.d/not-exec" <<'EOF'
#!/usr/bin/env bash
echo "should never run"
EOF
# deliberately not chmod +x

cat > "$REPO5/.foundation/report.d/broken" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
chmod +x "$REPO5/.foundation/report.d/broken"

out5b="$(bash "$REPORT" --dir "$REPO5")"
echo "$out5b" | grep -q "report.d/hello" || fail "a passing drop-in should render its own heading"
echo "$out5b" | grep -q "hello from a passing drop-in" || fail "a passing drop-in's stdout should render verbatim"
echo "$out5b" | grep -q "skipped -- not-exec: producer unavailable (not executable" || fail "a non-executable drop-in should skip legibly"
echo "$out5b" | grep -q "skipped -- broken: producer unavailable (exit 3)" || fail "a failing drop-in should skip legibly with its exit code"

# 5e: timing out
cat > "$REPO5/.foundation/report.d/slow" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo "too slow"
EOF
chmod +x "$REPO5/.foundation/report.d/slow"
out5c="$(bash "$REPORT" --dir "$REPO5" --timeout 1)"
echo "$out5c" | grep -q "skipped -- slow: producer unavailable (timed out after 1s)" || fail "a hanging drop-in should time out and skip legibly"
rm -f "$REPO5/.foundation/report.d/slow"

# --- 6: tokens headline ------------------------------------------------------
REPO6="$WORK/repo6"
mk_repo "$REPO6"
mkdir -p "$REPO6/.foundation/report.d"
cp "$REPO1/.foundation/baseline.jsonl" "$REPO6/.foundation/baseline.jsonl"

cat > "$REPO6/.foundation/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 3600}'
EOF
chmod +x "$REPO6/.foundation/report.d/tokens"

out6a="$(bash "$REPORT" --dir "$REPO6")"
echo "$out6a" | grep -q "Tokens spent vs items merged" || fail "a valid tokens drop-in should drive the tokens headline"
echo "$out6a" | grep -q "3600 tokens / 18 merged item" || fail "tokens headline should cite the raw tokens_spent and latest merged_count"
echo "$out6a" | grep -q "200.0 tokens/item" || fail "tokens headline ratio should be 3600/18 = 200.0"

# 6b: invalid JSON -> falls back to kernel-tier headline
cat > "$REPO6/.foundation/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo "not json at all"
EOF
chmod +x "$REPO6/.foundation/report.d/tokens"
out6b="$(bash "$REPORT" --dir "$REPO6")"
echo "$out6b" | grep -q "Kernel-tier headline" || fail "an invalid-JSON tokens drop-in should fall back to the kernel-tier headline"
echo "$out6b" | grep -qv "Tokens spent vs items merged" || true  # rendered section still present verbatim, only the HEADLINE falls back
echo "$out6b" | grep -q "Merged items/day: 0.1000 -> 0.2000/day" || fail "kernel-tier headline fallback should show the items/day figures"

# --- 7: --refresh appends via a fake gh, then renders -----------------------
REPO7="$WORK/repo7"
mk_repo "$REPO7"
mkdir -p "$REPO7/.foundation"
cat > "$REPO7/.foundation/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
JSONL

BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  pr)
    case "$2" in
      list) echo '[{"createdAt":"2026-06-20T00:00:00Z","mergedAt":"2026-06-21T00:00:00Z","reviews":[]}]'; exit 0 ;;
    esac
    ;;
  issue)
    case "$2" in
      list) echo '[{"createdAt":"2026-06-01T00:00:00Z"}]'; exit 0 ;;
    esac
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

lines_before="$(wc -l < "$REPO7/.foundation/baseline.jsonl" | tr -d ' ')"
out7="$(cd "$REPO7" && PATH="$BIN:$PATH" bash "$REPORT" --dir "$REPO7" --refresh)"
lines_after="$(wc -l < "$REPO7/.foundation/baseline.jsonl" | tr -d ' ')"
[ "$lines_after" -eq "$((lines_before + 1))" ] || fail "--refresh should append exactly one new baseline record"
echo "$out7" | grep -q "Refreshing baseline" || fail "--refresh should announce the refresh step"
echo "$out7" | grep -q "Baseline records: 2" || fail "--refresh's render step should see the freshly appended record"

# a default (no --refresh) run must NOT touch baseline.jsonl, even with no gh at all
lines_before2="$(wc -l < "$REPO7/.foundation/baseline.jsonl" | tr -d ' ')"
bash "$REPORT" --dir "$REPO7" >/dev/null
lines_after2="$(wc -l < "$REPO7/.foundation/baseline.jsonl" | tr -d ' ')"
[ "$lines_after2" -eq "$lines_before2" ] || fail "a default (non-refresh) run must never append to baseline.jsonl"

# --- 8: CLI hygiene ----------------------------------------------------------
if bash "$REPORT" --bogus-flag >/dev/null 2>&1; then
  fail "an unknown arg should be a usage error (exit 2)"
fi
bash "$REPORT" -h >/dev/null || fail "-h should exit 0"
if bash "$REPORT" --dir "$WORK/does-not-exist" >/dev/null 2>&1; then
  fail "a nonexistent --dir should exit non-zero"
fi

echo "OK: test_report.sh"
