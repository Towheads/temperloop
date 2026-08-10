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
# `.requestId`. That is the corpus behind every field in the default report
# — LOCAL FILES, zero network, no API, no `gh` (see workflows/scripts/kernel/
# check-producer-egress.sh's documented empty egress surface, which this
# zero-network claim holds exactly, unchanged).
#
# OPTIONAL WIDER READ — --by-agent-type (temperloop#1314). Claude Code's real
# on-disk layout is `<project-dir>/<session-uuid>/subagents/...`: a project
# directory (one per repo checkout, under $SPEND_TRANSCRIPT_ROOT) holding one
# subdirectory per Claude Code SESSION, each of which has its own
# `subagents/` folder — `agent-*.jsonl` sitting directly in it for a
# non-workflow ("ext") subagent, or nested under `subagents/workflows/wf_*/`
# for a `/build`-style workflow subagent. --by-agent-type ALSO reads, for
# each such journal it collects, Claude Code's own sidecar file
# `agent-<id>.meta.json`, written next to `agent-<id>.jsonl` in the SAME
# directory — no new join mechanism, the profiler already carries
# `input_filename` per usage line.
# STRUCTURAL PRIVACY GUARANTEE (engineering-principles.md Principle 5 —
# counter AI failure modes structurally, not by convention/testing alone):
# the ONLY selector ever applied to a sidecar, anywhere in this script, is
# `.agentType // empty` — never `.description` (the sidecar's free-text
# spawn-prompt field that ADR 0020's allowlist keeps out of reach) or any
# other field. This mirrors workflows/scripts/lib/token_sum.sh's own
# STRUCTURAL PRIVACY GUARANTEE; see this script's own test suite for the
# regression PROOF (a synthetic-recognizable-content sidecar fixture).
# This read is STILL local files, zero network — only the ON-DISK SCOPE
# widens, and only when the flag is passed (see § by_agent_type below for
# the depth-pinned single-project walk and the corpus-scoping refusal that
# keeps that scope from ever silently going machine-wide).
#
# The `.temperloop/report.d/tokens` drop-in producer is this script's one
# in-repo consumer: it wraps `--format json` into the `{"tokens_spent": <n>}`
# shape `temperloop report` reads (workflows/scripts/lib/report.contract.md).
# It does NOT wire up --by-agent-type (temperloop#1314 disposition) — that
# stays a standalone CLI-only side channel; see report.contract.md's own
# "Kernel-shipped `tokens` producer's transcript scope" section, unchanged.
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
#     --by-agent-type      OPT-IN (temperloop#1314): also emit `by_agent_type`,
#                          an attribution side channel over ONE Claude Code
#                          project directory's `*/subagents/agent-*.jsonl`
#                          journals (ext + wf_, sidecar-derived seat name).
#                          REQUIRES --root to name that single project
#                          directory (one whose session subdirectories hold
#                          at least one `subagents/agent-*.jsonl`); refuses
#                          (exit 2) otherwise, rather than ever walking
#                          machine-wide. Combined with --run, restricts to
#                          the wf_ half only. See § by_agent_type below —
#                          its totals are NEVER a decomposition of
#                          units_total, and it is absent from the default
#                          output entirely.
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
#   -- and, ONLY when --by-agent-type is passed (absent entirely otherwise):
#   {
#     ..., "by_agent_type": {
#       "scope": "<str>",                 -- which project dir + wf/ext coverage
#       "agents": n, "api_calls": n, "units": n,   -- SELF-CONTAINED corpus
#                                                   -- total; NOT a slice of
#                                                   -- units_total above
#       "recognized_agent_definitions": n, -- count of claude/agents/**/*.md
#                                          -- basenames found on THIS checkout
#       "notice": <str|null>,             -- non-null ONLY when that count is
#                                          -- 0 (see § by_agent_type below)
#       "seats": {"<agent-def-name>": {"agents":n,"api_calls":n,"units":n}, ...},
#       "unattributed": {"agents":n, "api_calls":n, "units":n,
#                        "by_raw_value": {"<raw-agentType-or-marker>": n, ...}}
#     }
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
# ── § by_agent_type (temperloop#1314, --by-agent-type only) ───────────────
# A SEPARATE, opt-in accumulator — NOT a widened version of the walk above.
# The corpus feeding units_total/corpus.*/raw_tokens.*/machinery.*/
# item_workers.*/worker_profile.*/by_model/by_run is completely UNCHANGED by
# this flag (widening it was measured, during the temperloop#1314 spike, to
# move units_total 283,230,998 -> 835,875,837 — a 2.95x shift — and invert
# the machinery/item_workers split 21.8/78.2 -> 9.5/90.5; that is exactly
# what must never happen). Instead a second walk, pinned to a SINGLE Claude
# Code project directory named by --root, feeds `by_agent_type` alone.
#
# ALLOWLIST, NOT PASSTHROUGH. A sidecar's `agentType` is reported as a SEAT
# only when it matches a deployed agent-definition basename under
# `claude/agents/**/*.md` in THIS checkout. Every other value — including
# `general-purpose`, which `claude/workflows/build-level.mjs`'s
# `machineryAgent()` pins as every machinery executor's type once one
# resolution attempt fails, so it is indistinguishable from a genuine
# general-purpose agent on a checkout that never ran
# workflows/scripts/install/project-agents.sh — buckets to `unattributed`,
# with the raw value kept visible under `unattributed.by_raw_value` rather
# than silently asserted as a seat. When `recognized_agent_definitions` is 0,
# `notice` names workflows/scripts/install/project-agents.sh as the reason:
# an unqualified "0 units attributed" would read as "reviewers cost nothing"
# — an undetectable wrong number — so the degradation is stated plainly
# rather than left for a reader to misinterpret.
#
# CORPUS SCOPING is a REFUSAL, never a silent machine-wide fallback: --root
# must resolve to a directory with at least one match at
# `"$root"/*/subagents/agent-*.jsonl` (one wildcard SESSION level, pinned —
# never a recursive find) or the script exits 2 naming what it needed. Every
# known contaminant (`/private/tmp` probe dirs, worktree test-fixture pools,
# cross-repo journals) lives under a DIFFERENT project directory, so pinning
# --root to one makes them structurally unreachable, not merely filtered.
# `--by-agent-type` combined with `--run` restricts the corpus to the wf_
# half only (ext journals excluded) and `scope` states that explicitly.
#
# schema_version STAYS 1 for this addition: nothing existing is removed, no
# type changes, no meaning changes, and by_agent_type appears only under the
# explicit flag (same precedent as the temperloop#943 per-class sub-fields
# above). The trigger that WOULD force schema_version: 2 is narrow and
# explicit: if the widened by_agent_type walk ever became the DEFAULT (no
# flag needed), that changes the MEANING of units_total with no field
# renamed or removed — exactly the silent-semantics-change schema_version
# exists to catch — and would require a `BREAKING` CHANGELOG section with a
# migration note, not just a version bump.
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
                                [--by-agent-type]

Cost-weighted token-spend profile over Claude Code workflow agent
transcripts. Local files only; no network. See this script's header for the
four correctness traps it encodes and the JSON schema.

--by-agent-type: OPT-IN per-seat attribution side channel (temperloop#1314).
Requires --root to name a SINGLE Claude Code project directory (one whose
session subdirectories hold at least one */subagents/agent-*.jsonl journal);
refuses (exit 2) otherwise rather than ever walking machine-wide. Emits an
additional, self-contained `by_agent_type` field -- NEVER a decomposition of
the default report's units_total. See the script header's own
"by_agent_type" section for the full corpus-scoping and allowlist rules.
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
by_agent_type=""

is_iso_date() { case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; [ -n "$since" ] || { echo "pipeline-spend-report: --since needs a YYYY-MM-DD value" >&2; usage >&2; exit 2; }; shift 2 ;;
    --until) until_="${2:-}"; [ -n "$until_" ] || { echo "pipeline-spend-report: --until needs a YYYY-MM-DD value" >&2; usage >&2; exit 2; }; shift 2 ;;
    --run)   run_filter="${2:-}"; [ -n "$run_filter" ] || { echo "pipeline-spend-report: --run needs a workflow id" >&2; usage >&2; exit 2; }; shift 2 ;;
    --root)  root="${2:-}"; [ -n "$root" ] || { echo "pipeline-spend-report: --root needs a directory" >&2; usage >&2; exit 2; }; shift 2 ;;
    --format) format="${2:-}"; shift 2 ;;
    --top)   top_runs="${2:-}"; shift 2 ;;
    --by-agent-type) by_agent_type=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pipeline-spend-report: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$format" in text|json) ;; *) echo "pipeline-spend-report: --format must be text or json; got '$format'" >&2; exit 2 ;; esac
case "$top_runs" in ''|*[!0-9]*) echo "pipeline-spend-report: --top must be a non-negative integer; got '$top_runs'" >&2; exit 2 ;; esac
[ -z "$since" ]  || is_iso_date "$since"  || die "--since must be YYYY-MM-DD; got '$since'"
[ -z "$until_" ] || is_iso_date "$until_" || die "--until must be YYYY-MM-DD; got '$until_'"

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

# ---------------------------------------------------------------------------
# --by-agent-type corpus-scoping REFUSAL (temperloop#1314 governing verdict,
# point 3). --root must name a SINGLE Claude Code project directory: one
# whose session subdirectories hold at least one match at the depth-pinned
# glob "$root"/*/subagents/agent-*.jsonl (one wildcard SESSION level, never a
# recursive find/-path search). The unscoped default ($SPEND_TRANSCRIPT_ROOT,
# the parent of EVERY project directory) has an extra path component before
# any subagents/ folder and so structurally never matches this glob — the
# same check therefore also catches "the caller never passed --root at all"
# with no separate flag to track. Refuse (exit 2) rather than ever silently
# walking machine-wide; name exactly what was needed, per the verdict. (This
# is a cheap existence probe only — the real collection, into a tmpdir-backed
# file list, happens later once tmpdir exists; see § by_agent_type below.)
# ---------------------------------------------------------------------------
if [ -n "$by_agent_type" ]; then
  bat_root_ok=""
  for _bf in "$root"/*/subagents/agent-*.jsonl; do
    if [ -e "$_bf" ]; then bat_root_ok=1; break; fi
  done
  if [ -z "$bat_root_ok" ]; then
    echo "pipeline-spend-report: --by-agent-type requires --root to name a SINGLE Claude Code project directory (one whose session subdirectories hold at least one journal at */subagents/agent-*.jsonl, e.g. ~/.claude/projects/<encoded-repo-name>); '$root' matched none" >&2
    usage >&2
    exit 2
  fi
fi

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

# ===========================================================================
# § by_agent_type (temperloop#1314, --by-agent-type only) — a SEPARATE,
# opt-in accumulator. Nothing above this block is touched: $files_z,
# $usage_tsv, $agents_tsv, $runs_tsv and everything derived from them are the
# UNCHANGED existing walk. See this script's own header § by_agent_type for
# the full rationale; this is the implementation.
# ===========================================================================
bat_tot_agents=0; bat_tot_calls=0; bat_tot_units=0
bat_unattr_agents=0; bat_unattr_calls=0; bat_unattr_units=0
bat_recognized_defs=0
bat_scope=""
bat_seats_tsv="$tmpdir/bat_seats.tsv"; : >"$bat_seats_tsv"
bat_raw_tsv="$tmpdir/bat_raw.tsv"; : >"$bat_raw_tsv"

if [ -n "$by_agent_type" ]; then
  # --- 1. Collect the real file list (the cheap probe above only proved
  #     non-emptiness; this is the actual walk) — the SAME depth-pinned glob,
  #     one wildcard SESSION level, never a recursive find. ---------------
  bat_ext_files_z="$tmpdir/bat_ext_files.z"
  : >"$bat_ext_files_z"
  for _bf in "$root"/*/subagents/agent-*.jsonl; do
    [ -e "$_bf" ] || continue
    printf '%s\0' "$_bf" >>"$bat_ext_files_z"
  done

  # --- 2. Extract usage lines from the ext-only collection, via the SAME
  #     shape jq filter the existing (unchanged) walk uses above — a
  #     deliberate duplicate, not a shared/refactored call, so the existing
  #     walk's own source is provably untouched by this feature. -----------
  bat_ext_usage_tsv="$tmpdir/bat_ext_usage.tsv"
  : >"$bat_ext_usage_tsv"
  if [ -s "$bat_ext_files_z" ]; then
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
    ' <"$bat_ext_files_z" >"$bat_ext_usage_tsv" 2>/dev/null || true
  fi

  # --- 3. wf_ rows are NOT re-walked — reused directly from $usage_tsv,
  #     which is ALREADY exactly this project directory's own wf_ corpus
  #     now that --root is project-scoped (the existing walk's own `-path
  #     "*/wf_*"` recursion is unchanged; it just naturally sees less when
  #     $root is narrower). Combine with the ext usage lines collected
  #     above into one per-file dedupe+cost-weight pass. -------------------
  bat_all_usage_tsv="$tmpdir/bat_all_usage.tsv"
  cat "$usage_tsv" "$bat_ext_usage_tsv" >"$bat_all_usage_tsv" 2>/dev/null || true

  # --- 4. Per-FILE (not per-run+agent) dedupe by requestId (trap 1, same
  #     rule, independently applied here since this is a disjoint
  #     accumulator) + cost-weighting (same named SPEND_WEIGHT_* settings),
  #     then classify each file's ORIGIN (wf vs ext) and RUN id from its own
  #     path — no synthesized run id for an ext row, ever, since there is no
  #     wf_ directory in its path to read one from. Optionally restricted to
  #     the wf_ half when --by-agent-type is combined with --run.
  #
  #     The emitted "run" column below is "-", never a bare empty string,
  #     for an ext row. This is not cosmetic: the ONLY downstream reader of
  #     bat_records_tsv is a `while IFS=<tab> read -r ...` loop, and bash
  #     read collapses ADJACENT IFS-whitespace delimiters (a bare tab counts
  #     as whitespace) into ONE — a truly-empty interior field there
  #     silently shifts every LATER field left by one, which is exactly the
  #     bug this sentinel was added to fix (caught empirically: an ext row's
  #     calls/units swapped into the wrong columns and its units vanished).
  #     ---------------------------------------------------------------------
  bat_records_tsv="$tmpdir/bat_records.tsv"
  bat_run_scope=0; [ -n "$run_filter" ] && bat_run_scope=1
  awk -F'\t' \
    -v w_in="$SPEND_WEIGHT_INPUT" -v w_cr="$SPEND_WEIGHT_CACHE_READ" \
    -v w_cc="$SPEND_WEIGHT_CACHE_CREATE" -v w_out="$SPEND_WEIGHT_OUTPUT" \
    -v since="$since" -v until_="$until_" \
    -v run_norm="$run_norm" -v run_scope="$bat_run_scope" '
  {
    f = $1
    d = substr($2, 1, 10)
    if (d != "" && (!(f in mind) || d < mind[f])) mind[f] = d
    rid = $3
    if (rid != "none") { if (seen[f SUBSEP rid]++) next }
    calls[f]++
    units[f] += $5*w_cr + $6*w_cc + $7*w_out + $8*w_in
  }
  END {
    for (f in calls) {
      if (since != "" && mind[f] < since) continue
      if (until_ != "" && mind[f] > until_) continue
      origin = (index(f, "/subagents/workflows/") > 0) ? "wf" : "ext"
      # NEVER a real empty string here (see the awk call site comment above
      # this pass for why): "-" is a deliberate non-empty sentinel.
      run = "-"
      if (origin == "wf") {
        n = split(f, parts, "/")
        run = parts[n-1]
      }
      if (run_scope == 1) {
        if (origin != "wf") continue
        bare = run; sub(/^wf_/, "", bare)
        if (run_norm != "" && index(run_norm, "," bare ",") == 0) continue
      }
      printf "%s\t%s\t%s\t%d\t%d\n", f, origin, run, calls[f], int(units[f])
    }
  }' "$bat_all_usage_tsv" >"$bat_records_tsv"

  # --- 5. Sidecar resolution — one jq call per collected agent file (single
  #     project/session scope, so this is a small, bounded loop). THE ONLY
  #     SELECTOR EVER APPLIED IS `.agentType // empty` (structural privacy
  #     guarantee, see header + workflows/scripts/lib/token_sum.sh's sibling
  #     guarantee). A missing sidecar, or a sidecar with no `agentType`,
  #     resolves to the empty string here — never fabricated, never fatal. --
  bat_meta_tsv="$tmpdir/bat_meta.tsv"
  : >"$bat_meta_tsv"
  while IFS="$(printf '\t')" read -r bf borigin brun bcalls bunits; do
    [ -n "$bf" ] || continue
    bsidecar="${bf%.jsonl}.meta.json"
    if [ -f "$bsidecar" ]; then
      batype="$(jq -r '.agentType // empty' "$bsidecar" 2>/dev/null)"
    else
      batype=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bf" "$borigin" "$brun" "$bcalls" "$bunits" "$batype" >>"$bat_meta_tsv"
  done <"$bat_records_tsv"

  # --- 6. The ALLOWLIST — deployed agent-definition basenames under
  #     claude/agents/**/*.md in THIS checkout. NOT a passthrough: a sidecar
  #     value that doesn't match one of these names (general-purpose,
  #     workflow-subagent, claude, unrecognized, empty) is never a seat. ---
  bat_allow_tsv="$tmpdir/bat_allow.tsv"
  : >"$bat_allow_tsv"
  bat_agent_defs_dir="$REPO_ROOT/claude/agents"
  if [ -d "$bat_agent_defs_dir" ]; then
    find "$bat_agent_defs_dir" -name '*.md' -print0 2>/dev/null \
      | xargs -0 -n1 basename 2>/dev/null \
      | sed 's/\.md$//' \
      | sort -u >"$bat_allow_tsv"
  fi
  bat_recognized_defs="$(wc -l <"$bat_allow_tsv" | tr -d ' ')"

  # --- 7. Bucket into seats (allowlist match) vs unattributed (everything
  #     else), with the raw sidecar value retained per K#5's "distribution
  #     stays visible without being asserted as a seat". --------------------
  bat_totals_tsv="$tmpdir/bat_totals.tsv"
  : >"$bat_totals_tsv"
  awk -F'\t' -v allowfile="$bat_allow_tsv" -v seatsfile="$bat_seats_tsv" \
    -v rawfile="$bat_raw_tsv" -v totalsfile="$bat_totals_tsv" '
  BEGIN {
    while ((getline line < allowfile) > 0) { if (line != "") allow[line] = 1 }
    close(allowfile)
  }
  {
    calls = $4 + 0; units = $5 + 0; a = $6
    tot_agents++; tot_calls += calls; tot_units += units
    if (a != "" && (a in allow)) {
      seat_agents[a]++; seat_calls[a] += calls; seat_units[a] += units
    } else {
      raw = (a == "" ? "(unattributed: no sidecar or no agentType)" : a)
      rawc[raw]++
      unattr_agents++; unattr_calls += calls; unattr_units += units
    }
  }
  END {
    for (s in seat_agents) printf "%s\t%d\t%d\t%d\n", s, seat_agents[s], seat_calls[s], seat_units[s] >>seatsfile
    for (r in rawc) printf "%s\t%d\n", r, rawc[r] >>rawfile
    printf "%d\t%d\t%d\t%d\t%d\t%d\n", tot_agents+0, tot_calls+0, tot_units+0, unattr_agents+0, unattr_calls+0, unattr_units+0 >>totalsfile
  }' "$bat_meta_tsv"

  if [ -s "$bat_totals_tsv" ]; then
    bat_tot_agents="$(cut -f1 "$bat_totals_tsv")"
    bat_tot_calls="$(cut -f2 "$bat_totals_tsv")"
    bat_tot_units="$(cut -f3 "$bat_totals_tsv")"
    bat_unattr_agents="$(cut -f4 "$bat_totals_tsv")"
    bat_unattr_calls="$(cut -f5 "$bat_totals_tsv")"
    bat_unattr_units="$(cut -f6 "$bat_totals_tsv")"
  fi

  if [ "$bat_run_scope" -eq 1 ]; then
    bat_scope="single Claude Code project directory ($root), restricted to wf_ run(s) matching --run — ext (non-workflow) journals excluded"
  else
    bat_scope="single Claude Code project directory ($root) — every */subagents/ session under it, wf_ and ext journals both included"
  fi
fi

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
  if [ -n "$by_agent_type" ]; then
    printf '  ],\n'
    printf '  "by_agent_type": {\n'
    printf '    "scope": %s,\n' "$(json_or_null "$bat_scope")"
    printf '    "agents": %s, "api_calls": %s, "units": %s,\n' "$bat_tot_agents" "$bat_tot_calls" "$bat_tot_units"
    printf '    "recognized_agent_definitions": %s,\n' "$bat_recognized_defs"
    if [ "$bat_recognized_defs" -eq 0 ]; then
      printf '    "notice": %s,\n' \
        "$(json_or_null "0 recognized agent definitions found under claude/agents/**/*.md — every seat in this corpus reads unattributed; run workflows/scripts/install/project-agents.sh to install the deployed agent set")"
    else
      printf '    "notice": null,\n'
    fi
    printf '    "seats": {'
    awk -F'\t' '{ k=$1; gsub(/\\/, "\\\\", k); gsub(/"/, "\\\"", k); printf "%s\"%s\": {\"agents\": %s, \"api_calls\": %s, \"units\": %s}", (NR>1 ? ", " : ""), k, $2, $3, $4 }' "$bat_seats_tsv"
    printf '},\n'
    printf '    "unattributed": {"agents": %s, "api_calls": %s, "units": %s, "by_raw_value": {' \
      "$bat_unattr_agents" "$bat_unattr_calls" "$bat_unattr_units"
    awk -F'\t' '{ k=$1; gsub(/\\/, "\\\\", k); gsub(/"/, "\\\"", k); printf "%s\"%s\": %s", (NR>1 ? ", " : ""), k, $2 }' "$bat_raw_tsv"
    printf '}}\n'
    printf '  }\n}\n'
  else
    printf '  ]\n}\n'
  fi
  exit 0
fi

printf 'pipeline spend — cost-weighted units from Claude Code workflow agent transcripts\n'
printf '  transcript root : %s\n' "$root"
printf '  window          : %s\n' "$( [ -z "$since" ] && [ -z "$until_" ] && printf 'all dates' || printf '%s .. %s' "${since:-(open)}" "${until_:-(open)}" )"
printf '  run filter      : %s\n' "${run_filter:-(none)}"
printf '  weights         : input=%s cache_read=%s cache_create=%s output=%s   (SPEND_WEIGHT_*)\n' \
  "$SPEND_WEIGHT_INPUT" "$SPEND_WEIGHT_CACHE_READ" "$SPEND_WEIGHT_CACHE_CREATE" "$SPEND_WEIGHT_OUTPUT"
printf '\n'

# render_by_agent_type_text — the --by-agent-type text section (temperloop#1314).
# A no-op when the flag is absent, so it is safe to call unconditionally at
# both the "no transcripts matched" early exit below and the normal end of
# this report — the empty-corpus arm still owes its own by_agent_type output
# when the flag is set (that corpus is independent of the default one).
render_by_agent_type_text() {
  [ -n "$by_agent_type" ] || return 0
  printf '\n'
  printf 'by agent type (attribution side channel — NEVER a decomposition of "cost-weighted spend" above)\n'
  printf '  scope                   %s\n' "$bat_scope"
  printf '  recognized agent defs   %s\n' "$bat_recognized_defs"
  if [ "$bat_recognized_defs" -eq 0 ]; then
    printf '  NOTE: 0 recognized agent definitions found under claude/agents/**/*.md -- every seat below reads unattributed; run workflows/scripts/install/project-agents.sh\n'
  fi
  printf '  total          agents=%-6s api_calls=%-8s units=%s\n' "$bat_tot_agents" "$bat_tot_calls" "$bat_tot_units"
  printf '  seats:\n'
  if [ -s "$bat_seats_tsv" ]; then
    sort -t'	' -k4,4nr "$bat_seats_tsv" | while IFS="$(printf '\t')" read -r s sa sc su; do
      [ -n "$s" ] || continue
      printf '    %-30s agents=%-6s api_calls=%-8s units=%s\n' "$s" "$sa" "$sc" "$su"
    done
  else
    printf '    (none)\n'
  fi
  printf '  unattributed   agents=%-6s api_calls=%-8s units=%s\n' "$bat_unattr_agents" "$bat_unattr_calls" "$bat_unattr_units"
  if [ -s "$bat_raw_tsv" ]; then
    sort -t'	' -k2,2nr "$bat_raw_tsv" | while IFS="$(printf '\t')" read -r rv rc; do
      [ -n "$rv" ] || continue
      printf '    raw=%-40s agents=%s\n' "$rv" "$rc"
    done
  fi
}

if [ "$n_agents" -eq 0 ]; then
  printf 'no transcripts matched — nothing to report.\n'
  printf '  (looked under %s for */wf_*/agent-*.jsonl)\n' "$root"
  render_by_agent_type_text
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
render_by_agent_type_text
