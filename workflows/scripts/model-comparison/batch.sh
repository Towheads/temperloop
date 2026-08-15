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
# ── AN INTERRUPT STOPS THE BATCH (temperloop#1527) ────────────────────────
# SIGINT/SIGTERM tear the in-flight worktree down AND STOP — they do not clean
# up and continue to the next leg. An operator's ^C on a spend-bearing loop
# means stop spending, so the signal arms re-raise under the default
# disposition and the process dies with the signal-derived status. This is
# NOT a weakening of the per-leg failure resilience above: a leg that fails is
# still recorded and the batch still continues; only a real signal stops it.
#
# ── A SYSTEMIC FAILURE STOPS THE BATCH (temperloop#1554) ──────────────────
# The paragraph above is about ONE leg failing. This one is about the whole
# spawn path failing, which is a different fact and needs a different answer.
#
# On the first live batch, 14 records replayed successfully over ~3.1h and
# then EVERY remaining leg fast-failed in ~4-5s: 28 consecutive
# `candidate-spawn` integration errors, almost certainly a rate or usage
# limit. The per-leg resilience above is what made that possible — each
# failure was recorded, the batch continued, and the driver hammered an
# endpoint that was telling it to stop, ~5s apart, to the end of the corpus.
# Continuing is the worst available response to that specific cause.
#
# So this driver carries a CIRCUIT BREAKER, and its shape is chosen to
# separate the two facts rather than blur them:
#
#   * It counts CONSECUTIVE integration errors carrying the SAME
#     `integration_error.stage` (replay.sh's own vocabulary:
#     candidate-spawn, candidate-timeout, envelope-parse, vendor-error,
#     envelope-usage-missing). 28 consecutive candidate-spawn failures trip
#     it; a scatter of unrelated per-record incompatibilities does not,
#     because the streak RE-KEYS to 1 whenever the stage changes.
#   * ANY leg that scores resets the streak to zero. A systemic outage is
#     precisely the case where nothing succeeds in between.
#   * The threshold is MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS —
#     named here, valued only in workflows/scripts/build/build.config.sh
#     (§ Named-setting convention). 0 disables the breaker.
#   * Only legs THIS INVOCATION executed are counted. A resumed leg is
#     evidence about a previous run, not about whether the endpoint is
#     available now, so it neither increments nor resets the streak.
#
# When it trips, every remaining leg is recorded `not-attempted` — NOT an
# integration error. That distinction is the whole point: an integration
# error is a claim about a RECORD ("this one is incompatible"), and the
# breaker's skipped legs make no such claim about anything. A `not-attempted`
# leg is always retryable (it cost nothing, so there is nothing to protect
# from a re-spend) and a plain resume re-drives it. The judge pass is skipped
# too, with a NAMED reason — judging runs through the same spawn seam that
# just went unavailable.
#
# The stop is reported DISTINGUISHABLY from a completed-but-degraded batch:
# outcome BATCH_STOPPED_EARLY, exit 5 (not 4), a named
# `circuit_breaker_tripped` degradation, and a `circuit_breaker` block
# carrying the stage, the streak, and how many legs and whole RECORDS were
# never attempted. "The corpus was exhausted and some records were
# incompatible" and "the driver stopped early because the spawn path went
# systemically unavailable" are different statements, and this file keeps
# them apart the same way it keeps CANNOT_EVALUATE apart from BATCH_COMPLETE.
#
# ── THE COMPLETION RATE IS RECONCILED AGAINST THE ARTIFACT (temperloop#1556)
# Every count this driver publishes — `replay_completion_rate`, `legs.*`,
# `arms.*.records_n` — is derived from the LEG state files, which are written
# once and never touched again. The ARM FILE is a different artifact, and the
# judge pass REWRITES it in place. Nothing reconciled the two, and on the
# first live batch that gap was load-bearing: `judge.sh judge-batch` replaced
# 14 of 21 records per arm with bare error objects while this driver reported
# `replay_completion_rate: 1` and 21 records per arm off the intact legs. The
# summary read perfectly healthy over an arm file that was already destroyed;
# the operator found out only when the report producer refused to render.
#
# So a completion rate is published only alongside a `reconciliation` block
# that checks the arm file ON DISK against the leg records this driver
# COUNTED — record count, per-record identity, and record SHAPE (a line that
# is not an object carrying `.candidate` is not a replay record at all, which
# is exactly the corruption signature). A mismatch is a NAMED degradation
# (`arm_reconciliation_mismatch`), flips the run to BATCH_DEGRADED, and
# stamps `completion.rate_is_over_a_reconciled_arm:false` with a named
# caveat — the rate is still reported, because it is still a true statement
# about the legs, but it can no longer be read as a clean run over that file.
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
#   5  BATCH_STOPPED_EARLY the CIRCUIT BREAKER tripped: too many consecutive
#                         same-stage integration errors, so the driver
#                         STOPPED rather than running the rest of the corpus
#                         out against a spawn path that has gone
#                         systemically unavailable. Deliberately NOT 4 —
#                         "the corpus was exhausted, some records were
#                         incompatible" and "the driver stopped early" are
#                         different statements. Every un-attempted leg is
#                         recorded `not-attempted` (never an integration
#                         error) and a resume re-drives it. See § A SYSTEMIC
#                         FAILURE STOPS THE BATCH.
#   4  BATCH_DEGRADED     the batch RAN end to end, but at least one leg
#                         failed, or the judge degraded, or an arm file
#                         failed to RECONCILE against the leg records this
#                         driver counted, or the parent checkout was left
#                         dirty. The arm files ARE written and the summary
#                         names every degradation — "some of it did not
#                         work" is a different statement from "it worked",
#                         and this file keeps them apart.
#
# 128+N INTERRUPTED       deliberately OUTSIDE the closed set above: the run
#                         was signalled (^C / kill), so the process dies OF
#                         that signal rather than reporting a verdict of its
#                         own. No summary object is printed — an interrupted
#                         batch never reached one. See § AN INTERRUPT STOPS
#                         THE BATCH.
#
# Every setting this file reads is registered in
# workflows/scripts/config/setting-registry.tsv and defaulted in
# workflows/scripts/build/build.config.sh — named symbolically, never
# re-valued in this prose. This file introduces exactly ONE setting of its
# own, MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS (§ A SYSTEMIC
# FAILURE STOPS THE BATCH), and it lives at that same seam: the batch cap
# still comes from the gate, and the state dir is still derived from the
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
: "${MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS:=5}"
: "${MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT:=25}"

# shellcheck source=../lib/cannot-evaluate.sh
[ -f "$HERE/../lib/cannot-evaluate.sh" ] && . "$HERE/../lib/cannot-evaluate.sh"
if ! command -v cannot_evaluate_emit >/dev/null 2>&1; then
  # DEGRADED, never silently duplicated (temperloop#1475 review MEDIUM-3):
  # cannot-evaluate.sh ships alongside this file in every kernel install, so
  # reaching this branch means the checkout is structurally off — e.g. this
  # file reached via a symlink ($HERE resolves the DIRECTORY via `cd -P`,
  # which does not resolve a symlinked *file*, so a symlinked entry point
  # can land here even with a normal lib/ present) — or the lib is genuinely
  # missing. Re-typing the frozen contract's human-line shape here a second
  # time would be exactly the silent duplication this hoist exists to
  # eliminate, so this fallback does NOT pretend to be the real thing: it
  # defines RC_CANNOT_EVALUATE itself (so a caller using the lib's own
  # advertised idiom never hits an unbound-variable abort under `set -u`),
  # still emits the machine JSON so a downstream `.outcome` reader sees
  # CANNOT_EVALUATE, still fails CLOSED on that reserved code, but replaces
  # the human line with an explicit degradation notice naming what's wrong.
  RC_CANNOT_EVALUATE=2
  cannot_evaluate_emit() {
    jq -cn --arg e "$2" '{outcome:"CANNOT_EVALUATE",error:$e}'
    printf '%s: CANNOT-EVALUATE-DEGRADED — workflows/scripts/lib/cannot-evaluate.sh could not be sourced (checkout is structurally off); original message: %s\n' "$1" "$2" >&2
    return "$RC_CANNOT_EVALUATE"
  }
fi

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
# bd_cannot_evaluate <msg> — the ONE refusal path, delegating to the shared
# idiom in workflows/scripts/lib/cannot-evaluate.sh (temperloop#1475): the
# machine verdict on stdout, the distinct human CANNOT EVALUATE line on
# stderr, and now RC_CANNOT_EVALUATE (2) as ITS OWN return status — a caller
# that forgets to branch on it fails closed rather than falling through.
# Every existing caller already follows it with an explicit `return 1` (or
# `return 2` on an arg-parse error), so this changes no observed behavior.
bd_cannot_evaluate() {
  cannot_evaluate_emit "batch.sh" "$1"
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

# bd_trap_signal <SIGNAL-NAME> — the INTERRUPTED path (temperloop#1527), and
# the reason it is a SEPARATE handler from the EXIT one above.
#
# A bash trap handler RETURNS. On EXIT that is exactly right — the shell is
# already leaving. On INT/TERM it is exactly wrong: bash runs the handler and
# then RESUMES the script at the next command, so a single handler registered
# on `EXIT INT TERM` made a ^C or a `kill` tear the in-flight worktree down
# and then calmly start the NEXT leg. On this file — the module's
# spend-bearing entry point, the one thing that calls `replay.sh execute` in a
# loop — that is not cosmetic: the operator's interrupt was the operator
# saying STOP SPENDING, and the batch kept spending.
#
# So the signal arms run the SAME cleanup and then re-raise under the DEFAULT
# disposition, which is what makes the process die with the conventional
# signal-derived status (128+N) rather than an invented exit code — a caller
# (a shell, a supervisor, a CI harness) can then tell "the operator killed it"
# apart from every code in this file's own closed set.
#
# NOTE what is deliberately NOT changed: per-leg failure resilience. A leg
# that genuinely FAILS still records its failure and lets the batch continue
# (the whole point of the resumable-by-leg design) — only an actual signal
# stops the run. Every leg that already reached a terminal state is on disk,
# so re-invoking resumes and re-spends none of them.
bd_trap_signal() {
  local sig="$1" signum
  bd_trap_cleanup
  printf 'batch.sh: INTERRUPTED (SIG%s) — the in-flight replay worktree was torn down and the batch STOPPED before the next leg; legs already in a terminal state are recorded, so re-invoking resumes without re-spending them\n' \
    "$sig" >&2
  # Reset to the default disposition and re-raise, so the process dies OF the
  # signal. EXIT is cleared too: the cleanup above already ran, and letting the
  # EXIT handler fire again during the re-raise would only re-run a no-op.
  trap - EXIT INT TERM
  kill -"$sig" "$$"
  # Reached only if the signal was inherited as IGNORED (a `nohup`-style
  # parent), where `trap -` restores "ignore" rather than "default" and the
  # kill above is a no-op. Stopping is still the answer — with the same
  # signal-derived status, computed rather than hard-coded.
  signum="$(kill -l "$sig" 2>/dev/null)"
  case "$signum" in ''|*[!0-9]*) signum=0 ;; esac
  exit $((128 + signum))
}

trap bd_trap_cleanup EXIT
trap 'bd_trap_signal INT' INT
trap 'bd_trap_signal TERM' TERM

cmd_schema() {
  jq -cn --arg sv "$BATCH_SUMMARY_SCHEMA_VERSION" '{
    schema_version: $sv,
    outcome: null,
    units: null,
    authorized: {records_n:null, replays_n:null, pairs_n:null,
                 estimated_cost:null, cost_basis:null, batch_cap:null},
    selection: {corpus_file:null, corpus_sha256:null, selected_records_n:null, refs:[]},
    legs: {planned_n:null, completed_n:null, resumed_n:null, failed_n:null,
           scored_n:null, integration_error_n:null, not_attempted_n:null},
    circuit_breaker: {basis:null, setting:null, threshold:null, tripped:null,
                      stage:null, consecutive_same_stage_n:null,
                      legs_not_attempted_n:null, records_not_attempted_n:null,
                      not_attempted:[], detail:null},
    completion: {basis:null, replay_completion_rate:null,
                 rate_is_over_a_reconciled_arm:null, rate_caveat:null, per_arm:null},
    failures: [],
    arms: {baseline:{file:null, records_n:null}, candidate:{file:null, records_n:null}},
    pairing: {paired_outcomes_n:null, min_sample_n:null, meets_min_sample:null},
    judge: {ran:null, reason:null, per_arm:null},
    reconciliation: {basis:null, reconciled:null, per_arm:null},
    spend_reconciliation: {basis:null, unit:null, weights_resolved:null,
                           projected_total:null, projected_per_replay:null,
                           projected_basis_mode:null, projected_replays_n:null,
                           observed_total:null, observed_costed_replays_n:null,
                           observed_uncosted_replays_n:null, observed_mean_per_replay:null,
                           coverage_complete:null, ratio_observed_over_projected:null,
                           drift_pct:null, alert_threshold_pct:null, alert_setting:null,
                           drift_alert:null, statement:null},
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

  # The circuit-breaker threshold is read ONCE, here, and validated fail-closed
  # like every other input: a non-integer would otherwise turn every later
  # `[ "$cb_streak" -ge "$cb_threshold" ]` into a shell error the loop swallows,
  # leaving the breaker silently disarmed on a spend-bearing run. 0 is a
  # legitimate value (breaker off); a negative one is not.
  local cb_threshold="$MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS"
  case "$cb_threshold" in
    ''|*[!0-9]*)
      bd_cannot_evaluate "MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS must be a non-negative integer (0 disables the circuit breaker), got \"$cb_threshold\" — refusing to start a spend-bearing batch whose stop condition could not be read"
      return 1 ;;
  esac

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
    # THE CONFIRMATION LINE CARRIES THE PROVENANCE AND THE DISPERSION
    # (temperloop#1555). This is the sentence an operator actually reads
    # before authorizing spend, so it must not hand them a bare point
    # estimate: it names WHERE the per-replay figure came from (derived from
    # n observed records, or the unmeasured configured literal) and, when a
    # distribution exists, what the same batch would cost at the observed
    # p90 and maximum. All of it is read off the gate's own JSON — this
    # driver still computes no estimate of its own.
    local pf_provenance pf_dispersion
    pf_provenance="$(jq -r '
      if .tokens_per_replay_mode == "derived-from-observed-records"
      then "per-replay figure DERIVED from n=" + ((.observed_replay_cost.records_n // 0)|tostring)
           + " observed replays (mean " + ((.tokens_per_replay_estimate // 0)|tostring) + ")"
      else "per-replay figure UNMEASURED on this host — the configured literal ("
           + ((.tokens_per_replay_estimate // 0)|tostring) + ")" end' <<<"$pf_json" 2>/dev/null)"
    pf_dispersion="$(jq -r '
      if (.estimated_total_tokens_range.available // false)
      then "; at the observed p90 the same batch projects "
           + ((.estimated_total_tokens_range.high_total_at_observed_p90 // 0)|tostring)
           + " and at the observed maximum " + ((.estimated_total_tokens_range.high_total_at_observed_max // 0)|tostring)
           + " (observed spread " + ((.estimated_total_tokens_range.observed_spread_ratio // 0)|tostring) + "x) — the projection is a MEAN, not a bound"
      else "; no observed distribution exists on this host, so no range can be shown" end' <<<"$pf_json" 2>/dev/null)"
    bd_stopped "confirmation_required" \
      "the pre-flight gate requires explicit operator confirmation of the estimate above ($(jq -r '.estimated_cost' <<<"$pf_json") $(jq -r '.cost_basis' <<<"$pf_json") over $(jq -r '.planned_replays_n' <<<"$pf_json") executed replays; ${pf_provenance}${pf_dispersion}); re-run with --confirm to authorize it. Nothing was spent" "$pf_json"
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

  # ── THE CIRCUIT BREAKER's running state (temperloop#1554) ──────────────
  # cb_stage/cb_streak are the CURRENT run of same-stage integration errors:
  # cb_stage is the stage they all carry, cb_streak how many in a row. A leg
  # that scores zeroes both; a leg whose stage differs re-keys to that stage
  # at 1. Once cb_tripped flips, no further leg is executed — each remaining
  # one is recorded `not-attempted` instead, which is a statement about THIS
  # RUN and never about the record.
  local cb_streak=0 cb_stage="" cb_tripped=0 cb_trip_stage="" cb_trip_streak=0
  local legs_unattempted=0 records_unattempted=0
  local unattempted_file="$scratch/unattempted.jsonl"; : >"$unattempted_file"

  # Read the selection on fd 3, NOT stdin: every `replay.sh execute` below
  # spawns a candidate runner, and the `--live` arm redirects its own stdin
  # from the prompt file — but a stubbed runner is an arbitrary operator
  # command that may read stdin, and one that did would silently swallow the
  # rest of this loop's selection and truncate the batch.
  while IFS="$(printf '\t')" read -r sel_idx sel_ref sel_rec <&3; do
    [ -n "$sel_idx" ] || continue
    # How many of THIS record's legs the breaker skipped. A record all of
    # whose legs were skipped was never attempted at all in this run, which
    # is the count an operator needs to size what a resume still owes.
    local rec_skipped=0
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
        # A `not-attempted` leg (temperloop#1554) is ALWAYS retryable, with or
        # without --retry-failed: --retry-failed exists to protect a leg that
        # may have failed AFTER the candidate ran from a blind re-spend, and a
        # leg the circuit breaker skipped never ran at all. There is nothing to
        # protect, so a plain resume re-drives it.
        [ "$prev_state" = "not-attempted" ] && retryable=1
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

      # ── THE CIRCUIT BREAKER HAS TRIPPED (temperloop#1554) ─────────────
      # Deliberately AFTER the resume block above: a leg that already reached
      # a terminal state in an earlier run keeps that state — the breaker
      # never overwrites recorded work — and only a leg this run would have
      # EXECUTED is recorded not-attempted. Nothing is prepared and nothing is
      # spent from here on; the loop keeps walking purely so every remaining
      # leg gets its `not-attempted` record rather than silently vanishing.
      if [ "$cb_tripped" -eq 1 ]; then
        jq -cn --arg stage "$cb_trip_stage" --argjson n "$cb_trip_streak" \
          '{state:"not-attempted",
            reason:("the circuit breaker tripped earlier in this batch after " + ($n|tostring)
                    + " consecutive \"" + $stage + "\" integration errors, so this leg was NEVER EXECUTED. This is not a claim that this record is incompatible — nothing was attempted, nothing was spent, and a resume re-drives it"),
            stage:null}' >"$leg_state"
        rm -f "$leg_rec"
        legs_unattempted=$((legs_unattempted + 1))
        rec_skipped=$((rec_skipped + 1))
        jq -cn --arg a "$arm" --arg r "$sel_ref" \
          '{arm:$a, outcome_ref:$r}' >>"$unattempted_file"
        printf 'batch.sh: [%s/%s] %s %s — NOT ATTEMPTED (circuit breaker tripped); nothing spent, a resume re-drives it\n' \
          "$sel_idx" "$idx" "$arm" "$sel_ref" >&2
        continue
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
        jq -cn '{state:"scored", reason:null, stage:null}' >"$leg_state"
        legs_done=$((legs_done + 1)); legs_scored=$((legs_scored + 1))
        # A success is the one thing that proves the spawn path is alive, so
        # it zeroes the breaker's streak outright (temperloop#1554).
        cb_streak=0; cb_stage=""
        printf 'batch.sh: [%s/%s] %s %s — scored\n' "$sel_idx" "$idx" "$arm" "$sel_ref" >&2
      elif [ "$x_rc" -eq 4 ] && [ "$have_record" -eq 1 ]; then
        # The STAGE comes off the record replay.sh just wrote — its own
        # vocabulary, read rather than re-derived, so the breaker keys on the
        # same word the record and the report producer already use.
        local ie_stage
        ie_stage="$(jq -r '.candidate.integration_error.stage // ""' <"$leg_rec" 2>/dev/null)"
        [ -n "$ie_stage" ] || ie_stage="unknown"
        jq -cn --arg r "$(head -c 400 "$x_err" 2>/dev/null)" --arg s "$ie_stage" \
          '{state:"integration-error", reason:$r, stage:$s}' >"$leg_state"
        legs_done=$((legs_done + 1)); legs_interr=$((legs_interr + 1))
        if [ "$ie_stage" = "$cb_stage" ]; then
          cb_streak=$((cb_streak + 1))
        else
          cb_stage="$ie_stage"; cb_streak=1
        fi
        printf 'batch.sh: [%s/%s] %s %s — integration error (stage %s, %s in a row; a record WAS produced); the batch continues\n' \
          "$sel_idx" "$idx" "$arm" "$sel_ref" "$ie_stage" "$cb_streak" >&2
        if [ "$cb_threshold" -gt 0 ] && [ "$cb_streak" -ge "$cb_threshold" ]; then
          cb_tripped=1; cb_trip_stage="$cb_stage"; cb_trip_streak="$cb_streak"
          printf 'batch.sh: CIRCUIT BREAKER TRIPPED — %s consecutive "%s" integration errors reached the threshold MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS (%s). The spawn path looks systemically unavailable, not the records incompatible, so this batch STOPS here instead of running the rest of the corpus out against it. Every remaining leg is recorded not-attempted and a resume re-drives it once the cause is cleared\n' \
            "$cb_streak" "$cb_stage" "$cb_threshold" >&2
        fi
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
    # A record NONE of whose legs were attempted — the unit an operator sizes
    # a resume in. A record whose first arm ran and whose second was skipped
    # is deliberately NOT counted here: it was partially attempted, and
    # legs_not_attempted_n already carries that leg.
    if [ "$rec_skipped" -eq "$BATCH_ARMS_N" ]; then
      records_unattempted=$((records_unattempted + 1))
    fi
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
  # The LEG-RECORD CENSUS this step assembles from is snapshotted per arm as
  # it is written — a count plus the identity of every leg record that went
  # in. STEP 5's judge pass REWRITES the arm file in place, so this snapshot
  # is the only "what did we actually count" the reconciliation below (STEP
  # 5.5, temperloop#1556) can hold the rewritten file against.
  for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
    local tmp_arm="$scratch/$arm.jsonl"; : >"$tmp_arm"
    local census="$scratch/$arm.legs.census"; : >"$census"
    while IFS="$(printf '\t')" read -r sel_idx sel_ref sel_rec; do
      [ -n "$sel_idx" ] || continue
      local f
      f="$state_dir/legs/$arm/$(printf '%03d' "$sel_idx")-$(bd_slugify "$sel_ref").json"
      if [ -s "$f" ] && jq -e 'type=="object"' >/dev/null 2>&1 <"$f"; then
        jq -c . <"$f" >>"$tmp_arm"
        jq -r 'if (.pr // null) != null then "pr:\(.pr)" elif (.issue // null) != null then "issue:\(.issue)" else "unref" end' \
          <"$f" >>"$census"
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
  if [ "$cb_tripped" -eq 1 ]; then
    # The breaker tripped because the spawn seam went systemically
    # unavailable — and the judge pass runs through that SAME seam. Judging
    # now would hammer the endpoint that just stopped answering, which is the
    # behaviour temperloop#1554 exists to end. So it is skipped, and NAMED
    # (never silent — a skipped judge is a fact this file always states). A
    # resume judges the arms once the cause is cleared, since the judge pass
    # is keyed on the arm file's own sha256 and re-spends nothing already done.
    judge_json="$(jq -cn --arg stage "$cb_trip_stage" \
      '{ran:false, degraded:false,
        reason:("SKIPPED — the circuit breaker tripped on consecutive \"" + $stage
                + "\" integration errors, and the judge pass spawns through the same seam that just went systemically unavailable. Judging now would re-hammer it. The arm files are written UNJUDGED; re-run this batch once the cause is cleared and the judge pass will run over them without re-spending any replay"),
        per_arm:null}')"
  elif [ "$live" -eq 0 ] && [ -z "$judge_runner" ]; then
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
  # STEP 5.5 — RECONCILE the arm file this driver WROTE against the leg
  # records it COUNTED (temperloop#1556).
  #
  # Every count this driver publishes — replay_completion_rate, legs.*,
  # arms.*.records_n — is derived from the LEG state files, which are
  # written once and never touched again. The ARM FILE, by contrast, is
  # rewritten in place by STEP 5's judge pass. Nothing reconciled the two,
  # and on the first live batch that gap was load-bearing: judge-batch
  # replaced 14 of 21 records per arm with bare error objects while this
  # driver reported `replay_completion_rate: 1` and 21 records per arm off
  # the intact legs. The summary read healthy over an arm file that was
  # already destroyed, and the operator learned otherwise only when the
  # report producer refused to render.
  #
  # So: a completion rate is only trustworthy if the artifact it describes
  # still holds what was counted. Three checks per arm, all against the
  # STEP-4 census — record count, per-record identity, and SHAPE (a line
  # that is not an object carrying `.candidate` is not a replay record at
  # all, which is exactly the corruption signature). A mismatch is a NAMED
  # degradation, never a silently-clean rate.
  # ═════════════════════════════════════════════════════════════════════
  local recon_file="$scratch/reconciliation.jsonl"; : >"$recon_file"
  local arms_reconciled=1
  for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
    local recon_arm_file="$out_dir/$arm.jsonl"
    local census="$scratch/$arm.legs.census"
    local arm_refs="$scratch/$arm.arm.refs"
    local legs_n=0 arm_n=0 foreign_n=0 missing_n=0 rline
    [ -f "$census" ] || : >"$census"
    legs_n="$(grep -c . "$census" 2>/dev/null || true)"; case "$legs_n" in ''|*[!0-9]*) legs_n=0 ;; esac
    arm_n="$(grep -c . "$recon_arm_file" 2>/dev/null || true)"; case "$arm_n" in ''|*[!0-9]*) arm_n=0 ;; esac
    : >"$arm_refs"
    if [ -s "$recon_arm_file" ]; then
      while IFS= read -r rline; do
        [ -n "$rline" ] || continue
        if jq -e 'type=="object" and ((.candidate | type) == "object")' >/dev/null 2>&1 <<<"$rline"; then
          jq -r 'if (.pr // null) != null then "pr:\(.pr)" elif (.issue // null) != null then "issue:\(.issue)" else "unref" end' \
            <<<"$rline" >>"$arm_refs"
        else
          foreign_n=$((foreign_n + 1))
        fi
      done <"$recon_arm_file"
    fi
    sort "$census" >"$scratch/$arm.census.sorted"
    sort "$arm_refs" >"$scratch/$arm.arm.sorted"
    comm -23 "$scratch/$arm.census.sorted" "$scratch/$arm.arm.sorted" >"$scratch/$arm.missing" 2>/dev/null || : >"$scratch/$arm.missing"
    missing_n="$(grep -c . "$scratch/$arm.missing" 2>/dev/null || true)"; case "$missing_n" in ''|*[!0-9]*) missing_n=0 ;; esac
    local missing_refs_json
    missing_refs_json="$(jq -R -s 'split("\n") | map(select(length > 0))' <"$scratch/$arm.missing" 2>/dev/null)"
    [ -n "$missing_refs_json" ] || missing_refs_json='[]'
    local arm_ok=true
    if [ "$arm_n" -ne "$legs_n" ] || [ "$foreign_n" -gt 0 ] || [ "$missing_n" -gt 0 ]; then
      arm_ok=false
      arms_reconciled=0
    fi
    jq -cn --arg a "$arm" --argjson legs "$legs_n" --argjson recs "$arm_n" \
      --argjson foreign "$foreign_n" --argjson missing "$missing_n" \
      --argjson missing_refs "$missing_refs_json" --argjson ok "$arm_ok" \
      '{arm:$a, leg_records_counted_n:$legs, arm_records_n:$recs,
        foreign_records_n:$foreign, missing_n:$missing, missing_refs:$missing_refs,
        reconciled:$ok,
        detail: (if $ok
                 then "the arm file on disk carries exactly the leg records this driver counted"
                 else ("MISMATCH: the arm file on disk does NOT carry what this driver counted — "
                       + ($legs|tostring) + " leg record(s) assembled, " + ($recs|tostring)
                       + " line(s) in the arm file, " + ($foreign|tostring)
                       + " of which are not replay records at all (no .candidate), and "
                       + ($missing|tostring)
                       + " counted record(s) are absent from it. The completion figures below are computed off the LEG records and must NOT be read as a clean run over this arm file") end)}' \
      >>"$recon_file"
  done
  local reconciliation_json recon_ok=true
  [ "$arms_reconciled" -eq 1 ] || recon_ok=false
  reconciliation_json="$(jq -cs --argjson ok "$recon_ok" \
    '{basis: "the arm files this driver WROTE, checked line by line against the leg records it COUNTED (count, per-record identity, and record shape). The judge pass rewrites an arm file in place, so a healthy-looking completion rate derived from the intact leg records can otherwise sit beside an arm file that no longer holds them",
      reconciled: $ok, per_arm: .}' <"$recon_file")"

  # ═════════════════════════════════════════════════════════════════════
  # STEP 5.6 — RECONCILE THE SPEND: PROJECTED vs OBSERVED (temperloop#1555).
  #
  # STEP 5.5 above reconciles the COUNTS this driver published against the
  # artifact on disk. This one reconciles the MONEY: the spend the operator
  # AUTHORIZED at the gate against the spend the run actually INCURRED.
  #
  # Nothing did this before, and the gap was load-bearing. The gate's
  # per-replay figure was an n=1 literal; the first live batch executed 14
  # real replays that came in 1.49x above it; the projection and the outturn
  # sat in two different places and nothing ever put them side by side, so
  # the only way to notice was for a human to sum the raw lake by hand. A
  # projection that is never checked against outturn cannot drift-correct,
  # and since the projection is what the ceiling check and the operator
  # confirmation are computed from, an uncorrected drift understates the
  # margin on every future batch by the same factor.
  #
  # THE OBSERVED FIGURE IS COMPUTED FROM THE ARM RECORDS THIS RUN PRODUCED,
  # not from the lake: the arm files are scoped to exactly this batch, carry
  # the same `candidate.tokens` blocks the comparison report prices, and are
  # already on disk. The weighting is the SPEND_WEIGHT_* multiply-add — the
  # same expression, in the same unit (the gate's own `cost_basis`), as
  # report-producers/model-comparison and emit-model-usage.sh use, so the
  # three surfaces cannot disagree about what a "token" is.
  #
  # A DRIFT ALERT IS NOT A DEGRADATION. Beyond
  # MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT in either direction this raises
  # `drift_alert` and prints a stderr notice — but it never adds a
  # degradation and never changes `outcome`. A wrong projection is a fact
  # about the ESTIMATE, not a defect in the batch that just completed;
  # turning a clean BATCH_COMPLETE into a BATCH_DEGRADED because the
  # forecast was off would be reporting the wrong thing about the wrong
  # artifact.
  #
  # A record with NO token block contributes NOTHING and is counted in
  # `observed_uncosted_replays_n` rather than as a zero — a missing
  # measurement is not a measurement of zero (the report producer's own
  # rule) — and `coverage_complete` says outright whether the observed total
  # covers every replay the projection was over, so a partial-coverage ratio
  # can never be read as a whole-batch drift figure.
  # ═════════════════════════════════════════════════════════════════════
  local spend_recon_json spend_drift_alert=0
  # A non-integer alert threshold DISABLES the alert rather than breaking the
  # reconciliation: the figures are the point of this block, and a malformed
  # tunable must not cost the operator the projected-vs-observed comparison
  # itself.
  local drift_alert_pct="${MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT:-0}"
  case "$drift_alert_pct" in ''|*[!0-9]*) drift_alert_pct=0 ;; esac
  spend_recon_json="$(
    jq -n \
      --slurpfile b "$base_file" --slurpfile c "$cand_file" \
      --argjson pf "$pf_json" \
      --arg w_in "${SPEND_WEIGHT_INPUT-}" --arg w_cr "${SPEND_WEIGHT_CACHE_READ-}" \
      --arg w_cc "${SPEND_WEIGHT_CACHE_CREATE-}" --arg w_out "${SPEND_WEIGHT_OUTPUT-}" \
      --argjson alert_pct "$drift_alert_pct" '
      def num: (try (tonumber) catch null);
      ($w_in | num) as $wi | ($w_cr | num) as $wcr
      | ($w_cc | num) as $wcc | ($w_out | num) as $wo
      | (($wi != null) and ($wcr != null) and ($wcc != null) and ($wo != null)) as $weights_ok
      | ($b + $c) as $recs
      | ($recs | map(select(((.candidate // {}).tokens | type) == "object"))) as $costed
      | (if $weights_ok
         then ($costed | map((((.candidate.tokens.input // 0) * $wi)
                            + ((.candidate.tokens.cache_read // 0) * $wcr)
                            + ((.candidate.tokens.cache_creation // 0) * $wcc)
                            + ((.candidate.tokens.output // 0) * $wo)) | floor) | add // 0)
         else null end) as $observed
      | ($pf.estimated_cost // null) as $projected
      | (if $observed == null or $projected == null or $projected == 0 then null
         else ((($observed / $projected) * 1000) | round) / 1000 end) as $ratio
      | (if $ratio == null then null else ((($ratio - 1) * 1000) | round) / 10 end) as $drift_pct
      | (($costed | length) == ($pf.planned_replays_n // -1)) as $complete
      | {basis: "the spend the operator AUTHORIZED at the pre-flight gate, put beside the spend this run actually INCURRED. Projected is the gate figure verbatim (this driver computes no estimate of its own). Observed is the SPEND_WEIGHT_* multiply-add over every arm record that carries a token block, both arms, in the cost_basis unit the gate published — the same expression report-producers/model-comparison prices with. A record with no token block contributes NOTHING and is counted uncosted, never as a zero",
         unit: ($pf.cost_basis // null),
         weights_resolved: $weights_ok,
         projected_total: $projected,
         projected_per_replay: ($pf.tokens_per_replay_estimate // null),
         projected_basis_mode: ($pf.tokens_per_replay_mode // null),
         projected_replays_n: ($pf.planned_replays_n // null),
         observed_total: $observed,
         observed_costed_replays_n: ($costed | length),
         observed_uncosted_replays_n: (($recs | length) - ($costed | length)),
         observed_mean_per_replay:
           (if $observed == null or ($costed | length) == 0 then null
            else (($observed / ($costed | length)) | floor) end),
         coverage_complete: $complete,
         ratio_observed_over_projected: $ratio,
         drift_pct: $drift_pct,
         alert_threshold_pct: $alert_pct,
         alert_setting: "MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT",
         drift_alert: (if $drift_pct == null or $alert_pct == 0 then false
                       else (($drift_pct | fabs) > $alert_pct) end),
         statement:
           (if $observed == null then "the SPEND_WEIGHT_* settings did not resolve, so no observed cost could be computed in the unit the gate authorized this batch in — refusing to state a figure in an undefined unit rather than printing one"
            elif ($costed | length) == 0 then "no arm record carries a token block, so this run produced no observed spend to reconcile the projection against"
            elif $ratio == null then "the gate published no projected cost to reconcile against"
            else (("this run was PROJECTED at " + ($projected|tostring) + " and OBSERVED at " + ($observed|tostring)
                   + " (" + ($ratio|tostring) + "x, " + ($drift_pct|tostring) + "% drift), over "
                   + (($costed | length)|tostring) + " costed of " + (($pf.planned_replays_n // 0)|tostring)
                   + " projected executed replays")
                  + (if $complete then "" else ". COVERAGE IS PARTIAL — the observed total does not cover every replay the projection was over, so read the ratio as a floor, not as a whole-batch drift figure" end)
                  + (if ($drift_pct != null and $alert_pct != 0 and (($drift_pct | fabs) > $alert_pct))
                     then ". This exceeds MODEL_COMPARISON_SPEND_DRIFT_ALERT_PCT: the per-replay estimate the gate authorizes batches with is out of date against what replays now actually cost" else "" end)) end)}
    ' 2>/dev/null)"
  if [ -z "$spend_recon_json" ] || ! jq -e 'type=="object"' >/dev/null 2>&1 <<<"$spend_recon_json"; then
    spend_recon_json="$(jq -cn '{basis:"projected vs observed spend for this run", unit:null, weights_resolved:false,
      projected_total:null, observed_total:null, drift_alert:false,
      statement:"the projected-vs-observed spend reconciliation could not be computed — neither figure is being asserted"}')"
  fi
  [ "$(jq -r '.drift_alert // false' <<<"$spend_recon_json" 2>/dev/null)" = "true" ] && spend_drift_alert=1

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

  # ── THE CIRCUIT-BREAKER VERDICT (temperloop#1554) ─────────────────────
  # Published on EVERY run, tripped or not, so "the breaker was armed and did
  # not fire" is a positive statement in the summary rather than an absence a
  # reader has to infer. When it did fire, this block is what tells the
  # operator that the run ENDED EARLY rather than ran out of corpus — the
  # stage that kept failing, how many in a row, and how much was never
  # attempted (in legs AND in whole records).
  local cb_tripped_json=false
  [ "$cb_tripped" -eq 1 ] && cb_tripped_json=true
  local circuit_breaker_json
  circuit_breaker_json="$(jq -cn \
    --argjson tripped "$cb_tripped_json" --argjson threshold "$cb_threshold" \
    --arg setting "MODEL_COMPARISON_BATCH_MAX_CONSECUTIVE_STAGE_ERRORS" \
    --arg stage "$cb_trip_stage" --argjson streak "$cb_trip_streak" \
    --argjson legs_na "$legs_unattempted" --argjson recs_na "$records_unattempted" \
    --slurpfile not_attempted "$unattempted_file" \
    '{basis: "consecutive integration errors carrying the SAME integration_error.stage, counted over the legs THIS invocation executed. Any leg that scores resets the run to zero; a different stage re-keys it to 1; a resumed leg is evidence about a previous run and is not counted. So a scatter of unrelated per-record incompatibilities cannot trip it, and a spawn path that has gone systemically unavailable does",
      setting: $setting, threshold: $threshold, armed: ($threshold > 0),
      tripped: $tripped,
      stage: (if $stage == "" then null else $stage end),
      consecutive_same_stage_n: $streak,
      legs_not_attempted_n: $legs_na,
      records_not_attempted_n: $recs_na,
      not_attempted: $not_attempted,
      detail: (if $tripped
               then ("STOPPED EARLY: " + ($streak|tostring) + " consecutive \"" + $stage
                     + "\" integration errors reached the threshold, so " + ($legs_na|tostring)
                     + " further executed replay(s) — " + ($recs_na|tostring)
                     + " corpus record(s) entirely — were NEVER ATTEMPTED. They are recorded not-attempted, NOT as integration errors: nothing was spent on them and no claim is being made that those records are incompatible. Re-run this batch against the same --state-dir once the cause is cleared and they will be driven without re-spending anything already done"
                     )
               elif $threshold == 0
               then "the circuit breaker is DISABLED (threshold 0): this run would have executed every planned leg however many consecutive integration errors it hit"
               else "the circuit breaker was armed and did not fire: no run of consecutive same-stage integration errors reached the threshold, so every planned leg was attempted and this batch ended because the corpus was exhausted" end)}')"

  local degradations="$scratch/degradations.jsonl"; : >"$degradations"
  [ "$cb_tripped" -eq 1 ] && jq -cn --arg stage "$cb_trip_stage" \
    --argjson legs_na "$legs_unattempted" --argjson recs_na "$records_unattempted" \
    '{kind:"circuit_breaker_tripped",
      detail:("the batch STOPPED EARLY on consecutive \"" + $stage + "\" integration errors — "
              + ($legs_na|tostring) + " executed replay(s) across " + ($recs_na|tostring)
              + " never-attempted corpus record(s) were skipped. This is NOT a completed-but-degraded batch: the corpus was not exhausted, and the skipped legs make no compatibility claim about their records. See circuit_breaker")}' \
    >>"$degradations"
  [ "$legs_failed" -gt 0 ] && jq -cn --argjson n "$legs_failed" \
    '{kind:"leg_failures", detail:("\($n) of the planned executed replays did not produce a record; each is named in failures[] with its reason")}' >>"$degradations"
  [ "$judge_degraded" -eq 1 ] && jq -cn \
    '{kind:"judge_degraded", detail:"at least one arm did not reach a clean JUDGED pass; see judge.per_arm"}' >>"$degradations"
  [ "$arms_reconciled" -eq 0 ] && jq -cn \
    '{kind:"arm_reconciliation_mismatch", detail:"at least one arm file on disk does not carry the leg records this driver counted — see reconciliation.per_arm. The completion figures in this summary are derived from the LEG records and must NOT be read as a clean run over that arm file"}' >>"$degradations"
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
    --argjson legs_unattempted "$legs_unattempted" \
    --argjson circuit_breaker "$circuit_breaker_json" \
    --argjson rate "$rate" \
    --slurpfile failures "$failures_file" \
    --slurpfile degradations "$degradations" \
    --arg base_file "$base_file" --arg cand_file "$cand_file" \
    --argjson base_n "$base_n" --argjson cand_n "$cand_n" --argjson paired_n "$paired_n" \
    --argjson min_sample_n "$MODEL_COMPARISON_MIN_SAMPLE_N" \
    --argjson judge "$judge_json" \
    --argjson reconciliation "$reconciliation_json" \
    --argjson spend_reconciliation "$spend_recon_json" \
    --argjson vcp "$vcp_json" --arg vcp_outcome "$vcp_outcome" --argjson swept "$swept" \
    --arg base_arm "$BATCH_ARM_BASELINE" --arg cand_arm "$BATCH_ARM_CANDIDATE" \
    '{schema_version:$sv,
      outcome: (if $circuit_breaker.tripped then "BATCH_STOPPED_EARLY"
                elif (($legs_failed > 0) or (($degradations | length) > 0)) then "BATCH_DEGRADED"
                else "BATCH_COMPLETE" end),
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
            failed_n:$legs_failed, scored_n:$legs_scored, integration_error_n:$legs_interr,
            not_attempted_n:$legs_unattempted},
      circuit_breaker: $circuit_breaker,
      completion:{
        basis: "an executed replay COMPLETED when it produced a record — a scored record OR an integration-error record, both of which the comparison report consumes (the latter as a compatibility fact, never a quality one). A leg that produced no record at all is counted as failed and named in failures[]. A leg the CIRCUIT BREAKER skipped is neither: it is legs.not_attempted_n, and it is why the rate on a BATCH_STOPPED_EARLY run is low without any record having been found incompatible — read circuit_breaker before reading this rate as a quality signal",
        replay_completion_rate:$rate,
        legs_not_attempted_n:$legs_unattempted,
        rate_is_over_a_reconciled_arm: $reconciliation.reconciled,
        rate_caveat: (if $reconciliation.reconciled then null else "this rate is computed off the LEG records, and reconciliation[] reports that at least one arm file no longer carries them — do NOT read it as a clean run over that arm file" end),
        per_arm:{($base_arm): {records_n:$base_n}, ($cand_arm): {records_n:$cand_n}}},
      failures: $failures,
      arms:{($base_arm): {file:$base_file, records_n:$base_n},
            ($cand_arm): {file:$cand_file, records_n:$cand_n}},
      pairing:{
        basis: "outcome refs present in BOTH arm files — the same intersection workflows/scripts/report-producers/model-comparison computes, reported here so the operator can see the comparison'"'"'s real N without opening the report",
        paired_outcomes_n:$paired_n, min_sample_n:$min_sample_n,
        meets_min_sample: ($paired_n >= $min_sample_n)},
      judge: $judge,
      reconciliation: $reconciliation,
      spend_reconciliation: $spend_reconciliation,
      isolation:{verify_clean_parent:$vcp_outcome, verify_clean_parent_detail:$vcp,
                 worktrees_swept_n:$swept},
      degradations: $degradations,
      preflight: $pf}'

  rm -rf "$scratch"

  if [ "$arms_reconciled" -eq 0 ]; then
    printf 'batch.sh: ARM RECONCILIATION MISMATCH — an arm file on disk does not carry the leg records this driver counted; see reconciliation.per_arm. The completion rate below is over the LEG records, NOT over that arm file\n' >&2
  fi
  # The spend-drift notice (temperloop#1555) — stderr, alongside the summary,
  # NEVER a degradation and never a non-zero exit: the projection being wrong
  # says nothing about whether this batch ran correctly.
  if [ "$spend_drift_alert" -eq 1 ]; then
    printf 'batch.sh: SPEND DRIFT — %s (see spend_reconciliation)\n' \
      "$(jq -r '.statement // "projected and observed spend diverge"' <<<"$spend_recon_json" 2>/dev/null)" >&2
  fi
  # BATCH_STOPPED_EARLY takes precedence over BATCH_DEGRADED and gets its OWN
  # code: a degraded batch ran the corpus out, this one did not, and a caller
  # that cannot tell them apart cannot tell "some records are incompatible"
  # from "the endpoint stopped answering" (temperloop#1554).
  if [ "$cb_tripped" -eq 1 ]; then
    printf 'batch.sh: BATCH STOPPED EARLY — the circuit breaker tripped on %s consecutive "%s" integration errors; %s executed replay(s) across %s never-attempted corpus record(s) were skipped and are recorded not-attempted, NOT as integration errors. %s of %s planned executed replays completed. Re-run against the same --state-dir once the cause is cleared to drive the remainder without re-spending anything\n' \
      "$cb_trip_streak" "$cb_trip_stage" "$legs_unattempted" "$records_unattempted" \
      "$legs_done" "$legs_planned" >&2
    return 5
  fi
  if [ "$legs_failed" -gt 0 ] || [ "$judge_degraded" -eq 1 ] || [ "$vcp_outcome" != "CLEAN" ] \
     || [ "$arms_reconciled" -eq 0 ]; then
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
