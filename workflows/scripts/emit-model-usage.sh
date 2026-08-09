#!/usr/bin/env bash
#
# emit-model-usage.sh — append one per-spawned-seat record to the append-only
# model-usage raw-lake stream (temperloop#1253, epic #1225 "model comparison
# harness", ADR 0026: docs/adr/0026-attribution-telemetry-coexists-with-transcript-cost.md).
#
# WHY THIS EXISTS: ADR 0020's transcript-based cost measurement owns the
# report's headline dollar figure, but a transcript cannot say WHICH pipeline
# seat spent it, nor WHICH outcome (issue/PR) the spend produced — only the
# spawn site knows both at spawn time. This script is that spawn-site emit:
# seat name, model, provider, token counts, duration, and an outcome ref, one
# record per spawn. Sibling to emit-command-run.sh / emit-issue-touch.sh: same
# structure, arg style, warn-don't-drop contract, and raw-lake conventions.
#
# GATE SCOPE (temperloop#1253) — this item shipped the emit script, its
# content validator, and the record schema. Wiring the three emit-feasible
# seats named below into their actual spawn sites (pipeline-drive.sh's A7/A8,
# pipeline-retro-judge-spawn.sh's A9 — via the shared
# workflows/scripts/lib/model-usage-envelope.sh extraction) was a LATER item,
# attribution-spawn-site-wiring (temperloop#1255), now done — see that lib
# file and validate-model-usage-emit.sh's own "6. SPAWN-SITE COVERAGE"
# section for the wiring + its coverage gate. An empty or absent stream is
# still legal (a fresh checkout that hasn't run the pipeline yet has nothing
# to append), just no longer for the "nothing is wired" reason.
#
# ── The spike verdict this schema is built from ─────────────────────────────
# temperloop#1246's L0 usage-capture-feasibility spike (operator knowledge
# store: Context/temperloop - per-seat usage capture feasibility.md) found:
#
#   * Only 3 of 12 pipeline spawn seats can emit a token-bearing record TODAY
#     — A7 (pipeline-drive.sh level-5b safe driver), A8 (pipeline-drive.sh
#     level-5c merge driver), A9 (the retro judge, pipeline-retro-judge-spawn.sh).
#     All three are shell wrappers around `claude -p --output-format json`;
#     the captured stdout IS the envelope carrying `usage`/`modelUsage`.
#     Everything else either has no shell seam at spawn time, or the harness
#     drops the seat label before the token-bearing journal is written (the
#     `.mjs` class: build-level.mjs's worker/machinery calls). This is why
#     `--usage-source` below is a real discriminator, not a formality: an
#     ATTRIBUTION-ONLY record (seat + model + outcome ref, no tokens) is a
#     legitimate, spike-anticipated shape for a future emit-feasible-but-not-
#     token-bearing seat, not a malformed one.
#   * The CLI envelope's `modelUsage[model]` block carries `inputTokens`,
#     `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, and
#     `provider` NATIVELY, all four token classes together, every time —
#     which is why `--usage-source cli-envelope` requires all four token
#     flags TOGETHER (never a partial subset): a genuine cli-envelope caller
#     always has all four, so a partial set signals a caller bug, not a
#     partial observation to silently accept.
#
# ── Divergence from ADR 0020's two counting rules, per the spike ───────────
# ADR 0026's original text said this stream "inherits ADR 0020's counting
# rules (requestId dedup, cache-class weighting)". The spike found that only
# HALF of that is mechanically true, and narrows it as follows — this is the
# "declared owner" documentation temperloop#1253's acceptance criterion
# requires when a rule is not mechanically inheritable:
#
#   1. requestId DEDUP — NOT inheritable, because it is STRUCTURALLY
#      INAPPLICABLE, not merely hard. ADR 0020's dedup rule
#      (pipeline-spend-report.sh:400's `awk` `seen[key SUBSEP rid]++`) exists
#      to collapse a TRANSCRIPT's redundant JSONL lines — one API response
#      written as several lines (thinking/text/tool_use blocks), each
#      repeating the same `usage` object, inflating a naive sum ~2.16x. The
#      CLI envelope this script's `--usage-source cli-envelope` records from
#      is already a per-run AGGREGATE (the CLI itself sums an internal
#      `usage.iterations[]` array) and carries NO `requestId` field at all —
#      there is nothing to dedupe, and applying a dedup step here would
#      imply a duplicate-detection guarantee this script cannot make. The
#      DECLARED OWNER of this divergence is the CLI envelope itself (its
#      already-aggregated, requestId-less shape), not a gap in this script.
#   2. cache-class WEIGHTING — genuinely inheritable, but only as VALUES,
#      never as code: there is no sourceable weighting FUNCTION anywhere in
#      this repo (pipeline-spend-report.sh's `units()` arithmetic is
#      duplicated inline three times inside that one file, not exposed as a
#      library call). What IS inheritable, and what this script actually
#      does, is source the same four `SPEND_WEIGHT_*` settings from
#      build.config.sh (never a second hardcoded copy of the numbers) and
#      apply the identical one-line multiply-add
#      (input*W_IN + cache_read*W_CR + cache_creation*W_CC + output*W_OUT,
#      floored) to produce `weighted_units` — so a weight retune in
#      build.config.sh changes both producers' numbers together, and the two
#      producers can never silently disagree about how a token is counted
#      (ADR 0026's stated goal).
#
# ── ADR 0028 divergence: no host, no cross-repo operator identifier ────────
# Every sibling emit script here (emit-issue-touch.sh, emit-item-efficiency.sh)
# carries a `host` field (`${SUBSET_HOST_LABEL:-$(hostname -s)}`). This
# script DELIBERATELY DOES NOT — ADR 0028's Consequences section requires
# that model-comparison records "carry seat role names rather than any
# cross-repo operator identifier, so records from two repos cannot be
# correlated". A machine hostname is exactly such a cross-repo correlator (a
# consultant's `.jsonl` files from two different client repos, both stamped
# with the same laptop hostname, would let a reader link the two
# engagements), so `--seat` (a role name: "pipeline-drive-safe",
# "retro-judge", …) is the only identity field this record carries, and there
# is no `--host` flag to accept one. `session_id` is kept (every other stream
# in this repo keys on it, and it is a per-run, non-durable, non-identifying
# token, not an operator identifier) — see docs/features/model-comparison.md
# "What it never contains" for the plain-language version of this guarantee.
#
# canonical sink spec: docs/features/model-comparison.md (this module has its
# own feature doc, pre-shipped ahead of this item — see its "Per-seat
# attribution telemetry" and "What the attribution telemetry collects, in
# plain terms" sections); the generic raw-lake path/schema-version convention
# is docs/features/telemetry.md, which also lists this stream.
#
# Record shape: {schema_version, ts, session_id, repo, seat, model, provider,
#                usage_source, tokens, weighted_units, duration_ms, outcome_ref}
#   schema_version    "1" (string)
#   ts                ISO-8601 UTC, `Z` suffix
#   session_id        the RAW $CLAUDE_CODE_SESSION_ID (full value,
#                      UNTRUNCATED), null when unset — same join-key
#                      convention as every other stream in meta/data/raw/
#   repo              "owner/repo" from --repo, or null
#   seat               the spawn's role name (--seat), e.g.
#                      "pipeline-drive-safe" / "pipeline-drive-merge" /
#                      "retro-judge" — NEVER a machine/operator identifier
#   model             the model id that ran (--model), verbatim
#   provider          the ADR 0028 vendor-provider name (--provider),
#                      required (and content-validated against the committed
#                      allowlist by validate-model-usage-emit.sh) when
#                      usage_source is cli-envelope; null when unavailable
#   usage_source      "cli-envelope" | "unavailable" — cli-envelope means
#                      tokens/provider came from a captured
#                      `claude -p --output-format json` envelope; unavailable
#                      means an attribution-only record (seat/model/outcome
#                      ref known, tokens structurally unreachable — see the
#                      `.mjs` class in the spike note above)
#   tokens            {input, output, cache_read, cache_creation} (all
#                      non-negative integers), present iff usage_source is
#                      cli-envelope; null iff unavailable
#   weighted_units    cost-weighted total per the inherited SPEND_WEIGHT_*
#                      values (see divergence note above), present iff
#                      tokens is present AND the weight settings resolved
#                      cleanly; null otherwise. CAVEAT (advisory 9a/A7): this
#                      record does NOT also carry the weight vector it was
#                      computed with, so weighted_units is comparable only
#                      WITHIN a single SPEND_WEIGHT_* "retune epoch" — after a
#                      weight retune in build.config.sh, an old record's
#                      weighted_units and a new record's are not
#                      apples-to-apples, and there is no way to recompute the
#                      old figure under the new weights from the record alone.
#                      `tokens` is the durable, retune-independent figure;
#                      treat weighted_units as a today's-weights convenience
#                      view, not the figure to trend across a retune. (A
#                      carried `weights_version` field would let a reader
#                      detect/re-derive across a retune — a real improvement,
#                      but out of scope here; this is the documented
#                      cheaper-but-honest alternative.) The validator
#                      deliberately does NOT re-verify weighted_units against
#                      tokens for the same reason: a retuned weight would make
#                      an old, correctly-recorded value look "wrong" against
#                      today's formula.
#   duration_ms       non-negative integer (--duration-ms) or null —
#                      independent of usage_source (wall-clock timing needs
#                      no envelope)
#   outcome_ref       the issue/PR this spawn was working on, e.g.
#                      "issue:1253" or "pr:1289" (--outcome-ref, required)
#
# Usage:
#   emit-model-usage.sh --seat <role> --model <id> --usage-source cli-envelope|unavailable \
#     --outcome-ref <ref> [--provider <name>] \
#     [--input-tokens <n> --output-tokens <n> --cache-read-tokens <n> --cache-creation-tokens <n>] \
#     [--duration-ms <n>] [--repo <owner/repo>] [--print-only]
#
#   --usage-source cli-envelope REQUIRES --provider and all four token flags
#   TOGETHER (never a subset). --usage-source unavailable FORBIDS --provider
#   and all four token flags (a contradiction warns and drops the record —
#   see "WARN, DON'T DROP" below).
#
# Appends ONE JSONL line to:
#   ${MODEL_USAGE_RAW_DIR:-<repo>/meta/data/raw}/model-usage-YYYY-MM.jsonl
# (monthly rotation, matching every other stream in that directory).
#
# --print-only computes and prints the record WITHOUT appending (same
# convention as emit-item-efficiency.sh's own --print-only).
#
# WARN, DON'T DROP: any failure here (bad/missing args, a contradictory
# usage-source/token-or-provider pairing, jq missing, sink unwritable) warns
# to stderr and exits 0. A telemetry emit must never fail or block the
# calling spawn site — see the `|| true`-safe contract in the epic #724
# Contract (the same contract every sibling emit script here follows).
#
# ARG-ARITY GUARD: every value-taking flag below is arity-checked before the
# arg-loop shifts — a value-taking flag with NO following argument (e.g. this
# script invoked with a trailing `--seat`) is dropped with a warning rather
# than shifting past the end of `$#`, which — since this script deliberately
# does not run under `set -e` (a telemetry emit warns, never aborts a caller)
# — would otherwise spin `$1` forever at 100% CPU instead of returning. A
# value that itself looks like another flag (starts with `--`, e.g.
# `--seat --model foo`) is rejected the same way rather than silently
# consumed as the flag's value. Dropping the flag reliably surfaces as the
# pre-existing "required flag missing" warn-and-drop path below, so this is
# no new failure shape, only a hang closed off.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warn() { printf '%s: WARN %s\n' "$self" "$*" >&2; }

seat=""
model=""
usage_source=""
outcome_ref=""
provider=""
input_tokens=""
output_tokens=""
cache_read_tokens=""
cache_creation_tokens=""
duration_ms=""
repo=""
print_only=0

# arg_ok <flagname> <remaining-argc> <next-arg-or-empty>
# Returns 0 iff <flagname> has a real value to take, having already warned
# and returned 1 otherwise (no value at all, or a value that looks like
# another flag) — see the header's ARG-ARITY GUARD note. Never shifts;
# the call site decides how many positions to consume.
arg_ok() {
  local flag="$1" remaining="$2" next="$3"
  if [ "$remaining" -lt 2 ]; then
    warn "$flag requires a value but none was given (ignored)"
    return 1
  fi
  case "$next" in
    --*)
      warn "$flag requires a value, got flag-like '$next' (ignored, not consumed as the value)"
      return 1
      ;;
  esac
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --seat)                  if arg_ok --seat $# "${2:-}"; then seat="$2"; shift 2; else shift; fi ;;
    --model)                 if arg_ok --model $# "${2:-}"; then model="$2"; shift 2; else shift; fi ;;
    --usage-source)          if arg_ok --usage-source $# "${2:-}"; then usage_source="$2"; shift 2; else shift; fi ;;
    --outcome-ref)           if arg_ok --outcome-ref $# "${2:-}"; then outcome_ref="$2"; shift 2; else shift; fi ;;
    --provider)               if arg_ok --provider $# "${2:-}"; then provider="$2"; shift 2; else shift; fi ;;
    --input-tokens)          if arg_ok --input-tokens $# "${2:-}"; then input_tokens="$2"; shift 2; else shift; fi ;;
    --output-tokens)         if arg_ok --output-tokens $# "${2:-}"; then output_tokens="$2"; shift 2; else shift; fi ;;
    --cache-read-tokens)     if arg_ok --cache-read-tokens $# "${2:-}"; then cache_read_tokens="$2"; shift 2; else shift; fi ;;
    --cache-creation-tokens) if arg_ok --cache-creation-tokens $# "${2:-}"; then cache_creation_tokens="$2"; shift 2; else shift; fi ;;
    --duration-ms)           if arg_ok --duration-ms $# "${2:-}"; then duration_ms="$2"; shift 2; else shift; fi ;;
    --repo)                  if arg_ok --repo $# "${2:-}"; then repo="$2"; shift 2; else shift; fi ;;
    --print-only)             print_only=1; shift ;;
    -h|--help)
      # Print the WHOLE header comment block (line 1 is the shebang, skipped;
      # the header ends at the first non-'#' line, i.e. the blank line right
      # before `set -uo pipefail`) rather than a hardcoded line range — a
      # hardcoded range silently truncates mid-sentence (and cuts off the
      # WARN-DON'T-DROP contract, the single most important thing a spawn-site
      # author needs) the next time the header grows or shrinks (advisory 9b).
      awk 'NR==1{next} /^#/{print; next} {exit}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      warn "unknown argument $1 (ignored)"
      shift
      ;;
  esac
done

if [ -z "$seat" ]; then
  warn "--seat is required — no record emitted"
  exit 0
fi
if [ -z "$model" ]; then
  warn "--model is required — no record emitted"
  exit 0
fi
if [ -z "$outcome_ref" ]; then
  warn "--outcome-ref is required — no record emitted"
  exit 0
fi
case "$usage_source" in
  cli-envelope|unavailable) : ;;
  *)
    warn "--usage-source must be cli-envelope or unavailable, got '$usage_source' — no record emitted"
    exit 0
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found — no record emitted (seat=$seat)"
  exit 0
fi

# is_nonneg_int <flagname> <value> -> 0 ok, 1 malformed (already warned)
is_nonneg_int() {
  case "$2" in
    ''|*[!0-9]*)
      warn "$1 must be a non-negative integer, got \"$2\" — no record emitted (seat=$seat)"
      return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# usage_source pairing rules — see the header's spike-grounded rationale.
# ---------------------------------------------------------------------------
tokens_json="null"
weighted_enabled=0

case "$usage_source" in
  cli-envelope)
    if [ -z "$provider" ]; then
      warn "--usage-source cli-envelope requires --provider — no record emitted (seat=$seat)"
      exit 0
    fi
    if [ -z "$input_tokens" ] || [ -z "$output_tokens" ] || [ -z "$cache_read_tokens" ] || [ -z "$cache_creation_tokens" ]; then
      warn "--usage-source cli-envelope requires --input-tokens, --output-tokens, --cache-read-tokens, and --cache-creation-tokens all together (the CLI envelope always returns all four) — no record emitted (seat=$seat)"
      exit 0
    fi
    is_nonneg_int --input-tokens "$input_tokens" || exit 0
    is_nonneg_int --output-tokens "$output_tokens" || exit 0
    is_nonneg_int --cache-read-tokens "$cache_read_tokens" || exit 0
    is_nonneg_int --cache-creation-tokens "$cache_creation_tokens" || exit 0
    # Base-10 normalize so a zero-padded count isn't read as octal.
    input_tokens=$((10#$input_tokens))
    output_tokens=$((10#$output_tokens))
    cache_read_tokens=$((10#$cache_read_tokens))
    cache_creation_tokens=$((10#$cache_creation_tokens))
    tokens_json="$(jq -nc \
      --argjson i "$input_tokens" --argjson o "$output_tokens" \
      --argjson cr "$cache_read_tokens" --argjson cc "$cache_creation_tokens" \
      '{input: $i, output: $o, cache_read: $cr, cache_creation: $cc}')"
    weighted_enabled=1
    ;;
  unavailable)
    if [ -n "$provider" ]; then
      warn "--usage-source unavailable but --provider was supplied — contradictory input, no record emitted (seat=$seat)"
      exit 0
    fi
    if [ -n "$input_tokens" ] || [ -n "$output_tokens" ] || [ -n "$cache_read_tokens" ] || [ -n "$cache_creation_tokens" ]; then
      warn "--usage-source unavailable but token counts were supplied — contradictory input, no record emitted (seat=$seat)"
      exit 0
    fi
    ;;
esac

if [ -n "$duration_ms" ]; then
  is_nonneg_int --duration-ms "$duration_ms" || exit 0
  duration_ms=$((10#$duration_ms))
fi

# ---------------------------------------------------------------------------
# Cache-class weighting — inherited as VALUES from build.config.sh (see the
# header's "Divergence from ADR 0020" note, point 2). Degrades weighted_units
# to null (with a warning) rather than failing the whole emit if the settings
# are missing or malformed — this script's core job (the seat/token/outcome
# record) must not be held hostage by a weighting side-computation.
# ---------------------------------------------------------------------------
weights_ok=1
if [ "$weighted_enabled" -eq 1 ]; then
  if [ -f "$here/build/build.config.sh" ]; then
    # shellcheck source=workflows/scripts/build/build.config.sh
    source "$here/build/build.config.sh"
  fi
  : "${SPEND_WEIGHT_INPUT:=}"
  : "${SPEND_WEIGHT_CACHE_READ:=}"
  : "${SPEND_WEIGHT_CACHE_CREATE:=}"
  : "${SPEND_WEIGHT_OUTPUT:=}"
  for _w in "$SPEND_WEIGHT_INPUT" "$SPEND_WEIGHT_CACHE_READ" "$SPEND_WEIGHT_CACHE_CREATE" "$SPEND_WEIGHT_OUTPUT"; do
    case "$_w" in
      ''|*[!0-9.]*|*.*.*) weights_ok=0 ;;
    esac
  done
  if [ "$weights_ok" -eq 0 ]; then
    warn "SPEND_WEIGHT_* settings missing or malformed (workflows/scripts/build/build.config.sh) — weighted_units will be null this record"
  fi
fi
[ "$weights_ok" -eq 1 ] || weighted_enabled=0

# ---------------------------------------------------------------------------
# Assemble + append.
# ---------------------------------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"

record="$(jq -nc \
  --arg ts "$ts" \
  --arg session_id "$session_id" \
  --arg repo "$repo" \
  --arg seat "$seat" \
  --arg model "$model" \
  --arg provider "$provider" \
  --arg usage_source "$usage_source" \
  --argjson tokens "$tokens_json" \
  --argjson wu_enabled "$weighted_enabled" \
  --argjson w_in "${SPEND_WEIGHT_INPUT:-0}" \
  --argjson w_cr "${SPEND_WEIGHT_CACHE_READ:-0}" \
  --argjson w_cc "${SPEND_WEIGHT_CACHE_CREATE:-0}" \
  --argjson w_out "${SPEND_WEIGHT_OUTPUT:-0}" \
  --arg duration_ms "$duration_ms" \
  --arg outcome_ref "$outcome_ref" \
  '
  def wu:
    if $wu_enabled == 1 and $tokens != null then
      (($tokens.input * $w_in) + ($tokens.cache_read * $w_cr)
       + ($tokens.cache_creation * $w_cc) + ($tokens.output * $w_out) | floor)
    else null end;
  {
    schema_version: "1",
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    repo: (if $repo == "" then null else $repo end),
    seat: $seat,
    model: $model,
    provider: (if $provider == "" then null else $provider end),
    usage_source: $usage_source,
    tokens: $tokens,
    weighted_units: wu,
    duration_ms: (if $duration_ms == "" then null else ($duration_ms | tonumber) end),
    outcome_ref: $outcome_ref
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  warn "failed to build JSON record (seat=$seat) — no record emitted"
  exit 0
fi

if [ "$print_only" -eq 1 ]; then
  printf '%s\n' "$record"
  exit 0
fi

# Resolve the raw sink dir the same way every sibling emit script does: an
# explicit override env var first, else the repo this script lives in
# (workflows/scripts/../.. == repo root), so it works from any checkout that
# vendors this file. NO foreign-path guess (advisory 9a): a prior version of
# this line fell back to a hardcoded $HOME/dev/foundation when the repo-root
# resolution failed, but this is temperloop (a different repo), and a
# stranger's checkout has no such directory at all — silently writing there
# (or into whatever unrelated tree happens to exist at that path) is worse
# than not writing. If MODEL_USAGE_RAW_DIR is unset AND the repo root can't
# be resolved, warn and drop the record (WARN, DON'T DROP still holds — this
# just never guesses a path).
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd)"
# `${MODEL_USAGE_RAW_DIR:+x}` (not `${MODEL_USAGE_RAW_DIR:-}`) deliberately —
# the setting-registry lint (workflows/scripts/config/check-setting-registry.sh)
# scans for every `${MODEL_USAGE_RAW_DIR:-...}`-shaped seam in this file and
# requires each one's default literal to match the registry row for this
# name; a second `:-` seam here (even one only used for an emptiness test)
# would need its own registry row. `:+` sidesteps that — it's a plain
# "is this set and non-empty" test, not a defaulting seam.
if [ -z "${MODEL_USAGE_RAW_DIR:+x}" ] && [ -z "$raw_root" ]; then
  warn "cannot resolve the repo root above $here, and MODEL_USAGE_RAW_DIR is unset — no fallback path guessed, no record emitted (seat=$seat)"
  exit 0
fi
raw_dir="${MODEL_USAGE_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/model-usage-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  warn "failed to append record to $raw_file (seat=$seat)"
  exit 0
fi

printf '%s\n' "$record"
