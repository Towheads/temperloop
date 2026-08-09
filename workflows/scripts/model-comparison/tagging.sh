#!/usr/bin/env bash
#
# tagging.sh — live candidate tagging provenance (temperloop#1257, epic
# #1225 "model comparison harness"). Owns PROVENANCE ONLY for a live-tagged
# `/sweep` seat: a bounded window record, the PR provenance stamp, and the
# telemetry tag — and the mechanical cross-check between the stamp and the
# tag. It does NOT own model selection (that stays the existing
# `SWEEP_WORKER_MODEL` setting — sweep.md Step 0.4/Step 3), and it does NOT
# own the comparison report (a later item).
#
# ── NO NEW SELECTION MECHANISM ──────────────────────────────────────────────
# The candidate MODEL is read from `$SWEEP_WORKER_MODEL` alone (sourced from
# workflows/scripts/build/build.config.sh, the same seam sweep.md Step 0.4
# already sources) — there is no `--model` flag anywhere in this file's CLI,
# so there is no second lever that could ever disagree with
# `SWEEP_WORKER_MODEL` about which model is live. The PROVIDER is a required
# `--provider` argument, checked against the SAME committed allowlist file
# every other provider check in this module reads
# (workflows/scripts/model-comparison/allowlist.sh's `pa_is_allowed` —
# reused, never re-derived): live-tagging designation is governed by that
# one file, exactly like a replay or a rotated judge.
#
# ── THE THREE ARTIFACTS ──────────────────────────────────────────────────
#   1. WINDOW RECORD — `tag` appends one bounded, timestamped entry (ts,
#      provider, model, run_id, seat, reason) to the local, gitignored
#      ledger at `$LIVE_TAG_WINDOW_LOG` — the audit trail of *when* a live
#      tag was designated and for *which run*. "Bounded" because each entry
#      is scoped to exactly one run (never a standing, open-ended toggle);
#      there is no window-close state to forget to clear.
#   2. TELEMETRY TAG — `tag` also appends one record to the existing
#      per-seat attribution raw lake via `workflows/scripts/emit-model-usage.sh`
#      (temperloop#1253/#1255 — reused verbatim, never a parallel stream):
#      `--seat sweep-live-tag --usage-source unavailable` (a `/sweep` fix
#      worker is not one of the three emit-feasible seats the L0 spike
#      found, so this is an attribution-only record — seat/model/outcome
#      known, tokens structurally unreachable, exactly the spike-anticipated
#      shape emit-model-usage.sh's own header documents).
#   3. PR PROVENANCE STAMP — `tag` prints ONE line to stdout, meant to be
#      appended to the resulting PR's body or trailer:
#        Model-provenance: model=<model> provider=<provider> run=<run_id>
#      Model and provider ONLY — never a key, never content.
#
# ── THE CROSS-CHECK (`crosscheck`) ──────────────────────────────────────
# A THREE-WAY check — PR stamp, window record, telemetry-lake record — not
# a two-way one, for a structural reason discovered empirically while
# building this: emit-model-usage.sh's OWN validator REFUSES a `provider`
# value whenever `usage_source` is `unavailable` ("usage_source unavailable
# but --provider was supplied — contradictory input, no record emitted" —
# see that script's own pairing rules). A `/sweep` fix-worker seat is not
# one of the three emit-feasible seats the L0 spike found, so the telemetry
# tag this module emits is necessarily `usage_source: unavailable`, and its
# `provider` field is therefore ALWAYS `null` by the existing schema's own
# design — the telemetry-lake record structurally cannot carry the provider
# half of the stamp. Cross-checking provider against a field that is always
# null would be a check that can never fail, i.e. worth nothing. So:
#
#   - MODEL is cross-checked against BOTH the window record and the
#     telemetry-lake record (by run id) — the one field every artifact here
#     can carry.
#   - PROVIDER is cross-checked against the WINDOW RECORD (the bounded,
#     run-scoped ledger `tag` writes itself, alongside and atomically with
#     the telemetry tag — the acceptance's own second named artifact, not a
#     parallel attribution stream: the telemetry tag still rides
#     emit-model-usage.sh's existing lake verbatim, per REQUIRED READING).
#   - The telemetry-lake record's mere PRESENCE (matching seat
#     `sweep-live-tag` + outcome_ref == run id) is itself asserted — a
#     window record with no corresponding lake entry means the emit step
#     failed or was skipped, which is exactly the kind of silent gap this
#     item exists to catch.
#
# Greps the PR body/trailer for the stamp, looks up the window record and
# the telemetry-lake record by run id, and FAILS when any pair disagrees —
# a stamp with no window record, a window record with no stamp, a
# model/provider mismatch between stamp and window record, or a window
# record with no matching telemetry-lake entry are all failures. This is
# the whole point of the item: a reviewer must never discover mid-review
# that a PR was candidate-authored.
#
# FAIL-CLOSED (temperloop#1365 class): `crosscheck` prints a message
# starting `CANNOT EVALUATE` and exits non-zero — never a silent pass, never
# a partial verdict — when it cannot read the PR body, cannot read a named
# window/telemetry file, cannot resolve the run id, or hits malformed JSON
# on ANY line of a scanned file (not only the matching one — a file it
# cannot fully trust is not a file it can partially trust either). A
# genuine DISAGREEMENT (stamp vs record, or one present without the other)
# is a distinct `FAIL` verdict, also non-zero, never confused with
# CANNOT EVALUATE in the printed message.
#
# Usage:
#   tagging.sh resolve-model
#       Prints $SWEEP_WORKER_MODEL verbatim (possibly empty). No side
#       effects. The one place a caller checks "is a candidate designated".
#
#   tagging.sh tag --provider <name> --run-id <issue:N|pr:N> \
#       [--repo <owner/repo>] [--reason <text>] [--print-only]
#       Resolves the model from SWEEP_WORKER_MODEL (refuses, exit 1, if
#       empty — nothing to tag), validates --provider against the committed
#       allowlist (refuses, exit 1, if not allowed), appends the window
#       record + the telemetry tag (skipped under --print-only), then prints
#       the PR provenance stamp line on stdout. Exit 2 on a usage error
#       (missing/malformed argument, or an unknown flag such as --model).
#
#   tagging.sh crosscheck --pr-body <file|-> --run-id <issue:N|pr:N> \
#       [--window-file <file|->] [--usage-file <file|->]
#       Prints one of `OK`, `FAIL`, or `CANNOT EVALUATE` (each on its own
#       line, prefixed with the tool name) and exits 0 / 1 / 1 respectively
#       — CANNOT EVALUATE and FAIL are both non-zero, distinguished only by
#       the message text (mirrors validate-model-usage-emit.sh's own
#       convention). --window-file/--usage-file each scan exactly one file
#       (or stdin); omitted, --window-file defaults to $LIVE_TAG_WINDOW_LOG
#       and --usage-file scans $MODEL_USAGE_RAW_DIR/model-usage-*.jsonl
#       (default <repo>/meta/data/raw), the same resolution
#       validate-model-usage-emit.sh uses. An EXPLICITLY named
#       --window-file/--usage-file that does not exist is CANNOT EVALUATE
#       (the caller asked for a specific file); an absent DEFAULT window
#       ledger or scan directory is legal (nothing tagged/emitted yet, same
#       precedent as validate-model-usage-emit.sh's own "absent lake is
#       legal" rule).
#
# Config (env overrides win):
#   SWEEP_WORKER_MODEL     the ONE model selector (sweep.md Step 0.4;
#                          sourced from build.config.sh)
#   LIVE_TAG_WINDOW_LOG    path to the window-record ledger (default:
#                          <repo>/.temperloop/model-comparison/live-tag-windows.jsonl
#                          — repo-local, gitignored via .temperloop/.gitignore's
#                          existing `model-comparison/` line)
#   MODEL_USAGE_RAW_DIR    the existing emit-model-usage.sh raw-lake dir
#                          (default <repo>/meta/data/raw) — reused as-is for
#                          crosscheck's default scan, never a second sink
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, per this repo's usual convention.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../../.." && pwd)"

# ── SWEEP_WORKER_MODEL — the ONE model selector ─────────────────────────
# Optional source (mirrors candidate-session.sh's own `[ -f ... ] && .`
# idiom): a non-vendoring checkout without build.config.sh still runs, with
# SWEEP_WORKER_MODEL simply empty (the "nothing to tag" state).
# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
: "${SWEEP_WORKER_MODEL:=}"

# ── allowlist.sh — the committed provider ceiling, reused not re-derived ──
ALLOWLIST_LIB="$HERE/allowlist.sh"
if [ ! -f "$ALLOWLIST_LIB" ]; then
  echo "tagging.sh: CANNOT EVALUATE — required library not found at $ALLOWLIST_LIB" >&2
  exit 1
fi
# shellcheck source=./allowlist.sh
. "$ALLOWLIST_LIB"

: "${LIVE_TAG_WINDOW_LOG:=$REPO_ROOT/.temperloop/model-comparison/live-tag-windows.jsonl}"

EMIT_SCRIPT="$REPO_ROOT/workflows/scripts/emit-model-usage.sh"

# need_operand <flag> <remaining-arg-count> [<next-arg>] — same contract as
# replay.sh's own need_operand (temperloop#1254): a value-taking flag with
# no following argument returns 2 rather than falling through to a
# shift-2-silently-no-ops-under-no-set-e hang. Also rejects a value that
# itself looks like another flag, so `--provider --run-id x` never silently
# consumes `--run-id` as the provider name.
need_operand() {
  if [ "$2" -lt 2 ]; then
    printf 'tagging.sh: %s requires a value\n' "$1" >&2
    return 2
  fi
  case "${3:-}" in
    --*)
      printf 'tagging.sh: %s requires a value, got flag-like %s\n' "$1" "$3" >&2
      return 2
      ;;
  esac
  return 0
}

_tag_valid_run_id() {  # rc 0 iff "$1" looks like issue:<ref> or pr:<ref>, no whitespace
  case "$1" in
    '') return 1 ;;
    *[[:space:]]*) return 1 ;;
    issue:*|pr:*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── subcommand: resolve-model ───────────────────────────────────────────
cmd_resolve_model() {
  printf '%s\n' "$SWEEP_WORKER_MODEL"
}

# ── subcommand: tag ──────────────────────────────────────────────────────
cmd_tag() {
  local provider="" run_id="" repo="" reason="" print_only=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) need_operand --provider "$#" "${2:-}" || return 2; provider="$2"; shift 2 ;;
      --run-id)   need_operand --run-id "$#" "${2:-}" || return 2; run_id="$2"; shift 2 ;;
      --repo)     need_operand --repo "$#" "${2:-}" || return 2; repo="$2"; shift 2 ;;
      --reason)   need_operand --reason "$#" "${2:-}" || return 2; reason="$2"; shift 2 ;;
      --print-only) print_only=1; shift ;;
      --model)
        echo "tagging.sh tag: --model is not a valid flag here — the model is ALWAYS SWEEP_WORKER_MODEL (see 'tagging.sh resolve-model'); there is no second selector for this seat" >&2
        return 2
        ;;
      *)
        printf 'tagging.sh tag: unknown argument %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  [ -n "$provider" ] || { echo "tagging.sh tag: --provider is required" >&2; return 2; }
  [ -n "$run_id" ] || { echo "tagging.sh tag: --run-id is required" >&2; return 2; }
  _tag_valid_run_id "$run_id" || {
    printf "tagging.sh tag: --run-id '%s' must look like 'issue:<ref>' or 'pr:<ref>' with no whitespace\n" "$run_id" >&2
    return 2
  }

  local model="$SWEEP_WORKER_MODEL"
  if [ -z "$model" ]; then
    echo "tagging.sh tag: SWEEP_WORKER_MODEL is empty (inherits the session model) — nothing to live-tag. Point it at a candidate in workflows/scripts/build/build.config.sh (or export it) first." >&2
    return 1
  fi

  provider="$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')"
  if ! pa_is_allowed "$provider"; then
    printf "tagging.sh tag: refusing to tag — provider '%s' is not allowed by the committed provider allowlist (%s), the SAME file that governs every other model-comparison provider check\n" "$provider" "$(pa_committed_file)" >&2
    return 1
  fi

  if [ "$print_only" -eq 0 ]; then
    local ts window_record
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$LIVE_TAG_WINDOW_LOG")" 2>/dev/null || true
    window_record="$(jq -nc \
      --arg ts "$ts" --arg provider "$provider" --arg model "$model" \
      --arg run_id "$run_id" --arg reason "$reason" \
      '{schema_version: "1", ts: $ts, provider: $provider, model: $model,
        run_id: $run_id, seat: "sweep-live-tag",
        reason: (if $reason == "" then null else $reason end)}' 2>/dev/null)"
    if [ -z "$window_record" ]; then
      echo "tagging.sh tag: failed to build the window-record JSON — aborting, no telemetry tag emitted either" >&2
      return 1
    fi
    if ! printf '%s\n' "$window_record" >>"$LIVE_TAG_WINDOW_LOG"; then
      echo "tagging.sh tag: failed to append the window record to $LIVE_TAG_WINDOW_LOG — aborting, no telemetry tag emitted" >&2
      return 1
    fi

    if [ -x "$EMIT_SCRIPT" ]; then
      local -a emit_args=(--seat sweep-live-tag --model "$model" --usage-source unavailable --outcome-ref "$run_id")
      [ -n "$repo" ] && emit_args+=(--repo "$repo")
      "$EMIT_SCRIPT" "${emit_args[@]}" >/dev/null
    else
      printf 'tagging.sh tag: WARN emit-model-usage.sh not found/executable at %s — telemetry tag NOT emitted (the window record above was still written)\n' "$EMIT_SCRIPT" >&2
    fi
  fi

  printf 'Model-provenance: model=%s provider=%s run=%s\n' "$model" "$provider" "$run_id"
}

# ── subcommand: crosscheck ───────────────────────────────────────────────
_cc_eval() { printf 'tagging.sh crosscheck: CANNOT EVALUATE — %s\n' "$1" >&2; return 1; }
_cc_fail() { printf 'tagging.sh crosscheck: FAIL — %s\n' "$1"; return 1; }
_cc_ok()   { printf 'tagging.sh crosscheck: OK — %s\n' "$1"; return 0; }

# _cc_resolve_window_files <explicit-or-empty> — sets $_CC_FILES (a bash
# array; NOT `local`, so the assignment is visible to the caller). An
# EXPLICIT path that doesn't exist is CANNOT EVALUATE; the DEFAULT ledger
# (LIVE_TAG_WINDOW_LOG) being absent is legal (nothing tagged yet).
_cc_resolve_window_files() {
  _CC_FILES=()
  local explicit="$1" path
  if [ -n "$explicit" ]; then
    if [ "$explicit" = "-" ]; then
      [ -r /dev/stdin ] || { _cc_eval "stdin (--window-file -) is not readable (closed?)"; return 1; }
      _CC_FILES=("-")
      return 0
    fi
    [ -e "$explicit" ] || { _cc_eval "--window-file $explicit does not exist"; return 1; }
    [ -f "$explicit" ] || { _cc_eval "--window-file $explicit is not a regular file"; return 1; }
    [ -r "$explicit" ] || { _cc_eval "--window-file $explicit exists but is not readable"; return 1; }
    _CC_FILES=("$explicit")
    return 0
  fi
  path="$LIVE_TAG_WINDOW_LOG"
  if [ -e "$path" ]; then
    [ -f "$path" ] || { _cc_eval "$path (the default window ledger) is not a regular file"; return 1; }
    [ -r "$path" ] || { _cc_eval "$path (the default window ledger) exists but is not readable"; return 1; }
    _CC_FILES=("$path")
  fi
  return 0
}

# _cc_resolve_usage_files <explicit-or-empty> — same contract as
# _cc_resolve_window_files, scoped to the emit-model-usage.sh raw lake (a
# DIRECTORY scan when no explicit file is given, same resolution
# validate-model-usage-emit.sh uses; an absent default dir is legal).
_cc_resolve_usage_files() {
  _CC_FILES=()
  local explicit="$1" raw_dir f
  if [ -n "$explicit" ]; then
    if [ "$explicit" = "-" ]; then
      [ -r /dev/stdin ] || { _cc_eval "stdin (--usage-file -) is not readable (closed?)"; return 1; }
      _CC_FILES=("-")
      return 0
    fi
    [ -e "$explicit" ] || { _cc_eval "--usage-file $explicit does not exist"; return 1; }
    [ -f "$explicit" ] || { _cc_eval "--usage-file $explicit is not a regular file"; return 1; }
    [ -r "$explicit" ] || { _cc_eval "--usage-file $explicit exists but is not readable"; return 1; }
    _CC_FILES=("$explicit")
    return 0
  fi
  raw_dir="${MODEL_USAGE_RAW_DIR:-$REPO_ROOT/meta/data/raw}"
  if [ -d "$raw_dir" ]; then
    [ -r "$raw_dir" ] || { _cc_eval "$raw_dir exists but is not readable"; return 1; }
    for f in "$raw_dir"/model-usage-*.jsonl; do
      [ -e "$f" ] || continue
      [ -f "$f" ] || continue
      _CC_FILES+=("$f")
    done
  fi
  return 0
}

# _cc_scan <match-field> <match-value> [<seat-filter>] — scans $_CC_FILES
# (set by one of the resolvers above), matching every line whose
# .<match-field> equals <match-value> exactly (and, if <seat-filter> is
# given, whose .seat also equals it). Sets $_CC_PRESENT / $_CC_MODEL /
# $_CC_PROVIDER / $_CC_AMBIGUOUS (globals, read by the caller immediately —
# NOT `local`). ANY line in a scanned file that fails strict JSON parsing is
# CANNOT EVALUATE, not only a matching one: a file this scan cannot fully
# trust is not a file it can partially trust either.
_cc_scan() {
  local match_field="$1" match_value="$2" seat_filter="${3:-}"
  _CC_PRESENT=0; _CC_MODEL=""; _CC_PROVIDER=""; _CC_AMBIGUOUS=0
  local f src rline
  for f in ${_CC_FILES[@]+"${_CC_FILES[@]}"}; do
    if [ "$f" = "-" ]; then src="/dev/stdin"; else
      src="$f"
      [ -r "$f" ] || { _cc_eval "$f exists but is not readable"; return 1; }
    fi
    # `{ exec 3<...; } 2>/dev/null` — NOT a bare `exec 3<... 2>/dev/null`.
    # A bare `exec` with no command word applies ALL its redirects
    # PERMANENTLY to the current shell once the open succeeds, which would
    # silently redirect this script's own stderr to /dev/null for the rest
    # of the run (verified empirically — a real trap, not a hypothetical
    # one) and swallow every later CANNOT EVALUATE/FAIL message. Wrapping in
    # a `{ }` command group scopes the `2>/dev/null` to just this open
    # attempt (bash saves/restores the group's fds), while `exec 3<...`
    # inside it still opens fd 3 in the CURRENT shell (no subshell), so the
    # descriptor survives for the read loop below exactly as intended.
    if ! { exec 3<"$src"; } 2>/dev/null; then
      _cc_eval "could not open $f for reading"
      return 1
    fi
    rline=""
    while IFS= read -r rline <&3 || [ -n "$rline" ]; do
      [ -z "$rline" ] && continue
      local val seat m p
      if ! val="$(printf '%s' "$rline" | jq -r --arg k "$match_field" '.[$k] // empty' 2>/dev/null)"; then
        exec 3<&-
        _cc_eval "$f contains a line that is not valid JSON — refusing to trust a partial scan of it"
        return 1
      fi
      [ "$val" = "$match_value" ] || continue
      if [ -n "$seat_filter" ]; then
        seat="$(printf '%s' "$rline" | jq -r '.seat // empty' 2>/dev/null)"
        [ "$seat" = "$seat_filter" ] || continue
      fi
      m="$(printf '%s' "$rline" | jq -r '.model // empty' 2>/dev/null)"
      p="$(printf '%s' "$rline" | jq -r '.provider // empty' 2>/dev/null)"
      if [ "$_CC_PRESENT" -eq 1 ] && { [ "$m" != "$_CC_MODEL" ] || [ "$p" != "$_CC_PROVIDER" ]; }; then
        _CC_AMBIGUOUS=1
      fi
      _CC_PRESENT=1
      _CC_MODEL="$m"
      _CC_PROVIDER="$p"
    done
    exec 3<&-
  done
  return 0
}

cmd_crosscheck() {
  local pr_body="" run_id="" window_file="" usage_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr-body)     need_operand --pr-body "$#" "${2:-}" || return 2; pr_body="$2"; shift 2 ;;
      --run-id)      need_operand --run-id "$#" "${2:-}" || return 2; run_id="$2"; shift 2 ;;
      --window-file) need_operand --window-file "$#" "${2:-}" || return 2; window_file="$2"; shift 2 ;;
      --usage-file)  need_operand --usage-file "$#" "${2:-}" || return 2; usage_file="$2"; shift 2 ;;
      *) printf 'tagging.sh crosscheck: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$pr_body" ] || { _cc_eval "no --pr-body given"; return $?; }
  [ -n "$run_id" ] || { _cc_eval "no --run-id given"; return $?; }
  _tag_valid_run_id "$run_id" || {
    _cc_eval "--run-id '$run_id' does not look like 'issue:<ref>' or 'pr:<ref>' — cannot resolve which record to compare against"
    return $?
  }
  command -v jq >/dev/null 2>&1 || { _cc_eval "jq not found"; return $?; }

  # --- read the PR body ---------------------------------------------------
  local body_src body_content
  if [ "$pr_body" = "-" ]; then
    body_src="/dev/stdin"
    [ -r "$body_src" ] || { _cc_eval "stdin (--pr-body -) is not readable (closed?)"; return $?; }
  else
    [ -e "$pr_body" ] || { _cc_eval "--pr-body $pr_body does not exist"; return $?; }
    [ -f "$pr_body" ] || { _cc_eval "--pr-body $pr_body is not a regular file"; return $?; }
    [ -r "$pr_body" ] || { _cc_eval "--pr-body $pr_body exists but is not readable"; return $?; }
    body_src="$pr_body"
  fi
  if ! body_content="$(cat "$body_src" 2>/dev/null)"; then
    _cc_eval "could not read $pr_body"
    return $?
  fi

  # --- parse the stamp, if any ---------------------------------------------
  local stamp_line stamp_model="" stamp_provider="" stamp_run="" stamp_present=0
  stamp_line="$(printf '%s\n' "$body_content" | grep -E '^Model-provenance: model=[^[:space:]]+ provider=[^[:space:]]+ run=[^[:space:]]+$' | head -n 1 || true)"
  if [ -n "$stamp_line" ]; then
    stamp_present=1
    stamp_model="${stamp_line#Model-provenance: model=}"
    stamp_model="${stamp_model%% *}"
    stamp_provider="${stamp_line#*provider=}"
    stamp_provider="${stamp_provider%% *}"
    stamp_run="${stamp_line##* run=}"
  fi

  # --- the window record: model + provider, keyed by run_id --------------
  _cc_resolve_window_files "$window_file" || return $?
  _cc_scan "run_id" "$run_id" "" || return $?
  local window_present="$_CC_PRESENT" window_model="$_CC_MODEL" window_provider="$_CC_PROVIDER"
  if [ "$_CC_AMBIGUOUS" -eq 1 ]; then
    _cc_eval "more than one window record for run $run_id disagree with each other on model/provider — cannot determine which is authoritative"
    return $?
  fi

  # --- the telemetry-lake record: model only (provider is structurally
  #     always null under usage_source=unavailable — see this file's own
  #     header) — scoped to our own seat so a same-named outcome_ref from a
  #     different pipeline seat can never be mistaken for our tag ---------
  _cc_resolve_usage_files "$usage_file" || return $?
  _cc_scan "outcome_ref" "$run_id" "sweep-live-tag" || return $?
  local telemetry_present="$_CC_PRESENT" telemetry_model="$_CC_MODEL"
  if [ "$_CC_AMBIGUOUS" -eq 1 ]; then
    _cc_eval "more than one telemetry-lake record for run $run_id (seat sweep-live-tag) disagree with each other on model — cannot determine which is authoritative"
    return $?
  fi

  # --- the verdict ---------------------------------------------------------
  if [ "$stamp_present" -eq 0 ] && [ "$window_present" -eq 0 ]; then
    _cc_ok "run $run_id carries no PR stamp and no window record — not live-tagged"
    return $?
  fi
  if [ "$stamp_present" -eq 1 ] && [ "$window_present" -eq 0 ]; then
    _cc_fail "PR body stamps run $run_id as model=$stamp_model provider=$stamp_provider but no matching window record exists for run_id=$run_id — the stamp is unverifiable"
    return $?
  fi
  if [ "$stamp_present" -eq 0 ] && [ "$window_present" -eq 1 ]; then
    _cc_fail "a window record exists for run $run_id (model=$window_model provider=$window_provider) but the PR body carries no Model-provenance stamp — undisclosed candidate authorship"
    return $?
  fi
  if [ "$stamp_run" != "$run_id" ]; then
    _cc_fail "PR stamp's own run token ('$stamp_run') does not match the requested --run-id ('$run_id')"
    return $?
  fi
  if [ "$stamp_model" != "$window_model" ] || [ "$stamp_provider" != "$window_provider" ]; then
    _cc_fail "PR stamp declares model=$stamp_model provider=$stamp_provider but the window record for run $run_id shows model=$window_model provider=$window_provider — DISAGREEMENT"
    return $?
  fi
  if [ "$telemetry_present" -eq 0 ]; then
    _cc_fail "a window record and a matching PR stamp both exist for run $run_id (model=$window_model provider=$window_provider), but no telemetry-lake record (seat sweep-live-tag, outcome_ref=$run_id) was found — the telemetry tag emission failed or was skipped"
    return $?
  fi
  if [ "$telemetry_model" != "$window_model" ]; then
    _cc_fail "the telemetry-lake record for run $run_id shows model=$telemetry_model, which disagrees with the window record's model=$window_model — DISAGREEMENT"
    return $?
  fi
  _cc_ok "PR stamp (model=$stamp_model provider=$stamp_provider) matches the window record and the telemetry-lake record for run $run_id"
}

# ── CLI dispatch ──────────────────────────────────────────────────────────
_usage() {  # the whole leading comment block, minus the shebang
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  resolve-model)
    [ $# -eq 0 ] || { printf 'tagging.sh resolve-model: takes no arguments (got %s)\n' "$1" >&2; exit 2; }
    cmd_resolve_model
    exit $?
    ;;
  tag)
    cmd_tag "$@"
    exit $?
    ;;
  crosscheck)
    cmd_crosscheck "$@"
    exit $?
    ;;
  -h|--help|"")
    _usage
    [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ] && exit 0
    exit 2
    ;;
  *)
    printf 'tagging.sh: unknown subcommand %s\n' "$cmd" >&2
    _usage
    exit 2
    ;;
esac
