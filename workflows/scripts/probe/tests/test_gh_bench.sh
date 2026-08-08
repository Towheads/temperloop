#!/usr/bin/env bash
#
# Tests for gh-bench.sh + emit-gh-perf.sh (F#988 measurement harness). Zero
# network: the bench runs in --dry-run (no gh, no board.sh, fake timings) so the
# stats -> emit -> lake pipeline and arg handling are covered offline. The
# emitter is exercised both end-to-end (via the bench) and directly for its
# WARN-don't-drop reject paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$HERE/../gh-bench.sh"
EMIT="$HERE/../../emit-gh-perf.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
[ -f "$BENCH" ] || fail "gh-bench.sh not found"
[ -f "$EMIT" ]  || fail "emit-gh-perf.sh not found"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-bench-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

lakefile() { set -- "$1"/gh-perf-*.jsonl; [ -e "$1" ] && printf '%s' "$1"; }

# --- 1: dry-run end-to-end: one record per section + _run_total -------------
D="$WORK/d1"; mkdir -p "$D"
out="$(GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase before --label t1 --both --reps 3 --dry-run)" \
  || fail "dry-run exited nonzero"
LF="$(lakefile "$D")"; [ -n "$LF" ] || fail "no lake file written"
# every line valid JSON, schema_version 1, phase=before, source=bench, and
# label prefixed with the base "t1" (resolve_cold/resolve_warm/_run_total
# fold their arm/sourcing-state into the label — see test 6 below for the
# exact per-op_class suffix assertions).
while IFS= read -r line; do
  echo "$line" | jq -e '.schema_version=="1" and .phase=="before" and (.label|startswith("t1")) and .source=="bench"' >/dev/null \
    || fail "bad record: $line"
done <"$LF"
for oc in resolve_cold resolve_warm item_list resolve_item worklist reconcile_status pipeline_read_emu rel_loop _run_total; do
  grep -q "\"op_class\":\"$oc\"" "$LF" || fail "missing op_class $oc in lake"
done
grep -q "^op_class" <<<"$out" || fail "table header not printed"
echo "  [ok] dry-run: record per section + _run_total, valid schema, table"

# --- 2: --reps reflected in count -------------------------------------------
D="$WORK/d2"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase after --label t2 --cold --reps 5 --dry-run >/dev/null || fail "reps run failed"
LF="$(lakefile "$D")"
cnt="$(grep '"op_class":"resolve_cold"' "$LF" | jq -r '.count')"
[ "$cnt" = "5" ] || fail "resolve_cold count should be 5, got $cnt"
# --cold mode omits resolve_warm
grep -q '"op_class":"resolve_warm"' "$LF" && fail "--cold should not emit resolve_warm"
echo "  [ok] --reps count + --cold omits resolve_warm"

# --- 3: --with-mutations adds mutation_noop ---------------------------------
D="$WORK/d3"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase before --label t3 --warm --with-mutations --reps 2 --dry-run >/dev/null || fail "mutations run failed"
grep -q '"op_class":"mutation_noop"' "$(lakefile "$D")" || fail "--with-mutations should emit mutation_noop"
echo "  [ok] --with-mutations emits mutation_noop"

# --- 4: arg validation ------------------------------------------------------
code=0; bash "$BENCH" --phase before --label x --dry-run >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "missing --board should exit 2, got $code"
code=0; bash "$BENCH" --board 7 --phase sideways --label x --dry-run >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "bad --phase should exit 2, got $code"
echo "  [ok] arg validation (missing board / bad phase -> exit 2)"

# --- 5: emitter direct — reject paths never write, exit 0 -------------------
D="$WORK/d5"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$EMIT" --phase before --label x --board 7 --op-class y --count abc >/dev/null 2>&1
[ -z "$(lakefile "$D")" ] || fail "non-numeric count must not write a record"
GH_PERF_RAW_DIR="$D" bash "$EMIT" --phase nope --label x --board 7 --op-class y --count 1 >/dev/null 2>&1
[ -z "$(lakefile "$D")" ] || fail "bad phase must not write a record"
rec="$(GH_PERF_RAW_DIR="$D" bash "$EMIT" --phase after --label ok --board 4 --op-class z --count 2 --p50 9 --total 18)"
echo "$rec" | jq -e '.board==4 and .op_class=="z" and .p50_ms==9 and .total_ms==18' >/dev/null \
  || fail "valid emit record wrong: $rec"
echo "  [ok] emitter reject paths (exit 0, no write) + valid record shape"

# label_for <lakefile> <op_class>  ->  the .label of that op_class's record
# (empty if absent). Field-order-agnostic (reads via jq, not positional grep).
label_for() { jq -r --arg oc "$2" 'select(.op_class==$oc) | .label' "$1" 2>/dev/null; }

# --- 6: per-section arm label suffix (temperloop cache-arm fix) -------------
# resolve_cold/resolve_warm fold the arm they measured into --label
# (<label>-live / <label>-cached); every other section keeps the plain label;
# _run_total folds in whether lib/cache.sh was sourced this run instead
# (always "unavailable" in --dry-run, since board.sh/cache.sh sourcing is
# itself gated on dry_run==0 — deterministic, no live network needed).
D="$WORK/d6"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase before --label armtest --both --reps 2 --dry-run >/dev/null \
  || fail "arm-label (--both) run failed"
LF="$(lakefile "$D")"
[ "$(label_for "$LF" resolve_cold)" = "armtest-live" ] \
  || fail "resolve_cold record missing label armtest-live"
[ "$(label_for "$LF" resolve_warm)" = "armtest-cached" ] \
  || fail "resolve_warm record missing label armtest-cached"
[ "$(label_for "$LF" item_list)" = "armtest" ] \
  || fail "item_list record should carry the plain (unsuffixed) label"
[ "$(label_for "$LF" _run_total)" = "armtest-cache-unavailable" ] \
  || fail "_run_total record missing label armtest-cache-unavailable (dry-run never sources cache.sh)"
echo "  [ok] --both: resolve_cold/-live, resolve_warm/-cached, other sections plain, _run_total/-cache-unavailable"

# --cold: only the live arm's record appears, still suffixed
D="$WORK/d7"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase before --label c7 --cold --reps 2 --dry-run >/dev/null \
  || fail "arm-label (--cold) run failed"
LF="$(lakefile "$D")"
[ "$(label_for "$LF" resolve_cold)" = "c7-live" ] || fail "--cold resolve_cold missing label c7-live"
[ -z "$(label_for "$LF" resolve_warm)" ] || fail "--cold should not emit a resolve_warm record"
echo "  [ok] --cold: resolve_cold labeled c7-live, no resolve_warm"

# --warm: only the cached arm's record appears, still suffixed
D="$WORK/d8"; mkdir -p "$D"
GH_PERF_RAW_DIR="$D" bash "$BENCH" --board 7 --phase after --label w8 --warm --reps 2 --dry-run >/dev/null \
  || fail "arm-label (--warm) run failed"
LF="$(lakefile "$D")"
[ "$(label_for "$LF" resolve_warm)" = "w8-cached" ] || fail "--warm resolve_warm missing label w8-cached"
[ -z "$(label_for "$LF" resolve_cold)" ] || fail "--warm should not emit a resolve_cold record"
echo "  [ok] --warm: resolve_warm labeled w8-cached, no resolve_cold"

echo "PASS: gh-bench + emit-gh-perf"
