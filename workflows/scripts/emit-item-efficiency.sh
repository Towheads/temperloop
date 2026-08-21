#!/usr/bin/env bash
#
# emit-item-efficiency.sh — append ONE per-merged-item efficiency record to the
# append-only raw lake (temperloop#943): what one shipped change actually cost,
# in tokens AND wall-clock AND agent-count, split by pipeline PHASE.
#
# WHY THIS EXISTS: epic #923 spent ~55M tokens on `/workshop`+`/assess` prep
# before a single `/build` worker ran, the `/build` session another 17.2M
# across 77 API turns in 11 minutes before its FIRST worker, and the whole
# epic tracked toward ~170M tokens with only part of L0+L1 landed. None of
# that surfaced anywhere. Ceremony cost was a hunch, and a hunch cannot be
# ratcheted down — this stream makes it a number, which is the kernel's
# "Measure the delta, don't assume it" rule applied to the pipeline's own
# overhead rather than to the code it ships.
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented there under
# `item-efficiency`, and summarised below).
#
# ── COMPOSITION, NOT REIMPLEMENTATION ─────────────────────────────────────
# Every token figure here comes from `workflows/scripts/pipeline-spend-report.sh
# --format json`, invoked once per phase run-group. That script — NOT this one
# — owns the cost-weighted per-agent transcript analysis and, critically, the
# FOUR CORRECTNESS TRAPS documented in its own header (dedupe-by-requestId
# above all; summing per line inflated the #953 corpus 2.16x). This script
# derives NO token number of its own and never opens a transcript: it selects
# fields out of that report's JSON and attributes them to a phase. If the
# profiler is unreachable, the phases render `null` — never a locally
# recomputed substitute, which would silently fork the traps.
#
# ── PHASES ────────────────────────────────────────────────────────────────
#   design       the `/workshop` + `/assess` prep that preceded the build —
#                its workflow run ids, via --design-run
#   driver_prep  the `/build` driver's own pre-worker turns — via
#                --driver-prep-run
#   worker       the item workers inside the build run(s) — the
#                `item_workers` class of --build-run's report
#   mechanical   the orchestration/executor agents inside the same build
#                run(s) — the `machinery` class of the same report
# The worker/mechanical split is the profiler's OWN
# SPEND_MACHINERY_MAX_CALLS-keyed classification, reused verbatim rather than
# re-derived here — the same threshold that produced its 31.8/68.2 headline.
# A phase whose run-group is not supplied renders `null` (honestly
# un-attributed), never 0 (which would read as "this phase was free").
#
# Each phase carries `tokens: {output, cache_create, cache_read, input}` as
# RAW counts alongside the cost-weighted `units`, because the cheap-cache-read
# distortion is exactly what a single blended number hides: an agent can look
# enormous in raw tokens and small in cost, or the reverse.
#
# ── WALL-CLOCK ────────────────────────────────────────────────────────────
#   worker_ms       longest single item-worker span (from the profiler's own
#                   item_workers.wall_ms) unless --worker-ms overrides it
#   ci_ms           the PR's CI run span            (--ci-ms, or derived from
#                                                    --ci-sha via `gh`)
#   merge_group_ms  the merge-queue run span        (--merge-group-ms, or
#                                                    derived from
#                                                    --merge-group-sha)
#   gate_wait_ms    time the item waited between CI-green (3h) and the merge
#                   that landed it (--gate-wait-ms) — parked `[m]` until the
#                   level's batch gate, or the far shorter `[>]` wait of a
#                   3h.5 as-you-go merge (temperloop#1026 — conversational
#                   path only, temperloop#1452; a default Workflow-path run
#                   always records the parked `[m]` wait). Deliberately ONE
#                   metric across both waits: it is what measures that change.
#   end_to_end_ms   claim -> confirmed MERGED (--end-to-end-ms)
# Anything not supplied and not derivable is `null`. NEVER a fabricated or
# back-computed number: an absent measurement and a zero measurement mean
# opposite things to a reader deciding whether ceremony grew.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   emit-item-efficiency.sh --slug <plan-item-slug>
#     [--repo <owner/repo>] [--epic <N>] [--issue <N>] [--pr <N>] [--level <N>]
#     [--build-run <WF[,WF...]>] [--design-run <WF[,WF...]>]
#     [--driver-prep-run <WF[,WF...]>]
#     [--worker-ms <N>] [--ci-ms <N>] [--merge-group-ms <N>]
#     [--gate-wait-ms <N>] [--end-to-end-ms <N>]
#     [--ci-sha <sha>] [--merge-group-sha <sha>]
#     [--print-only]
#
# Appends ONE JSONL line to:
#   ${ITEM_EFFICIENCY_RAW_DIR:-<repo>/meta/data/raw}/item-efficiency-YYYY-MM.jsonl
# (monthly rotation, matching every other stream in that directory).
#
# --print-only computes and prints the record WITHOUT appending — the
# on-demand reading, same convention as emit-session-context.sh's own
# --print-only.
#
# WARN, DON'T DROP: every failure path here (jq missing, profiler missing, gh
# missing, sink unwritable) warns to stderr and exits 0 with the record
# degraded to `null` fields. This is telemetry hanging off a MERGE step — it
# must never fail or block the merge that triggered it.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) and BSD/GNU
# portable, matching the rest of workflows/scripts/.

set -uo pipefail

self="$(basename "$0")"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warn() { printf '%s: WARN %s\n' "$self" "$*" >&2; }

slug=""
repo=""
epic=""
issue=""
pr=""
level=""
build_runs=""
design_runs=""
prep_runs=""
worker_ms=""
ci_ms=""
merge_group_ms=""
gate_wait_ms=""
end_to_end_ms=""
ci_sha=""
merge_group_sha=""
print_only=0

# ARG LOOP — the shift is deliberately TWO steps (temperloop#1342). Bash's
# `shift 2` FAILS (count out of range) when the flag is the LAST argument, and
# a FAILED shift does not shift: `$#` never decreases, the same arm re-matches,
# and this loop spins at 100% CPU forever. `${2:-}` is what makes that a HANG
# rather than a `set -u` crash. A hang here is strictly worse than the failure
# this file's never-fail-or-block-the-spawn-site contract exists to prevent —
# the conventional `emit-… || true` call shape cannot save a caller from it.
# So: shift the FLAG, then the value only if one is actually there.
# scripts/lint-argloop-shift2.sh is the mechanical guard for the class.
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)             slug="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --repo)             repo="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --epic)             epic="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --issue)            issue="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --pr)               pr="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --level)            level="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --build-run)        build_runs="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --design-run)       design_runs="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --driver-prep-run)  prep_runs="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --worker-ms)        worker_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --ci-ms)            ci_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --merge-group-ms)   merge_group_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --gate-wait-ms)     gate_wait_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --end-to-end-ms)    end_to_end_ms="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --ci-sha)           ci_sha="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --merge-group-sha)  merge_group_sha="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --print-only)       print_only=1; shift ;;
    -h|--help)          sed -n '2,110p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) warn "unknown argument $1 (ignored)"; shift ;;
  esac
done

if [ -z "$slug" ]; then
  warn "--slug is required — no record emitted"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found — no record emitted (slug=$slug)"
  exit 0
fi

# num_or_null — a value that is not a plain non-negative integer becomes JSON
# null rather than corrupting the record with a bare word. Deliberate: an
# unparsable measurement is an ABSENT measurement, never a zero.
num_or_null() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Phase token attribution — one pipeline-spend-report.sh invocation per
# distinct run-group, then field selection. No transcript is read here.
# ---------------------------------------------------------------------------
SPEND_BIN="$here/pipeline-spend-report.sh"
spend_warned=0

spend_json() {  # $1 = comma-separated run ids -> report JSON on stdout
  [ -n "$1" ] || return 1
  if [ ! -f "$SPEND_BIN" ]; then
    [ "$spend_warned" -eq 0 ] && warn "pipeline-spend-report.sh not found at $SPEND_BIN — phase tokens will be null"
    spend_warned=1
    return 1
  fi
  local out
  out="$(bash "$SPEND_BIN" --format json --run "$1" 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# phase_from — $1 = report JSON, $2 = which block of it to attribute:
#   "corpus"        the whole run-group (used for design / driver_prep, where
#                   the machinery/worker split carries no meaning)
#   "machinery" | "item_workers"
#                   one class of the build run's OWN split — the profiler's
#                   SPEND_MACHINERY_MAX_CALLS classification, reused verbatim.
phase_from() {
  local report="$1" sel="$2"
  if [ "$sel" = "corpus" ]; then
    printf '%s' "$report" | jq -c '{
      agents: .corpus.agents, api_calls: .corpus.api_calls, units: .units_total,
      wall_ms: ([ .by_run[]?.wall_ms | select(. != null) ] | max),
      tokens: {output: .raw_tokens.output, cache_create: .raw_tokens.cache_create,
               cache_read: .raw_tokens.cache_read, input: .raw_tokens.input}
    }' 2>/dev/null
  else
    printf '%s' "$report" | jq -c --arg k "$sel" '.[$k] as $c | {
      agents: $c.agents, api_calls: $c.api_calls, units: $c.units,
      wall_ms: $c.wall_ms,
      tokens: {output: $c.raw_tokens.output, cache_create: $c.raw_tokens.cache_create,
               cache_read: $c.raw_tokens.cache_read, input: $c.raw_tokens.input}
    }' 2>/dev/null
  fi
}

design_phase="null"
prep_phase="null"
worker_phase="null"
mech_phase="null"

if [ -n "$design_runs" ]; then
  rep="$(spend_json "$design_runs")" && design_phase="$(phase_from "$rep" corpus)"
  [ -n "$design_phase" ] || design_phase="null"
fi
if [ -n "$prep_runs" ]; then
  rep="$(spend_json "$prep_runs")" && prep_phase="$(phase_from "$rep" corpus)"
  [ -n "$prep_phase" ] || prep_phase="null"
fi
if [ -n "$build_runs" ]; then
  # ONE invocation feeds BOTH build-side phases — the worker/mechanical split
  # is two blocks of the same report, not two walks of the corpus.
  if rep="$(spend_json "$build_runs")"; then
    worker_phase="$(phase_from "$rep" item_workers)"
    mech_phase="$(phase_from "$rep" machinery)"
    [ -n "$worker_phase" ] || worker_phase="null"
    [ -n "$mech_phase" ] || mech_phase="null"
    # The profiler's own item_workers wall span IS the worker duration, unless
    # the caller measured it directly.
    if [ -z "$worker_ms" ]; then
      derived="$(printf '%s' "$rep" | jq -r '.item_workers.wall_ms // empty' 2>/dev/null)"
      case "$derived" in ''|null) : ;; *) worker_ms="$derived" ;; esac
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Optional `gh`-derived CI wall-clock. Best-effort and OFF unless a SHA is
# supplied: a telemetry emit on the merge path must never turn a network
# hiccup into a blocked merge, so every failure here degrades to null.
# ---------------------------------------------------------------------------
run_span_ms() {  # $1 = sha -> span in ms, or "" when undeterminable
  local sha="$1" out
  [ -n "$sha" ] || return 1
  [ -n "$repo" ] || { warn "--repo is required to derive CI timing from a sha; leaving it null"; return 1; }
  command -v gh >/dev/null 2>&1 || { warn "gh not on PATH — CI wall-clock left null"; return 1; }
  out="$(gh run list --repo "$repo" --commit "$sha" --limit 50 \
          --json startedAt,updatedAt 2>/dev/null)" || return 1
  printf '%s' "$out" | jq -r '
    [ .[] | select(.startedAt != null and .updatedAt != null) ] as $r
    | if ($r | length) == 0 then empty
      else ((( [ $r[].updatedAt | fromdateiso8601 ] | max)
            - ([ $r[].startedAt | fromdateiso8601 ] | min)) * 1000 | floor)
      end' 2>/dev/null
}

if [ -z "$ci_ms" ] && [ -n "$ci_sha" ]; then
  ci_ms="$(run_span_ms "$ci_sha")" || ci_ms=""
fi
if [ -z "$merge_group_ms" ] && [ -n "$merge_group_sha" ]; then
  merge_group_ms="$(run_span_ms "$merge_group_sha")" || merge_group_ms=""
fi

# ---------------------------------------------------------------------------
# Assemble + append.
# ---------------------------------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
host="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
session_id="${CLAUDE_CODE_SESSION_ID:-}"

record="$(jq -nc \
  --arg ts "$ts" \
  --arg host "$host" \
  --arg session_id "$session_id" \
  --arg repo "$repo" \
  --arg slug "$slug" \
  --arg epic "$epic" \
  --arg issue "$issue" \
  --arg pr "$pr" \
  --arg level "$level" \
  --arg build_runs "$build_runs" \
  --arg design_runs "$design_runs" \
  --arg prep_runs "$prep_runs" \
  --argjson design "$design_phase" \
  --argjson driver_prep "$prep_phase" \
  --argjson worker "$worker_phase" \
  --argjson mechanical "$mech_phase" \
  --argjson worker_ms "$(num_or_null "$worker_ms")" \
  --argjson ci_ms "$(num_or_null "$ci_ms")" \
  --argjson merge_group_ms "$(num_or_null "$merge_group_ms")" \
  --argjson gate_wait_ms "$(num_or_null "$gate_wait_ms")" \
  --argjson end_to_end_ms "$(num_or_null "$end_to_end_ms")" \
  '
  def idlist($s): if $s == "" then [] else ($s | split(",") | map(select(length > 0))) end;
  def num($s): if $s == "" then null else ($s | tonumber? // $s) end;
  {
    schema_version: "1",
    ts: $ts,
    host: $host,
    session_id: (if $session_id == "" then null else $session_id end),
    repo: (if $repo == "" then null else $repo end),
    slug: $slug,
    epic: num($epic),
    issue: num($issue),
    pr: num($pr),
    level: num($level),
    phases: {design: $design, driver_prep: $driver_prep,
             worker: $worker, mechanical: $mechanical},
    agent_counts: {worker: ($worker.agents // null),
                   mechanical: ($mechanical.agents // null)},
    wall_ms: {worker: $worker_ms, ci: $ci_ms, merge_group: $merge_group_ms,
              gate_wait: $gate_wait_ms, end_to_end: $end_to_end_ms},
    runs: {design: idlist($design_runs), driver_prep: idlist($prep_runs),
           build: idlist($build_runs)},
    spend_source: "pipeline-spend-report.sh"
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  warn "failed to build JSON record (slug=$slug) — no record emitted"
  exit 0
fi

if [ "$print_only" -eq 1 ]; then
  printf '%s\n' "$record"
  exit 0
fi

# Resolve the raw sink dir exactly as emit-command-run.sh does: an explicit
# override env first, else the repo this script lives in — so it works from any
# checkout that vendors this file, never a hardcoded personal path.
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${ITEM_EFFICIENCY_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/item-efficiency-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true
if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  warn "failed to append record to $raw_file (slug=$slug)"
  exit 0
fi

printf '%s\n' "$record"
