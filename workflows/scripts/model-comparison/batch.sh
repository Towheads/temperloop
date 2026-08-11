#!/usr/bin/env bash
#
# batch.sh — the replay BATCH DRIVER (temperloop#1401, epic #1225 "model
# comparison harness"). Epic #1225 shipped sixteen components and nothing
# that connected them: a corpus file at one end, a report producer reading
# `baseline.jsonl` + `candidate.jsonl` at the other, and no operator-invokable
# thing in between. This file is that thing, and NOTHING more — it
# ORCHESTRATES; it derives no statistic, re-implements no scoring, no
# judging, and no corpus selection.
#
# ── THE ONE THING THAT MUST STAY TRUE OF THIS FILE'S TESTS ─────────────────
# Inherited verbatim from replay.sh's own header, because this driver is the
# only thing that ever calls `replay.sh execute` in a loop and so is the only
# place a single mistake could spend a whole batch of real money.
#
# There is NO implicit candidate binary and NO implicit judge binary here.
# For EACH arm the caller must pass EITHER `--baseline-runner` /
# `--candidate-runner` (a recorded/stubbed runner) OR the single explicit
# `--live` flag, and the two are mutually exclusive. With neither, this file
# prints CANNOT EVALUATE and exits non-zero BEFORE it prepares a worktree,
# before it consults the spend gate, and therefore before any token could be
# spent. `--live` is the ONLY path to a real model, it is never implied by
# any other flag, and no default anywhere in this file selects it. The
# fixture suite (tests/test_replay_batch.sh) drives every arm through a
# recorded runner, never passes `--live`, and asserts the property the same
# way its siblings do: a canary `claude` prepended to PATH that the whole run
# proves was never invoked — with a MUTATION PROOF that forcing the live arm
# DOES reach that canary, so the assertion is a measurement rather than a
# tautology.
#
# ── FAIL-CLOSED (the temperloop#1365 class) ────────────────────────────────
# This driver is NOT a report drop-in (that is
# workflows/scripts/report-producers/model-comparison, which must exit 0 as a
# `.temperloop/report.d/` contract obligation). It is fail-CLOSED like the
# rest of the module: "could not evaluate" must never render as "evaluated,
# and fine". Unreadable input, a missing sibling script, a corpus whose
# selection disagrees with the gate that authorized it, a pre-flight it could
# not parse — every one of those prints CANNOT EVALUATE with a reason and
# exits non-zero rather than proceeding on a default.
#
# ── THE UNITS, CONSUMED FROM THE GATE RATHER THAN RE-DERIVED ──────────────
# temperloop#1379 pinned three non-interchangeable units in `replay.sh
# preflight`, and the whole point of a driver is that EXECUTION obeys the
# same three or the operator's authorized estimate and the actual spend
# describe different things:
#
#     1 CORPUS RECORD  ->  arms_n EXECUTED REPLAYS  ->  1 PAIRED OUTCOME
#
# So: the batch cap is read off pre-flight's own `batch_cap` (records) and
# applied to RECORDS; every selected record is executed in BOTH arms; and the
# driver refuses outright if pre-flight reports an `arms_n` other than the two
# arms it actually knows how to run. It re-reads
# REPLAY_PREFLIGHT_BATCH_CAP from no config of its own — the number it honours
# is the number the gate published, so the two can never drift apart.
#
# The cost figure this file reports is likewise pre-flight's own
# `estimated_cost` under pre-flight's own `cost_basis`
# (REPLAY_COST_BASIS_UNIT, cost-weighted token units — temperloop#1380). This
# file computes no cost of its own and never prints a raw token sum under the
# same word.
#
# ── OPERATOR-INITIATED ONLY, AND CONFIRMED ────────────────────────────────
# ADR 0027 "inert by design": nothing scheduled, cron, or autonomous may
# invoke this file. Beyond that, pre-flight publishes
# `confirmation_required`, and this driver HONOURS it: without `--confirm` on
# the command line it prints the pre-flight verdict and STOPS (exit 3) having
# spent nothing. An un-gated batch is structurally unreachable — the gate runs
# FIRST, before the first worktree is prepared.
#
# ── RESUMABLE, BY LEG ─────────────────────────────────────────────────────
# The unit of work is a LEG: one (corpus record, arm) pair — i.e. exactly one
# `replay.sh execute`. Every leg's terminal state is written to the state dir
# the moment it reaches one, so re-invoking after an interruption SKIPS every
# leg that already reached a terminal state and re-spends nothing. A leg that
# failed without producing a record is likewise not retried by default (it may
# have failed AFTER the candidate ran — score.sh's own refusal path is exactly
# that shape, and a blind retry would re-spend it); `--retry-failed` asks for
# those explicitly. The judge pass is resumable on the same principle, keyed
# by the sha256 of the arm file it judged.
#
# A state dir is bound to ONE batch: it records the corpus file's sha256 and
# the selected outcome refs, and refuses to resume against a different
# selection rather than silently mixing two batches' records into one arm
# file.
#
# ── ISOLATION ─────────────────────────────────────────────────────────────
# Every worktree is prepared through `replay.sh worktree-prepare` and torn
# down through `replay.sh worktree-teardown` on BOTH the success and the
# failure path — plus an EXIT trap for the interrupted path, plus an
# end-of-batch sweep that tears down any leg worktree a PREVIOUS interrupted
# run left behind. `replay.sh verify-clean-parent` runs after the batch and a
# DIRTY parent is reported as a named degradation, never swallowed.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#   batch.sh run --corpus-file <path> --repo-root <path>
#           ( --baseline-runner <cmd> --candidate-runner <cmd> | --live )
#           [--judge-runner <cmd>]
#           [--baseline-model <id>] [--candidate-model <id>] [--judge-model <id>]
#           [--baseline-provider <name>] [--candidate-provider <name>]
#           [--judge-provider <name>]
#           [--repo <owner/repo>] [--gate-relpath <rel>]
#           [--out-dir <dir>] [--state-dir <dir>]
#           [--confirm] [--retry-failed] [--preflight-only]
#
#       Runs the pre-flight spend gate, then replays every gate-authorized
#       corpus record in BOTH arms, judges each arm (when a judge seam is
#       configured), and writes `baseline.jsonl` + `candidate.jsonl` into
#       --out-dir (default: MODEL_COMPARISON_REPORT_RECORDS_DIR, resolved
#       against --repo-root when relative — the same directory
#       workflows/scripts/report-producers/model-comparison reads, so its
#       output is that producer's input UNCHANGED). Prints ONE JSON object.
#
#       --preflight-only runs the gate and prints its verdict without
#       executing anything (the "what would this cost me" probe).
#
#   batch.sh schema      the summary object's shape, empty-valued.
#
# ── Exit codes — a closed set, deliberately distinguishable ───────────────
#   0  BATCH_COMPLETE     every planned leg produced a record; parent clean.
#   1  CANNOT_EVALUATE    refused. Nothing was executed, or the run is
#                         structurally unusable. Never a partial success
#                         dressed as a whole one.
#   2  usage error.
#   3  STOPPED            the gate said stop (`stop:true`) or the operator's
#                         `--confirm` was absent. NOTHING was spent.
#   4  BATCH_DEGRADED     the batch RAN end to end, but at least one leg
#                         failed, or the judge degraded, or the parent
#                         checkout was left dirty. The arm files ARE written
#                         and the summary names every degradation — "some of
#                         it did not work" is a different statement from
#                         "it worked", and this file keeps them apart.
#
# Every setting this file reads is registered in
# workflows/scripts/config/setting-registry.tsv and defaulted in
# workflows/scripts/build/build.config.sh — named symbolically, never
# re-valued in this prose. This file introduces NO setting of its own: the
# batch cap comes from the gate, and the state dir is derived from the
# records dir (overridable with --state-dir).
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"CANNOT_EVALUATE","error":"jq not found"}' >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLAY_SH="$HERE/replay.sh"
JUDGE_SH="$HERE/judge.sh"

# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
# Layer-6 non-vendoring-caller fallbacks, byte-identical to the registry.
: "${MODEL_COMPARISON_REPORT_RECORDS_DIR:=.temperloop/model-comparison}"
: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"

# ── vocabulary constants (record vocabulary, NOT operator settings) ────────
# THE TWO ARMS this driver knows how to run, in the order it runs them. A
# structural fact of the comparison design (replay.sh's own REPLAY_ARMS_N
# carries the same reasoning: "a one-arm comparison is not a comparison"),
# not a knob — and the names are the report producer's own arm file
# basenames, so renaming one here would silently stop producing that
# producer's input.
BATCH_ARM_BASELINE="baseline"
BATCH_ARM_CANDIDATE="candidate"
BATCH_ARMS_N=2
# The state subdirectory, hung off the records dir so a comparison's
# resume state sits beside the arm files it is building (both under
# .temperloop/, which .temperloop/.gitignore already excludes from the tree).
BATCH_STATE_SUBDIR="batch-state"
BATCH_SUMMARY_SCHEMA_VERSION="replay-batch-summary-v1"

usage() {
  cat <<'EOF' >&2
usage: batch.sh run --corpus-file <path> --repo-root <path>
                    ( --baseline-runner <cmd> --candidate-runner <cmd> | --live )
                    [--judge-runner <cmd>]
                    [--baseline-model <id>] [--candidate-model <id>] [--judge-model <id>]
                    [--baseline-provider <n>] [--candidate-provider <n>] [--judge-provider <n>]
                    [--repo <owner/repo>] [--gate-relpath <rel>]
                    [--out-dir <dir>] [--state-dir <dir>]
                    [--confirm] [--retry-failed] [--preflight-only]
       batch.sh schema
EOF
}

# ── fail-closed emission ──────────────────────────────────────────────────
# bd_cannot_evaluate <msg> — the ONE refusal path. Machine verdict on stdout,
# the distinct human CANNOT EVALUATE line on stderr (same contract, same
# rationale, as replay.sh's preflight_cannot_evaluate / execute_cannot_
# evaluate). Every caller MUST follow it with `return 1` — this only prints.
bd_cannot_evaluate() {
  jq -cn --arg e "$1" '{outcome:"CANNOT_EVALUATE",error:$e}'
  printf 'batch.sh: CANNOT EVALUATE — %s\n' "$1" >&2
}

# bd_stopped <reason> <detail> <preflight-json> — the gate refused, or the
# operator did not confirm. Structurally distinct from CANNOT_EVALUATE: the
# inputs were fine and nothing was spent; the run was simply not authorized.
bd_stopped() {
  jq -cn --arg r "$1" --arg d "$2" --argjson pf "$3" \
    '{outcome:"STOPPED", stop_reason:$r, detail:$d, spent:false, preflight:$pf}'
  printf 'batch.sh: STOPPED (%s) — %s\n' "$1" "$2" >&2
}

# bd_need_operand <flag> <remaining-arg-count> [<next-arg>] — the same
# trailing-flag / flag-like-value guard replay.sh's own need_operand applies
# (temperloop#1342), duplicated rather than sourced because replay.sh is a
# command-line entry point, not a library.
bd_need_operand() {
  if [ "$2" -lt 2 ]; then
    printf 'batch.sh: %s requires a value\n' "$1" >&2
    return 2
  fi
  if [ "$#" -ge 3 ]; then
    case "$3" in
      --*) printf 'batch.sh: %s requires a value, got flag-like %s\n' "$1" "$3" >&2; return 2 ;;
    esac
  fi
  return 0
}

bd_sha256() {  # <file> -> hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | awk '{print $1}'
  else
    shasum -a 256 <"$1" | awk '{print $1}'
  fi
}

bd_slugify() {  # <text> -> [a-z0-9-]+ (filename-safe leg key component)
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g'
}

# ── the interrupted-path teardown ─────────────────────────────────────────
# BD_LIVE_SLUG holds the slug of the worktree that is prepared RIGHT NOW.
# The trap is what makes "torn down on both success and failure" true even
# when the failure is a ^C or a kill between prepare and teardown.
BD_LIVE_SLUG=""
BD_REPO_ROOT=""
bd_trap_cleanup() {
  if [ -n "$BD_LIVE_SLUG" ] && [ -n "$BD_REPO_ROOT" ]; then
    bash "$REPLAY_SH" worktree-teardown "$BD_REPO_ROOT" "$BD_LIVE_SLUG" >/dev/null 2>&1 || true
    BD_LIVE_SLUG=""
  fi
}
trap bd_trap_cleanup EXIT INT TERM

cmd_schema() {
  jq -cn --arg sv "$BATCH_SUMMARY_SCHEMA_VERSION" '{
    schema_version: $sv,
    outcome: null,
    units: null,
    authorized: {records_n:null, replays_n:null, pairs_n:null,
                 estimated_cost:null, cost_basis:null, batch_cap:null},
    selection: {corpus_file:null, corpus_sha256:null, selected_records_n:null, refs:[]},
    legs: {planned_n:null, completed_n:null, resumed_n:null, failed_n:null,
           scored_n:null, integration_error_n:null},
    completion: {basis:null, replay_completion_rate:null, per_arm:null},
    failures: [],
    arms: {baseline:{file:null, records_n:null}, candidate:{file:null, records_n:null}},
    pairing: {paired_outcomes_n:null, min_sample_n:null, meets_min_sample:null},
    judge: {ran:null, reason:null, per_arm:null},
    isolation: {verify_clean_parent:null, worktrees_torn_down_n:null},
    degradations: [],
    preflight: null
  }'
}

# ═══════════════════════════════════════════════════════════════════════════
# run
# ═══════════════════════════════════════════════════════════════════════════
cmd_run() {
  local corpus_file="" repo_root="" out_dir="" state_dir="" owner_repo="" gate_relpath=""
  local baseline_runner="" candidate_runner="" judge_runner=""
  local baseline_model="" candidate_model="" judge_model=""
  local baseline_provider="" candidate_provider="" judge_provider=""
  local live=0 confirm=0 preflight_only=0 retry_failed=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --corpus-file) bd_need_operand --corpus-file "$#" "${2:-}" || return 2; corpus_file="$2"; shift 2 ;;
      --repo-root) bd_need_operand --repo-root "$#" "${2:-}" || return 2; repo_root="$2"; shift 2 ;;
      --out-dir) bd_need_operand --out-dir "$#" "${2:-}" || return 2; out_dir="$2"; shift 2 ;;
      --state-dir) bd_need_operand --state-dir "$#" "${2:-}" || return 2; state_dir="$2"; shift 2 ;;
      --repo) bd_need_operand --repo "$#" "${2:-}" || return 2; owner_repo="$2"; shift 2 ;;
      --gate-relpath) bd_need_operand --gate-relpath "$#" "${2:-}" || return 2; gate_relpath="$2"; shift 2 ;;
      --baseline-runner) bd_need_operand --baseline-runner "$#" "${2:-}" || return 2; baseline_runner="$2"; shift 2 ;;
      --candidate-runner) bd_need_operand --candidate-runner "$#" "${2:-}" || return 2; candidate_runner="$2"; shift 2 ;;
      --judge-runner) bd_need_operand --judge-runner "$#" "${2:-}" || return 2; judge_runner="$2"; shift 2 ;;
      --baseline-model) bd_need_operand --baseline-model "$#" "${2:-}" || return 2; baseline_model="$2"; shift 2 ;;
      --candidate-model) bd_need_operand --candidate-model "$#" "${2:-}" || return 2; candidate_model="$2"; shift 2 ;;
      --judge-model) bd_need_operand --judge-model "$#" "${2:-}" || return 2; judge_model="$2"; shift 2 ;;
      --baseline-provider) bd_need_operand --baseline-provider "$#" "${2:-}" || return 2; baseline_provider="$2"; shift 2 ;;
      --candidate-provider) bd_need_operand --candidate-provider "$#" "${2:-}" || return 2; candidate_provider="$2"; shift 2 ;;
      --judge-provider) bd_need_operand --judge-provider "$#" "${2:-}" || return 2; judge_provider="$2"; shift 2 ;;
      --live) live=1; shift ;;
      --confirm) confirm=1; shift ;;
      --retry-failed) retry_failed=1; shift ;;
      --preflight-only) preflight_only=1; shift ;;
      *) printf 'batch.sh run: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  # ── input validation, all fail-closed, ALL BEFORE THE GATE ─────────────
  [ -n "$corpus_file" ] || { bd_cannot_evaluate "no --corpus-file given"; return 1; }
  [ -n "$repo_root" ] || { bd_cannot_evaluate "no --repo-root given"; return 1; }
  [ -f "$REPLAY_SH" ] || { bd_cannot_evaluate "replay.sh not found at $REPLAY_SH — this driver orchestrates it and re-implements none of it"; return 1; }
  if [ ! -f "$corpus_file" ] || [ ! -r "$corpus_file" ]; then
    bd_cannot_evaluate "corpus file not found or not a readable regular file: $corpus_file"
    return 1
  fi

  local repo_top
  repo_top="$(cd "$repo_root" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
  if [ -z "$repo_top" ]; then
    bd_cannot_evaluate "--repo-root is not inside a git work tree: $repo_root"
    return 1
  fi
  repo_top="$(cd -P "$repo_top" && pwd)"
  local repo_abs; repo_abs="$(cd -P "$repo_root" 2>/dev/null && pwd)"
  if [ "$repo_abs" != "$repo_top" ]; then
    bd_cannot_evaluate "--repo-root is not a git toplevel (toplevel is $repo_top): $repo_root — the replay worktree path is derived from the toplevel, so a subdirectory would put it somewhere neither this driver nor worktree.sh expects"
    return 1
  fi
  repo_root="$repo_top"
  BD_REPO_ROOT="$repo_root"

  # ── THE SEAM CHECK. Before the gate, before a worktree, before a token. ─
  # There is deliberately NO implicit binary for either arm: with neither
  # seam given there is nothing to fall back TO, so a `claude` sitting on
  # PATH is unreachable from here.
  if [ "$live" -eq 1 ]; then
    if [ -n "$baseline_runner" ] || [ -n "$candidate_runner" ] || [ -n "$judge_runner" ]; then
      bd_cannot_evaluate "--live and a recorded --baseline-runner/--candidate-runner/--judge-runner are mutually exclusive — pick the recorded runners or the real spawn, never both"
      return 1
    fi
  else
    if [ -z "$baseline_runner" ] || [ -z "$candidate_runner" ]; then
      bd_cannot_evaluate "no candidate runner configured for both arms: pass --baseline-runner <cmd> AND --candidate-runner <cmd> (recorded/stubbed runners) or the explicit --live flag. There is deliberately NO implicit fallback to a 'claude' binary on PATH — an unset seam refuses rather than silently spending, and a batch is the one place a single unset seam would spend many times over"
      return 1
    fi
  fi

  # ═════════════════════════════════════════════════════════════════════
  # STEP 1 — THE GATE, FIRST. Nothing below this point can be reached by
  # an un-gated batch, because nothing is prepared or executed above it.
  # ═════════════════════════════════════════════════════════════════════
  local pf_json pf_rc=0
  pf_json="$(bash "$REPLAY_SH" preflight --corpus-file "$corpus_file" 2>/dev/null)" || pf_rc=$?
  if [ -z "$pf_json" ] || ! jq -e 'type=="object"' >/dev/null 2>&1 <<<"$pf_json"; then
    bd_cannot_evaluate "replay.sh preflight did not print a JSON object (exit $pf_rc) — refusing to start a batch whose spend gate could not be read"
    return 1
  fi
  if [ "$(jq -r '.outcome // ""' <<<"$pf_json")" = "CANNOT_EVALUATE" ]; then
    bd_cannot_evaluate "the pre-flight spend gate could not evaluate this corpus: $(jq -r '.error // "no reason given"' <<<"$pf_json")"
    return 1
  fi

  if [ "$preflight_only" = "1" ]; then
    printf '%s\n' "$pf_json"
    [ "$(jq -r '.stop' <<<"$pf_json")" = "true" ] && return 3
    return 0
  fi

  if [ "$(jq -r '.stop' <<<"$pf_json")" = "true" ]; then
    bd_stopped "$(jq -r '.stop_reason // "unknown"' <<<"$pf_json")" \
      "the pre-flight spend gate stopped this batch before any replay was executed; nothing was spent" "$pf_json"
    return 3
  fi
  if [ "$(jq -r '.confirmation_required' <<<"$pf_json")" = "true" ] && [ "$confirm" -eq 0 ]; then
    bd_stopped "confirmation_required" \
      "the pre-flight gate requires explicit operator confirmation of the estimate above ($(jq -r '.estimated_cost' <<<"$pf_json") $(jq -r '.cost_basis' <<<"$pf_json") over $(jq -r '.planned_replays_n' <<<"$pf_json") executed replays); re-run with --confirm to authorize it. Nothing was spent" "$pf_json"
    return 3
  fi

  # THE UNIT CONTRACT (temperloop#1379). This driver executes exactly the
  # two arms it knows the names of. If the gate budgeted a different number
  # of arms, the estimate the operator authorized and the spend this driver
  # would make describe different things — refuse rather than reconcile.
  local pf_arms; pf_arms="$(jq -r '.arms_n' <<<"$pf_json")"
  case "$pf_arms" in
    "$BATCH_ARMS_N") ;;
    *)
      bd_cannot_evaluate "the pre-flight gate budgeted arms_n=$pf_arms but this driver executes exactly $BATCH_ARMS_N named arms ($BATCH_ARM_BASELINE, $BATCH_ARM_CANDIDATE) — the authorized estimate and the actual spend would describe different things"
      return 1 ;;
  esac

  local batch_cap planned_records_n planned_replays_n planned_pairs_n
  batch_cap="$(jq -r '.batch_cap' <<<"$pf_json")"
  planned_records_n="$(jq -r '.planned_records_n' <<<"$pf_json")"
  planned_replays_n="$(jq -r '.planned_replays_n' <<<"$pf_json")"
  planned_pairs_n="$(jq -r '.planned_pairs_n' <<<"$pf_json")"
  local _v
  for _v in "$batch_cap" "$planned_records_n" "$planned_replays_n" "$planned_pairs_n"; do
    case "$_v" in
      ''|*[!0-9]*)
        bd_cannot_evaluate "the pre-flight gate published a non-integer plan figure (\"$_v\") — the batch this driver would run cannot be evaluated against it"
        return 1 ;;
    esac
  done

  # ═════════════════════════════════════════════════════════════════════
  # STEP 2 — SELECTION. The batch cap is applied to CORPUS RECORDS, and the
  # result must agree exactly with what the gate authorized.
  # ═════════════════════════════════════════════════════════════════════
  local scratch; scratch="$(mktemp -d "${TMPDIR:-/tmp}/replay-batch.XXXXXX")" || {
    bd_cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }

  # out dir / state dir
  if [ -z "$out_dir" ]; then out_dir="$MODEL_COMPARISON_REPORT_RECORDS_DIR"; fi
  case "$out_dir" in /*) ;; *) out_dir="$repo_root/$out_dir" ;; esac
  if [ -z "$state_dir" ]; then state_dir="$out_dir/$BATCH_STATE_SUBDIR"; fi
  case "$state_dir" in /*) ;; *) state_dir="$repo_root/$state_dir" ;; esac
  if ! mkdir -p "$out_dir" "$state_dir/records" "$state_dir/legs/$BATCH_ARM_BASELINE" \
       "$state_dir/legs/$BATCH_ARM_CANDIDATE" "$state_dir/judge" 2>/dev/null; then
    rm -rf "$scratch"
    bd_cannot_evaluate "could not create the output directory ($out_dir) or the resume state directory ($state_dir)"
    return 1
  fi

  local sel_tsv="$state_dir/selection.tsv"
  : >"$sel_tsv"
  local line idx=0 status ref rec_file refs_json
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! jq -e 'type=="object" and has("status")' >/dev/null 2>&1 <<<"$line"; then
      rm -rf "$scratch"
      bd_cannot_evaluate "malformed corpus record (not a JSON object with a status field): $line"
      return 1
    fi
    status="$(jq -r '.status' <<<"$line")"
    case "$status" in eligible|flagged-eligible) ;; *) continue ;; esac
    [ "$idx" -lt "$batch_cap" ] || break
    ref="$(jq -r 'if (.pr // null) != null then "pr:\(.pr)" elif (.issue // null) != null then "issue:\(.issue)" else "" end' <<<"$line")"
    if [ -z "$ref" ]; then
      rm -rf "$scratch"
      bd_cannot_evaluate "an eligible corpus record identifies neither an issue nor a PR, so it has no outcome ref to pair the two arms on: $line"
      return 1
    fi
    idx=$((idx + 1))
    rec_file="$state_dir/records/$(printf '%03d' "$idx")-$(bd_slugify "$ref").json"
    printf '%s\n' "$line" >"$rec_file"
    printf '%s\t%s\t%s\n' "$idx" "$ref" "$rec_file" >>"$sel_tsv"
  done <"$corpus_file"

  if [ "$idx" -ne "$planned_records_n" ]; then
    rm -rf "$scratch"
    bd_cannot_evaluate "this driver selected $idx corpus records but the pre-flight gate authorized $planned_records_n — refusing to execute a batch that does not match the one the operator authorized"
    return 1
  fi
  if [ "$idx" -eq 0 ]; then
    rm -rf "$scratch"
    bd_cannot_evaluate "no eligible corpus records to replay — there is nothing to compare"
    return 1
  fi
  refs_json="$(cut -f2 "$sel_tsv" | jq -R . | jq -cs .)"

  # ── the state dir is bound to ONE batch ───────────────────────────────
  local corpus_sha manifest cur_manifest
  corpus_sha="$(bd_sha256 "$corpus_file")"
  manifest="$state_dir/batch.json"
  cur_manifest="$(jq -cn --arg sha "$corpus_sha" --arg repo "$repo_root" \
    --argjson refs "$refs_json" --argjson cap "$batch_cap" \
    '{corpus_sha256:$sha, repo_root:$repo, refs:$refs, batch_cap:$cap}')"
  if [ -f "$manifest" ]; then
    if ! jq -e --argjson cur "$cur_manifest" \
        '.corpus_sha256 == $cur.corpus_sha256 and .refs == $cur.refs and .repo_root == $cur.repo_root' \
        >/dev/null 2>&1 <"$manifest"; then
      rm -rf "$scratch"
      bd_cannot_evaluate "the resume state directory $state_dir was created for a DIFFERENT batch (its corpus sha256 / selected refs / repo-root do not match this invocation's) — resuming would mix two batches' records into one arm file; use a fresh --state-dir"
      return 1
    fi
  else
    printf '%s\n' "$cur_manifest" >"$manifest"
  fi

  # ═════════════════════════════════════════════════════════════════════
  # STEP 3 — EXECUTE. Every selected record, in BOTH arms.
  # ═════════════════════════════════════════════════════════════════════
  local legs_planned=$(( idx * BATCH_ARMS_N ))
  local legs_done=0 legs_resumed=0 legs_failed=0 legs_scored=0 legs_interr=0
  local failures_file="$scratch/failures.jsonl"; : >"$failures_file"
  local arm sel_idx sel_ref sel_rec

  # Read the selection on fd 3, NOT stdin: every `replay.sh execute` below
  # spawns a candidate runner, and the `--live` arm redirects its own stdin
  # from the prompt file — but a stubbed runner is an arbitrary operator
  # command that may read stdin, and one that did would silently swallow the
  # rest of this loop's selection and truncate the batch.
  while IFS="$(printf '\t')" read -r sel_idx sel_ref sel_rec <&3; do
    [ -n "$sel_idx" ] || continue
    for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
      local leg_key leg_rec leg_state
      leg_key="$(printf '%03d' "$sel_idx")-$(bd_slugify "$sel_ref")"
      leg_rec="$state_dir/legs/$arm/$leg_key.json"
      leg_state="$state_dir/legs/$arm/$leg_key.state.json"

      # ── RESUME: a leg that already reached a terminal state is never
      #    re-spent. A failed leg is not retried either unless asked, since
      #    a failure can land AFTER the candidate ran (score.sh's own
      #    refusal path is exactly that shape) and a blind retry would
      #    re-spend it.
      if [ -f "$leg_state" ]; then
        local prev_state; prev_state="$(jq -r '.state // ""' <"$leg_state" 2>/dev/null)"
        local retryable=0
        [ "$prev_state" = "cannot-evaluate" ] && [ "$retry_failed" -eq 1 ] && retryable=1
        if [ "$retryable" -eq 0 ]; then
          legs_resumed=$((legs_resumed + 1))
          case "$prev_state" in
            scored) legs_done=$((legs_done + 1)); legs_scored=$((legs_scored + 1)) ;;
            integration-error) legs_done=$((legs_done + 1)); legs_interr=$((legs_interr + 1)) ;;
            *)
              legs_failed=$((legs_failed + 1))
              jq -cn --arg a "$arm" --arg r "$sel_ref" \
                --arg reason "$(jq -r '.reason // "no reason recorded"' <"$leg_state" 2>/dev/null)" \
                '{arm:$a, outcome_ref:$r, reason:$reason, from:"a previous invocation of this batch"}' >>"$failures_file" ;;
          esac
          printf 'batch.sh: [%s/%s] %s %s — resumed (%s), not re-spent\n' \
            "$sel_idx" "$idx" "$arm" "$sel_ref" "$prev_state" >&2
          continue
        fi
      fi

      # ── prepare ────────────────────────────────────────────────────────
      local slug prep_out prep_path rec_base
      slug="mc-replay-$arm-$(printf '%03d' "$sel_idx")"
      rec_base="$(jq -r '.base // ""' "$sel_rec")"
      # stderr is deliberately NOT merged into this capture — worktree.sh's
      # create() writes its structured JSON to stdout but a diagnostic guard
      # banner to stderr, and merging the two corrupts the JSON parse below on
      # every run where the banner fires (replay.sh's own worktree-prepare
      # carries the same comment for the same reason; observed here as every
      # leg "failing" with a PREPARED payload inside its own failure text).
      prep_out="$(bash "$REPLAY_SH" worktree-prepare "$repo_root" "$slug" "$rec_base" 2>"$scratch/prep-stderr.txt")"
      prep_path="$(jq -r '.path // empty' <<<"$prep_out" 2>/dev/null)"
      if [ "$(jq -r '.outcome // empty' <<<"$prep_out" 2>/dev/null)" != "PREPARED" ] || [ -z "$prep_path" ]; then
        # worktree-prepare tears its own partial worktree down on every
        # failure path (its header's mid-run-failure guarantee), so there
        # is nothing to clean up here — only to record.
        jq -cn --arg s "cannot-evaluate" \
          --arg r "worktree-prepare failed for slug $slug: $(printf '%s' "$prep_out" | head -c 400) $(head -c 400 "$scratch/prep-stderr.txt" 2>/dev/null)" \
          '{state:$s, reason:$r}' >"$leg_state"
        legs_failed=$((legs_failed + 1))
        jq -cn --arg a "$arm" --arg r "$sel_ref" \
          --arg reason "worktree-prepare failed: $(printf '%s' "$prep_out" | head -c 200)" \
          '{arm:$a, outcome_ref:$r, reason:$reason, from:"this invocation"}' >>"$failures_file"
        printf 'batch.sh: [%s/%s] %s %s — FAILED (worktree-prepare); the batch continues\n' \
          "$sel_idx" "$idx" "$arm" "$sel_ref" >&2
        continue
      fi
      BD_LIVE_SLUG="$slug"

      # ── execute ────────────────────────────────────────────────────────
      local -a xa
      xa=(execute --record "$sel_rec" --repo-root "$repo_root" --worktree "$prep_path" --out "$leg_rec")
      if [ "$live" -eq 1 ]; then
        xa+=(--live)
      else
        case "$arm" in
          "$BATCH_ARM_BASELINE") xa+=(--candidate-runner "$baseline_runner") ;;
          *) xa+=(--candidate-runner "$candidate_runner") ;;
        esac
      fi
      local arm_model arm_provider
      case "$arm" in
        "$BATCH_ARM_BASELINE") arm_model="$baseline_model"; arm_provider="$baseline_provider" ;;
        *) arm_model="$candidate_model"; arm_provider="$candidate_provider" ;;
      esac
      [ -n "$arm_model" ] && xa+=(--model "$arm_model")
      [ -n "$arm_provider" ] && xa+=(--provider "$arm_provider")
      [ -n "$owner_repo" ] && xa+=(--repo "$owner_repo")
      [ -n "$gate_relpath" ] && xa+=(--gate-relpath "$gate_relpath")

      local x_rc=0 x_err="$scratch/exec-stderr.txt"
      rm -f "$leg_rec"
      bash "$REPLAY_SH" "${xa[@]}" >/dev/null 2>"$x_err" || x_rc=$?

      # ── teardown, on BOTH the success and the failure path ────────────
      bash "$REPLAY_SH" worktree-teardown "$repo_root" "$slug" >/dev/null 2>&1 || true
      BD_LIVE_SLUG=""

      # A record must actually exist and parse before this leg counts as
      # having produced one — an exit code alone is not evidence.
      local have_record=0
      if [ -s "$leg_rec" ] && jq -e 'type=="object"' >/dev/null 2>&1 <"$leg_rec"; then have_record=1; fi

      if [ "$x_rc" -eq 0 ] && [ "$have_record" -eq 1 ]; then
        jq -cn '{state:"scored", reason:null}' >"$leg_state"
        legs_done=$((legs_done + 1)); legs_scored=$((legs_scored + 1))
        printf 'batch.sh: [%s/%s] %s %s — scored\n' "$sel_idx" "$idx" "$arm" "$sel_ref" >&2
      elif [ "$x_rc" -eq 4 ] && [ "$have_record" -eq 1 ]; then
        jq -cn --arg r "$(head -c 400 "$x_err" 2>/dev/null)" \
          '{state:"integration-error", reason:$r}' >"$leg_state"
        legs_done=$((legs_done + 1)); legs_interr=$((legs_interr + 1))
        printf 'batch.sh: [%s/%s] %s %s — integration error (a record WAS produced); the batch continues\n' \
          "$sel_idx" "$idx" "$arm" "$sel_ref" >&2
      else
        local why
        why="replay.sh execute exited $x_rc and produced no usable record: $(head -c 400 "$x_err" 2>/dev/null)"
        rm -f "$leg_rec"
        jq -cn --arg r "$why" '{state:"cannot-evaluate", reason:$r}' >"$leg_state"
        legs_failed=$((legs_failed + 1))
        jq -cn --arg a "$arm" --arg r "$sel_ref" --arg reason "$why" \
          '{arm:$a, outcome_ref:$r, reason:$reason, from:"this invocation"}' >>"$failures_file"
        printf 'batch.sh: [%s/%s] %s %s — FAILED (%s); the batch continues\n' \
          "$sel_idx" "$idx" "$arm" "$sel_ref" "$why" >&2
      fi
    done
  done 3<"$sel_tsv"

  # ── the end-of-batch worktree sweep. Covers a leg worktree left behind by
  #    a PREVIOUS interrupted run (this run's own legs are already torn
  #    down above, and teardown of an absent worktree is a no-op).
  local swept=0 sweep_idx=1
  while [ "$sweep_idx" -le "$idx" ]; do
    for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
      local sweep_slug
      sweep_slug="mc-replay-$arm-$(printf '%03d' "$sweep_idx")"
      if [ -d "${repo_root}.wt/$sweep_slug" ]; then
        bash "$REPLAY_SH" worktree-teardown "$repo_root" "$sweep_slug" >/dev/null 2>&1 || true
        swept=$((swept + 1))
      fi
    done
    sweep_idx=$((sweep_idx + 1))
  done

  # ═════════════════════════════════════════════════════════════════════
  # STEP 4 — ASSEMBLE THE ARM FILES, in selection order, from the state
  # dir — so a RESUMED run emits complete arm files, not just this
  # invocation's share.
  # ═════════════════════════════════════════════════════════════════════
  local base_file="$out_dir/$BATCH_ARM_BASELINE.jsonl"
  local cand_file="$out_dir/$BATCH_ARM_CANDIDATE.jsonl"
  for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
    local tmp_arm="$scratch/$arm.jsonl"; : >"$tmp_arm"
    while IFS="$(printf '\t')" read -r sel_idx sel_ref sel_rec; do
      [ -n "$sel_idx" ] || continue
      local f
      f="$state_dir/legs/$arm/$(printf '%03d' "$sel_idx")-$(bd_slugify "$sel_ref").json"
      if [ -s "$f" ] && jq -e 'type=="object"' >/dev/null 2>&1 <"$f"; then
        jq -c . <"$f" >>"$tmp_arm"
      fi
    done <"$sel_tsv"
    cp "$tmp_arm" "$out_dir/$arm.jsonl"
  done

  # ═════════════════════════════════════════════════════════════════════
  # STEP 5 — JUDGE. Optional seam; a skip is NAMED, never silent.
  # Resumable on the sha256 of the arm file it judged, so a re-invocation
  # re-spends no judge call either.
  # ═════════════════════════════════════════════════════════════════════
  local judge_json judge_degraded=0
  if [ "$live" -eq 0 ] && [ -z "$judge_runner" ]; then
    judge_json="$(jq -cn '{ran:false, reason:"no judge seam configured — pass --judge-runner <cmd> (a recorded/stubbed runner) or --live to judge these arms. The arm files are written UNJUDGED; the comparison report counts such rows as unjudged rather than treating an absent judgment as a zero", per_arm:null}')"
  elif [ ! -f "$JUDGE_SH" ]; then
    judge_json="$(jq -cn --arg p "$JUDGE_SH" '{ran:false, reason:("judge.sh not found at " + $p + " — the judge seam is unavailable; the arm files are written UNJUDGED"), per_arm:null}')"
    judge_degraded=1
  else
    local per_arm_judge="$scratch/judge-arms.jsonl"; : >"$per_arm_judge"
    for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
      local arm_file="$out_dir/$arm.jsonl"
      local arm_sha judged_sha judged_out j_rc=0 j_state
      if [ ! -s "$arm_file" ]; then
        jq -cn --arg a "$arm" '{arm:$a, ran:false, outcome:"SKIPPED", detail:"this arm carries no records to judge"}' >>"$per_arm_judge"
        continue
      fi
      arm_sha="$(bd_sha256 "$arm_file")"
      judged_sha="$state_dir/judge/$arm.sha256"
      judged_out="$state_dir/judge/$arm.jsonl"
      # The stored digest is the digest of the UNJUDGED input this arm file
      # was assembled to, not of the judged output — the resume check runs
      # against a freshly reassembled (and therefore unjudged) arm file, so
      # storing the output's digest would never match and every invocation
      # would silently re-spend the whole judge pass.
      if [ -f "$judged_sha" ] && [ -s "$judged_out" ] \
         && [ "$(cat "$judged_sha")" = "$arm_sha" ]; then
        cp "$judged_out" "$arm_file"
        jq -cn --arg a "$arm" '{arm:$a, ran:false, outcome:"RESUMED", detail:"this arm was already judged by a previous invocation over byte-identical input; the judged records were reused rather than re-spent"}' >>"$per_arm_judge"
        continue
      fi
      local -a ja
      ja=(judge-batch --records-file "$arm_file" --out "$scratch/$arm.judged.jsonl")
      if [ "$live" -eq 1 ]; then ja+=(--live); else ja+=(--judge-runner "$judge_runner"); fi
      [ -n "$judge_model" ] && ja+=(--model "$judge_model")
      [ -n "$judge_provider" ] && ja+=(--provider "$judge_provider")
      [ -n "$owner_repo" ] && ja+=(--repo "$owner_repo")
      bash "$JUDGE_SH" "${ja[@]}" >/dev/null 2>"$scratch/judge-stderr.txt" || j_rc=$?
      if [ "$j_rc" -eq 0 ] || [ "$j_rc" -eq 4 ]; then
        if [ -s "$scratch/$arm.judged.jsonl" ]; then
          cp "$scratch/$arm.judged.jsonl" "$arm_file"
          cp "$scratch/$arm.judged.jsonl" "$judged_out"
          printf '%s\n' "$arm_sha" >"$judged_sha"
        fi
        j_state="JUDGED"
        [ "$j_rc" -eq 4 ] && { j_state="DEGRADED"; judge_degraded=1; }
        jq -cn --arg a "$arm" --arg s "$j_state" --argjson rc "$j_rc" \
          --arg d "$(head -c 400 "$scratch/judge-stderr.txt" 2>/dev/null)" \
          '{arm:$a, ran:true, outcome:$s, exit_code:$rc, detail:$d}' >>"$per_arm_judge"
      else
        judge_degraded=1
        jq -cn --arg a "$arm" --argjson rc "$j_rc" \
          --arg d "$(head -c 400 "$scratch/judge-stderr.txt" 2>/dev/null)" \
          '{arm:$a, ran:true, outcome:"CANNOT_EVALUATE", exit_code:$rc,
            detail:("judge.sh judge-batch could not judge this arm; the arm file is left UNJUDGED rather than partially rewritten: " + $d)}' >>"$per_arm_judge"
      fi
    done
    judge_json="$(jq -cs --argjson deg "$judge_degraded" \
      '{ran:true, reason:null, degraded:($deg==1), per_arm:.}' <"$per_arm_judge")"
  fi

  # ═════════════════════════════════════════════════════════════════════
  # STEP 6 — the isolation backstop, then the ONE summary object.
  # ═════════════════════════════════════════════════════════════════════
  local vcp_json vcp_rc=0
  vcp_json="$(bash "$REPLAY_SH" verify-clean-parent "$repo_root" 2>/dev/null)" || vcp_rc=$?
  if [ -z "$vcp_json" ] || ! jq -e 'type=="object"' >/dev/null 2>&1 <<<"$vcp_json"; then
    vcp_json="$(jq -cn --argjson rc "$vcp_rc" '{outcome:"UNKNOWN", detail:("replay.sh verify-clean-parent printed no parseable verdict (exit " + ($rc|tostring) + ") — the post-run isolation backstop could not be read, which is NOT the same as a clean parent")}')"
  fi
  local vcp_outcome; vcp_outcome="$(jq -r '.outcome // "UNKNOWN"' <<<"$vcp_json" 2>/dev/null)"
  [ -n "$vcp_outcome" ] || vcp_outcome="UNKNOWN"

  local base_n cand_n paired_n
  base_n="$(grep -c . "$base_file" 2>/dev/null || true)"; case "$base_n" in ''|*[!0-9]*) base_n=0 ;; esac
  cand_n="$(grep -c . "$cand_file" 2>/dev/null || true)"; case "$cand_n" in ''|*[!0-9]*) cand_n=0 ;; esac
  paired_n="$(jq -n --slurpfile b "$base_file" --slurpfile c "$cand_file" '
      def refof: if (.pr // null) != null then "pr:\(.pr)" elif (.issue // null) != null then "issue:\(.issue)" else null end;
      ($b | map(refof) | map(select(. != null))) as $br
      | ($c | map(refof) | map(select(. != null))) as $cr
      | ($br - ($br - $cr)) | unique | length' 2>/dev/null)"
  case "$paired_n" in ''|*[!0-9]*) paired_n=0 ;; esac

  local degradations="$scratch/degradations.jsonl"; : >"$degradations"
  [ "$legs_failed" -gt 0 ] && jq -cn --argjson n "$legs_failed" \
    '{kind:"leg_failures", detail:("\($n) of the planned executed replays did not produce a record; each is named in failures[] with its reason")}' >>"$degradations"
  [ "$judge_degraded" -eq 1 ] && jq -cn \
    '{kind:"judge_degraded", detail:"at least one arm did not reach a clean JUDGED pass; see judge.per_arm"}' >>"$degradations"
  if [ "$vcp_outcome" != "CLEAN" ]; then
    jq -cn --arg o "$vcp_outcome" \
      '{kind:"parent_not_clean", detail:("replay.sh verify-clean-parent reported " + $o + " after the batch — the parent checkout carries residue that the isolated replay worktrees should have kept out of it")}' >>"$degradations"
  fi

  local rate
  rate="$(jq -n --argjson completed "$legs_done" --argjson planned "$legs_planned" \
    'if $planned == 0 then null else (($completed / $planned * 10000) | round) / 10000 end')"

  jq -n \
    --arg sv "$BATCH_SUMMARY_SCHEMA_VERSION" \
    --argjson pf "$pf_json" \
    --arg corpus "$corpus_file" --arg csha "$corpus_sha" \
    --argjson refs "$refs_json" --argjson records_n "$idx" --argjson cap "$batch_cap" \
    --argjson arms_n "$BATCH_ARMS_N" \
    --argjson legs_planned "$legs_planned" --argjson legs_done "$legs_done" \
    --argjson legs_resumed "$legs_resumed" --argjson legs_failed "$legs_failed" \
    --argjson legs_scored "$legs_scored" --argjson legs_interr "$legs_interr" \
    --argjson rate "$rate" \
    --slurpfile failures "$failures_file" \
    --slurpfile degradations "$degradations" \
    --arg base_file "$base_file" --arg cand_file "$cand_file" \
    --argjson base_n "$base_n" --argjson cand_n "$cand_n" --argjson paired_n "$paired_n" \
    --argjson min_sample_n "$MODEL_COMPARISON_MIN_SAMPLE_N" \
    --argjson judge "$judge_json" \
    --argjson vcp "$vcp_json" --arg vcp_outcome "$vcp_outcome" --argjson swept "$swept" \
    --arg base_arm "$BATCH_ARM_BASELINE" --arg cand_arm "$BATCH_ARM_CANDIDATE" \
    '{schema_version:$sv,
      outcome: (if (($legs_failed > 0) or (($degradations | length) > 0)) then "BATCH_DEGRADED" else "BATCH_COMPLETE" end),
      units:{
        basis: "the SAME three non-interchangeable count units replay.sh preflight publishes (temperloop#1379): 1 corpus record = arms_n executed replays = 1 paired outcome. This driver consumes those numbers from the gate rather than re-deriving them, so the batch it executes and the batch the operator authorized are the same batch",
        selected_records_n: "corpus_records", batch_cap: "corpus_records",
        legs_planned_n: "executed_replays", legs_completed_n: "executed_replays",
        replay_completion_rate: "executed_replays completed / executed_replays planned",
        paired_outcomes_n: "paired_outcomes", min_sample_n: "paired_outcomes",
        estimated_cost: "see authorized.cost_basis — cost-weighted token units, never a raw token sum"},
      authorized:{
        basis: "read verbatim off the pre-flight gate this run passed; this driver computes no estimate and no cost of its own",
        records_n: $pf.planned_records_n, replays_n: $pf.planned_replays_n,
        pairs_n: $pf.planned_pairs_n, arms_n: $arms_n,
        estimated_cost: $pf.estimated_cost, cost_basis: $pf.cost_basis,
        batch_cap: $cap, confirmed: true},
      selection:{corpus_file:$corpus, corpus_sha256:$csha,
                 selected_records_n:$records_n, refs:$refs},
      legs:{planned_n:$legs_planned, completed_n:$legs_done, resumed_n:$legs_resumed,
            failed_n:$legs_failed, scored_n:$legs_scored, integration_error_n:$legs_interr},
      completion:{
        basis: "an executed replay COMPLETED when it produced a record — a scored record OR an integration-error record, both of which the comparison report consumes (the latter as a compatibility fact, never a quality one). A leg that produced no record at all is counted as failed and named in failures[]",
        replay_completion_rate:$rate,
        per_arm:{($base_arm): {records_n:$base_n}, ($cand_arm): {records_n:$cand_n}}},
      failures: $failures,
      arms:{($base_arm): {file:$base_file, records_n:$base_n},
            ($cand_arm): {file:$cand_file, records_n:$cand_n}},
      pairing:{
        basis: "outcome refs present in BOTH arm files — the same intersection workflows/scripts/report-producers/model-comparison computes, reported here so the operator can see the comparison'"'"'s real N without opening the report",
        paired_outcomes_n:$paired_n, min_sample_n:$min_sample_n,
        meets_min_sample: ($paired_n >= $min_sample_n)},
      judge: $judge,
      isolation:{verify_clean_parent:$vcp_outcome, verify_clean_parent_detail:$vcp,
                 worktrees_swept_n:$swept},
      degradations: $degradations,
      preflight: $pf}'

  rm -rf "$scratch"

  if [ "$legs_failed" -gt 0 ] || [ "$judge_degraded" -eq 1 ] || [ "$vcp_outcome" != "CLEAN" ]; then
    printf 'batch.sh: BATCH DEGRADED — %s of %s executed replays produced a record; see degradations[] and failures[]\n' \
      "$legs_done" "$legs_planned" >&2
    return 4
  fi
  return 0
}

# ── dispatch — no while-loop parses the top-level subcommand, so a missing
#    trailing operand can never shift-2-no-op into a hang (§ testing bar).
[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  run) cmd_run "$@" ;;
  schema) cmd_schema ;;
  *) usage; exit 2 ;;
esac
