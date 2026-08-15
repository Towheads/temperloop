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
  PIPELINE_RAW_DIR="$lake" GH_CALLS_RAW_DIR="$lake" KS_SEARCH_FALLBACK_RAW_DIR="$lake" \
  ITEM_EFFICIENCY_RAW_DIR="$lake" \
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
assert_has "$out" "no data yet — pipeline stream is empty" "pipeline no-data line"
assert_has "$out" "no data yet — gh-calls stream is empty" "gh-calls no-data line"
assert_has "$out" "no data yet — issue-touches stream is empty" "issue-touches no-data line"
assert_has "$out" "no data yet — claims stream is empty" "claims no-data line"
assert_has "$out" "no data yet — knowledge-search-fallback stream is empty" "ks-fallback no-data line"
assert_has "$out" "no data yet — item-efficiency stream is empty" "item-efficiency no-data line (temperloop#943)"
assert_has "$out" "no data yet — ks read-log is empty" "read-log no-data line"
assert_has "$out" "## 1. Attention" "renders Q1 heading"
assert_has "$out" "## 2. Pipeline health & trust" "renders Q2 heading"
assert_has "$out" "## 3. Spend" "renders Q3 heading"
assert_has "$out" "## 4. Improvement" "renders Q4 heading"
assert_has "$out" "## 5. Command effectiveness" "renders Q5 heading"

# ── 2. fixture streams → expected render ─────────────────────────────────────
echo "fixture streams:"
lake="$TMP/lake"
mkdir -p "$lake"
cat > "$lake/command-runs-${month}.jsonl" <<EOF
{"ts":"$now_ts","session_id":"s1","command":"sweep","board":3,"items_processed":4,"merged":3,"parked":1}
{"ts":"$now_ts","session_id":"s2","command":"triage","board":4,"items_processed":6,"merged":0,"resolved":4,"parked":2}
EOF
# ↑ deliberately MIXED eras (temperloop#1084): the sweep row is a pre-#1084
#   record with NO `resolved` key (absent = UNKNOWN, never 0), the triage row
#   is post-#1084 and carries it. Q5 must render both without conflating them.
cat > "$lake/issue-touches-${month}.jsonl" <<EOF
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":1,"session_id":"s1","host":"h","kind":"pr-open"}
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":1,"session_id":"s1","host":"h","kind":"merge"}
{"schema_version":"1","ts":"$now_ts","repo":"o/r","issue":2,"session_id":"s2","host":"h","kind":"capture"}
EOF
cat > "$lake/claims-${month}.jsonl" <<EOF
{"ts":"$now_ts","host":"h","session_id":"s1","board":3,"issue":1,"item_id":"PVTI_x"}
EOF
cat > "$lake/pipeline-${month}.jsonl" <<EOF
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
# temperloop#943 — two merged items on ONE epic. Item `a` has every phase and
# every wall-clock leg measured; item `b` has design/driver-prep unattributed
# (null) and three unmeasured wall-clock legs, so the same fixture exercises
# both the arithmetic and the "an absent measurement is not a zero" contract.
# Hand-checked arithmetic the assertions below reconcile against:
#   units:  design 6000 · driver-prep 2000 · worker 2232+9000=11232 · mech 186+300=486
#           total 19718 -> 9859 units/item; shares 30/10/56/2, ceremony 43%
#   raw:    output 970 · cache_create 2050 · cache_read 35900 per item
#   medians (2 records -> mean of the two): worker (420000+900000)/2 = 660000ms = 11m
#           end-to-end (1800000+2400000)/2 = 2100000ms = 35m
#           CI: only ONE measured (300000) -> median 300000 = 5m, NOT 150000
cat > "$lake/item-efficiency-${month}.jsonl" <<EOF
{"schema_version":"1","ts":"$now_ts","host":"h","session_id":"s1","repo":"o/r","slug":"a","epic":923,"issue":1,"pr":10,"level":0,"phases":{"design":{"agents":1,"api_calls":20,"units":6000,"wall_ms":1000,"tokens":{"output":600,"cache_create":1000,"cache_read":18000,"input":120}},"driver_prep":{"agents":1,"api_calls":10,"units":2000,"wall_ms":500,"tokens":{"output":200,"cache_create":300,"cache_read":9000,"input":50}},"worker":{"agents":1,"api_calls":8,"units":2232,"wall_ms":420000,"tokens":{"output":160,"cache_create":800,"cache_read":4000,"input":32}},"mechanical":{"agents":3,"api_calls":9,"units":186,"wall_ms":120000,"tokens":{"output":30,"cache_create":0,"cache_read":300,"input":6}}},"agent_counts":{"worker":1,"mechanical":3},"wall_ms":{"worker":420000,"ci":300000,"merge_group":180000,"gate_wait":60000,"end_to_end":1800000},"runs":{"design":["wf_d"],"driver_prep":["wf_p"],"build":["wf_b"]},"spend_source":"pipeline-spend-report.sh"}
{"schema_version":"1","ts":"$now_ts","host":"h","session_id":"s2","repo":"o/r","slug":"b","epic":923,"issue":2,"pr":11,"level":1,"phases":{"design":null,"driver_prep":null,"worker":{"agents":1,"api_calls":40,"units":9000,"wall_ms":900000,"tokens":{"output":900,"cache_create":2000,"cache_read":40000,"input":100}},"mechanical":{"agents":4,"api_calls":12,"units":300,"wall_ms":100000,"tokens":{"output":50,"cache_create":0,"cache_read":500,"input":10}}},"agent_counts":{"worker":1,"mechanical":4},"wall_ms":{"worker":900000,"ci":null,"merge_group":null,"gate_wait":null,"end_to_end":2400000},"runs":{"design":[],"driver_prep":[],"build":["wf_b2"]},"spend_source":"pipeline-spend-report.sh"}
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
assert_has "$out" "pipeline drive errors (7d): 1" "Q1 drive errors reconcile with pipeline fixtures"
# Q2 — 3 wakes: ran 1, skipped 1, drive 1 (errored 1); 1 fallback
assert_has "$out" "wakes (7d): 3 (ran 1 · skipped 1 · drive 1, of which 1 errored)" "Q2 wake counts reconcile"
assert_has "$out" "knowledge-search warm→cold fallbacks (7d): 1" "Q2 fallback count reconciles"
# Q3 — 2 gh calls, 3s total, 1 failure, worklist top context; 3 ks ops (read=2 search=1)
assert_has "$out" "gh/git-bug calls (7d): 2, 3s total wall-time, 1 non-zero exits" "Q3 gh-calls reconcile"
assert_has "$out" "worklist (1 calls, 2s)" "Q3 top context named"
assert_has "$out" "knowledge-store ops (7d): 3" "Q3 ks read-log total reconciles"
# Q3b — overhead per merged item (temperloop#943)
assert_has "$out" "overhead per merged item (7d): 2 merged item(s) · 9859 cost-weighted units/item" "Q3b units/item reconciles with the fixture records"
assert_has "$out" "design 30% · driver-prep 10% · worker 56% · mechanical 2% → ceremony (everything but the worker) 43%" "Q3b phase split reconciles"
assert_has "$out" "970 output · 2050 cache-create · 35900 cache-read" "Q3b raw token split is shown UNWEIGHTED (the cheap-cache-read distortion stays visible)"
assert_has "$out" "worker 11m · CI 5m · merge-group 3m · gate-wait 1m · end-to-end 35m" "Q3b wall-clock medians reconcile — and CI's median is the ONE measured value (5m), never diluted toward 0 by the unmeasured record"
assert_has "$out" "agents per merged item (7d, median): 1 worker · 3.5 mechanical" "Q3b agent counts by role reconcile"
assert_has "$out" "per epic #923: 2 item(s) · 9859 units/item · end-to-end 35m/item · levels 0,1" "Q3b rolls up per EPIC as well as per item"
assert_has "$out" "read=2" "Q3 ks per-op breakdown (read)"
assert_has "$out" "search=1" "Q3 ks per-op breakdown (search)"
# Q4 — 1 merge, 1 pr-open, 1 capture, 1 claim
assert_has "$out" "issue touches (7d): 1 merged · 1 PRs opened · 1 captured · 1 claimed" "Q4 touch counts reconcile"
# Q5 — per-command rollup with merge rate
assert_has "$out" "sweep: 1 runs · 4 items · 3 merged · 0 resolved · 1 parked · merge rate 75% (resolved unknown for 1 pre-#1084 run(s))" "Q5 sweep row reconciles, and flags the pre-#1084 record's absent resolved as UNKNOWN rather than 0"
assert_has "$out" "triage: 1 runs · 6 items · 0 merged · 4 resolved · 2 parked" "Q5 triage row reconciles with an explicit resolved count"
assert_not_has "$out" "triage: 1 runs · 6 items · 0 merged · 4 resolved · 2 parked · merge rate 0% (resolved unknown" "a post-#1084 record never gets the unknown suffix"
# every section names its source stream
assert_has "$out" "source: command-runs-*.jsonl @ $lake" "Q1/Q5 name their source stream"
assert_has "$out" "source: pipeline-*.jsonl @ $lake" "Q2 names its source streams"
assert_has "$out" "ks read-log (knowledge_store.sh ks__read_log_emit) @ $rlog" "Q3 names the ks read-log emit"
assert_has "$out" "item-efficiency-*.jsonl @ $lake (emit-item-efficiency.sh, token figures composed from pipeline-spend-report.sh)" "Q3b names its source stream verbatim, and names the profiler it composes"
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
assert_has "$out" "sweep: 1 runs · 1 items · 1 merged · 0 resolved · 0 parked" "torn line skipped, intact record rendered"

# ── 5. lookback flag override ────────────────────────────────────────────────
echo "lookback flag:"
out="$(run_brief "$stale" "$TMP/stale/absent-reads.log" --lookback-days 60 2>&1)"; rc=$?
assert_rc0 "$rc" "exit 0 with --lookback-days"
assert_has "$out" "sweep: 1 runs · 2 items · 2 merged · 0 resolved · 0 parked" "60-day window picks up the 30-day-old record"

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

# ── 7. legacy stream read (temperloop#729): funnel-*.jsonl unioned ──────────
# A pre-rename install's lake has only funnel-<YYYY-MM>.jsonl history — the
# renderer must still see it (read-only legacy glob, NOTE on stderr) so the
# accumulated telemetry does not go dark at upgrade. This read is PERMANENT:
# it deliberately survived the v0.19.0 terminology-window close
# (temperloop#767) because the raw lake is append-only immutable history.
legacy_lake="$TMP/legacy-lake"
mkdir -p "$legacy_lake"
cat > "$legacy_lake/funnel-${month}.jsonl" <<EOF
{"event":"drive","status":"error","date":"2026-07-16","duration_ms":100,"reason":"driver-failed","context":"boom","ts":"$now_ts"}
EOF
out="$(run_brief "$legacy_lake" "$TMP/no-reads.log" 2>"$TMP/legacy-stderr.txt")"; rc=$?
assert_rc0 "$rc" "legacy-only lake renders (rc 0)"
assert_has "$out" "pipeline drive errors" "legacy funnel-*.jsonl records are counted as the pipeline stream"
assert_not_has "$out" "no data yet — pipeline stream is empty" "pipeline stream is NOT reported empty on a legacy-only lake"
assert_has "$(cat "$TMP/legacy-stderr.txt")" "reading legacy funnel-*.jsonl telemetry" "legacy read surfaces the one-line NOTE on stderr"


# ── 8. item-efficiency degradation (temperloop#943) ─────────────────────────
# Three arms the metric MUST get right, because a ceremony-cost number that
# quietly fabricates zeros is worse than no number at all:
#   8a. records exist but all fall outside the window -> the stale note, never
#       a rendered 0-units-per-item headline;
#   8b. a record whose phases and wall_ms legs are ALL null -> every wall-clock
#       leg renders "—", never "0m";
#   8c. a torn trailing line -> skipped, the intact record still renders.
echo "item-efficiency degradation:"
ie_stale="$TMP/ie-stale"
mkdir -p "$ie_stale"
cat > "$ie_stale/item-efficiency-${old_month}.jsonl" <<EOF
{"schema_version":"1","ts":"$old_ts","slug":"old","epic":1,"level":0,"phases":{"design":null,"driver_prep":null,"worker":null,"mechanical":null},"agent_counts":{"worker":null,"mechanical":null},"wall_ms":{"worker":null,"ci":null,"merge_group":null,"gate_wait":null,"end_to_end":null},"runs":{"design":[],"driver_prep":[],"build":[]}}
EOF
out="$(run_brief "$ie_stale" "$TMP/ie-stale/absent-reads.log" 2>&1)"; rc=$?
assert_rc0 "$rc" "8a exit 0 on a stale item-efficiency lake"
assert_has "$out" "no item-efficiency records in the last 7 days (freshest: $old_ts)" "8a stale item-efficiency names its freshest record"
assert_not_has "$out" "overhead per merged item" "8a no out-of-window overhead headline rendered as current"

ie_null="$TMP/ie-null"
mkdir -p "$ie_null"
{
  printf '{"schema_version":"1","ts":"%s","slug":"x","epic":null,"level":null,"phases":{"design":null,"driver_prep":null,"worker":null,"mechanical":null},"agent_counts":{"worker":null,"mechanical":null},"wall_ms":{"worker":null,"ci":null,"merge_group":null,"gate_wait":null,"end_to_end":null},"runs":{}}\n' "$now_ts"
  printf '{"schema_version":"1","ts":"%s","slug":"tor\n' "$now_ts"
} > "$ie_null/item-efficiency-${month}.jsonl"
out="$(run_brief "$ie_null" "$TMP/ie-null/absent-reads.log" 2>&1)"; rc=$?
assert_rc0 "$rc" "8b/8c exit 0 with all-null phases and a torn trailing line"
assert_has "$out" "overhead per merged item (7d): 1 merged item(s)" "8c torn line skipped, the intact record still counted"
assert_has "$out" "worker — · CI — · merge-group — · gate-wait — · end-to-end —" "8b an unmeasured wall-clock leg renders — , never a fabricated 0m"
assert_has "$out" "per epic (unattributed):" "8b a record with no epic rolls up under (unattributed), not under a made-up epic"


# ── 9. PIPELINE stream default equals the WRITER's absolute pin ─────────────
# (temperloop#1564, the sibling defect temperloop#1185 already fixed in
# pipeline-retro-health.sh). pipeline-cron.sh:299 (the writer) pins the
# pipeline stream's default to the ABSOLUTE, checkout-independent
# $HOME/dev/foundation/meta/data/raw — deliberately, so a cron sandbox
# checkout still writes into the MAIN checkout's lake. This renderer (the
# reader) must fall back to that SAME absolute literal, not the
# checkout-relative $TELEMETRY_RAW_DIR the other three per-stream dirs use —
# otherwise, invoked with PIPELINE_RAW_DIR unset from any checkout other than
# $HOME/dev/foundation, it silently reads an empty directory instead of the
# writer's lake.
echo "pipeline stream root convergence (temperloop#1564):"

# 9a. Literal equality: the reader's fallback literal must be byte-identical
# to the writer's own default literal in pipeline-cron.sh:299 — never
# re-derived from $raw_root/$TELEMETRY_RAW_DIR.
CRON_SCRIPT="$REPO/workflows/scripts/build/pipeline-cron.sh"
cron_literal="$(grep -oE 'RAW_DIR="\$\{PIPELINE_RAW_DIR:-[^}]*\}"' "$CRON_SCRIPT" \
  | sed -E 's/^RAW_DIR="\$\{PIPELINE_RAW_DIR:-(.*)\}"$/\1/')"
brief_literal="$(grep -oE 'pipeline_dir="\$\{PIPELINE_RAW_DIR:-[^}]*\}"' "$SCRIPT" \
  | sed -E 's/^pipeline_dir="\$\{PIPELINE_RAW_DIR:-(.*)\}"$/\1/')"
if [ -n "$cron_literal" ] && [ -n "$brief_literal" ] && [ "$cron_literal" = "$brief_literal" ]; then
  ok "pipeline-cron.sh's writer default ($cron_literal) matches telemetry-brief.sh's reader default verbatim"
else
  fail_test "reader/writer literal equality" "cron=$cron_literal brief=$brief_literal"
fi

# 9b. Behavioral convergence: with PIPELINE_RAW_DIR unset, HOME faked to a
# scratch dir, and TELEMETRY_RAW_DIR pointed at a DIFFERENT, empty dir (so
# following $TELEMETRY_RAW_DIR instead of the writer's literal is
# observable), the pipeline records the "writer" placed under
# $HOME/dev/foundation/meta/data/raw must be the ones this renderer reads —
# reader and writer converge on the SAME directory. This is invoked with a
# Bash cwd inside this worktree checkout (NOT $HOME/dev/foundation), so a
# checkout-relative resolution would land somewhere else entirely.
#
# Against the UNFIXED script (pipeline_dir="${PIPELINE_RAW_DIR:-$TELEMETRY_RAW_DIR}")
# this diverges: pipeline_dir would resolve to the empty $wrong_telemetry_dir
# instead, so the fixture's drive-error record would never be seen and the
# assertions below would instead see "no data yet — pipeline stream is
# empty" — i.e. this case FAILS against the unfixed script and PASSES only
# once the reader's fallback matches the writer's absolute literal.
FAKE_HOME="$TMP/fakehome9"
writer_pipeline_dir="$FAKE_HOME/dev/foundation/meta/data/raw"
mkdir -p "$writer_pipeline_dir"
cat > "$writer_pipeline_dir/pipeline-${month}.jsonl" <<EOF
{"event":"drive","status":"error","date":"2026-07-16","duration_ms":100,"reason":"driver-failed","context":"boom","ts":"$now_ts"}
EOF
wrong_telemetry_dir="$TMP/wrong-telemetry-9"
empty_other_streams="$TMP/other-streams-9"
mkdir -p "$wrong_telemetry_dir" "$empty_other_streams"
out9="$(
  HOME="$FAKE_HOME" \
  CMD_RUN_RAW_DIR="$empty_other_streams" ISSUE_TOUCHES_RAW_DIR="$empty_other_streams" \
  CLAIMS_RAW_DIR="$empty_other_streams" GH_CALLS_RAW_DIR="$empty_other_streams" \
  KS_SEARCH_FALLBACK_RAW_DIR="$empty_other_streams" ITEM_EFFICIENCY_RAW_DIR="$empty_other_streams" \
  TELEMETRY_RAW_DIR="$wrong_telemetry_dir" KNOWLEDGE_READ_LOG="$TMP/absent-reads-9.log" \
    bash "$SCRIPT" 2>&1
)"; rc9=$?
assert_rc0 "$rc9" "exit 0 (pipeline root convergence case)"
assert_has "$out9" "pipeline drive errors (7d): 1" "reader found the writer's fixture under \$HOME/dev/foundation/meta/data/raw with PIPELINE_RAW_DIR unset — reader and writer converged"
assert_not_has "$out9" "no data yet — pipeline stream is empty" "pipeline stream is NOT reported empty — it did not fall back to the checkout-relative \$TELEMETRY_RAW_DIR"

echo
echo "test_telemetry_brief: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
