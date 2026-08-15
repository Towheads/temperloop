#!/usr/bin/env bash
#
# model-usage-envelope.sh — shared helper: given the raw stdout of a
# captured `claude -p --output-format json` envelope, emit ONE model-usage
# attribution record via emit-model-usage.sh (temperloop#1255, epic #1225
# "model comparison harness").
#
# WHY THIS EXISTS: per the L0 usage-capture-feasibility spike (operator
# knowledge store: Context/temperloop - per-seat usage capture
# feasibility.md), exactly THREE pipeline spawn seats capture a
# `claude -p --output-format json` envelope today — pipeline-drive.sh's
# level-5b safe driver (A7) and level-5c merge driver (A8), and
# pipeline-retro-judge-spawn.sh's retro judge (A9). All three need the SAME
# envelope→record extraction; this file is the ONE place that logic lives,
# so the three call sites share it instead of three hand-rolled copies that
# could silently drift apart (and so a fixture test can exercise the
# extraction once instead of three times).
#
# SOURCED LIBRARY, not a standalone script — like allowlist.sh /
# setting-registry-lib.sh, this file defines a function only and never sets
# shell options (`set -e`/`pipefail`) at source time, so sourcing it never
# mutates the caller's shell, and it is safe to source into a caller that
# runs under `set -euo pipefail` (pipeline-drive.sh) as well as one that
# does not (pipeline-retro-judge-spawn.sh, `set -uo pipefail` only).
#
# model_usage_emit_from_envelope <seat> <requested-model> <outcome-ref> <repo> <emit-script-path>
#   stdin = the raw captured envelope (claude -p --output-format json stdout)
#
#   <seat>              the ADR 0026 role name, e.g. "pipeline-drive-safe" /
#                       "pipeline-drive-merge" / "retro-judge" — NEVER a
#                       machine/operator identifier (ADR 0028)
#   <requested-model>   the --model value the caller passed to claude -p —
#                       the FALLBACK model reported when the envelope can't
#                       be parsed (jq missing, malformed JSON, no modelUsage)
#   <outcome-ref>       "(issue|pr):<ref>" — the caller resolves this (a
#                       specific issue/PR when the spawn covered exactly
#                       one, else a board-scoped composite ref for a batch
#                       spawn that touched several)
#   <repo>              "owner/repo", or empty/unset for none
#   <emit-script-path>  path to emit-model-usage.sh — a TEST SEAM: a
#                       fixture test can point this at a test double
#                       instead of the real script
#
# EXTRACTION. The captured envelope's `modelUsage` object is keyed by model
# id, one entry per model actually used during the spawn (a spawn CAN
# legitimately touch more than one model, e.g. a delegated subagent) — token
# counts are a WHOLE-SPAWN total, summed across every key present, never
# split per model (a single emit-model-usage.sh record has one `tokens`
# object). The RESOLVED `model` reported is the key carrying the GREATEST
# total token weight (input+output+cache_read+cache_creation) — "resolved"
# in the ADR 0026 sense: what actually ran, not merely what the caller
# asked for via --model. Falls back to <requested-model> whenever
# `modelUsage` is absent, empty, or every key's token fields fail to
# resolve to clean non-negative integers.
#
# PROVIDER. Hardcoded "anthropic" whenever a usable modelUsage block is
# found. These three seats are ALWAYS a direct `claude -p` call against
# Anthropic's own first-party CLI — never a model-comparison cross-provider
# call — so ADR 0028's vendor-provider concept is unambiguous here. This is
# DELIBERATELY not the envelope's own internal `provider` vocabulary (e.g.
# "firstParty", observed live against claude 2.1.226) — that is a
# Claude-Code-internal routing label, not an ADR 0028 vendor name, and the
# two must never be conflated (the ADR 0028 committed allowlist —
# workflows/scripts/model-comparison/provider-allowlist.txt — names
# "anthropic", never "firstParty").
#
# FAIL-OPEN, matching emit-model-usage.sh's own WARN-DON'T-DROP contract: a
# missing jq, an unparseable envelope, or an empty/malformed modelUsage all
# degrade to an ATTRIBUTION-ONLY record (usage_source=unavailable, no
# tokens/provider) — this function NEVER aborts the caller and NEVER drops
# the seat/model/outcome-ref triple entirely. Everything downstream of that
# (a missing/non-executable emit script, an unwritable sink, a malformed
# arg) is emit-model-usage.sh's own job, already covered by its own
# WARN-DON'T-DROP contract and validate-model-usage-emit.sh.
#
# STDOUT DISCIPLINE — the reason this is called out explicitly: every
# emit-model-usage.sh invocation below is ALWAYS silenced to /dev/null,
# never merely `--print-only`-avoided. emit-model-usage.sh unconditionally
# prints the assembled record to its OWN stdout (the same line it appends to
# the raw lake) — a courtesy for a direct/interactive/--print-only caller.
# But all three of THIS function's callers are themselves required to put
# EXACTLY ONE JSON object on their own stdout (pipeline-drive.sh's
# `emit_outcome`; pipeline-retro-judge-spawn.sh's `_emit`) that a downstream
# consumer (pipeline-cron.sh) parses as machine output — a leaked second
# JSON object on that same stream corrupts the parse (observed: this exact
# leak broke test_pipeline_drive.sh's t4/t4b JSON assertions before this
# comment existed). The record is not lost by silencing stdout — it is
# already durably appended to the raw lake by emit-model-usage.sh itself;
# only the redundant stdout echo is suppressed.
#
# Kept bash-3.2-friendly (macOS dev shell + Linux CI) — no mapfile, no
# associative arrays.

# _model_usage_run_emit <emit-script> [args…] — run the emitter with the
# caller's resolved sink applied as a PER-COMMAND env prefix, never an export.
#
# WHY A PREFIX AND NOT AN EXPORT (temperloop#1565, review follow-up). The
# callers know the canonical lake dir the emitter cannot derive for itself, and
# the obvious way to hand it over is `export MODEL_USAGE_RAW_DIR` at the top of
# the caller. That is WRONG, and the failure is not hypothetical: an export is
# process-wide and INHERITED, and pipeline-drive.sh spawns a headless
# `claude -p` driver with the full inherited environment. That session runs
# /pipeline-drive → /build → scripts/quality-gates.sh, and MODEL_USAGE_RAW_DIR
# is read by more than the emitter — validate-model-usage-emit.sh and
# validate-provider-disclosure.sh both consult it, as do the model-comparison
# readers (replay.sh, tagging.sh, report-producers/model-comparison). An
# exported pin therefore silently converts two REPO-SCOPED quality gates into
# PRODUCTION-DATA gates inside an autonomous drive: the emit validator starts
# strict-parsing a long-lived append-only stream written by multiple emitter
# versions (observed: a legacy record fails the CLOSED schema), and the
# disclosure gate joins production sends against the WORKTREE's disclosure log,
# so every non-default-provider production send reads as SEND-WITHOUT-DISCLOSURE
# and a single non-JSON line anywhere in the lake hard-aborts it. That is
# temperloop#1565's own defect class inverted — a check reading the wrong lake.
#
# The prefix binds the variable for the emitter process ALONE. `_`-prefixed
# because it is private implementation state shared between this lib and its
# callers, not an operator-tunable setting (the setting-registry sweep excludes
# `_`-prefixed names for exactly this category). Empty/unset ⇒ no prefix at
# all, so the emitter keeps its own checkout-relative default.
#
# Stdout is silenced here, once, for every path — see this file's own STDOUT
# DISCIPLINE note above: all three callers must put exactly one JSON object on
# their own stdout, and emit-model-usage.sh unconditionally echoes the record it
# appended.
_model_usage_run_emit() {
  local emit_script="$1"
  shift
  if [ -n "${_MODEL_USAGE_SINK_DIR:-}" ]; then
    MODEL_USAGE_RAW_DIR="$_MODEL_USAGE_SINK_DIR" "$emit_script" "$@" >/dev/null || true
  else
    "$emit_script" "$@" >/dev/null || true
  fi
  return 0
}

model_usage_emit_from_envelope() {
  local seat="$1" req_model="$2" outcome_ref="$3" repo="$4" emit_script="$5"
  local blob
  blob="$(cat)"

  # Nothing to call — this is a fixture/misconfiguration case, not this
  # function's job to diagnose (emit-model-usage.sh's own presence-lint,
  # validate-model-usage-emit.sh, already covers that). Never abort.
  if [ ! -x "$emit_script" ]; then
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    local args=(--seat "$seat" --model "$req_model" --usage-source unavailable --outcome-ref "$outcome_ref")
    [ -n "$repo" ] && args+=(--repo "$repo")
    _model_usage_run_emit "$emit_script" "${args[@]}"
    return 0
  fi

  # duration_ms — independent of usage_source (wall-clock timing needs no
  # envelope). A malformed/absent value degrades to "flag omitted", never a
  # hard failure.
  local duration_ms=""
  duration_ms="$(jq -r '.duration_ms // empty' <<<"$blob" 2>/dev/null || true)"
  case "$duration_ms" in
    ''|*[!0-9]*) duration_ms="" ;;
  esac

  local n_keys=0
  n_keys="$(jq -r '(.modelUsage // {}) | keys | length' <<<"$blob" 2>/dev/null || true)"
  case "$n_keys" in ''|*[!0-9]*) n_keys=0 ;; esac

  local args=(--seat "$seat" --outcome-ref "$outcome_ref")
  [ -n "$repo" ] && args+=(--repo "$repo")
  [ -n "$duration_ms" ] && args+=(--duration-ms "$duration_ms")

  if [ "$n_keys" -gt 0 ]; then
    local resolved_model input output cache_read cache_creation
    resolved_model="$(jq -r '
      .modelUsage | to_entries
      | max_by(((.value.inputTokens // 0) + (.value.outputTokens // 0)
               + (.value.cacheReadInputTokens // 0) + (.value.cacheCreationInputTokens // 0)))
      | .key
    ' <<<"$blob" 2>/dev/null || true)"
    input="$(jq -r '[.modelUsage[]?.inputTokens // 0] | add | floor' <<<"$blob" 2>/dev/null || true)"
    output="$(jq -r '[.modelUsage[]?.outputTokens // 0] | add | floor' <<<"$blob" 2>/dev/null || true)"
    cache_read="$(jq -r '[.modelUsage[]?.cacheReadInputTokens // 0] | add | floor' <<<"$blob" 2>/dev/null || true)"
    cache_creation="$(jq -r '[.modelUsage[]?.cacheCreationInputTokens // 0] | add | floor' <<<"$blob" 2>/dev/null || true)"
    case "$resolved_model" in ''|null) resolved_model="$req_model" ;; esac
    case "$input" in ''|*[!0-9]*) input="" ;; esac
    case "$output" in ''|*[!0-9]*) output="" ;; esac
    case "$cache_read" in ''|*[!0-9]*) cache_read="" ;; esac
    case "$cache_creation" in ''|*[!0-9]*) cache_creation="" ;; esac
    if [ -n "$input" ] && [ -n "$output" ] && [ -n "$cache_read" ] && [ -n "$cache_creation" ]; then
      args+=(--model "$resolved_model" --usage-source cli-envelope --provider anthropic \
             --input-tokens "$input" --output-tokens "$output" \
             --cache-read-tokens "$cache_read" --cache-creation-tokens "$cache_creation")
      _model_usage_run_emit "$emit_script" "${args[@]}"
      return 0
    fi
  fi

  # No usable modelUsage (absent, empty, or a token field failed to resolve
  # to a clean non-negative integer) — attribution-only record. seat/model/
  # outcome-ref is still recorded; only usage_source degrades.
  args+=(--model "$req_model" --usage-source unavailable)
  _model_usage_run_emit "$emit_script" "${args[@]}"
  return 0
}
