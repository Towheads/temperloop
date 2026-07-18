#!/usr/bin/env bash
#
# test_telemetry_brief.sh — tests for workflows/scripts/telemetry-brief.sh,
# the kernel-side five-question telemetry brief renderer (temperloop#431).
#
# Exercises the renderer as a real subprocess against:
#   1. an EMPTY lake (fresh-install case) — DATA AGE: UNKNOWN, one honest
#      "no data yet" line per stream, exit 0, no fabricated numbers.
#   2. fixture jsonl streams (generated in a tmp lake with in-window
#      timestamps) — every one of the five sections renders real numbers
#      that reconcile with the fixture records, each section names its
#      source stream, and the ks read-log is counted.
#   3. stale streams (records exist, all OUTSIDE the lookback window) —
#      the section says "no ... records in the last N days" and names the
#      freshest record instead of rendering zeros as if current.
#   4. a torn (corrupt) trailing lake line — skipped, never fatal.
#   5. the check-in wiring — claude/commands/check-in.md invokes the
#      kernel renderer (the same presence check the activation proof runs).
#
# Usage: bash workflows/scripts/tests/test_telemetry_brief.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/telemetry-brief.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}
assert_rc0() {  # $1=observed rc, $2=test name
  if [ "$1" -eq 0 ]; then ok "$2"; else fail_test "$2" "exit $1"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "test_telemetry_brief: jq not found — cannot run (the renderer's own jq-less degradation is a manual check)" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/telemetry-brief-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# The renderer honors each emitter's own *_RAW_DIR first — pin every one to
# the fixture lake so an operator's real env can never leak into the test.
run_brief() {  # $1=lake dir, $2=read-log path, rest = extra args
  local lake="$1" rlog="$2"
  shift 2
  CMD_RUN_RAW_DIR="$lake" ISSUE_TOUCHES_RAW_DIR="$lake" CLAIMS_RAW_DIR="$lake" \
  FUNNEL_RAW_DIR="$lake" GH_CALLS_RAW_DIR="$lake" KS_SEARCH_FALLBACK_RAW_DIR="$lake" \
  TELEMETRY_RAW_DIR="$lake" KNOWLEDGE_READ_LOG="$rlog" \
    bash "$SCRIPT" "$@"
}

month="$(date -u +%Y-%m)"
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# A timestamp comfortably outside the default 7-day window (~30 days back),
# BSD date first, GNU fallback — same portability split as the renderer.
old_ts="$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)"
old_month="${old_ts%%-*}-$(printf '%s' "$old_ts" | cut -d- -f2)"

# ── 1. empty lake (fresh install) ────────────────────────────────────────────
echo "empty lake (fresh install):"
mkdir -p "$TMP/empty"
out="$(run_brief "$TMP/empty" "$TMP/empty/absent-reads.log" 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 on empty lake"
assert_has "$out" "DATA AGE: UNKNOWN" "leads with DATA AGE: UNKNOWN"
assert_has "$out" "no data yet — command-runs stream is empty" "command-runs no-data line"
assert_has "$out" "no data yet — funnel stream is empty" "funnel no-data line"
assert_has "$out" "no data yet — gh-calls stream is empty" "gh-calls no-data line"
assert_has "$out" "no data yet — issue-touches stream is empty" "issue-touches no-data line"
assert_has "$out" "no data yet — claims stream is empty" "claims no-data line"
assert_has "$out" "no data yet — knowledge-search-fallback stream is empty" "ks-fallback no-data line"
assert_has "$out" "no data yet — ks read-log is empty" "read-log no-data line"
assert_has "$out" "## 1. Attention" "renders Q1 heading"
assert_has "$out" "## 2. Funnel health & trust" "renders Q2 heading"
assert_has "$out" "## 3. Spend" "renders Q3 heading"
assert_has "$out" "## 4. Improvement" "renders Q4 heading"
assert_has "$out" "## 5. Command effectiveness" "renders Q5 heading"

# ── 2. fixture streams → expected render ─────────────────────────────────────
echo "fixture streams:"
lake="$TMP/lake"
mkdir -p "$lake"
cat > "$lake/command-runs-${month}.jsonl" <<EOF
{"ts":"$now_ts","session_id":"s1","command":"sweep","board":3,"items_processed":4,"merged":3,"parked":1}
{"ts":"$now_ts","session_id":"s2","command":"triage","board":4,"items_processed":6,"merged":0,"parked":2}
EOF
cat > "$lake/issue-touches-${month}.jsonl" <<EOF
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":1,"session_id":"s1","host":"h","kind":"pr-open"}
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":1,"session_id":"s1","host":"h","kind":"merge"}
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":2,"session_id":"s2","host":"h","kind":"capture"}
EOF
cat > "$lake/claims-${month}.jsonl" <<EOF
{"ts":"$now_ts","host":"h","session_id":"s1","board":3,"issue":1,"item_id":"PVTI_x"}
EOF
cat > "$lake/funnel-${month}.jsonl" <<EOF
{"event":"ran","date":"2026-07-16","boards":["3"],"nonop_actions":1,"duration_ms":900,"ts":"$now_ts"}
{"event":"skipped","date":"2026-07-15","reason":"not-scheduled","ts":"$now_ts"}
{"event":"drive","status":"error","date":"2026-07-16","duration_ms":100,"reason":"driver-failed","context":"boom","ts":"$now_ts"}
EOF
cat > "$lake/gh-calls-${month}.jsonl" <<EOF
{"schema_version":"1","ts":"$now_ts","host":"h","start_ms":1,"dur_ms":2000,"exit_code":0,"pid":1,"ppid":1,"tool":"gh","context":"worklist","op":null,"cwd":"/","args":"issue list","session_id":"s1"}
{"schema_version":"1","ts":"$now_ts","host":"h","start_ms":2,"dur_ms":1000,"exit_code":1,"pid":1,"ppid":1,"tool":"gh","context":"reconcile","op":null,"cwd":"/","args":"pr view","session_id":"s1"}
EOF
cat > "$lake/knowledge-search-fallback-${month}.jsonl" <<EOF
{"schema_version":"1","ts":"$now_ts","session_id":"s1","host":"h","backend":"basic-memory-mcp","reason":"unreachable","detail":"d","url":"u","project":"p"}
EOF
rlog="$TMP/reads.log"
printf '%s \xc2\xb7 s1 \xc2\xb7 script \xc2\xb7 read \xc2\xb7 Decisions/foo.md\n' "$now_ts" > "$rlog"
printf '%s \xc2\xb7 s1 \xc2\xb7 script \xc2\xb7 search \xc2\xb7 some query\n' "$now_ts" >> "$rlog"
printf '%s \xc2\xb7 s1 \xc2\xb7 script \xc2\xb7 read \xc2\xb7 Patterns/bar.md\n' "$now_ts" >> "$rlog"

out="$(run_brief "$lake" "$rlog" 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 on fixture lake"
assert_has "$out" "DATA AGE: 0h" "data age computed from freshest record"
assert_not_has "$out" "no data yet" "no spurious no-data lines with all streams populated"
# Q1 — parked = 1 + 2 across 2 of 2 runs; 1 drive error
assert_has "$out" "parked/deferred items (7d): 3 across 2 of 2 command runs" "Q1 parked reconciles with command-runs fixtures"
assert_has "$out" "funnel drive errors (7d): 1" "Q1 drive errors reconcile with funnel fixtures"
# Q2 — 3 wakes: ran 1, skipped 1, drive 1 (errored 1); 1 fallback
assert_has "$out" "wakes (7d): 3 (ran 1 · skipped 1 · drive 1, of which 1 errored)" "Q2 wake counts reconcile"
assert_has "$out" "knowledge-search warm→cold fallbacks (7d): 1" "Q2 fallback count reconciles"
# Q3 — 2 gh calls, 3s total, 1 failure, worklist top context; 3 ks ops (read=2 search=1)
assert_has "$out" "gh/git-bug calls (7d): 2, 3s total wall-time, 1 non-zero exits" "Q3 gh-calls reconcile"
assert_has "$out" "worklist (1 calls, 2s)" "Q3 top context named"
assert_has "$out" "knowledge-store ops (7d): 3" "Q3 ks read-log total reconciles"
assert_has "$out" "read=2" "Q3 ks per-op breakdown (read)"
assert_has "$out" "search=1" "Q3 ks per-op breakdown (search)"
# Q4 — 1 merge, 1 pr-open, 1 capture, 1 claim
assert_has "$out" "issue touches (7d): 1 merged · 1 PRs opened · 1 captured · 1 claimed" "Q4 touch counts reconcile"
# Q5 — per-command rollup with merge rate
assert_has "$out" "sweep: 1 runs · 4 items · 3 merged · 1 parked · merge rate 75%" "Q5 sweep row reconciles"
assert_has "$out" "triage: 1 runs · 6 items · 0 merged · 2 parked" "Q5 triage row reconciles"
# every section names its source stream
assert_has "$out" "source: command-runs-*.jsonl @ $lake" "Q1/Q5 name their source stream"
assert_has "$out" "source: funnel-*.jsonl @ $lake" "Q2 names its source streams"
assert_has "$out" "ks read-log (knowledge_store.sh ks__read_log_emit) @ $rlog" "Q3 names the ks read-log emit"
assert_has "$out" "issue-touches-*.jsonl @ $lake ∪ claims-*.jsonl @ $lake" "Q4 names the unioned streams"

# ── 3. stale streams (records exist, none in window) ────────────────────────
echo "stale streams:"
stale="$TMP/stale"
mkdir -p "$stale"
cat > "$stale/command-runs-${old_month}.jsonl" <<EOF
{"ts":"$old_ts","session_id":"s9","command":"sweep","board":3,"items_processed":2,"merged":2,"parked":0}
EOF
out="$(run_brief "$stale" "$TMP/stale/absent-reads.log" 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 on stale lake"
assert_has "$out" "DATA STALE" "stale data alarms in the header"
assert_has "$out" "no command-runs records in the last 7 days (freshest: $old_ts)" "stale stream names its freshest record"
assert_not_has "$out" "sweep: 1 runs" "no out-of-window numbers rendered as current"

# ── 4. torn trailing line is skipped, never fatal ────────────────────────────
echo "torn lake line:"
torn="$TMP/torn"
mkdir -p "$torn"
cat > "$torn/command-runs-${month}.jsonl" <<EOF
{"ts":"$now_ts","session_id":"s1","command":"sweep","board":3,"items_processed":1,"merged":1,"parked":0}
{"ts":"$now_ts","session_id":"s2","command":"swe
EOF
out="$(run_brief "$torn" "$TMP/torn/absent-reads.log" 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 with a torn line"
assert_has "$out" "sweep: 1 runs · 1 items · 1 merged · 0 parked" "torn line skipped, intact record rendered"

# ── 5. lookback flag override ────────────────────────────────────────────────
echo "lookback flag:"
out="$(run_brief "$stale" "$TMP/stale/absent-reads.log" --lookback-days 60 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 with --lookback-days"
assert_has "$out" "sweep: 1 runs · 2 items · 2 merged · 0 parked" "60-day window picks up the 30-day-old record"

# ── 6. check-in wiring (the contract this renderer exists to satisfy) ───────
echo "check-in wiring:"
if grep -qE 'workflows/scripts/[A-Za-z0-9/_.-]*telemetry' "$REPO/claude/commands/check-in.md"; then
  ok "claude/commands/check-in.md invokes a kernel telemetry renderer"
else
  fail_test "claude/commands/check-in.md invokes a kernel telemetry renderer" "no workflows/scripts/*telemetry* reference found"
fi
if grep -q 'telemetry-brief.sh' "$REPO/claude/commands/check-in.md"; then
  ok "check-in.md names telemetry-brief.sh specifically"
else
  fail_test "check-in.md names telemetry-brief.sh specifically" "reference missing"
fi

echo
echo "test_telemetry_brief: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
