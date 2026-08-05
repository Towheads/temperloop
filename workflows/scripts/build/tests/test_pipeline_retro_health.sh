#!/usr/bin/env bash
#
# Tests for pipeline-retro-health.sh — the retro-judge seam detector
# (temperloop#1150). Zero network, zero real lake: every case builds a
# synthetic raw lake under TMP and points PIPELINE_RAW_DIR / RETRO_RUNS_RAW_DIR
# at it.
#
# The property under test is the one the seam lacked: a zero-row retro-runs
# stream must NOT collapse to a single steady state. "No retros were due"
# (no-signal), "the trigger refused and said why" (refused), and "the trigger
# fired and produced nothing" (defect) are three different verdicts, and the
# third is the failure that hid for months.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pipeline-retro-health.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/retro-health-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

NOW_MONTH="$(date -u +%Y-%m)"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Deliberately outside any sane window, to prove `rows_ever` is whole-history
# while `rows_in_window` is not.
OLD_TS="2019-01-01T00:00:00Z"

# $1 = lake dir; seeds an empty lake with a pipeline month-file present.
new_lake() { mkdir -p "$1"; : > "$1/pipeline-$NOW_MONTH.jsonl"; }

# $1=lake $2=action $3=reason(optional) — append one wake record carrying one action.
wake() {
  local lake="$1" action="$2" reason="${3:-}"
  jq -nc --arg ts "$NOW_TS" --arg a "$action" --arg r "$reason" \
    '{event:"ran",ts:$ts,plans:[{board:"3",actions:[
        (if $r == "" then {phase:"retro",action:$a} else {phase:"retro",action:$a,reason:$r} end)]}]}' \
    >> "$lake/pipeline-$NOW_MONTH.jsonl"
}

run() {  # $1=lake  [$2=retro-runs dir]
  PIPELINE_RAW_DIR="$1" RETRO_RUNS_RAW_DIR="${2:-$1}" bash "$SCRIPT" --days 30
}

echo "--- test 1: an absent lake is UNKNOWN (no-lake), never a clean bill of health ---"
OUT="$(PIPELINE_RAW_DIR="$TMP/nope" RETRO_RUNS_RAW_DIR="$TMP/nope" bash "$SCRIPT" --days 30)"
[ "$(jq -r '.status' <<<"$OUT")" = "no-lake" ] \
  && ok "status=no-lake when there is no pipeline stream to read" || bad "t1.status" "$OUT"
jq -e '.detail | test("UNKNOWN")' <<<"$OUT" >/dev/null \
  && ok "the detail says UNKNOWN rather than implying health" || bad "t1.detail" "$OUT"

echo "--- test 2: lake present, no retro action at all -> no-signal (the genuine steady state) ---"
L="$TMP/l2"; new_lake "$L"
jq -nc --arg ts "$NOW_TS" '{event:"ran",ts:$ts,plans:[{board:"3",actions:[{action:"no-op"}]}]}' \
  >> "$L/pipeline-$NOW_MONTH.jsonl"
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "no-signal" ] \
  && ok "status=no-signal — nothing was due" || bad "t2.status" "$OUT"
jq -e '.detail | test("no retros were due")' <<<"$OUT" >/dev/null \
  && ok "the detail states the 'no retros were due' reading explicitly" || bad "t2.detail" "$OUT"

echo "--- test 3: a refusal is REFUSED, not a defect, and names its reason ---"
L="$TMP/l3"; new_lake "$L"
wake "$L" skip-retro-judge not-declared
wake "$L" skip-retro-judge not-declared
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "refused" ] \
  && ok "status=refused for a legibly-declining trigger" || bad "t3.status" "$OUT"
[ "$(jq -r '.skips["not-declared"]' <<<"$OUT")" = "2" ] \
  && ok "the refusal reasons are counted by reason" || bad "t3.skips" "$OUT"

echo "--- test 4: a headless-unsupported refusal is called out as ACTIONABLE ---"
L="$TMP/l4"; new_lake "$L"
wake "$L" skip-retro-judge headless-unsupported
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "refused" ] \
  && ok "status=refused (the seam declined; it did not silently succeed)" || bad "t4.status" "$OUT"
jq -e '.detail | test("headless-unattended") and test("ACTIONABLE")' <<<"$OUT" >/dev/null \
  && ok "the detail names the actionable gap and its remedy" || bad "t4.detail" "$OUT"

echo "--- test 5: THE 2026-08-05 FAILURE — trigger fired, stream never had a row -> defect ---"
L="$TMP/l5"; new_lake "$L"
wake "$L" retro-judge
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] \
  && ok "status=defect — a fired trigger with no rows is NOT a steady state" || bad "t5.status" "$OUT"
[ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "defect_kind=never-had-a-row (the loop has never closed)" || bad "t5.kind" "$OUT"
[ "$(jq -r '.judge_actions' <<<"$OUT")" = "2" ] \
  && ok "the trigger count is reported (2)" || bad "t5.count" "$OUT"
[ "$(jq -r '.retro_runs.stream_present' <<<"$OUT")" = "false" ] \
  && ok "an absent retro-runs stream is reported as absent, not assumed empty-but-fine" || bad "t5.present" "$OUT"

echo "--- test 6: a present-but-empty retro-runs file is still never-had-a-row ---"
L="$TMP/l6"; new_lake "$L"; : > "$L/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] && [ "$(jq -r '.defect_kind' <<<"$OUT")" = "never-had-a-row" ] \
  && ok "an existing but row-less stream is the same defect (presence != rows)" || bad "t6.status" "$OUT"
[ "$(jq -r '.retro_runs.stream_present' <<<"$OUT")" = "true" ] \
  && ok "stream_present distinguishes 'file exists' from 'file has rows'" || bad "t6.present" "$OUT"

echo "--- test 7: rows exist historically but none in the window -> defect(stalled) ---"
L="$TMP/l7"; new_lake "$L"
jq -nc --arg ts "$OLD_TS" '{ts:$ts,event:"retro-run"}' > "$L/retro-runs-2019-01.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "defect" ] && [ "$(jq -r '.defect_kind' <<<"$OUT")" = "stalled" ] \
  && ok "defect_kind=stalled — distinguished from never-had-a-row" || bad "t7.kind" "$OUT"
[ "$(jq -r '.retro_runs.rows_ever' <<<"$OUT")" = "1" ] && [ "$(jq -r '.retro_runs.rows_in_window' <<<"$OUT")" = "0" ] \
  && ok "rows_ever is whole-history while rows_in_window respects the window" || bad "t7.rows" "$OUT"

echo "--- test 8: trigger fired AND a row landed -> healthy ---"
L="$TMP/l8"; new_lake "$L"
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run",judged:2}' > "$L/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L")"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "status=healthy when the loop actually closed" || bad "t8.status" "$OUT"

echo "--- test 9: a separate RETRO_RUNS_RAW_DIR is honored ---"
L="$TMP/l9"; new_lake "$L"; R="$TMP/l9-retro"; mkdir -p "$R"
jq -nc --arg ts "$NOW_TS" '{ts:$ts,event:"retro-run"}' > "$R/retro-runs-$NOW_MONTH.jsonl"
wake "$L" retro-judge
OUT="$(run "$L" "$R")"
[ "$(jq -r '.status' <<<"$OUT")" = "healthy" ] \
  && ok "the retro-runs stream can live in its own dir" || bad "t9.status" "$OUT"

echo "--- test 10: read-only + always exit 0 (fail-open) ---"
L="$TMP/l10"; new_lake "$L"
wake "$L" retro-judge
BEFORE="$(find "$L" -type f | sort | xargs -I{} shasum {} | shasum | cut -c1-40)"
run "$L" >/dev/null; rc=$?
AFTER="$(find "$L" -type f | sort | xargs -I{} shasum {} | shasum | cut -c1-40)"
[ "$rc" -eq 0 ] && ok "exit 0 even on a defect verdict (the verdict is .status, never the exit code)" || bad "t10.rc" "rc=$rc"
[ "$BEFORE" = "$AFTER" ] && ok "the lake is byte-identical afterwards (read-only)" || bad "t10.readonly" "lake mutated"

echo "--- test 11: --format report renders a human verdict line ---"
OUT="$(PIPELINE_RAW_DIR="$L" RETRO_RUNS_RAW_DIR="$L" bash "$SCRIPT" --days 30 --format report)"
printf '%s' "$OUT" | grep -q "VERDICT: defect (never-had-a-row)" \
  && ok "the report format names the verdict and its kind" || bad "t11.report" "$OUT"

echo
echo "pipeline-retro-health tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
