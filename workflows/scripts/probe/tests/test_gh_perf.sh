#!/usr/bin/env bash
#
# Tests for gh-perf-report.sh (F#988 measurement harness — the go/no-go artifact).
# Zero network: golden v2-TSV + golden lake fixtures, no real gh. Asserts:
#   1. default report: per-op table + graphql/rest/porcelain classification;
#   2. classification is derived correctly from the args column;
#   3. --by context / --by op grouping;
#   4. --emit freezes live-window per-op summaries into the lake (source=live);
#   5. --compare joins before vs after and computes delta/ratio;
#   6. arg validation (bad --by, --emit without --phase -> exit 2);
#   7. an absent TSV degrades gracefully (exit 0, a notice).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../gh-perf-report.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
[ -f "$REPORT" ] || fail "gh-perf-report.sh not found"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-perf-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# v2 TSV row helper: start dur exit pid ppid tool context op cwd args
row() { printf '%s\t%s\t0\t11\t10\tgh\t%s\t%s\t/r\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

TSV="$WORK/tsv"
{
  row 1000 500 worklist  board:list    "issue list --repo o/r"       # porcelain
  row 1001 700 worklist  board:list    "issue list --repo o/r"       # porcelain
  row 1002 300 reconcile board:resolve "api repos/o/r/issues/5"      # rest
  row 1003 900 reconcile board:resolve "api graphql -f query=xyz"    # graphql
  row 1004 2000 ""        ""            "project item-list 4"         # graphql, untagged
} >"$TSV"

# --- 1 + 2: default report + classification ---------------------------------
out="$(GH_CALL_LOG_FILE="$TSV" bash "$REPORT")" || fail "default report exited nonzero"
grep -q "grouped by op" <<<"$out"                 || fail "missing op-grouped header"
grep -q "board:list" <<<"$out"                    || fail "missing board:list op row"
grep -q "(untagged)" <<<"$out"                    || fail "empty op should render as (untagged)"
grep -q "classification rollup" <<<"$out"         || fail "missing classification rollup"
# graphql = the two 900+2000 rows -> total 2900; rest = 300; porcelain = 1200
graphql_row="$(awk '/rollup/{r=1} r&&/^graphql/{print; found=1} END{exit !found}' <<<"$out")" \
  && grep -qE "graphql[[:space:]]+2[[:space:]]+.*2900" <<<"$graphql_row" \
  || fail "graphql rollup wrong (want 2 calls / 2900ms)"
rest_row="$(awk '/rollup/{r=1} r&&/^rest/{print}' <<<"$out")"
grep -qE "rest[[:space:]]+1[[:space:]]+.*300" <<<"$rest_row" \
  || fail "rest rollup wrong (want 1 call / 300ms)"
echo "  [ok] default report + graphql/rest/porcelain classification"

# --- 3: --by context --------------------------------------------------------
out="$(GH_CALL_LOG_FILE="$TSV" bash "$REPORT" --by context)" || fail "--by context failed"
grep -q "grouped by context" <<<"$out" || fail "context grouping header missing"
grep -qE "worklist[[:space:]]+2" <<<"$out"  || fail "worklist context should have 2 calls"
grep -qE "reconcile[[:space:]]+2" <<<"$out" || fail "reconcile context should have 2 calls"
echo "  [ok] --by context grouping"

# --- 4: --emit freezes live summaries (source=live) -------------------------
LAKE="$WORK/lake"; mkdir -p "$LAKE"
GH_CALL_LOG_FILE="$TSV" GH_PERF_RAW_DIR="$LAKE" bash "$REPORT" --emit --phase before --label run >/dev/null \
  || fail "--emit failed"
LF="$(set -- "$LAKE"/gh-perf-*.jsonl; echo "$1")"
[ -e "$LF" ] || fail "--emit wrote no lake file"
jq -e 'select(.source=="live" and .phase=="before")' "$LF" >/dev/null || fail "emitted record not source=live/before"
jq -e 'select(.op_class=="board:list")' "$LF" >/dev/null || fail "board:list summary not emitted"
echo "  [ok] --emit freezes per-op live summaries (source=live)"

# --- 5: --compare delta/ratio -----------------------------------------------
CLAKE="$WORK/clake"; mkdir -p "$CLAKE"
{
  echo '{"phase":"before","op_class":"board:list","p50_ms":800,"source":"live","ts":"2026-07-04T10:00:00Z"}'
  echo '{"phase":"after","op_class":"board:list","p50_ms":300,"source":"gitbug","ts":"2026-07-04T11:00:00Z"}'
  echo '{"phase":"before","op_class":"_run_total","p50_ms":0,"gql_pts":40,"ts":"2026-07-04T10:00:00Z"}'
} >"$CLAKE/gh-perf-2026-07.jsonl"
out="$(GH_PERF_RAW_DIR="$CLAKE" bash "$REPORT" --compare)" || fail "--compare failed"
grep -qE "board:list[[:space:]]+800[[:space:]]+300[[:space:]]+-500" <<<"$out" \
  || fail "compare delta wrong (want 800 300 -500): $out"
grep -q "_run_total" <<<"$out" && fail "_run_total must be excluded from --compare"
echo "  [ok] --compare before->after delta/ratio (and _run_total excluded)"

# --- 6: arg validation ------------------------------------------------------
code=0; GH_CALL_LOG_FILE="$TSV" bash "$REPORT" --by bogus >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "bad --by should exit 2, got $code"
code=0; GH_CALL_LOG_FILE="$TSV" bash "$REPORT" --emit --label x >/dev/null 2>&1 || code=$?
[ "$code" -eq 2 ] || fail "--emit without --phase should exit 2, got $code"
echo "  [ok] arg validation (bad --by / --emit without --phase -> exit 2)"

# --- 7: absent TSV degrades gracefully --------------------------------------
out="$(GH_CALL_LOG_FILE="$WORK/nope.tsv" bash "$REPORT")" || fail "absent TSV should exit 0"
grep -qi "no live TSV" <<<"$out" || fail "absent TSV should print a notice"
echo "  [ok] absent TSV -> graceful notice, exit 0"

echo "PASS: gh-perf-report"
