#!/usr/bin/env bash
#
# gh-perf-report.sh — the GO/NO-GO artifact for the F#988 tracker evaluation.
# Reads the gh-call-logger v2 TSV (the passive live window) and the gh-perf lake
# (the gh-bench synthetic anchor + frozen live summaries) and renders the tables
# a human uses to decide whether the migration paid off:
#
#   (default)            per-op-class table from the live TSV + a
#                        graphql/rest/porcelain classification rollup + time share%.
#   --by op|context|class   choose the grouping key (default op).
#   --emit --phase P --label L
#                        freeze the current live-window per-op summaries into the
#                        lake (source=live) via emit-gh-perf.sh, so a --compare
#                        later has a durable before/after anchor.
#   --compare            join the lake's before vs after per op_class and show the
#                        delta + ratio — the one table that answers "did it help".
#
# Classification is derived HERE (report time) from the args column, so the shim
# stays dumb and never distorts the timing it records:
#   graphql   — `api graphql`, `project …`, or any arg containing "graphql"
#   rest      — `api <path>` (a direct REST endpoint)
#   porcelain — everything else (issue/pr/… subcommands; REST underneath)
#
# Inputs (overridable):
#   --tsv PATH    live TSV (default: $GH_CALL_LOG_FILE or ~/.cache/gh-calls-v2.tsv)
#   --lake DIR    lake dir  (default: $GH_PERF_RAW_DIR or <repo>/meta/data/raw)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="${GH_PERF_REPORT_EMIT_BIN:-$HERE/../emit-gh-perf.sh}"

die() { echo "gh-perf-report: $1" >&2; exit 2; }

TSV="${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}"
raw_root="$(cd -P "$HERE/../../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
LAKE="${GH_PERF_RAW_DIR:-$raw_root/meta/data/raw}"
by="op"; do_emit=0; do_compare=0; phase=""; label=""

while [ $# -gt 0 ]; do
  case "$1" in
    --by)      by="${2:-}"; shift 2 ;;
    --emit)    do_emit=1; shift ;;
    --compare) do_compare=1; shift ;;
    --phase)   phase="${2:-}"; shift 2 ;;
    --label)   label="${2:-}"; shift 2 ;;
    --tsv)     TSV="${2:-}"; shift 2 ;;
    --lake)    LAKE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

case "$by" in op|context|class) : ;; *) die "--by must be op|context|class" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"

# ---------------------------------------------------------------------------
# _agg <tsv> <mode>  ->  rows "key\tcalls\tp50\tp95\tmax\ttotal\tshare_pct"
#   sorted by total_ms desc. Percentiles are nearest-rank over the per-key
#   duration set (sorted by the pipeline before the aggregation awk).
# ---------------------------------------------------------------------------
_agg() {
  local tsv="$1" mode="$2"
  [ -f "$tsv" ] || return 0
  awk -F'\t' -v mode="$mode" '
    function classify(a) {
      if (a ~ /graphql/) return "graphql"
      if (a ~ /^project([ ]|$)/) return "graphql"
      if (a ~ /^api[ ]/) return "rest"
      return "porcelain"
    }
    NF>=10 {
      if (mode=="context")   key=$7
      else if (mode=="class") key=classify($10)
      else                    key=$8
      if (key=="") key = (mode=="context") ? "(none)" : "(untagged)"
      print key "\t" ($2+0)
    }' "$tsv" \
  | sort -t"$(printf '\t')" -k1,1 -k2,2n \
  | awk -F'\t' '
    {
      k=$1; d=$2+0
      if (k!=cur) { if (cur!="") flush(); cur=k; n=0; sum=0; split("",arr) }
      arr[++n]=d; sum+=d
    }
    END {
      if (cur!="") flush()
      for (i=1;i<=g;i++) {
        share = (gtot>0) ? (gsum[i]*100.0/gtot) : 0
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%.1f\n", gname[i],gn[i],gp50[i],gp95[i],gmx[i],gsum[i],share
      }
    }
    function flush() {
      g++
      gname[g]=cur; gn[g]=n; gsum[g]=sum; gmx[g]=arr[n]
      gp50[g]=arr[int((n-1)*0.5)+1]
      gp95[g]=arr[int((n-1)*0.95)+1]
      gtot+=sum
    }' \
  | sort -t"$(printf '\t')" -k6,6 -rn
}

# ---------------------------------------------------------------------------
# --emit: freeze the live window's per-op summaries into the lake (source=live)
# ---------------------------------------------------------------------------
if [ "$do_emit" -eq 1 ]; then
  [ -n "$phase" ] || die "--emit requires --phase before|after"
  [ -n "$label" ] || die "--emit requires --label"
  case "$phase" in before|after) : ;; *) die "--phase must be before|after" ;; esac
  [ -f "$TSV" ] || die "no live TSV at $TSV — nothing to emit"
  n=0
  while IFS="$(printf '\t')" read -r key calls p50 p95 mx total _share; do
    [ -n "$key" ] || continue
    GH_PERF_RAW_DIR="$LAKE" "$EMIT" --phase "$phase" --label "$label" --source live \
      --board 0 --op-class "$key" --count "$calls" \
      --p50 "$p50" --p95 "$p95" --max "$mx" --total "$total" >/dev/null 2>&1 || true
    n=$((n+1))
  done <<EOF
$(_agg "$TSV" op)
EOF
  echo "gh-perf-report: emitted $n live-window op summaries (phase=$phase label=$label) to the lake"
  exit 0
fi

# ---------------------------------------------------------------------------
# --compare: before vs after per op_class, from the lake
# ---------------------------------------------------------------------------
if [ "$do_compare" -eq 1 ]; then
  files=""
  for f in "$LAKE"/gh-perf-*.jsonl; do [ -e "$f" ] && files="$files $f"; done
  [ -n "$files" ] || die "no lake files under $LAKE"
  echo "== gh-perf before -> after (per op_class; latest record per phase) =="
  printf '%-18s %10s %10s %9s %7s\n' "op_class" "before_p50" "after_p50" "delta" "ratio"
  printf '%-18s %10s %10s %9s %7s\n' "------------------" "----------" "----------" "---------" "-------"
  # shellcheck disable=SC2086  # intentional word-split of the file list
  jq -rs '
    map(select(.op_class!="_run_total"))
    | (map(select(.phase=="before")) | group_by(.op_class)
        | map({key:.[0].op_class, value:(sort_by(.ts)|last)}) | from_entries) as $before
    | (map(select(.phase=="after"))  | group_by(.op_class)
        | map({key:.[0].op_class, value:(sort_by(.ts)|last)}) | from_entries) as $after
    | ([$before|keys[]] + [$after|keys[]] | unique)
    | map({op:., b:($before[.].p50_ms // 0), a:($after[.].p50_ms // 0)})
    | .[] | [.op, .b, .a, (.a - .b),
             (if .b>0 then (.a/.b) else 0 end)] | @tsv
  ' $files \
  | while IFS="$(printf '\t')" read -r op b a delta ratio; do
      printf '%-18s %10s %10s %9s %6.2fx\n' "$op" "$b" "$a" "$delta" "$ratio"
    done
  exit 0
fi

# ---------------------------------------------------------------------------
# default: live-window report from the TSV
# ---------------------------------------------------------------------------
if [ ! -f "$TSV" ]; then
  echo "gh-perf-report: no live TSV at $TSV yet — run some gh commands with the v2 shim installed first."
  exit 0
fi

rows="$(_agg "$TSV" "$by")"
total_calls="$(awk -F'\t' 'END{print NR}' "$TSV")"
echo "== gh-perf live window ($TSV) — $total_calls calls, grouped by $by =="
printf '%-26s %7s %8s %8s %8s %10s %7s\n' "$by" "calls" "p50_ms" "p95_ms" "max_ms" "total_ms" "share%"
printf '%-26s %7s %8s %8s %8s %10s %7s\n' "--------------------------" "-------" "--------" "--------" "--------" "----------" "-------"
if [ -n "$rows" ]; then
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r key calls p50 p95 mx total share; do
    printf '%-26s %7s %8s %8s %8s %10s %6s%%\n' "$key" "$calls" "$p50" "$p95" "$mx" "$total" "$share"
  done
fi

echo
echo "== classification rollup (graphql / rest / porcelain) =="
printf '%-12s %7s %8s %8s %10s %7s\n' "class" "calls" "p50_ms" "p95_ms" "total_ms" "share%"
printf '%-12s %7s %8s %8s %10s %7s\n' "------------" "-------" "--------" "--------" "----------" "-------"
_agg "$TSV" class | while IFS="$(printf '\t')" read -r key calls p50 p95 _mx total share; do
  printf '%-12s %7s %8s %8s %10s %6s%%\n' "$key" "$calls" "$p50" "$p95" "$total" "$share"
done
