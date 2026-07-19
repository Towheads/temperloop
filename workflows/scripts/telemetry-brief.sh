#!/usr/bin/env bash
#
# telemetry-brief.sh — the KERNEL-side five-question telemetry brief renderer
# (temperloop#431). Renders the same five operator questions the composed
# overlay's rich renderer (`build_telemetry_brief.py`, rollup-backed,
# overlay-only) answers — re-grounded in the raw streams a BARE KERNEL
# checkout actually emits, so `/check-in`'s Part 1 and the `/telemetry` pull
# surface work on a stranger's kernel-only clone with no overlay, no vault,
# and no rollup pipeline.
#
# The five questions (order and names shared with the overlay renderer):
#   1. Attention              — what needs you now
#   2. Funnel health & trust  — is the autonomous machinery alive and honest
#   3. Spend                  — what the pipeline is costing (kernel-observable
#                               spend: gh wall-time + knowledge-store op volume;
#                               token-cost spend is an overlay enrichment)
#   4. Improvement            — is landed work flowing (touch throughput;
#                               rework/retro yield is an overlay enrichment)
#   5. Command effectiveness  — /sweep + /triage volume and merge rate
#
# Sources (kernel-side raw streams ONLY — every section names its own source
# stream verbatim in the output, so numbers are reconcilable by reading the
# named file; canonical sink spec: meta/data/raw/README.md):
#   command-runs-<YYYY-MM>.jsonl               (emit-command-run.sh)
#   issue-touches-<YYYY-MM>.jsonl              (emit-issue-touch.sh, capture.sh)
#   claims-<YYYY-MM>.jsonl                     (board/claim.sh claim_log_emit)
#   funnel-<YYYY-MM>.jsonl                     (build/funnel-cron.sh)
#   gh-calls-<YYYY-MM>.jsonl                   (gh-call-logger.sh lake stream)
#   knowledge-search-fallback-<YYYY-MM>.jsonl  (lib/knowledge_search_mcp.sh)
#   knowledge-reads.log                        (lib/knowledge_store.sh
#                                               ks__read_log_emit — the ks
#                                               read-log; " · "-separated
#                                               lines, NOT jsonl)
#
# Degradation contract (the fresh-install case): an absent or empty stream
# renders an honest "no data yet — <stream> is empty" line for its section —
# never a crash, never a fabricated number. A stream with records but none
# inside the lookback window says so and names the freshest record it DID
# find. jq missing degrades the whole brief to an honest one-liner, exit 0.
# This script never mutates anything and always exits 0 (a status readout
# must never block the ritual that reads it).
#
# Usage:
#   telemetry-brief.sh [--lookback-days N]
#
# Knobs (registered in workflows/scripts/config/knob-registry.tsv):
#   TELEMETRY_LOOKBACK_DAYS  window for every windowed number (default 7;
#                            the --lookback-days flag wins over the env var,
#                            per docs/config-precedence.md rung 1 > rung 2)
#   TELEMETRY_RAW_DIR        the raw lake dir every stream falls back to when
#                            its own emitter's *_RAW_DIR override is unset
#                            (default: this checkout's meta/data/raw, resolved
#                            BASH_SOURCE-relative like emit-command-run.sh)
#   Per-stream overrides honored first, so the reader follows the emitters
#   wherever they were pointed: CMD_RUN_RAW_DIR, ISSUE_TOUCHES_RAW_DIR,
#   CLAIMS_RAW_DIR, FUNNEL_RAW_DIR, GH_CALLS_RAW_DIR,
#   KS_SEARCH_FALLBACK_RAW_DIR (registered by their owning emit scripts), and
#   KNOWLEDGE_READ_LOG (owning: lib/knowledge_store.sh — the fallback literal
#   below is a byte-identical duplicate of that owning seam, per the registry
#   header's documented duplicate-fallback convention).
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) and BSD/GNU
# date-portable, matching the rest of workflows/scripts/.

set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
: "${TELEMETRY_RAW_DIR:=$raw_root/meta/data/raw}"
: "${TELEMETRY_LOOKBACK_DAYS:=7}"

lookback="$TELEMETRY_LOOKBACK_DAYS"
while [ $# -gt 0 ]; do
  case "$1" in
    --lookback-days) lookback="${2:-$lookback}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$lookback" in
  ''|*[!0-9]*) lookback=7 ;;
esac

# Per-stream dir resolution: the emitter's own override env first (so reader
# and writer can never silently diverge), else the shared kernel lake.
cmd_run_dir="${CMD_RUN_RAW_DIR:-$TELEMETRY_RAW_DIR}"
issue_touch_dir="${ISSUE_TOUCHES_RAW_DIR:-$TELEMETRY_RAW_DIR}"
claims_dir="${CLAIMS_RAW_DIR:-$TELEMETRY_RAW_DIR}"
funnel_dir="${FUNNEL_RAW_DIR:-$TELEMETRY_RAW_DIR}"
gh_calls_dir="${GH_CALLS_RAW_DIR:-$TELEMETRY_RAW_DIR}"
ks_fallback_dir="${KS_SEARCH_FALLBACK_RAW_DIR:-$TELEMETRY_RAW_DIR}"
read_log="${KNOWLEDGE_READ_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log}"

# Human-facing "today" bucket renders in the operator's display timezone, not
# UTC, so a late-evening run isn't filed under tomorrow's date (kernel doc §
# Communication conventions). Belt-and-suspenders default per § Prose-resident
# knob convention — respects an exported DISPLAY_TZ, else the build.config.sh
# default. The interval math below (cutoff_iso / iso_to_epoch, epoch diffs) stays
# UTC by design: absolute instants, unaffected by display zone.
today="$(TZ="${DISPLAY_TZ:-America/Los_Angeles}" date +%Y-%m-%d)"

# ── date portability helpers (BSD first, GNU fallback) ──────────────────────
cutoff_iso() {  # $1 = days back -> ISO-8601 Z
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo ""
}
iso_to_epoch() {  # $1 = ISO-8601 Z timestamp -> epoch seconds ("" on failure)
  date -j -u -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo ""
}

cutoff="$(cutoff_iso "$lookback")"

# ── stream plumbing ──────────────────────────────────────────────────────────
stream_files() {  # $1=dir $2=stream-prefix -> matching month-files, one per line
  [ -d "$1" ] || return 0
  local f
  for f in "$1/$2"-*.jsonl; do
    [ -e "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

cat_stream() {  # $1=dir $2=stream-prefix -> concatenated records (may be empty)
  local f
  stream_files "$1" "$2" | while IFS= read -r f; do
    cat "$f" 2>/dev/null
  done
  return 0
}

# window_records <dir> <stream> -> JSON array of in-window records on stdout.
# Torn/corrupt lines are skipped (fromjson?), never fatal — append-only lake
# files can carry a partial last line mid-write.
window_records() {
  cat_stream "$1" "$2" \
    | jq -c -R 'fromjson? // empty' 2>/dev/null \
    | jq -s --arg c "$cutoff" '[ .[] | select((.ts // "") >= $c) ]' 2>/dev/null \
    || echo '[]'
}

stream_max_ts() {  # $1=dir $2=stream -> freshest .ts across all month-files
  cat_stream "$1" "$2" \
    | jq -c -R 'fromjson? // empty' 2>/dev/null \
    | jq -r '.ts // empty' 2>/dev/null \
    | sort | tail -1
}

stream_empty_line() {  # $1=stream-name $2=dir — the honest fresh-install line
  printf -- '- no data yet — %s stream is empty (%s/%s-*.jsonl)\n' "$1" "$2" "$1"
}

# stale_note <stream> <dir> <max_ts> — records exist, none in window
stale_note() {
  printf -- '- no %s records in the last %s days (freshest: %s)\n' "$1" "$lookback" "$3"
}

# ── header / data age ────────────────────────────────────────────────────────
echo "# Kernel telemetry brief — $today"
echo

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found — the kernel raw streams cannot be parsed, so no numbers are rendered."
  echo "Install jq, then re-run. Streams this brief would read:"
  echo "  $cmd_run_dir/command-runs-*.jsonl · $issue_touch_dir/issue-touches-*.jsonl · $claims_dir/claims-*.jsonl"
  echo "  $funnel_dir/funnel-*.jsonl · $gh_calls_dir/gh-calls-*.jsonl · $ks_fallback_dir/knowledge-search-fallback-*.jsonl"
  echo "  $read_log"
  exit 0
fi
if [ -z "$cutoff" ]; then
  echo "DATA AGE: UNKNOWN — could not compute the lookback cutoff (date(1) unsupported?); no numbers rendered."
  exit 0
fi

# Freshest record across every kernel stream (read log included) — the brief
# always leads with data age, matching the overlay renderer's contract.
freshest=""
freshest_src=""
for pair in \
  "command-runs=$cmd_run_dir" \
  "issue-touches=$issue_touch_dir" \
  "claims=$claims_dir" \
  "funnel=$funnel_dir" \
  "gh-calls=$gh_calls_dir" \
  "knowledge-search-fallback=$ks_fallback_dir"; do
  s="${pair%%=*}"; d="${pair#*=}"
  ts="$(stream_max_ts "$d" "$s")"
  if [ -n "$ts" ] && [ "$ts" \> "$freshest" ]; then
    freshest="$ts"; freshest_src="$s"
  fi
done
if [ -f "$read_log" ]; then
  ts="$(awk -F' · ' 'NF { last = $1 } END { print last }' "$read_log" 2>/dev/null)"
  if [ -n "$ts" ] && [ "$ts" \> "$freshest" ]; then
    freshest="$ts"; freshest_src="knowledge-reads.log"
  fi
fi

if [ -z "$freshest" ]; then
  echo "DATA AGE: UNKNOWN — no records in any kernel stream yet (fresh install, or nothing has emitted on this host)."
else
  now_epoch="$(date -u +%s)"
  fresh_epoch="$(iso_to_epoch "$freshest")"
  if [ -n "$fresh_epoch" ]; then
    age_h=$(( (now_epoch - fresh_epoch) / 3600 ))
    if [ "$age_h" -gt 24 ]; then
      echo "DATA STALE: freshest kernel-stream record is ${age_h}h old ($freshest, from $freshest_src) — treat every number below with suspicion."
    else
      echo "DATA AGE: ${age_h}h (freshest record $freshest, from $freshest_src)"
    fi
  else
    echo "DATA AGE: UNKNOWN — freshest record timestamp unparsable ($freshest, from $freshest_src)"
  fi
fi
echo
echo "Window: last $lookback days (records with ts >= $cutoff) · kernel raw streams only — each section names its source. Token-cost, rework, and retro-yield numbers are an OVERLAY enrichment (rollup-backed \`build_telemetry_brief.py\`); this brief stands alone without them."

cmd_runs="$(window_records "$cmd_run_dir" "command-runs")"
cmd_files="$(stream_files "$cmd_run_dir" "command-runs")"
funnel_recs="$(window_records "$funnel_dir" "funnel")"
funnel_files="$(stream_files "$funnel_dir" "funnel")"

# ── 1. Attention ─────────────────────────────────────────────────────────────
echo
echo "## 1. Attention — what needs you now"
echo "source: command-runs-*.jsonl @ $cmd_run_dir · funnel-*.jsonl @ $funnel_dir"
attention_any=0
if [ -n "$cmd_files" ]; then
  n="$(printf '%s' "$cmd_runs" | jq 'length')"
  if [ "$n" -gt 0 ]; then
    parked="$(printf '%s' "$cmd_runs" | jq '[ .[].parked ] | add // 0')"
    runs_with_parked="$(printf '%s' "$cmd_runs" | jq '[ .[] | select((.parked // 0) > 0) ] | length')"
    echo "- parked/deferred items (${lookback}d): $parked across $runs_with_parked of $n command runs (each parked item is waiting on a human or a gate)"
    attention_any=1
  fi
fi
if [ -n "$funnel_files" ]; then
  n="$(printf '%s' "$funnel_recs" | jq 'length')"
  if [ "$n" -gt 0 ]; then
    drive_errs="$(printf '%s' "$funnel_recs" | jq '[ .[] | select(.event == "drive" and (has("reason"))) ] | length')"
    echo "- funnel drive errors (${lookback}d): $drive_errs (drive records carrying an error reason)"
    attention_any=1
  fi
fi
if [ "$attention_any" -eq 0 ]; then
  if [ -z "$cmd_files" ]; then stream_empty_line "command-runs" "$cmd_run_dir"; fi
  if [ -z "$funnel_files" ]; then stream_empty_line "funnel" "$funnel_dir"; fi
  if [ -n "$cmd_files" ] || [ -n "$funnel_files" ]; then
    echo "- no in-window attention signals (streams present, no records in the last $lookback days)"
  fi
fi
echo "note: parked \`/build\` items live in the active plan note's own item statuses, not a raw stream — check the plan note directly; the overlay brief adds funnel escalation/hand-off detail."

# ── 2. Funnel health & trust ────────────────────────────────────────────────
echo
echo "## 2. Funnel health & trust"
echo "source: funnel-*.jsonl @ $funnel_dir · knowledge-search-fallback-*.jsonl @ $ks_fallback_dir"
if [ -z "$funnel_files" ]; then
  stream_empty_line "funnel" "$funnel_dir"
else
  n="$(printf '%s' "$funnel_recs" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    stale_note "funnel" "$funnel_dir" "$(stream_max_ts "$funnel_dir" "funnel")"
  else
    ran="$(printf '%s' "$funnel_recs" | jq '[ .[] | select(.event == "ran") ] | length')"
    skipped="$(printf '%s' "$funnel_recs" | jq '[ .[] | select(.event == "skipped") ] | length')"
    drives="$(printf '%s' "$funnel_recs" | jq '[ .[] | select(.event == "drive") ] | length')"
    drive_errs="$(printf '%s' "$funnel_recs" | jq '[ .[] | select(.event == "drive" and (has("reason"))) ] | length')"
    last_wake="$(printf '%s' "$funnel_recs" | jq -r '[ .[].ts ] | max // "unknown"')"
    echo "- wakes (${lookback}d): $n (ran $ran · skipped $skipped · drive $drives, of which $drive_errs errored) · last wake: $last_wake"
  fi
fi
ksf_files="$(stream_files "$ks_fallback_dir" "knowledge-search-fallback")"
if [ -z "$ksf_files" ]; then
  echo "- no data yet — knowledge-search-fallback stream is empty ($ks_fallback_dir/knowledge-search-fallback-*.jsonl); zero recorded fallbacks — a signal of health only if the warm backend is actually in use"
else
  ksf="$(window_records "$ks_fallback_dir" "knowledge-search-fallback")"
  nf="$(printf '%s' "$ksf" | jq 'length')"
  echo "- knowledge-search warm→cold fallbacks (${lookback}d): $nf (each = one session degraded to the slow search path)"
fi

# ── 3. Spend ─────────────────────────────────────────────────────────────────
echo
echo "## 3. Spend — kernel-observable cost"
echo "source: gh-calls-*.jsonl @ $gh_calls_dir · ks read-log (knowledge_store.sh ks__read_log_emit) @ $read_log"
gh_files="$(stream_files "$gh_calls_dir" "gh-calls")"
if [ -z "$gh_files" ]; then
  stream_empty_line "gh-calls" "$gh_calls_dir"
else
  gh_recs="$(window_records "$gh_calls_dir" "gh-calls")"
  n="$(printf '%s' "$gh_recs" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    stale_note "gh-calls" "$gh_calls_dir" "$(stream_max_ts "$gh_calls_dir" "gh-calls")"
  else
    total_s="$(printf '%s' "$gh_recs" | jq '([ .[].dur_ms ] | add // 0) / 1000 | floor')"
    fails="$(printf '%s' "$gh_recs" | jq '[ .[] | select((.exit_code // 0) != 0) ] | length')"
    top="$(printf '%s' "$gh_recs" | jq -r '
      group_by(.context // "unattributed")
      | map({ctx: (.[0].context // "unattributed"), n: length, s: (([ .[].dur_ms ] | add // 0) / 1000 | floor)})
      | sort_by(-.s) | .[0:3]
      | map("\(.ctx) (\(.n) calls, \(.s)s)") | join(" · ")')"
    echo "- gh/git-bug calls (${lookback}d): $n, ${total_s}s total wall-time, $fails non-zero exits · top contexts: ${top:-none}"
  fi
fi
if [ ! -f "$read_log" ]; then
  echo "- no data yet — ks read-log is empty (no file at $read_log)"
else
  ks_counts="$(awk -F' · ' -v c="$cutoff" '
    NF >= 4 && $1 >= c { total++; ops[$4]++ }
    END {
      printf "%d", total + 0
      for (o in ops) printf " %s=%d", o, ops[o]
    }' "$read_log" 2>/dev/null)"
  ks_total="${ks_counts%% *}"
  if [ -z "$ks_total" ] || [ "$ks_total" = "0" ]; then
    echo "- no knowledge-store ops in the last $lookback days (read log present at $read_log)"
  else
    ks_by_op="${ks_counts#* }"
    [ "$ks_by_op" = "$ks_counts" ] && ks_by_op=""
    echo "- knowledge-store ops (${lookback}d): $ks_total ($ks_by_op)"
  fi
fi
echo "note: token-cost spend (cost-per-epic) requires the overlay rollup pipeline — not available kernel-side."

# ── 4. Improvement ───────────────────────────────────────────────────────────
echo
echo "## 4. Improvement — is landed work flowing"
echo "source: issue-touches-*.jsonl @ $issue_touch_dir ∪ claims-*.jsonl @ $claims_dir (unioned at read time per meta/data/raw/README.md)"
it_files="$(stream_files "$issue_touch_dir" "issue-touches")"
cl_files="$(stream_files "$claims_dir" "claims")"
if [ -z "$it_files" ] && [ -z "$cl_files" ]; then
  stream_empty_line "issue-touches" "$issue_touch_dir"
  stream_empty_line "claims" "$claims_dir"
else
  touches="$(window_records "$issue_touch_dir" "issue-touches")"
  claims="$(window_records "$claims_dir" "claims")"
  merges="$(printf '%s' "$touches" | jq '[ .[] | select(.kind == "merge") ] | length')"
  propens="$(printf '%s' "$touches" | jq '[ .[] | select(.kind == "pr-open") ] | length')"
  captures="$(printf '%s' "$touches" | jq '[ .[] | select(.kind == "capture") ] | length')"
  nclaims="$(printf '%s' "$claims" | jq 'length')"
  if [ "$((merges + propens + captures + nclaims))" -eq 0 ]; then
    echo "- no issue touches in the last $lookback days (freshest issue-touch: $(stream_max_ts "$issue_touch_dir" "issue-touches" || true)${cl_files:+ · freshest claim: $(stream_max_ts "$claims_dir" "claims")})"
  else
    echo "- issue touches (${lookback}d): $merges merged · $propens PRs opened · $captures captured · $nclaims claimed"
    [ -z "$it_files" ] && stream_empty_line "issue-touches" "$issue_touch_dir"
    [ -z "$cl_files" ] && stream_empty_line "claims" "$claims_dir"
  fi
fi
echo "note: rework events, attributed rework cost, and retro yield are overlay-rollup enrichments."

# ── 5. Command effectiveness ────────────────────────────────────────────────
echo
echo "## 5. Command effectiveness"
echo "source: command-runs-*.jsonl @ $cmd_run_dir"
if [ -z "$cmd_files" ]; then
  stream_empty_line "command-runs" "$cmd_run_dir"
else
  n="$(printf '%s' "$cmd_runs" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    stale_note "command-runs" "$cmd_run_dir" "$(stream_max_ts "$cmd_run_dir" "command-runs")"
  else
    printf '%s' "$cmd_runs" | jq -r '
      group_by(.command)
      | .[]
      | {cmd: .[0].command, runs: length,
         items: ([ .[].items_processed ] | add // 0),
         merged: ([ .[].merged ] | add // 0),
         parked: ([ .[].parked ] | add // 0)}
      | "- \(.cmd): \(.runs) runs · \(.items) items · \(.merged) merged · \(.parked) parked" +
        (if .items > 0 then " · merge rate \((.merged * 100 / .items) | floor)%" else "" end)'
  fi
fi

echo
echo "— end of kernel brief. Overlay enrichment (when composed): rollup-backed digest via workflows/scripts/build_telemetry_brief.py."
exit 0
