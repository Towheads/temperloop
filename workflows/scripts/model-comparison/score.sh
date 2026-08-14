#!/usr/bin/env bash
#
# score.sh — replay SCORING (temperloop#1258, epic #1225 "model comparison
# harness"). The second half of the replay pair: replay.sh owns corpus
# selection, isolation, the spend gate and (as of this item) EXECUTION;
# this file owns turning "a candidate worktree, a base, and merged truth"
# into the `score` sub-object of the versioned `replay-record-v1` record
# replay.sh's own `schema` prints.
#
# ── WHAT THIS FILE DELIBERATELY DOES NOT DO ────────────────────────────────
#   * It does NOT reimplement gate logic. `gates` below RUNS
#     scripts/quality-gates.sh — and specifically the copy INSIDE the
#     candidate's own base worktree ($WT/scripts/quality-gates.sh, the path
#     named by $REPLAY_SCORE_GATE_RELPATH), never today's tree's copy. That
#     is the keystone spike's trap-C disposition, stated there as "never mix
#     trees": a historical item's tree carries its own gate-paths.tsv and its
#     own gate list, and invoking today's gate script against it measures
#     five days of gate drift instead of the model
#     (Context/temperloop - replay ground-truth seam.md, trap C).
#   * It does NOT judge acceptance bullets. The spike's own 40-vs-38 finding
#     ("the scorer must NOT hard-assert an acceptance bullet's literal
#     numbers — it asserts the bullet's SHAPE") means a mechanical scorer
#     cannot honestly grade them. `acceptance_results` below therefore
#     carries every criterion VERBATIM plus a per-criterion
#     `carries_literal_numbers` flag and `mechanically_scored: false` — an
#     honest hand-off to a judge, never a fabricated grade. The mechanical
#     outcome scorer is quality-gates.sh plus the diff-scope partition; that
#     boundary is deliberate and is why this file grades neither.
#   * It does NOT spawn a model. Nothing here reaches a network.
#
# ── THE DIFF-SCOPE RULE IS TAKEN FROM THE SPIKE, NOT RE-DERIVED ────────────
# The N/T/X/R partition itself is computed by `replay.sh diff-scope` and
# arrives here inside the corpus record's `buckets` object. This file applies
# the spike's SCORING treatment for each bucket:
#
#   N (solution surface, named in the pre-cut issue text) — SCORED. Per path:
#     did the candidate change it at all, and does the candidate's resulting
#     file content match merged truth's byte-for-byte. Diffs are taken with
#     `--ignore-all-space --ignore-blank-lines` (trap B's disposition), and a
#     path whose TRUTH diff is non-empty raw but empty under those flags is
#     flagged `formatting-only-churn` — trap B, detected rather than assumed
#     absent.
#   T (test surface) — scored on PRESENCE + PASS, never bytes. "There are
#     many correct regression tests; byte-diffing them scores style, not
#     capability." Presence is computed here; PASS is the gate result below.
#   X (policy churn) — NEUTRAL. Recorded, never credited or penalized.
#   R (residue) — FLAGGED only. A record whose R held unnamed CODE was
#     already rejected at corpus time; md-only residue rides a flag.
#
# ── FAIL-CLOSED (temperloop#1365 class) ────────────────────────────────────
# "I could not evaluate this" is NEVER reported as "I evaluated it and it is
# fine". Every command below prints `{"outcome":"CANNOT_EVALUATE",...}` on
# stdout AND a distinct `score.sh: CANNOT EVALUATE — …` line on stderr, and
# exits NON-ZERO, when it cannot resolve a ref, read the record, reach the
# worktree, or run the gate script. It NEVER emits a partial score computed
# from the half it could read. A genuine "scored, and the candidate failed"
# is a completely different state: outcome SCORED, verdict "fail", exit 0.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#   score.sh score --repo-root <path> --candidate-worktree <path> \
#       --record <corpus-record-json-file> [--gate-relpath <rel>]
#       Emits {"outcome":"SCORED", ...the score sub-object...}. Base and
#       merged-truth head are read from the record's own `base`/`head`
#       fields — never re-resolved here, so the scorer and the corpus can
#       never disagree about which tree is truth. Exit 0 whether the verdict
#       is pass or fail; non-zero only when it could not score.
#
#   score.sh gates --worktree <path> [--gate-relpath <rel>]
#       Runs the worktree's OWN gate entry point under a bounded timeout and
#       reports {"outcome":"GATES", exit_code, passed, timed_out, ...}. Exit
#       0 when the gate RAN (whatever its verdict); non-zero (CANNOT_EVALUATE)
#       when the worktree or the gate script is absent/unreadable, i.e. when
#       "the gate failed" and "there was no gate to run" would otherwise be
#       indistinguishable.
#
#   score.sh aggregate --records-file <jsonl>
#       Rolls a JSONL file of executed replay records into the two-metric
#       summary the item's acceptance requires: a QUALITY block computed
#       over scored records only, and a separate COMPATIBILITY block for
#       integration errors. An `integration-error` record is EXCLUDED from
#       every quality figure (scored_n, pass_n, fail_n, pass_rate) by
#       construction — a vendor integration failure is never read as a model
#       quality failure. Fail-closed on absent/unreadable/empty/malformed
#       input.
#
# Every tunable below is a registered setting (workflows/scripts/config/
# setting-registry.tsv) defaulted in workflows/scripts/build/build.config.sh
# — named symbolically, never re-valued in prose. The `:=` fallbacks here are
# this file's own non-vendoring-caller layer-6 default, matching that
# registry exactly.
#
# Kept POSIX-bash-3.2-friendly (no mapfile, no associative arrays, no GNU-only
# flags) — macOS dev shell + Linux CI.

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"CANNOT_EVALUATE","error":"jq not found"}'; echo "score.sh: CANNOT EVALUATE — jq not found" >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"
: "${REPLAY_SCORE_GATE_RELPATH:=scripts/quality-gates.sh}"
: "${REPLAY_SCORE_GATE_TIMEOUT_SECS:=1800}"

# shellcheck source=../lib/portable-timeout.sh
[ -f "$HERE/../lib/portable-timeout.sh" ] && . "$HERE/../lib/portable-timeout.sh"
if ! command -v run_with_timeout >/dev/null 2>&1; then
  # Defensive only — portable-timeout.sh ships alongside this file in every
  # kernel install; this degrades to an unbounded call rather than aborting.
  run_with_timeout() { shift; "$@"; }
fi

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

usage() {
  cat <<'EOF' >&2
usage: score.sh score --repo-root <path> --candidate-worktree <path> --record <file> [--gate-relpath <rel>]
       score.sh gates --worktree <path> [--gate-relpath <rel>]
       score.sh aggregate --records-file <jsonl>
EOF
}

# ── fail-closed emission — delegates to the shared idiom in
#    workflows/scripts/lib/cannot-evaluate.sh (temperloop#1475): the machine
#    verdict on stdout, the distinct human line on stderr, and now
#    RC_CANNOT_EVALUATE (2) as ITS OWN return status — a caller that forgets
#    to branch on it fails closed rather than falling through. Every
#    existing caller already follows it with an explicit `return 1`, so this
#    changes no observed behavior.
cannot_evaluate() {
  cannot_evaluate_emit "score.sh" "$1"
}

need_operand() {
  [ "$2" -ge 2 ] && case "${3:-}" in
    --*) printf 'score.sh: %s requires a value, got flag-like %s\n' "$1" "$3" >&2; return 2 ;;
    *) return 0 ;;
  esac
  printf 'score.sh: %s requires a value\n' "$1" >&2
  return 2
}

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# ONE scratch dir, removed on every exit path (including a fail-closed
# early return) — never a per-file rm the next early return can skip.
_SCORE_TMPDIR=""
_score_cleanup() { [ -n "$_SCORE_TMPDIR" ] && rm -rf "$_SCORE_TMPDIR"; return 0; }
trap _score_cleanup EXIT
# scratch <name> — prints a path inside the scratch dir, creating the dir on
# first use. Returns non-zero (and prints nothing) if the dir cannot be made.
scratch() {
  if [ -z "$_SCORE_TMPDIR" ]; then
    _SCORE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/replay-score.XXXXXX")" || { _SCORE_TMPDIR=""; return 1; }
  fi
  printf '%s/%s\n' "$_SCORE_TMPDIR" "$1"
}

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# is_test_path <path> — byte-identical to replay.sh's own definition (the
# spike's T bucket: `*/tests/*` or `test_*`). Duplicated rather than sourced
# because replay.sh is a CLI, never a sourceable library (its dispatch runs
# on source); the two definitions are asserted equal by the fixture suite.
is_test_path() {
  case "$1" in
    */tests/*|test_*|*/test_*) return 0 ;;
    *) return 1 ;;
  esac
}

# sum_numstat — reads `git diff --numstat` output on stdin and prints
# "<added> <removed>" summed across every line. A binary file's `-` counts
# as 0 on both axes.
sum_numstat() {
  awk '{ a = ($1 == "-" ? 0 : $1); r = ($2 == "-" ? 0 : $2); A += a; R += r }
       END { printf "%d %d\n", A + 0, R + 0 }'
}

# ── gates ─────────────────────────────────────────────────────────────────

# ── The gate child's environment allowlist (temperloop#1378/#1377) ────────
# THE DEFECT this closes: line ~102 above sources build.config.sh for THIS
# script's own two settings, and that file's tail `export`s ~83 pipeline
# settings — after first sourcing the operator's machine conf (precedence
# layer 3) and repo-local conf (layer 4). Before this allowlist the gate
# child simply INHERITED all of them, with two measured consequences:
#
#   * the PRIMARY symptom (#1378): a leaked setting outranks every lower
#     layer inside the child, because build.config.sh's `:=` idiom makes an
#     already-set env value WIN. bin/subcommands/tests/test_config.sh asserts
#     the ladder itself, so its `machine-conf-set BUILD_MERGE_GATE_WINDOW`
#     case read `layer=env` under score.sh and `layer=machine-conf` bare —
#     i.e. every replay's gate_result.passed was deterministically false
#     regardless of candidate quality, and the mechanical outcome scorer
#     (#1258) contributed ZERO discriminating signal.
#   * the SECOND symptom (#1377): the leaked value included
#     KNOWLEDGE_STORE_ROOT pointing at the operator's REAL knowledge store.
#     workflows/scripts/tests/test_install_lifecycle.sh step 4b runs its
#     sync-init leg through the DEFAULT root seam under a sandboxed
#     XDG_DATA_HOME — an explicit KNOWLEDGE_STORE_ROOT overrides that seam,
#     so the leg `git init`-ed the operator's live store instead of the
#     sandbox's. Operator data damage, from an environment variable.
#
# THE FIX is the same shape candidate-session.sh already uses for its own
# child (`env -i` + a NAMED, reviewable allowlist — never `env VAR=value`,
# which ADDS to the inherited environment and closes nothing). Names below
# are what a `make`-driven gate suite genuinely needs to start: an
# executable search path, a home directory, a shell/terminal, a scratch dir,
# locale/timezone, and the XDG roots a suite sandboxes for itself. Every
# BUILD_*/PIPELINE_*/REPLAY_*/MODEL_COMPARISON_* setting and
# KNOWLEDGE_STORE_ROOT are absent BY CONSTRUCTION rather than by denylist —
# a new setting added to build.config.sh's export list can never re-open
# this leak. Add a name here only after verifying the gate actually needs
# it; an allowlist that silently breaks the gate trades one false signal
# for another.
#
# NOT constrained here: score.sh's OWN `. build.config.sh` above. This file
# still needs REPLAY_SCORE_GATE_RELPATH and REPLAY_SCORE_GATE_TIMEOUT_SECS;
# the bug is what the gate CHILD inherits, never what this process reads.
_SCORE_GATE_ENV_PASSTHROUGH='PATH HOME USER LOGNAME SHELL TERM TMPDIR TZ
LANG LC_ALL LC_CTYPE
XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME'

# _score_gate_child_env — prints one NAME=VALUE line per forwarded variable,
# skipping any name that is unset in THIS process (so the child never gets a
# spurious empty-valued var). Callers read it into an array and feed it
# straight into `env -i`'s argv. A value carrying a literal newline would not
# survive this line-oriented read; none of the names above ever carries one.
_score_gate_child_env() {
  local name
  for name in $_SCORE_GATE_ENV_PASSTHROUGH; do
    [ -n "${!name+x}" ] && printf '%s=%s\n' "$name" "${!name}"
  done
  return 0
}

# run_gates <worktree> <gate-relpath> — prints the gate JSON on stdout, or
# CANNOT_EVALUATE + non-zero. Never invokes THIS tree's quality-gates.sh:
# the script it runs is always the one inside <worktree> (trap C).
run_gates() {
  local wt="$1" relpath="$2" gate_abs started ended rc dur_ms timed_out=false

  if [ -z "$wt" ]; then
    cannot_evaluate "no worktree given to the gate runner"
    return 1
  fi
  if [ ! -d "$wt" ]; then
    cannot_evaluate "candidate worktree does not exist or is not a directory: $wt"
    return 1
  fi
  wt="$(abs_dir "$wt")" || { cannot_evaluate "candidate worktree is not enterable: $wt"; return 1; }

  case "$relpath" in
    /*|*..*)
      cannot_evaluate "gate relpath must be worktree-relative with no '..' segment, got: $relpath"
      return 1
      ;;
  esac
  gate_abs="$wt/$relpath"
  if [ ! -e "$gate_abs" ]; then
    # THE fail-closed case that matters most here: an absent gate script
    # would otherwise make "the gate ran and passed" and "there was no gate"
    # indistinguishable — the exact shape #1365 names.
    cannot_evaluate "the candidate worktree carries no gate entry point at $relpath ($gate_abs) — cannot report a gate outcome it never ran"
    return 1
  fi
  if [ ! -f "$gate_abs" ] || [ ! -r "$gate_abs" ]; then
    cannot_evaluate "the gate entry point at $gate_abs is not a readable regular file"
    return 1
  fi

  # The child's environment is CONSTRUCTED, not inherited — see the
  # allowlist block above for the two symptoms this closes.
  local -a gate_env=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && gate_env+=("$line")
  done < <(_score_gate_child_env)

  started="$(epoch_ms)"
  ( cd "$wt" && run_with_timeout "$REPLAY_SCORE_GATE_TIMEOUT_SECS" \
      env -i ${gate_env[@]+"${gate_env[@]}"} bash "$gate_abs" ) >/dev/null 2>&1
  rc=$?
  ended="$(epoch_ms)"
  dur_ms=$(( ended - started ))
  [ "$dur_ms" -lt 0 ] && dur_ms=0
  [ "$rc" -eq 137 ] && timed_out=true

  jq -cn --arg script "$relpath" --argjson rc "$rc" \
    --argjson passed "$( [ "$rc" -eq 0 ] && echo true || echo false )" \
    --argjson timed_out "$timed_out" --argjson dur "$dur_ms" \
    --argjson budget "$REPLAY_SCORE_GATE_TIMEOUT_SECS" \
    '{outcome:"GATES", ran:true, gate_script:$script, exit_code:$rc,
      passed:$passed, timed_out:$timed_out, duration_ms:$dur,
      timeout_secs:$budget}'
}

# epoch_ms — millisecond wall clock. perl when available (every host this
# repo targets ships it); otherwise second resolution, which is honest
# rather than fabricated sub-second precision.
epoch_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d", time * 1000' 2>/dev/null && return 0
  fi
  printf '%d' "$(( $(date +%s) * 1000 ))"
}

cmd_gates() {
  local wt="" relpath="$REPLAY_SCORE_GATE_RELPATH"
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) need_operand --worktree "$#" "${2:-}" || return 2; wt="$2"; shift 2 ;;
      --gate-relpath) need_operand --gate-relpath "$#" "${2:-}" || return 2; relpath="$2"; shift 2 ;;
      *) printf 'score.sh gates: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done
  run_gates "$wt" "$relpath"
}

# ── score ─────────────────────────────────────────────────────────────────

cmd_score() {
  local repo_root="" wt="" record_file="" relpath="$REPLAY_SCORE_GATE_RELPATH"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root) need_operand --repo-root "$#" "${2:-}" || return 2; repo_root="$2"; shift 2 ;;
      --candidate-worktree) need_operand --candidate-worktree "$#" "${2:-}" || return 2; wt="$2"; shift 2 ;;
      --record) need_operand --record "$#" "${2:-}" || return 2; record_file="$2"; shift 2 ;;
      --gate-relpath) need_operand --gate-relpath "$#" "${2:-}" || return 2; relpath="$2"; shift 2 ;;
      *) printf 'score.sh score: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$repo_root" ] || { cannot_evaluate "no --repo-root given"; return 1; }
  [ -n "$wt" ] || { cannot_evaluate "no --candidate-worktree given"; return 1; }
  [ -n "$record_file" ] || { cannot_evaluate "no --record given"; return 1; }

  if [ ! -f "$record_file" ] || [ ! -r "$record_file" ]; then
    cannot_evaluate "corpus record not found or not a readable regular file: $record_file"
    return 1
  fi
  if [ ! -s "$record_file" ]; then
    cannot_evaluate "corpus record file is empty: $record_file"
    return 1
  fi
  if ! jq -e 'type=="object" and has("base") and has("head") and has("buckets")' "$record_file" >/dev/null 2>&1; then
    cannot_evaluate "corpus record is malformed (want a JSON object carrying base, head and buckets): $record_file"
    return 1
  fi

  local base head
  base="$(jq -r '.base // empty' "$record_file")"
  head="$(jq -r '.head // empty' "$record_file")"
  if [ -z "$base" ] || [ -z "$head" ]; then
    cannot_evaluate "corpus record carries a null base and/or head — nothing to score against"
    return 1
  fi

  repo_root="$(abs_dir "$repo_root")" || { cannot_evaluate "--repo-root does not exist: $repo_root"; return 1; }
  if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    cannot_evaluate "--repo-root is not inside a git work tree: $repo_root"
    return 1
  fi
  if [ ! -d "$wt" ]; then
    cannot_evaluate "candidate worktree does not exist or is not a directory: $wt"
    return 1
  fi
  wt="$(abs_dir "$wt")" || { cannot_evaluate "candidate worktree is not enterable: $wt"; return 1; }
  if ! git -C "$wt" rev-parse --show-toplevel >/dev/null 2>&1; then
    cannot_evaluate "candidate worktree is not inside a git work tree: $wt"
    return 1
  fi

  # Fail CLOSED on an unresolvable ref — without this, every `git diff`
  # below prints nothing, every bucket scores "unchanged", and the verdict
  # is a confident `fail` computed from input this command never read.
  if ! git -C "$repo_root" cat-file -e "${base}^{commit}" 2>/dev/null; then
    cannot_evaluate "base commit not resolvable in $repo_root: $base"
    return 1
  fi
  if ! git -C "$repo_root" cat-file -e "${head}^{commit}" 2>/dev/null; then
    cannot_evaluate "merged-truth head commit not resolvable in $repo_root: $head"
    return 1
  fi
  if ! git -C "$wt" cat-file -e "${base}^{commit}" 2>/dev/null; then
    cannot_evaluate "base commit not resolvable inside the candidate worktree $wt: $base"
    return 1
  fi

  # ── N: the scored solution surface ────────────────────────────────────
  local n_tmp flags_tmp
  n_tmp="$(scratch n.jsonl)" || { cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  flags_tmp="$(scratch flags.txt)" || { cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  : >"$n_tmp"; : >"$flags_tmp"

  local n_total=0 n_changed=0 n_matched=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n_total=$((n_total + 1))
    local tw ta tr rawa rawr ca cr changed matched fmt_only truth_sha cand_sha

    tw="$(git -C "$repo_root" diff --numstat --ignore-all-space --ignore-blank-lines "$base" "$head" -- "$p" 2>/dev/null | sum_numstat)"
    ta="${tw%% *}"; tr="${tw##* }"
    tw="$(git -C "$repo_root" diff --numstat "$base" "$head" -- "$p" 2>/dev/null | sum_numstat)"
    rawa="${tw%% *}"; rawr="${tw##* }"

    tw="$(git -C "$wt" diff --numstat --ignore-all-space --ignore-blank-lines "$base" -- "$p" 2>/dev/null | sum_numstat)"
    ca="${tw%% *}"; cr="${tw##* }"

    if [ "$(( ca + cr ))" -gt 0 ]; then changed=true; n_changed=$((n_changed + 1)); else changed=false; fi

    # Trap B — formatting-only churn in the TRUTH. Detected, never assumed
    # absent: raw diff non-empty but whitespace-insensitive diff empty.
    if [ "$(( rawa + rawr ))" -gt 0 ] && [ "$(( ta + tr ))" -eq 0 ]; then
      fmt_only=true
      printf 'formatting-only-churn\n' >>"$flags_tmp"
    else
      fmt_only=false
    fi

    # "absent" is a distinct sentinel from "the empty file's digest" — truth
    # may DELETE a named path, and a candidate that also deleted it MATCHES,
    # while a candidate that merely emptied it does not.
    if git -C "$repo_root" cat-file -e "${head}:${p}" 2>/dev/null; then
      truth_sha="$(git -C "$repo_root" show "${head}:${p}" 2>/dev/null | sha256_of_stdin)"
    else
      truth_sha="absent"
    fi
    if [ -f "$wt/$p" ]; then
      cand_sha="$(sha256_of_stdin <"$wt/$p")"
    else
      cand_sha="absent"
    fi
    if [ "$cand_sha" = "$truth_sha" ]; then matched=true; n_matched=$((n_matched + 1)); else matched=false; fi

    jq -cn --arg path "$p" \
      --argjson truth_added "$ta" --argjson truth_removed "$tr" \
      --argjson truth_added_raw "$rawa" --argjson truth_removed_raw "$rawr" \
      --argjson candidate_added "$ca" --argjson candidate_removed "$cr" \
      --argjson changed "$changed" --argjson matches_truth "$matched" \
      --argjson formatting_only_truth_churn "$fmt_only" \
      '{path:$path, truth_added:$truth_added, truth_removed:$truth_removed,
        truth_added_raw:$truth_added_raw, truth_removed_raw:$truth_removed_raw,
        candidate_added:$candidate_added, candidate_removed:$candidate_removed,
        changed:$changed, matches_truth:$matches_truth,
        formatting_only_truth_churn:$formatting_only_truth_churn}' >>"$n_tmp"
  done < <(jq -r '(.buckets.N // [])[]' "$record_file" 2>/dev/null)

  # ── T: presence only, never bytes ─────────────────────────────────────
  local t_tmp cand_tests_tmp
  t_tmp="$(scratch touched.txt)" || { cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  {
    git -C "$wt" diff --name-only "$base" 2>/dev/null
    git -C "$wt" ls-files --others --exclude-standard 2>/dev/null
  } | sort -u >"$t_tmp"

  cand_tests_tmp="$(scratch cand-tests.txt)" || { cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  : >"$cand_tests_tmp"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_test_path "$p"; then printf '%s\n' "$p" >>"$cand_tests_tmp"; fi
  done <"$t_tmp"

  local t_truth_n t_cand_n t_required t_present
  t_truth_n="$(jq -r '(.buckets.T // []) | length' "$record_file")"
  t_cand_n="$(grep -c . "$cand_tests_tmp" 2>/dev/null || true)"
  case "$t_cand_n" in ''|*[!0-9]*) t_cand_n=0 ;; esac
  if [ "$t_truth_n" -gt 0 ]; then t_required=true; else t_required=false; fi
  if [ "$t_cand_n" -gt 0 ]; then t_present=true; else t_present=false; fi

  # ── the gate: the MECHANICAL outcome scorer, run from inside the base
  #    worktree (trap C) ────────────────────────────────────────────────
  local gate_json gate_rc=0
  gate_json="$(run_gates "$wt" "$relpath")" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    # A gate we could not RUN is not a gate the candidate failed. Propagate
    # the CANNOT_EVALUATE verbatim rather than scoring the half we could read.
    printf '%s\n' "$gate_json"
    printf 'score.sh: CANNOT EVALUATE — could not run the candidate worktree'"'"'s own gate entry point; refusing to emit a partial score\n' >&2
    return 1
  fi
  local gate_passed
  gate_passed="$(jq -r '.passed' <<<"$gate_json")"

  # ── contamination flags (the spike's enumerated traps) ────────────────
  # Carried forward from corpus selection: residue-md-only (tier B),
  # post-cut-edit-unverified (trap D), criterion-embedded-em-dash (fact 4).
  jq -r '(.flags // [])[]' "$record_file" 2>/dev/null >>"$flags_tmp"

  # Trap C — gate/prompt-template drift. The record's template_sha was read
  # at the item's OWN base; if today's tree carries a different template the
  # two runs are not comparable, and the record must SAY so.
  local rec_template today_template
  rec_template="$(jq -r '.template_sha // empty' "$record_file")"
  today_template="$(git -C "$repo_root" rev-parse "HEAD:claude/workflows/build-level.mjs" 2>/dev/null)"
  if [ -n "$rec_template" ] && [ -n "$today_template" ] && [ "$rec_template" != "$today_template" ]; then
    printf 'template-sha-drift\n' >>"$flags_tmp"
  fi

  # The 40-vs-38 lesson: an acceptance bullet carrying a hard numeric literal
  # is exactly the bullet that drifts under its own criteria. Flagged, so a
  # downstream judge grades its SHAPE rather than its numbers.
  local acc_tmp
  acc_tmp="$(scratch acceptance.jsonl)" || { cannot_evaluate "could not create a scratch dir under ${TMPDIR:-/tmp}"; return 1; }
  : >"$acc_tmp"
  local any_literal=false line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local has_num=false
    if printf '%s' "$line" | grep -E '(^|[^A-Za-z0-9_.-])[0-9]{2,}([^A-Za-z0-9_.-]|$)' >/dev/null 2>&1; then
      has_num=true; any_literal=true
    fi
    jq -cn --arg c "$line" --argjson n "$has_num" \
      '{criterion:$c, carries_literal_numbers:$n, mechanically_scored:false,
        basis:"shape-not-literals: mechanical scoring is the gate result plus the diff-scope partition; bullet grading is deliberately left to a judge"}' >>"$acc_tmp"
  done < <(jq -r '(.acceptance // [])[]' "$record_file" 2>/dev/null)
  [ "$any_literal" = "true" ] && printf 'acceptance-carries-literal-numbers\n' >>"$flags_tmp"

  [ "$n_total" -eq 0 ] && printf 'no-named-solution-surface\n' >>"$flags_tmp"

  # ── the verdict ────────────────────────────────────────────────────────
  local n_ok=false t_ok=false verdict="fail"
  [ "$n_total" -gt 0 ] && [ "$n_changed" -eq "$n_total" ] && n_ok=true
  if [ "$t_required" = "false" ] || [ "$t_present" = "true" ]; then t_ok=true; fi
  if [ "$n_ok" = "true" ] && [ "$t_ok" = "true" ] && [ "$gate_passed" = "true" ]; then
    verdict="pass"
  fi

  jq -n \
    --slurpfile n_files "$n_tmp" \
    --slurpfile acc "$acc_tmp" \
    --argjson gate "$gate_json" \
    --arg verdict "$verdict" \
    --argjson n_total "$n_total" --argjson n_changed "$n_changed" --argjson n_matched "$n_matched" \
    --argjson n_ok "$n_ok" --argjson t_ok "$t_ok" \
    --argjson t_required "$t_required" --argjson t_present "$t_present" \
    --argjson t_truth_n "$t_truth_n" \
    --argjson t_truth "$(jq -c '.buckets.T // []' "$record_file")" \
    --argjson t_cand "$(jq -R . <"$cand_tests_tmp" | jq -cs .)" \
    --argjson x_paths "$(jq -c '.buckets.X // []' "$record_file")" \
    --argjson r_paths "$(jq -c '.buckets.R // []' "$record_file")" \
    --argjson flags "$(sort -u <"$flags_tmp" | jq -R . | jq -cs 'map(select(length > 0))')" \
    --arg base "$base" --arg head "$head" \
    '{outcome:"SCORED", scored:true, verdict:$verdict,
      base:$base, truth_head:$head,
      diff:{
        n:{scored:true, total:$n_total, changed:$n_changed, matched_truth:$n_matched,
           all_changed:$n_ok, files:$n_files},
        t:{scored_on:"presence+pass", required:$t_required, present:$t_present,
           truth_count:$t_truth_n, truth_paths:$t_truth, candidate_paths:$t_cand, ok:$t_ok},
        x:{treatment:"neutral", paths:$x_paths},
        r:{treatment:"flagged-only", paths:$r_paths}
      },
      gate_result:$gate,
      acceptance_results:$acc,
      components:{named_surface_all_changed:$n_ok, test_surface_ok:$t_ok, gate_passed:$gate.passed},
      contamination_flags:$flags}' \
    | jq -c .
  return 0
}

# ── aggregate ─────────────────────────────────────────────────────────────

cmd_aggregate() {
  local records=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --records-file) need_operand --records-file "$#" "${2:-}" || return 2; records="$2"; shift 2 ;;
      *) printf 'score.sh aggregate: unknown arg %s\n' "$1" >&2; return 2 ;;
    esac
  done

  [ -n "$records" ] || { cannot_evaluate "no --records-file given"; return 1; }
  if [ ! -f "$records" ] || [ ! -r "$records" ]; then
    cannot_evaluate "records file not found or not a readable regular file: $records"
    return 1
  fi
  local n_lines
  n_lines="$(grep -c . "$records" 2>/dev/null || true)"
  case "$n_lines" in ''|*[!0-9]*) n_lines=0 ;; esac
  if [ "$n_lines" -eq 0 ]; then
    cannot_evaluate "records file has no records: $records"
    return 1
  fi

  # Every line must parse and carry the candidate.outcome discriminator. A
  # single unreadable line CANNOT-EVALUATEs the whole roll-up rather than
  # being skipped: a silently-skipped record moves both denominators.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! jq -e 'type=="object" and (.candidate|type=="object") and (.candidate|has("outcome"))' >/dev/null 2>&1 <<<"$line"; then
      cannot_evaluate "malformed replay record (want a JSON object whose .candidate carries an outcome): $line"
      return 1
    fi
    local oc; oc="$(jq -r '.candidate.outcome' <<<"$line")"
    case "$oc" in
      scored|integration-error) ;;
      *) cannot_evaluate "replay record carries an unknown candidate.outcome '$oc' — refusing to roll it into either metric: $line"; return 1 ;;
    esac
  done <"$records"

  # THE SPLIT the acceptance requires. `quality` is computed over
  # candidate.outcome == "scored" ONLY; an integration-error contributes to
  # `compatibility` and to NOTHING in `quality` — not the numerator, not the
  # denominator. A vendor integration failure is a compatibility fact about
  # the vendor, never a quality fact about the model.
  jq -s '
    (map(select(.candidate.outcome == "scored"))) as $scored
    | (map(select(.candidate.outcome == "integration-error"))) as $errs
    | ($scored | length) as $sn
    | ($scored | map(select(.score.verdict == "pass")) | length) as $pn
    | ($scored | map(select(.score.verdict == "fail")) | length) as $fn
    | ($errs | length) as $en
    | ($sn + $en) as $att
    | {outcome:"AGGREGATE",
       attempted_n:$att,
       quality:{basis:"candidate.outcome == \"scored\" records only; integration errors are excluded from every figure here",
                scored_n:$sn, pass_n:$pn, fail_n:$fn,
                pass_rate:(if $sn == 0 then null else (($pn * 10000 / $sn) | floor) / 10000 end)},
       compatibility:{basis:"a separate metric: vendor integration failures, never read as model quality",
                      attempted_n:$att, integration_error_n:$en,
                      integration_error_rate:(if $att == 0 then null else (($en * 10000 / $att) | floor) / 10000 end),
                      by_stage:( $errs
                                 | map(.candidate.integration_error.stage // "unknown")
                                 | group_by(.)
                                 | map({key:.[0], value:length})
                                 | from_entries )}}' \
    <"$records" | jq -c .
}

# ── dispatch ──────────────────────────────────────────────────────────────
[ $# -ge 1 ] || { usage; exit 2; }
cmd="$1"; shift
case "$cmd" in
  score)     cmd_score "$@" ;;
  gates)     cmd_gates "$@" ;;
  aggregate) cmd_aggregate "$@" ;;
  -h|--help) usage; exit 0 ;;
  *)         usage; exit 2 ;;
esac
