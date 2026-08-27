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
#   2. Pipeline health & trust  — is the autonomous machinery alive and honest
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
#   pipeline-<YYYY-MM>.jsonl                     (build/pipeline-cron.sh)
#   gh-calls-<YYYY-MM>.jsonl                   (gh-call-logger.sh lake stream)
#   item-efficiency-<YYYY-MM>.jsonl            (emit-item-efficiency.sh — the
#                                               per-merged-item overhead record,
#                                               temperloop#943)
#   knowledge-search-fallback-<YYYY-MM>.jsonl  (lib/knowledge_search_mcp.sh)
#   knowledge-reads.log                        (lib/knowledge_store.sh
#                                               ks__read_log_emit — the ks
#                                               read-log; " · "-separated
#                                               lines, NOT jsonl)
#
# ONE DELIBERATE EXCEPTION to "kernel raw streams only": section 1's
# asynchronous-workflow-health bullet (temperloop#1297) is a LIVE read of
# GitHub's own run history via async-workflow-health.sh, because a workflow's
# redness exists nowhere else — no emitter can write it into the lake. The
# section's own `source:` line names it as live rather than letting it pass
# for a stream, and the detector owns its own degradation and always exits 0,
# so the offline brief still renders in full without gh, jq, or a network.
#
# Degradation contract (the fresh-install case): an absent or empty stream
# renders an honest "no data yet — <stream> is empty" line for its section —
# never a crash, never a fabricated number. A stream with records but none
# inside the lookback window says so and names the freshest record it DID
# find. jq missing degrades the whole brief to an honest one-liner, exit 0.
# This script never mutates anything and always exits 0 (a status readout
# must never block the check-in that reads it).
#
# Usage:
#   telemetry-brief.sh [--lookback-days N]
#
# Settings (registered in workflows/scripts/config/setting-registry.tsv):
#   TELEMETRY_LOOKBACK_DAYS  window for every windowed number (default 7;
#                            the --lookback-days flag wins over the env var,
#                            per docs/config-precedence.md layer 1 > layer 2)
#   TELEMETRY_RAW_DIR        the raw lake dir every stream falls back to when
#                            its own emitter's *_RAW_DIR override is unset
#                            (default: this checkout's meta/data/raw, resolved
#                            BASH_SOURCE-relative like emit-command-run.sh).
#                            The PIPELINE stream still honors an explicitly-set
#                            TELEMETRY_RAW_DIR (the shared override must keep
#                            winning) but falls through to the writer's own
#                            absolute pin — not this checkout-relative default
#                            — when NEITHER PIPELINE_RAW_DIR nor
#                            TELEMETRY_RAW_DIR was set at all; see its own
#                            comment below (temperloop#1564).
#   Per-stream overrides honored first, so the reader follows the emitters
#   wherever they were pointed: CMD_RUN_RAW_DIR, ISSUE_TOUCHES_RAW_DIR,
#   CLAIMS_RAW_DIR, PIPELINE_RAW_DIR, GH_CALLS_RAW_DIR,
#   ITEM_EFFICIENCY_RAW_DIR,
#   KS_SEARCH_FALLBACK_RAW_DIR (registered by their owning emit scripts), and
#   KNOWLEDGE_READ_LOG (owning: lib/knowledge_store.sh — the fallback literal
#   below is a byte-identical duplicate of that owning seam, per the registry
#   header's documented duplicate-fallback convention).
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) and BSD/GNU
# date-portable, matching the rest of workflows/scripts/.

set -uo pipefail

here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${HOME:=/nonexistent}"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"

# Captured BEFORE the `:=` below applies this script's own checkout-relative
# fallback, so the PIPELINE-stream default further down can tell "the
# operator explicitly pointed the shared TELEMETRY_RAW_DIR fallback
# somewhere" (which must still win, unchanged) from "nothing was set" (which
# must fall through to the writer's own absolute pin, not a checkout-relative
# guess). `+1` tests SET-ness, not emptiness, and — unlike `:-`/`:=`/`-`/`=` —
# is not a seam operator the setting-registry lint scans for, so this probe
# doesn't create a second, divergent-literal TELEMETRY_RAW_DIR seam. Mirrors
# workflows/scripts/build/pipeline-retro-health.sh's identical probe.
telemetry_raw_dir_set="${TELEMETRY_RAW_DIR+1}"

: "${TELEMETRY_RAW_DIR:=$raw_root/meta/data/raw}"
: "${TELEMETRY_LOOKBACK_DAYS:=7}"

lookback="$TELEMETRY_LOOKBACK_DAYS"
while [ $# -gt 0 ]; do
  case "$1" in
    --lookback-days) lookback="${2:-$lookback}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *) shift ;;
  esac
done
case "$lookback" in
  ''|*[!0-9]*) lookback=7 ;;
esac

# Per-stream dir resolution: the emitter's own override env first (the reader
# follows the writer wherever an override pointed it), else the shared
# checkout-relative lake — which, with no env set, is ALSO where the three
# streams' writers land by default: emit-command-run.sh, emit-issue-touch.sh,
# capture.sh and claim.sh all default to their own checkout's
# meta/data/raw (claim.sh/capture.sh via git-toplevel since temperloop#1822;
# before that they pinned $HOME/dev/foundation and this reader silently saw
# an empty directory from any other checkout). The default-path convergence
# therefore holds only when reader and writers are the SAME checkout's
# scripts — a cross-checkout read still needs the env overrides.
cmd_run_dir="${CMD_RUN_RAW_DIR:-$TELEMETRY_RAW_DIR}"
issue_touch_dir="${ISSUE_TOUCHES_RAW_DIR:-$TELEMETRY_RAW_DIR}"
claims_dir="${CLAIMS_RAW_DIR:-$TELEMETRY_RAW_DIR}"
# PIPELINE stream: NOT unconditionally $TELEMETRY_RAW_DIR like the three
# siblings above. Its writer, pipeline-cron.sh:299, pins this stream to an
# ABSOLUTE, checkout-independent sink on purpose — "the CANONICAL ABSOLUTE
# SINK... deliberately NOT derived from $FOUNDATION" (that script's own
# comment, foundation#725), because the cron sandbox checkout must still
# write into the MAIN checkout's lake. Mirroring the checkout-relative
# $TELEMETRY_RAW_DIR here UNCONDITIONALLY would make this reader silently see
# a DIFFERENT, empty directory whenever it runs from any checkout other than
# $HOME/dev/foundation (temperloop#1564 — the sibling defect temperloop#1185
# already fixed in pipeline-retro-health.sh). But an EXPLICITLY-set
# TELEMETRY_RAW_DIR must still win for this stream too (the shared override
# is an intentional escape hatch, e.g. a sandboxed telemetry-brief run) —
# telemetry_raw_dir_set (captured above, before the `:=`) tells "explicitly
# set" apart from "defaulted". Only when NEITHER PIPELINE_RAW_DIR nor an
# explicit TELEMETRY_RAW_DIR was given does this fall through to the writer's
# own literal, duplicated verbatim (setting-registry.tsv's PIPELINE_RAW_DIR
# row, owning script pipeline-cron.sh — a "non-vendoring-checkout fallback"
# duplicate, same convention as pipeline-retro-health.sh's own PIPELINE
# stream default), never re-derived from $raw_root. Mirrors
# pipeline-retro-health.sh:144-154's identical three-way resolution.
pipeline_dir="${PIPELINE_RAW_DIR:-}"
if [ -z "$pipeline_dir" ]; then
  if [ -n "$telemetry_raw_dir_set" ]; then
    pipeline_dir="$TELEMETRY_RAW_DIR"
  else
    # Mirrors pipeline-cron.sh:299's own PIPELINE_RAW_DIR default literal,
    # byte-for-byte — see the header note above. Do NOT derive this from
    # $raw_root.
    pipeline_dir="$HOME/dev/foundation/meta/data/raw"
  fi
fi
# PERMANENT legacy-prefix read (temperloop#767 confirmed this survives the
# v0.19.0 window close, unlike the env shim and the forwarding stubs): the
# raw lake is append-only immutable history, so a pre-rename install's
# funnel-<YYYY-MM>.jsonl month-files can never be rewritten into the renamed
# prefix — stream_files unions them in READ-ONLY and forever (writers emit
# only pipeline-*.jsonl). NOTE once per run when any are present. See
# meta/data/raw/README.md § `pipeline`.
for _lf in "$pipeline_dir"/funnel-*.jsonl; do
  if [ -e "$_lf" ]; then
    echo "NOTE: reading legacy funnel-*.jsonl telemetry (the pipeline stream was renamed pipeline-*.jsonl in v0.17.0, temperloop#729; this read is permanent — the lake is append-only)" >&2
    break
  fi
done
unset _lf
gh_calls_dir="${GH_CALLS_RAW_DIR:-$TELEMETRY_RAW_DIR}"
item_eff_dir="${ITEM_EFFICIENCY_RAW_DIR:-$TELEMETRY_RAW_DIR}"
ks_fallback_dir="${KS_SEARCH_FALLBACK_RAW_DIR:-$TELEMETRY_RAW_DIR}"
read_log="${KNOWLEDGE_READ_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/foundation/knowledge-reads.log}"

# Human-facing "today" bucket renders in the operator's display timezone, not
# UTC, so a late-evening run isn't filed under tomorrow's date (kernel doc §
# Communication conventions). Belt-and-suspenders default per § Named-setting convention
# setting convention — respects an exported DISPLAY_TZ, else the build.config.sh
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
  # PERMANENT legacy-prefix read (temperloop#729 renamed the stream;
  # temperloop#767 kept THIS read when the rest of the window closed): the
  # pipeline stream was named funnel-<YYYY-MM>.jsonl before the terminology
  # consolidation, and the lake is append-only immutable history — those
  # month-files can never be renamed, so union them in read-only, forever, or
  # an existing install's accumulated history goes dark. Writers emit only
  # the new name. Self-limiting: no new legacy file is ever created.
  if [ "$2" = "pipeline" ]; then
    for f in "$1/funnel"-*.jsonl; do
      [ -e "$f" ] && printf '%s\n' "$f"
    done
  fi
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
  echo "  $pipeline_dir/pipeline-*.jsonl · $gh_calls_dir/gh-calls-*.jsonl · $ks_fallback_dir/knowledge-search-fallback-*.jsonl"
  echo "  $item_eff_dir/item-efficiency-*.jsonl"
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
  "pipeline=$pipeline_dir" \
  "gh-calls=$gh_calls_dir" \
  "item-efficiency=$item_eff_dir" \
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
pipeline_recs="$(window_records "$pipeline_dir" "pipeline")"
pipeline_files="$(stream_files "$pipeline_dir" "pipeline")"

# ── 1. Attention ─────────────────────────────────────────────────────────────
echo
echo "## 1. Attention — what needs you now"
echo "source: command-runs-*.jsonl @ $cmd_run_dir · pipeline-*.jsonl @ $pipeline_dir · async workflow health: LIVE (async-workflow-health.sh, not a raw stream)"
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
if [ -n "$pipeline_files" ]; then
  n="$(printf '%s' "$pipeline_recs" | jq 'length')"
  if [ "$n" -gt 0 ]; then
    drive_errs="$(printf '%s' "$pipeline_recs" | jq '[ .[] | select(.event == "drive" and (has("reason"))) ] | length')"
    echo "- pipeline drive errors (${lookback}d): $drive_errs (drive records carrying an error reason)"
    attention_any=1
  fi
fi
if [ "$attention_any" -eq 0 ]; then
  if [ -z "$cmd_files" ]; then stream_empty_line "command-runs" "$cmd_run_dir"; fi
  if [ -z "$pipeline_files" ]; then stream_empty_line "pipeline" "$pipeline_dir"; fi
  if [ -n "$cmd_files" ] || [ -n "$pipeline_files" ]; then
    echo "- no in-window attention signals (streams present, no records in the last $lookback days)"
  fi
fi
# ── 1b. Asynchronous workflow health (temperloop#1297) ───────────────────────
# A red ASYNCHRONOUS workflow — a nightly `schedule`, a release-tag push —
# reports to nobody in particular, so a broken quality gate can sit on `main`
# for weeks (nightly-macos.yml: 7 consecutive red nights; install-tier2.yml:
# its GitHub scheduled-failure email stopped applying when the cron was
# retired, docs/features/ci-install-tier2.md § step 5). This is the surface
# that alarm lands on — the Attention section /check-in already renders daily
# — rather than a parallel one invented for it.
#
# DELIBERATELY NOT A RAW-LAKE STREAM, and the `source:` line above says so:
# a workflow's redness lives only in GitHub's own run history, so this is the
# ONE live read in an otherwise offline brief. It is fully fenced: the
# detector owns its own degradation (no `gh`, no `jq`, an API failure — each
# renders a legible `skipped —` / `UNKNOWN` line), always exits 0, and is
# additionally `|| true`-guarded here so it can never fail the brief that
# reads it.
async_health="$here/async-workflow-health.sh"
if [ -r "$async_health" ]; then
  bash "$async_health" --format brief 2>/dev/null || true
else
  echo "- asynchronous workflow health: skipped — async-workflow-health.sh not found at $async_health (a red scheduled workflow would go unseen)"
fi
echo "note: parked \`/build\` items live in the active plan note's own item statuses, not a raw stream — check the plan note directly; the overlay brief adds pipeline escalation/hand-off detail."

# ── 2. Pipeline health & trust ────────────────────────────────────────────────
echo
echo "## 2. Pipeline health & trust"
echo "source: pipeline-*.jsonl @ $pipeline_dir · knowledge-search-fallback-*.jsonl @ $ks_fallback_dir"
if [ -z "$pipeline_files" ]; then
  stream_empty_line "pipeline" "$pipeline_dir"
else
  n="$(printf '%s' "$pipeline_recs" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    stale_note "pipeline" "$pipeline_dir" "$(stream_max_ts "$pipeline_dir" "pipeline")"
  else
    ran="$(printf '%s' "$pipeline_recs" | jq '[ .[] | select(.event == "ran") ] | length')"
    skipped="$(printf '%s' "$pipeline_recs" | jq '[ .[] | select(.event == "skipped") ] | length')"
    drives="$(printf '%s' "$pipeline_recs" | jq '[ .[] | select(.event == "drive") ] | length')"
    drive_errs="$(printf '%s' "$pipeline_recs" | jq '[ .[] | select(.event == "drive" and (has("reason"))) ] | length')"
    last_wake="$(printf '%s' "$pipeline_recs" | jq -r '[ .[].ts ] | max // "unknown"')"
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

# ── 2b. Epic funnel health — class-conditional (epic #1847) ─────────────────
# The funnel-health read is CLASS-CONDITIONAL, per epic #1847 "epic-as-
# metadata for operational work" Produces #9: a Foundational epic's healthy
# path stays epic -> plan (assessed) -> built; an Operational epic's healthy
# path is epic -> members-drained-via-sweep, with NO plan-note step at all —
# so plan-note absence on an Operational epic must never read as
# stalled-unassessed. NO NEW STREAM: both reads below are existing records
# already in the lake.
#   Operational signal — command-runs `command:"sweep"` records that carry
#     the epics_reviewed/epics_closed/epics_left_open fields (the
#     epic-closing-gate extension, emit-command-run.sh). These fields are
#     ONLY ever emitted by /sweep's end-of-run closing gate, which — per the
#     Foundational-wins mutual-exclusion guard (epic #1847 Produces #5) —
#     only ever reviews Operational epics. Their presence here is itself the
#     class signal; no label read is needed.
#   Foundational signal — item-efficiency's per-epic set of MERGED items
#     (already the source for the Q3b "per epic" rollup below). /build is
#     the sole emitter of that stream, and Operational-epic members are
#     driven via /sweep, never /build (same mutual exclusion), so an epic
#     appearing here is structurally a Foundational (ceremony-path) epic.
echo
echo "## 2b. Epic funnel health — class-conditional (epic #1847)"
echo "source: command-runs-*.jsonl @ $cmd_run_dir (sweep epic-closing-gate fields) · item-efficiency-*.jsonl @ $item_eff_dir (per-epic merged-item set)"
if [ -z "$cmd_files" ]; then
  echo "- Operational epics (drained via /sweep): no data yet — command-runs stream is empty ($cmd_run_dir/command-runs-*.jsonl)"
else
  sweep_epic_recs="$(printf '%s' "$cmd_runs" | jq '[ .[] | select(.command == "sweep" and has("epics_reviewed")) ]')"
  n_sweep="$(printf '%s' "$sweep_epic_recs" | jq 'length')"
  if [ "$n_sweep" -eq 0 ]; then
    echo "- Operational epics (drained via /sweep, ${lookback}d): no epic-closing-gate activity in window — no Operational epics admitted this window (or the admission setting is off)"
  else
    ereviewed="$(printf '%s' "$sweep_epic_recs" | jq '[ .[].epics_reviewed ] | add // 0')"
    eclosed="$(printf '%s' "$sweep_epic_recs" | jq '[ .[].epics_closed ] | add // 0')"
    eleft="$(printf '%s' "$sweep_epic_recs" | jq '[ .[].epics_left_open ] | add // 0')"
    echo "- Operational epics (drained via /sweep, ${lookback}d): epic-closing gate reviewed $ereviewed · closed $eclosed · left open $eleft — a plan-note-less epic here is the HEALTHY state for this class, never stalled-unassessed"
  fi
fi
ie2b_files="$(stream_files "$item_eff_dir" "item-efficiency")"
if [ -z "$ie2b_files" ]; then
  echo "- Foundational epics (assessed → built via /build): no data yet — item-efficiency stream is empty ($item_eff_dir/item-efficiency-*.jsonl)"
else
  ie2b_recs="$(window_records "$item_eff_dir" "item-efficiency")"
  n_ie2b="$(printf '%s' "$ie2b_recs" | jq 'length')"
  if [ "$n_ie2b" -eq 0 ]; then
    stale_note "item-efficiency" "$item_eff_dir" "$(stream_max_ts "$item_eff_dir" "item-efficiency")"
  else
    n_built_epics="$(printf '%s' "$ie2b_recs" | jq '[ .[] | select(.epic != null) | .epic ] | unique | length')"
    built_epics_list="$(printf '%s' "$ie2b_recs" | jq -r '[ .[] | select(.epic != null) | .epic ] | unique | map("#\(.)") | join(", ")')"
    if [ "$n_built_epics" -eq 0 ]; then
      echo "- Foundational epics (assessed → built via /build, ${lookback}d): 0 reached a merged item this window (a plan mid-review or mid-build shows no line here without being unhealthy — check the plan note's own status directly)"
    else
      echo "- Foundational epics (assessed → built via /build, ${lookback}d): $n_built_epics reached a merged item ($built_epics_list — see §3b's per-epic rollup for detail)"
    fi
  fi
fi

# ── 3. Spend ─────────────────────────────────────────────────────────────────
echo
echo "## 3. Spend — kernel-observable cost"
echo "source: gh-calls-*.jsonl @ $gh_calls_dir · ks read-log (knowledge_store.sh ks__read_log_emit) @ $read_log · item-efficiency-*.jsonl @ $item_eff_dir (emit-item-efficiency.sh, token figures composed from pipeline-spend-report.sh)"
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

# ── 3b. Overhead per merged item (temperloop#943) ────────────────────────────
# The ceremony-cost number: what one SHIPPED change cost in tokens, wall-clock
# and agent count, split by phase, rolled up per epic. Every figure below is a
# field of the item-efficiency record — this section never re-derives a token
# number, so it cannot disagree with pipeline-spend-report.sh.
ie_files="$(stream_files "$item_eff_dir" "item-efficiency")"
if [ -z "$ie_files" ]; then
  stream_empty_line "item-efficiency" "$item_eff_dir"
else
  ie_recs="$(window_records "$item_eff_dir" "item-efficiency")"
  n="$(printf '%s' "$ie_recs" | jq 'length')"
  if [ "$n" -eq 0 ]; then
    stale_note "item-efficiency" "$item_eff_dir" "$(stream_max_ts "$item_eff_dir" "item-efficiency")"
  else
    printf '%s' "$ie_recs" | jq -r --argjson lb "$lookback" '
      # An un-measured leg is null and STAYS null through every aggregate: a
      # median over [] renders "—", never 0. A 0 would read as "this cost
      # nothing", which is the opposite of "nobody measured it".
      def med: map(select(. != null)) | sort
        | if length == 0 then null
          elif (length % 2) == 1 then .[((length - 1) / 2)]
          else ((.[(length / 2) - 1] + .[length / 2]) / 2) end;
      def mins: if . == null then "—" else "\(((. / 60000) | floor))m" end;
      def share($p; $t): if ($t | not) or $t == 0 then 0 else (($p * 100 / $t) | floor) end;
      def units($k): map(.phases[$k].units // 0) | add // 0;
      def toks($k): map(.phases | to_entries | map(.value.tokens[$k] // 0) | add // 0) | add // 0;

      length as $n
      | units("design") as $d | units("driver_prep") as $p
      | units("worker") as $w | units("mechanical") as $m
      | ($d + $p + $w + $m) as $tot
      | ([ "- overhead per merged item (\($lb)d): \($n) merged item(s) · \((($tot / $n) | floor)) cost-weighted units/item · phase split design \(share($d; $tot))% · driver-prep \(share($p; $tot))% · worker \(share($w; $tot))% · mechanical \(share($m; $tot))% → ceremony (everything but the worker) \(share($d + $p + $m; $tot))%",
           "- raw tokens per merged item (\($lb)d): \(((toks("output") / $n) | floor)) output · \(((toks("cache_create") / $n) | floor)) cache-create · \(((toks("cache_read") / $n) | floor)) cache-read (shown unweighted so the cheap-cache-read distortion stays visible next to the cost-weighted units above)",
           "- wall-clock per merged item (\($lb)d, median): worker \(map(.wall_ms.worker) | med | mins) · CI \(map(.wall_ms.ci) | med | mins) · merge-group \(map(.wall_ms.merge_group) | med | mins) · gate-wait \(map(.wall_ms.gate_wait) | med | mins) · end-to-end \(map(.wall_ms.end_to_end) | med | mins)   (\"—\" = not measured, never 0)",
           "- agents per merged item (\($lb)d, median): \(map(.agent_counts.worker) | med // "—") worker · \(map(.agent_counts.mechanical) | med // "—") mechanical"
         ]
         + (group_by(.epic)
            | map(. as $g
                  | ($g | units("design") + units("driver_prep") + units("worker") + units("mechanical")) as $gt
                  | "- per epic \(if $g[0].epic == null then "(unattributed)" else "#\($g[0].epic)" end): \($g | length) item(s) · \((($gt / ($g | length)) | floor)) units/item · end-to-end \($g | map(.wall_ms.end_to_end) | med | mins)/item · levels \($g | map(.level) | map(select(. != null) | tostring) | unique | if length == 0 then "unrecorded" else join(",") end)"))
        )[]' 2>/dev/null \
      || echo "- item-efficiency records present but unreadable (malformed JSON in $item_eff_dir/item-efficiency-*.jsonl) — no numbers rendered"
  fi
fi
echo "note: token-cost spend (cost-per-epic) beyond the per-item records above requires the overlay rollup pipeline — not available kernel-side."

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
         # `resolved` is ABSENT on pre-temperloop#1084 records and absent means
         # UNKNOWN, never 0 — so sum only the records that carry it, and say
         # how many did not rather than implying those runs resolved nothing.
         resolved: ([ .[] | .resolved // empty ] | add // 0),
         resolved_unknown: ([ .[] | select(has("resolved") | not) ] | length),
         parked: ([ .[].parked ] | add // 0)}
      | "- \(.cmd): \(.runs) runs · \(.items) items · \(.merged) merged · \(.resolved) resolved · \(.parked) parked" +
        (if .items > 0 then " · merge rate \((.merged * 100 / .items) | floor)%" else "" end) +
        (if .resolved_unknown > 0 then " (resolved unknown for \(.resolved_unknown) pre-#1084 run(s))" else "" end)'
  fi
fi

echo
echo "— end of kernel brief. Overlay enrichment (when composed): rollup-backed digest via workflows/scripts/build_telemetry_brief.py."
exit 0
