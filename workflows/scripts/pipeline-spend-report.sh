#!/usr/bin/env bash
#
# pipeline-spend-report.sh — cost-weighted token-spend profiler over Claude
# Code's own workflow agent transcripts (temperloop#958, split out of the
# temperloop#953 investigation).
#
# WHAT IT READS: the per-agent JSONL transcripts Claude Code already persists
# for every workflow subagent, at
#   $SPEND_TRANSCRIPT_ROOT/**/subagents/workflows/wf_*/agent-*.jsonl
# Each assistant message in those files carries a `.message.usage` block
# (cache_read / cache_creation / output / input token counts) and a
# `.requestId`. That is the ONLY data this script consumes — LOCAL FILES,
# zero network, no API, no `gh` (see workflows/scripts/kernel/
# check-producer-egress.sh's documented empty egress surface).
#
# The `.temperloop/report.d/tokens` drop-in producer is this script's one
# in-repo consumer: it wraps `--format json` into the `{"tokens_spent": <n>}`
# shape `temperloop report` reads (workflows/scripts/lib/report.contract.md).
#
# ── FOUR CORRECTNESS TRAPS, each of which produced a WRONG ANSWER during
#    temperloop#953. They are encoded here deliberately; do not "simplify"
#    any of them away. ──────────────────────────────────────────────────────
#
# 1. DEDUPE BY requestId. One API response is split across SEPARATE
#    transcript lines (a `thinking` block, a `text` block, a `tool_use`
#    block), and EVERY one of those lines repeats the SAME `usage` object.
#    Summing per line therefore counts one API call two, three, or more
#    times: over this corpus it inflated the total 2.16x (390.2M -> 180.6M
#    cost-weighted units). A hand-checked worker showed 130 usage lines for
#    91 real API calls. So: the first line bearing a given requestId counts;
#    every later line repeating it is dropped. A line with NO requestId (and
#    no `.message.id` fallback) is never deduped — it is counted once, since
#    there is no key that could prove it a repeat.
#    Asserted by workflows/scripts/tests/test_pipeline_spend_report.sh's
#    duplicated-usage fixture — the single most important property here.
#
# 2. COST-WEIGHT THE TOKEN CLASSES. Raw token counts rank spend wrongly:
#    cache_creation bills ~12.5x cache_read, so ranking by raw cache-read
#    said the machinery agents were ~10% of spend when cost-weighted they are
#    31.8%. The four weights are NAMED SETTINGS resolved from
#    workflows/scripts/build/build.config.sh (SPEND_WEIGHT_INPUT,
#    SPEND_WEIGHT_CACHE_READ, SPEND_WEIGHT_CACHE_CREATE, SPEND_WEIGHT_OUTPUT)
#    — no weight literal appears anywhere in this file (kernel CLAUDE.md
#    § Named-setting convention). Change a weight in the config, never here.
#
# 3. NO TOOL-CALL-PARALLELISM METRIC, ever. The transcript records one
#    `tool_use` block per assistant message and therefore CANNOT express
#    whether two calls were issued in parallel. A naive per-message count
#    reports "zero parallelism" even for a session known to have issued
#    parallel calls — falsified against a control during #953. This script
#    deliberately derives no such metric; adding one would ship a number that
#    is structurally incapable of being right.
#
# 4. BSD/macOS DIALECT. Kept portable to the macOS dev shell as well as Linux
#    CI: no awk `asort` (absent from BSD awk — medians are computed by piping
#    through `sort -n`), no GNU `sed` `:label`/`t` loops, no `date -d` (the
#    --since/--until window is a LEXICOGRAPHIC compare of ISO-8601 date
#    prefixes, so no date arithmetic happens here at all), bash 3.2 (no
#    associative arrays, no `mapfile`).
#
# ── OUTPUT ────────────────────────────────────────────────────────────────
# Default `--format text` is the human read. `--format json` emits one JSON
# object (schema below) for machine use — the drop-in producer's input.
#
# Two named call-count thresholds classify agents; both are settings, never
# literals here:
#   SPEND_MACHINERY_MAX_CALLS       an agent with AT MOST this many deduped
#                                   API calls is `machinery` (a /build
#                                   mechanical executor — a prelude, pr-batch
#                                   or ci-batch agent that runs shell commands
#                                   and reasons about nothing). Everything
#                                   above it is an `item worker`. This is the
#                                   spend-ATTRIBUTION split (the 31.8/68.2
#                                   headline).
#   SPEND_WORKER_PROFILE_MIN_CALLS  the floor for the "typical item worker"
#                                   PROFILE (median calls / peak context /
#                                   units). Deliberately a SECOND, higher
#                                   threshold: the item-worker side of the
#                                   attribution split still contains a long
#                                   tail of short-lived helper agents
#                                   (reviewers, probes) that drag a median
#                                   toward them and stop it describing the
#                                   thing an operator means by "an item
#                                   worker". Attribution wants every unit
#                                   assigned; the profile wants a
#                                   representative agent. One threshold
#                                   cannot be both.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#   workflows/scripts/pipeline-spend-report.sh [OPTIONS]
#
#     --since YYYY-MM-DD   only agents whose FIRST recorded API call is on or
#                          after this UTC date
#     --until YYYY-MM-DD   only agents whose first recorded API call is on or
#                          before this UTC date (inclusive)
#     --run WF_ID          only the named workflow run (`wf_37846300-d12`, or
#                          the bare id without the `wf_` prefix). Repeatable
#                          via a comma-separated list. This plus --since is
#                          what makes a before/after comparison one command.
#     --root DIR           transcript root to walk (default:
#                          $SPEND_TRANSCRIPT_ROOT)
#     --format text|json   output shape (default: text)
#     --top N              how many runs the text report's "top runs" table
#                          lists (default: 10; JSON always carries every run)
#     -h, --help           this usage
#
#   Exit codes: 0 = report produced (including a legitimately empty corpus,
#   which prints a "no transcripts matched" report rather than failing).
#   1 = a real error (jq missing, unreadable root, bad flag value).
#   2 = invalid CLI usage.
#
# ── JSON SCHEMA (--format json) ───────────────────────────────────────────
#   {
#     "schema_version": 1,
#     "generated_at": "<ISO-8601 UTC>",
#     "transcript_root": "<dir>",
#     "filters": {"since": <str|null>, "until": <str|null>, "run": <str|null>},
#     "weights": {"input":n, "cache_read":n, "cache_create":n, "output":n},
#     "thresholds": {"machinery_max_calls":n, "worker_profile_min_calls":n},
#     "corpus": {"runs":n, "agents":n, "api_calls":n, "usage_lines":n,
#                "dedupe_ratio":n, "first_date":<str|null>, "last_date":<str|null>},
#     "raw_tokens": {"cache_read":n, "cache_create":n, "output":n, "input":n},
#     "units_total": n,
#     "machinery":    {"agents":n, "units":n, "pct":n, "api_calls":n,
#                      "wall_ms":n|null, "raw_tokens":{...}},
#     "item_workers": {"agents":n, "units":n, "pct":n, "api_calls":n,
#                      "wall_ms":n|null, "raw_tokens":{...}},
#     "worker_profile": {"n":n, "median_api_calls":n,
#                        "median_peak_context":n, "median_units":n},
#     "by_model": {"<model-id>": <units>, ...},
#     "by_run":   [{"run":"<wf_id>", "agents":n, "api_calls":n, "units":n,
#                   "wall_ms":n|null}, ...]
#   }
#
#   The per-class `api_calls` / `wall_ms` / `raw_tokens` sub-fields on
#   `machinery` and `item_workers` (temperloop#943) are PURELY ADDITIVE — the
#   pre-existing `agents`/`units`/`pct` keys are byte-unchanged, so no
#   `schema_version` bump (meta/data/raw/README.md's schema-version
#   convention). They exist so a consumer can see the OUTPUT vs CACHE_READ vs
#   CACHE_CREATE split PER CLASS: a corpus-wide `raw_tokens` hides the fact
#   that a mechanical agent's spend is nearly all cheap cache_read while a
#   worker's is output+cache_create, which is exactly the distortion trap 2's
#   cost weighting exists to correct for.
#
#   `wall_ms` semantics — MAX, NEVER A SUM. A class's `wall_ms` is the span of
#   the LONGEST SINGLE AGENT in it (its last recorded API call minus its
#   first), not the sum of every agent's span: /build runs item workers in
#   PARALLEL within a dependency level, so a sum would overstate the level's
#   real wall-clock by the fan-out width. `null` when no agent in the class
#   carried a parsable timestamp. This is a within-agent span, so it excludes
#   any time the agent spent before its first API call or after its last —
#   directional, like every other figure here.
#   Every token/unit figure is DIRECTIONAL cost-weighted units, never a
#   dollar amount and never a precise unit cost — the same stance
#   workflows/scripts/lib/report.contract.md's § Non-goals takes. No price
#   constant lives in this script.
#
# ── PROVENANCE ────────────────────────────────────────────────────────────
# The arithmetic is the verified arithmetic of #953's throwaway
# profile-workers.sh, re-derived here as a single-pass jq+awk pipeline (that
# scratch script shelled out to jq three times PER FILE). Validated
# byte-exactly against its 1,622-agent output: identical per-agent rows and
# an identical 180,608,852-unit corpus total.

set -uo pipefail

# This script lives at workflows/scripts/pipeline-spend-report.sh, so
# REPO_ROOT is TWO levels up from SCRIPT_DIR — the same resolution
# workflows/scripts/validate-prose-budget.sh uses.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# Settings — sourced from build.config.sh (tracked-repo layer 5) unless the
# caller already exported them (layer 2 env wins, per the six-layer ladder in
# docs/config-precedence.md). The `:?` form is deliberate: it makes it
# STRUCTURALLY impossible for a weight literal to live in this file, which is
# trap 2 above and this item's acceptance criterion. Same shape as
# workflows/scripts/validate-prose-budget.sh's cap resolution.
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/workflows/scripts/build/build.config.sh" ]; then
  # shellcheck source=workflows/scripts/build/build.config.sh
  source "$REPO_ROOT/workflows/scripts/build/build.config.sh"
fi

: "${SPEND_WEIGHT_INPUT:?SPEND_WEIGHT_INPUT is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_WEIGHT_CACHE_READ:?SPEND_WEIGHT_CACHE_READ is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_WEIGHT_CACHE_CREATE:?SPEND_WEIGHT_CACHE_CREATE is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_WEIGHT_OUTPUT:?SPEND_WEIGHT_OUTPUT is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_MACHINERY_MAX_CALLS:?SPEND_MACHINERY_MAX_CALLS is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_WORKER_PROFILE_MIN_CALLS:?SPEND_WORKER_PROFILE_MIN_CALLS is unset — build.config.sh missing, or the setting was removed}"
: "${SPEND_TRANSCRIPT_ROOT:?SPEND_TRANSCRIPT_ROOT is unset — build.config.sh missing, or the setting was removed}"

die() { echo "pipeline-spend-report: $*" >&2; exit 1; }

for _w in "$SPEND_WEIGHT_INPUT" "$SPEND_WEIGHT_CACHE_READ" "$SPEND_WEIGHT_CACHE_CREATE" "$SPEND_WEIGHT_OUTPUT"; do
  case "$_w" in
    ''|*[!0-9.]*|*.*.*) die "cost weights must be non-negative decimals; got '$_w' (see SPEND_WEIGHT_* in workflows/scripts/build/build.config.sh)" ;;
  esac
done
for _t in "$SPEND_MACHINERY_MAX_CALLS" "$SPEND_WORKER_PROFILE_MIN_CALLS"; do
  case "$_t" in
    ''|*[!0-9]*) die "call-count thresholds must be non-negative integers; got '$_t' (see SPEND_*_CALLS in workflows/scripts/build/build.config.sh)" ;;
  esac
done

usage() {
  cat <<'EOF'
usage: pipeline-spend-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD]
                                [--run WF_ID[,WF_ID...]] [--root DIR]
                                [--format text|json] [--top N]

Cost-weighted token-spend profile over Claude Code workflow agent
transcripts. Local files only; no network. See this script's header for the
four correctness traps it encodes and the JSON schema.
EOF
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
since=""
until_=""
run_filter=""
root="$SPEND_TRANSCRIPT_ROOT"
format="text"
top_runs=10

is_iso_date() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; [ -n "$since" ] || { echo "pipeline-spend-report: --since needs a YYYY-MM-DD value" >&2; usage >&2; exit 2; }; shift 2 ;;
    --until) until_="${2:-}"; [ -n "$until_" ] || { echo "pipeline-spend-report: --until needs a YYYY-MM-DD value" >&2; usage >&2; exit 2; }; shift 2 ;;
    --run)   run_filter="${2:-}"; [ -n "$run_filter" ] || { echo "pipeline-spend-report: --run needs a workflow id" >&2; usage >&2; exit 2; }; shift 2 ;;
    --root)  root="${2:-}"; [ -n "$root" ] || { echo "pipeline-spend-report: --root needs a directory" >&2; usage >&2; exit 2; }; shift 2 ;;
    --format) format="${2:-}"; shift 2 ;;
    --top)   top_runs="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pipeline-spend-report: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in text|json) ;; *) echo "pipeline-spend-report: --format must be text or json; got '$format'" >&2; exit 2 ;; esac
case "$top_runs" in ''|*[!0-9]*) echo "pipeline-spend-report: --top must be a non-negative integer; got '$top_runs'" >&2; exit 2 ;; esac
[ -z "$since" ]  || is_iso_date "$since"  || die "--since must be YYYY-MM-DD; got '$since'"
[ -z "$until_" ] || is_iso_date "$until_" || die "--until must be YYYY-MM-DD; got '$until_'"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

# Normalize the --run filter to a comma-delimited list of bare ids WITH the
# `wf_` prefix stripped, so both `--run wf_abc-123` and `--run abc-123` work.
run_norm=""
if [ -n "$run_filter" ]; then
  _old_ifs="$IFS"; IFS=','
  for _r in $run_filter; do
    _r="${_r#wf_}"
    [ -n "$_r" ] || continue
    run_norm="$run_norm,$_r"
  done
  IFS="$_old_ifs"
  run_norm="$run_norm,"
fi

# ---------------------------------------------------------------------------
# Collect the transcript file list.
#
# NUL-delimited throughout (a project dir name can in principle contain a
# space), written to a temp file first so the emptiness case is a plain
# file-size test rather than a bet on how this host's xargs treats empty
# input — BSD and GNU xargs disagree there (trap 4).
# ---------------------------------------------------------------------------
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-spend-report.XXXXXX")" || die "could not create a temp dir"
trap 'rm -rf "$tmpdir"' EXIT

files_z="$tmpdir/files.z"
: >"$files_z"
if [ -d "$root" ]; then
  find "$root" -path "*/wf_*" -name "agent-*.jsonl" -print0 2>/dev/null >"$files_z" || true
fi

usage_tsv="$tmpdir/usage.tsv"
: >"$usage_tsv"

if [ -s "$files_z" ]; then
  # ONE jq process per xargs batch over the whole corpus, not one per file.
  #
  # `-R` + `fromjson? // empty` reads each line as raw text and silently
  # drops any line that isn't valid JSON. That matters: a transcript being
  # appended to WHILE this runs can present a torn final line, and under
  # plain (non-`-R`) parsing jq aborts the entire batch there — silently
  # losing every remaining file in it. Skipping the one bad line is the
  # honest degradation; `input_filename` still attributes each surviving
  # line to its own file.
  xargs -0 jq -Rr '
    (fromjson? // empty)
    | select(.message.usage)
    | [ input_filename,
        (.timestamp // ""),
        (.requestId // .message.id // "none"),
        (.message.model // "unknown"),
        (.message.usage.cache_read_input_tokens // 0),
        (.message.usage.cache_creation_input_tokens // 0),
        (.message.usage.output_tokens // 0),
        (.message.usage.input_tokens // 0) ]
    | @tsv
  ' <"$files_z" >"$usage_tsv" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Aggregate.
#
# Pass 1 (awk, in memory — this corpus is ~21k usage lines, so holding it is
# cheap): dedupe by (file, requestId), roll up per agent, roll up per
# (agent, model), and remember each agent's earliest UTC date. The date
# window is applied at EMIT time in END, not per line, because an agent's
# date is a property of the agent (its first API call) and must not split an
# agent across a midnight boundary.
#
# Emits two record kinds on one stream, split by the shell below:
#   A <run> <agent> <date> <calls> <cr> <cc> <out> <in> <peak> <units> \
#     <naive_lines> <naive_units> <span_ms>
#   M <model> <units>
#
# <span_ms> (temperloop#943) is the agent's own wall-clock span — its LAST
# recorded usage-line timestamp minus its FIRST, in milliseconds — or -1 when
# no line carried a parsable timestamp. It is computed over EVERY usage line,
# before trap 1's requestId dedupe, because a repeated line still proves the
# agent was alive at that instant; deduping first would shorten the span for
# no reason. TRAP 4 (BSD dialect): the ISO-8601 -> epoch conversion is done in
# pure awk (days_from_civil), never `date -d` and never GNU awk's mktime().
# ---------------------------------------------------------------------------
records="$tmpdir/records.tsv"
awk -F'\t' \
  -v w_in="$SPEND_WEIGHT_INPUT" \
  -v w_cr="$SPEND_WEIGHT_CACHE_READ" \
  -v w_cc="$SPEND_WEIGHT_CACHE_CREATE" \
  -v w_out="$SPEND_WEIGHT_OUTPUT" \
  -v since="$since" -v until_="$until_" -v run_norm="$run_norm" '
function units(k) {
  # int(), not a rounding printf: the reference implementation this was
  # validated against truncates, and matching it exactly is what proves the
  # arithmetic identical (see this script header s Provenance note).
  return int(cr[k]*w_cr + cc[k]*w_cc + out[k]*w_out + inp[k]*w_in)
}
# days_from_civil (the standard proleptic-Gregorian algorithm): days since
# 1970-01-01 for a civil y/m/d. Pure arithmetic — no locale, no date(1), no
# gawk mktime(), so it behaves identically on the macOS dev shell and Linux CI.
function civil_days(y, m, d,   era, yoe, doy, doe) {
  if (m <= 2) y -= 1
  era = (y >= 0 ? int(y/400) : int((y-399)/400))
  yoe = y - era*400
  doy = int((153*(m + (m > 2 ? -3 : 9)) + 2)/5) + d - 1
  doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy
  return era*146097 + doe - 719468
}
# iso_ms: "2026-07-10T10:00:00.000Z" -> epoch milliseconds, or -1 when the
# string is not a parsable ISO-8601 instant. The result (~1.8e12) is exactly
# representable in a double, and only DIFFERENCES of it are ever printed.
function iso_ms(s,   y, mo, d, h, mi, sec, ms) {
  if (length(s) < 19) return -1
  y = substr(s,1,4) + 0; mo = substr(s,6,2) + 0; d = substr(s,9,2) + 0
  h = substr(s,12,2) + 0; mi = substr(s,15,2) + 0; sec = substr(s,18,2) + 0
  if (y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31) return -1
  ms = 0
  if (substr(s,20,1) == ".") ms = substr(s,21,3) + 0
  return (((civil_days(y,mo,d)*24 + h)*60 + mi)*60 + sec)*1000 + ms
}
{
  # NOTE (awk has no lexical scope — every variable is global): use distinct
  # names in the main block and END. The #953 investigation lost a whole
  # percentile table to exactly this class of shadowing bug.
  np = split($1, pp, "/")
  agent = pp[np]; run = pp[np-1]
  sub(/^agent-/, "", agent); sub(/\.jsonl$/, "", agent)
  bare = run; sub(/^wf_/, "", bare)
  if (run_norm != "" && index(run_norm, "," bare ",") == 0) next

  key = run "\t" agent
  d = substr($2, 1, 10)
  if (d != "" && (!(key in mind) || d < mind[key])) mind[key] = d

  # Wall-clock span bookkeeping, BEFORE the dedupe below: a repeated usage
  # line still proves the agent was alive at that instant.
  tms = iso_ms($2)
  if (tms >= 0) {
    if (!(key in minms) || tms < minms[key]) minms[key] = tms
    if (!(key in maxms) || tms > maxms[key]) maxms[key] = tms
  }

  # The NAIVE per-line rollup, kept alongside the deduped one purely so the
  # report can show what trap 1 costs on this corpus (#953 measured 2.16x).
  # It is never used as a spend figure.
  ncr[key] += $5; ncc[key] += $6; nout[key] += $7; ninp[key] += $8
  nlines[key]++

  rid = $3
  # TRAP 1 — dedupe by requestId. A missing requestId ("none") is never
  # deduped: there is no key that could prove the line a repeat.
  if (rid != "none") { if (seen[key SUBSEP rid]++) { next } }

  calls[key]++
  cr[key] += $5; cc[key] += $6; out[key] += $7; inp[key] += $8
  mkey = key SUBSEP $4
  mcr[mkey] += $5; mcc[mkey] += $6; mout[mkey] += $7; minp[mkey] += $8
  ctx = $5 + $6 + $8
  if (ctx > peak[key]) peak[key] = ctx
}
END {
  for (k in calls) {
    if (since != "" && mind[k] < since) continue
    if (until_ != "" && mind[k] > until_) continue
    keep[k] = 1
    span = (k in minms) ? int(maxms[k] - minms[k]) : -1
    printf "A\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      k, (mind[k] == "" ? "unknown" : mind[k]), calls[k], cr[k], cc[k], out[k], inp[k], peak[k], units(k), \
      nlines[k], int(ncr[k]*w_cr + ncc[k]*w_cc + nout[k]*w_out + ninp[k]*w_in), span
  }
  for (mk in mcr) {
    # mkey is `<run>\t<agent>` SUBSEP `<model>` — the agent key carries a TAB
    # inside it, so splitting on SUBSEP yields exactly two fields: kp[1] is
    # the whole agent key, kp[2] the model.
    nk = split(mk, kp, SUBSEP)
    ak = kp[1]
    if (!(ak in keep)) continue
    mu = int(mcr[mk]*w_cr + mcc[mk]*w_cc + mout[mk]*w_out + minp[mk]*w_in)
    printf "M\t%s\t%d\n", kp[nk], mu
  }
}' "$usage_tsv" >"$records"

agents_tsv="$tmpdir/agents.tsv"
models_tsv="$tmpdir/models.tsv"
awk -F'\t' '$1=="A"{ sub(/^A\t/, ""); print }' "$records" >"$agents_tsv"
awk -F'\t' '$1=="M"{ u[$2] += $3 } END { for (m in u) printf "%s\t%d\n", m, u[m] }' "$records" | sort >"$models_tsv"

# ---------------------------------------------------------------------------
# Scalars. One awk pass over the per-agent table.
# ---------------------------------------------------------------------------
summary="$(awk -F'\t' -v mach_max="$SPEND_MACHINERY_MAX_CALLS" '
{
  agents++
  runs[$1] = 1
  calls_total += $4
  cr += $5; cc += $6; out += $7; inp += $8
  units_total += $10
  naive_lines += $11; naive_units += $12
  # Per-class rollups (temperloop#943): the same machinery/item-worker split
  # the units attribution already draws, extended to API calls, the raw token
  # classes, and wall-clock. wall_ms is a MAX (parallel fan-out — a sum would
  # overstate); a span of -1 means "no parsable timestamp" and never competes.
  if ($4 <= mach_max) {
    mach_agents++; mach_units += $10; mach_calls += $4
    mcr += $5; mcc += $6; mout += $7; minp += $8
    if ($13 + 0 >= 0) { mach_span_n++; if ($13 + 0 > mach_wall) mach_wall = $13 + 0 }
  } else {
    work_agents++; work_units += $10; work_calls += $4
    wcr += $5; wcc += $6; wout += $7; winp += $8
    if ($13 + 0 >= 0) { work_span_n++; if ($13 + 0 > work_wall) work_wall = $13 + 0 }
  }
  if (first == "" || ($3 != "unknown" && $3 < first)) first = $3
  if ($3 != "unknown" && $3 > last) last = $3
}
END {
  nruns = 0; for (r in runs) nruns++
  printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d", \
    nruns, agents+0, calls_total+0, cr+0, cc+0, out+0, inp+0, units_total+0, \
    mach_agents+0, mach_units+0, work_agents+0, work_units+0, \
    (first == "" ? "-" : first), (last == "" ? "-" : last), \
    naive_lines+0, naive_units+0
  printf "\t%d\t%d\t%d\t%d\t%d\t%d", \
    mach_calls+0, mcr+0, mcc+0, mout+0, minp+0, (mach_span_n+0 > 0 ? mach_wall+0 : -1)
  printf "\t%d\t%d\t%d\t%d\t%d\t%d\n", \
    work_calls+0, wcr+0, wcc+0, wout+0, winp+0, (work_span_n+0 > 0 ? work_wall+0 : -1)
}' "$agents_tsv")"

n_runs="$(printf '%s' "$summary" | cut -f1)"
n_agents="$(printf '%s' "$summary" | cut -f2)"
n_calls="$(printf '%s' "$summary" | cut -f3)"
tok_cr="$(printf '%s' "$summary" | cut -f4)"
tok_cc="$(printf '%s' "$summary" | cut -f5)"
tok_out="$(printf '%s' "$summary" | cut -f6)"
tok_in="$(printf '%s' "$summary" | cut -f7)"
units_total="$(printf '%s' "$summary" | cut -f8)"
mach_agents="$(printf '%s' "$summary" | cut -f9)"
mach_units="$(printf '%s' "$summary" | cut -f10)"
work_agents="$(printf '%s' "$summary" | cut -f11)"
work_units="$(printf '%s' "$summary" | cut -f12)"
first_date="$(printf '%s' "$summary" | cut -f13)"
last_date="$(printf '%s' "$summary" | cut -f14)"
usage_lines="$(printf '%s' "$summary" | cut -f15)"
naive_units="$(printf '%s' "$summary" | cut -f16)"
mach_calls="$(printf '%s' "$summary" | cut -f17)"
mach_cr="$(printf '%s' "$summary" | cut -f18)"
mach_cc="$(printf '%s' "$summary" | cut -f19)"
mach_out="$(printf '%s' "$summary" | cut -f20)"
mach_in="$(printf '%s' "$summary" | cut -f21)"
mach_wall="$(printf '%s' "$summary" | cut -f22)"
work_calls="$(printf '%s' "$summary" | cut -f23)"
work_cr="$(printf '%s' "$summary" | cut -f24)"
work_cc="$(printf '%s' "$summary" | cut -f25)"
work_out="$(printf '%s' "$summary" | cut -f26)"
work_in="$(printf '%s' "$summary" | cut -f27)"
work_wall="$(printf '%s' "$summary" | cut -f28)"

# A -1 wall span means "no agent in this class carried a parsable timestamp" —
# render it as JSON null rather than a fabricated 0 (the degradation contract:
# never a made-up number).
ms_or_null() { case "${1:-}" in ''|-1) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

pct() { # pct <part> <whole> -> one decimal place, "0.0" when whole is 0
  awk -v p="$1" -v w="$2" 'BEGIN { printf "%.1f", (w+0 == 0 ? 0 : 100*p/w) }'
}
ratio() { # ratio <a> <b> -> two decimal places, "1.00" when b is 0
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", (b+0 == 0 ? 1 : a/b) }'
}
mach_pct="$(pct "$mach_units" "$units_total")"
work_pct="$(pct "$work_units" "$units_total")"
dedupe_ratio="$(ratio "$usage_lines" "$n_calls")"
# The COST inflation trap 1 removes — #953's headline 2.16x figure. Distinct
# from dedupe_ratio (a line count); this one is what summing per line would
# have added to the spend total.
naive_inflation="$(ratio "$naive_units" "$units_total")"

# median <column-index> — TRAP 4: BSD awk has no asort(), so the sort is a
# `sort -n` in the pipeline and awk only picks the middle element(s).
median() {
  awk -F'\t' -v col="$1" -v mn="$SPEND_WORKER_PROFILE_MIN_CALLS" '$4 >= mn { print $col }' "$agents_tsv" \
    | sort -n \
    | awk '{ v[NR] = $1 } END { if (NR == 0) { print 0; exit } printf "%.0f\n", (NR % 2 ? v[(NR+1)/2] : (v[NR/2] + v[NR/2+1]) / 2) }'
}
prof_n="$(awk -F'\t' -v mn="$SPEND_WORKER_PROFILE_MIN_CALLS" '$4 >= mn { n++ } END { print n+0 }' "$agents_tsv")"
prof_calls="$(median 4)"
prof_peak="$(median 9)"
prof_units="$(median 10)"

# Per-run rollup, richest first.
runs_tsv="$tmpdir/runs.tsv"
awk -F'\t' '
{
  a[$1]++; c[$1] += $4; u[$1] += $10
  # Same MAX-not-sum rule as the class rollup above: a run fans its item
  # workers out in parallel, so the run wall span is the longest agent in it.
  if ($13 + 0 >= 0) { n[$1]++; if ($13 + 0 > w[$1]) w[$1] = $13 + 0 }
}
END { for (r in a) printf "%s\t%d\t%d\t%d\t%d\n", r, a[r], c[r], u[r], (n[r] + 0 > 0 ? w[r] + 0 : -1) }' "$agents_tsv" \
  | sort -t'	' -k4,4nr >"$runs_tsv"

# ---------------------------------------------------------------------------
# Render.
# ---------------------------------------------------------------------------
json_str() { # minimal JSON string escaping (backslash, quote, control chars)
  printf '%s' "$1" | awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/[\001-\037]/, " "); printf "%s", $0 }'
}
json_or_null() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$(json_str "$1")"; fi; }

if [ "$format" = "json" ]; then
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "generated_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "transcript_root": "%s",\n' "$(json_str "$root")"
  printf '  "filters": {"since": %s, "until": %s, "run": %s},\n' \
    "$(json_or_null "$since")" "$(json_or_null "$until_")" "$(json_or_null "$run_filter")"
  printf '  "weights": {"input": %s, "cache_read": %s, "cache_create": %s, "output": %s},\n' \
    "$SPEND_WEIGHT_INPUT" "$SPEND_WEIGHT_CACHE_READ" "$SPEND_WEIGHT_CACHE_CREATE" "$SPEND_WEIGHT_OUTPUT"
  printf '  "thresholds": {"machinery_max_calls": %s, "worker_profile_min_calls": %s},\n' \
    "$SPEND_MACHINERY_MAX_CALLS" "$SPEND_WORKER_PROFILE_MIN_CALLS"
  printf '  "corpus": {"runs": %s, "agents": %s, "api_calls": %s, "usage_lines": %s, "dedupe_ratio": %s, "units_undeduped": %s, "undeduped_inflation": %s, "first_date": %s, "last_date": %s},\n' \
    "$n_runs" "$n_agents" "$n_calls" "$usage_lines" "$dedupe_ratio" "$naive_units" "$naive_inflation" \
    "$([ "$first_date" = "-" ] && printf null || printf '"%s"' "$first_date")" \
    "$([ "$last_date" = "-" ] && printf null || printf '"%s"' "$last_date")"
  printf '  "raw_tokens": {"cache_read": %s, "cache_create": %s, "output": %s, "input": %s},\n' \
    "$tok_cr" "$tok_cc" "$tok_out" "$tok_in"
  printf '  "units_total": %s,\n' "$units_total"
  printf '  "machinery": {"agents": %s, "units": %s, "pct": %s, "api_calls": %s, "wall_ms": %s, "raw_tokens": {"cache_read": %s, "cache_create": %s, "output": %s, "input": %s}},\n' \
    "$mach_agents" "$mach_units" "$mach_pct" "$mach_calls" "$(ms_or_null "$mach_wall")" \
    "$mach_cr" "$mach_cc" "$mach_out" "$mach_in"
  printf '  "item_workers": {"agents": %s, "units": %s, "pct": %s, "api_calls": %s, "wall_ms": %s, "raw_tokens": {"cache_read": %s, "cache_create": %s, "output": %s, "input": %s}},\n' \
    "$work_agents" "$work_units" "$work_pct" "$work_calls" "$(ms_or_null "$work_wall")" \
    "$work_cr" "$work_cc" "$work_out" "$work_in"
  printf '  "worker_profile": {"n": %s, "median_api_calls": %s, "median_peak_context": %s, "median_units": %s},\n' \
    "$prof_n" "$prof_calls" "$prof_peak" "$prof_units"
  # by_model / by_run are rendered by awk rather than a shell read-loop so the
  # comma placement is a single `NR>1` test instead of a hand-rolled
  # first-iteration flag. Model ids and wf_ run ids are bare identifiers by
  # construction; the same escape the shell helper applies is repeated here
  # defensively (a `"` or `\` in either would otherwise emit invalid JSON).
  printf '  "by_model": {'
  awk -F'\t' '{ k=$1; gsub(/\\/, "\\\\", k); gsub(/"/, "\\\"", k); printf "%s\"%s\": %s", (NR>1 ? ", " : ""), k, $2 }' "$models_tsv"
  printf '},\n'
  printf '  "by_run": [\n'
  awk -F'\t' '{ k=$1; gsub(/\\/, "\\\\", k); gsub(/"/, "\\\"", k); printf "%s    {\"run\": \"%s\", \"agents\": %s, \"api_calls\": %s, \"units\": %s, \"wall_ms\": %s}", (NR>1 ? ",\n" : ""), k, $2, $3, $4, ($5 == "-1" ? "null" : $5) } END { if (NR > 0) printf "\n" }' "$runs_tsv"
  printf '  ]\n}\n'
  exit 0
fi

printf 'pipeline spend — cost-weighted units from Claude Code workflow agent transcripts\n'
printf '  transcript root : %s\n' "$root"
printf '  window          : %s\n' "$( [ -z "$since" ] && [ -z "$until_" ] && printf 'all dates' || printf '%s .. %s' "${since:-(open)}" "${until_:-(open)}" )"
printf '  run filter      : %s\n' "${run_filter:-(none)}"
printf '  weights         : input=%s cache_read=%s cache_create=%s output=%s   (SPEND_WEIGHT_*)\n' \
  "$SPEND_WEIGHT_INPUT" "$SPEND_WEIGHT_CACHE_READ" "$SPEND_WEIGHT_CACHE_CREATE" "$SPEND_WEIGHT_OUTPUT"
printf '\n'

if [ "$n_agents" -eq 0 ]; then
  printf 'no transcripts matched — nothing to report.\n'
  printf '  (looked under %s for */wf_*/agent-*.jsonl)\n' "$root"
  exit 0
fi

printf 'corpus\n'
printf '  observed dates        %s .. %s\n' "$first_date" "$last_date"
printf '  workflow runs         %s\n' "$n_runs"
printf '  agents                %s\n' "$n_agents"
printf '  API calls (deduped)   %s   from %s usage lines (%sx line inflation absorbed)\n' "$n_calls" "$usage_lines" "$dedupe_ratio"
printf '\n'
printf 'raw tokens\n'
printf '  cache_read            %s\n' "$tok_cr"
printf '  cache_create          %s\n' "$tok_cc"
printf '  output                %s\n' "$tok_out"
printf '  input                 %s\n' "$tok_in"
printf '\n'
printf 'cost-weighted spend\n'
printf '  total units           %s\n' "$units_total"
printf '  (undeduped would be   %s — %sx, the requestId-dedupe trap)\n' "$naive_units" "$naive_inflation"
printf '  machinery (<= %s calls)   %6s agents  %14s units  %5s%%\n' "$SPEND_MACHINERY_MAX_CALLS" "$mach_agents" "$mach_units" "$mach_pct"
printf '  item workers (> %s calls) %6s agents  %14s units  %5s%%\n' "$SPEND_MACHINERY_MAX_CALLS" "$work_agents" "$work_units" "$work_pct"
printf '\n'
# Per-class raw-token + wall-clock detail (temperloop#943): the cost-weighted
# percentages above hide WHICH token class each side spends in, which is the
# whole cheap-cache-read distortion this report exists to correct for. Show it.
ms_show() { case "${1:-}" in ''|-1) printf 'unknown' ;; *) printf '%ss' "$(( $1 / 1000 ))" ;; esac; }
printf 'per-class detail (raw tokens; wall span = LONGEST single agent, never a sum)\n'
printf '  %-13s %8s %13s %13s %13s %11s %9s\n' "class" "calls" "output" "cache_create" "cache_read" "input" "wall"
printf '  %-13s %8s %13s %13s %13s %11s %9s\n' "machinery" "$mach_calls" "$mach_out" "$mach_cc" "$mach_cr" "$mach_in" "$(ms_show "$mach_wall")"
printf '  %-13s %8s %13s %13s %13s %11s %9s\n' "item workers" "$work_calls" "$work_out" "$work_cc" "$work_cr" "$work_in" "$(ms_show "$work_wall")"
printf '\n'
printf 'typical item worker (>= %s API calls, n=%s)\n' "$SPEND_WORKER_PROFILE_MIN_CALLS" "$prof_n"
printf '  median API calls      %s\n' "$prof_calls"
printf '  median peak context   %s tokens\n' "$prof_peak"
printf '  median units          %s\n' "$prof_units"
printf '\n'
printf 'by model (cost-weighted units)\n'
sort -t'	' -k2,2nr "$models_tsv" | while IFS="$(printf '\t')" read -r m u; do
  [ -n "$m" ] || continue
  printf '  %-40s %s\n' "$m" "$u"
done
printf '\n'
if [ "$top_runs" -gt 0 ]; then
  printf 'top %s runs by units\n' "$top_runs"
  printf '  %-22s %7s %9s %14s\n' "run" "agents" "calls" "units"
  head -n "$top_runs" "$runs_tsv" | while IFS="$(printf '\t')" read -r r a c u; do
    [ -n "$r" ] || continue
    printf '  %-22s %7s %9s %14s\n' "$r" "$a" "$c" "$u"
  done
fi
