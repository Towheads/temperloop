#!/usr/bin/env bash
#
# emit-gh-perf.sh — append one record to the append-only gh-performance raw-lake
# stream (F#988, the git-bug tracker evaluation's before/after measurement).
# Sibling to emit-issue-touch.sh / emit-command-run.sh: same structure, arg
# style, WARN-don't-drop contract, and <repo>/meta/data/raw sink resolution.
#
# WHY THIS EXISTS: the F#983 retro proved gh time is a real cost but left no
# durable per-op timing. gh-bench.sh (the synthetic anchor) and
# gh-perf-report.sh --emit (the live-window freeze) both summarise many gh calls
# into per-op-class stats; this script is the ONE place those summaries become a
# lake record, so the schema lives in exactly one spot and both producers agree.
#
# One record = one (run, op_class) summary. The raw per-call durations live in
# the gh-call-logger v2 TSV (~/.cache/gh-calls-v2.tsv); this stream is the
# rolled-up, comparable artifact the --compare before/after report reads.
#
# Usage:
#   emit-gh-perf.sh --phase before|after --label <str> --board <N> \
#                   --op-class <name> --count <N> \
#                   [--source bench|live] [--backend github|git-bug] \
#                   [--p50 <ms>] [--p95 <ms>] [--max <ms>] [--total <ms>] \
#                   [--gql-pts <n>] [--rest-calls <n>]
#
# Appends ONE JSONL line to:
#   ${GH_PERF_RAW_DIR:-<repo>/meta/data/raw}/gh-perf-YYYY-MM.jsonl
# (monthly rotation, matching the claims-/command-runs-/issue-touches-YYYY-MM
# convention already used in meta/data/raw/).
#
# Record shape: {schema_version, ts, phase, label, source, backend, board,
#                op_class, count, p50_ms, p95_ms, max_ms, total_ms, gql_pts,
#                rest_calls, session_id, host}
#
# WARN, DON'T DROP: any failure (bad args, jq missing, sink unwritable) warns to
# stderr and exits 0 — a telemetry emit must never fail the caller (the same
# contract emit-issue-touch.sh follows). Kept POSIX-bash-3.2-friendly.
set -uo pipefail

self="$(basename "$0")"

phase=""; label=""; board=""; op_class=""; count=""
source_kind="bench"; backend="github"
p50="0"; p95="0"; max="0"; total="0"; gql_pts="0"; rest_calls="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)      phase="${2:-}"; shift 2 ;;
    --label)      label="${2:-}"; shift 2 ;;
    --board)      board="${2:-}"; shift 2 ;;
    --op-class)   op_class="${2:-}"; shift 2 ;;
    --count)      count="${2:-}"; shift 2 ;;
    --source)     source_kind="${2:-}"; shift 2 ;;
    --backend)    backend="${2:-}"; shift 2 ;;
    --p50)        p50="${2:-}"; shift 2 ;;
    --p95)        p95="${2:-}"; shift 2 ;;
    --max)        max="${2:-}"; shift 2 ;;
    --total)      total="${2:-}"; shift 2 ;;
    --gql-pts)    gql_pts="${2:-}"; shift 2 ;;
    --rest-calls) rest_calls="${2:-}"; shift 2 ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$phase" ] || [ -z "$label" ] || [ -z "$board" ] || [ -z "$op_class" ] || [ -z "$count" ]; then
  printf '%s: WARN --phase, --label, --board, --op-class, --count are all required — no record emitted\n' "$self" >&2
  exit 0
fi

case "$phase" in before|after) : ;; *)
  printf '%s: WARN --phase must be before|after, got %s — no record emitted\n' "$self" "$phase" >&2
  exit 0 ;;
esac

# Numeric guard: every count/stat must be a non-negative integer (ms).
for pair in "count=$count" "p50=$p50" "p95=$p95" "max=$max" "total=$total" \
            "gql_pts=$gql_pts" "rest_calls=$rest_calls"; do
  v="${pair#*=}"
  case "$v" in ''|*[!0-9]*)
    printf '%s: WARN %s must be a non-negative integer, got %s — no record emitted\n' "$self" "${pair%%=*}" "$v" >&2
    exit 0 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (op_class=%s)\n' "$self" "$op_class" >&2
  exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"
host="${SUBSET_HOST_LABEL:-$(hostname -s)}"

# Resolve the raw sink dir exactly as emit-issue-touch.sh does: explicit
# override first, else the repo this script lives in (<repo>/meta/data/raw), so
# it works from any checkout that vendors this file.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${GH_PERF_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/gh-perf-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

record="$(jq -nc \
  --arg ts "$ts" \
  --arg phase "$phase" \
  --arg label "$label" \
  --arg source "$source_kind" \
  --arg backend "$backend" \
  --argjson board "$board" \
  --arg op_class "$op_class" \
  --argjson count "$count" \
  --argjson p50 "$p50" \
  --argjson p95 "$p95" \
  --argjson max "$max" \
  --argjson total "$total" \
  --argjson gql_pts "$gql_pts" \
  --argjson rest_calls "$rest_calls" \
  --arg session_id "$session_id" \
  --arg host "$host" \
  '{
    schema_version: "1",
    ts: $ts,
    phase: $phase,
    label: $label,
    source: $source,
    backend: $backend,
    board: $board,
    op_class: $op_class,
    count: $count,
    p50_ms: $p50,
    p95_ms: $p95,
    max_ms: $max,
    total_ms: $total,
    gql_pts: $gql_pts,
    rest_calls: $rest_calls,
    session_id: (if $session_id == "" then null else $session_id end),
    host: $host
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (op_class=%s) — no record emitted\n' "$self" "$op_class" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (op_class=%s)\n' "$self" "$raw_file" "$op_class" >&2
  exit 0
fi

printf '%s\n' "$record"
