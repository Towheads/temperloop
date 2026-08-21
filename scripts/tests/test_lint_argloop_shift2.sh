#!/usr/bin/env bash
# Regression tests for scripts/lint-argloop-shift2.sh (temperloop#1342).
#
# The gate this backstops: `shift 2` inside a `while [ $# -gt 0 ]` option loop
# spins at 100% CPU forever when the flag is the FINAL argument. Bash's
# `shift n` FAILS when n > $#, and a FAILED shift does not shift, so `$#` never
# decreases and the same case arm re-matches. 112 live sites across 26 files
# carried the shape; `emit-item-efficiency.sh --slug` was confirmed hanging.
#
# WHY THESE TESTS EXIST AT ALL. Same reason as the sibling suites for
# lint-bash32-ctlesc-ifs.sh and lint-bash32-cmdsubst-comment.sh: a lint ASSERTED
# to cover a class without ever being shown to fire on it is not coverage. T1 is
# therefore the load-bearing test — it feeds the lint the VERBATIM pre-fix line
# from workflows/scripts/emit-item-efficiency.sh and requires a non-zero exit.
#
# The `ok` fixtures fence in the false positives a wider rule produces, and each
# one is a REAL shape from this tree, not a hypothetical:
#   - `${2:?…}`                        every bin/subcommands/*.sh flag
#   - a bare `$2` under `set -u`       the same, minus the message
#   - `while [ "$#" -ge 2 ]`           board.sh's _board_issues_create_many
#   - a nested `case` before the shift bin/subcommands/configure.sh `--set`
#   - an `if [ $# -lt 2 ]` preflight   emit-session-context.sh (a DIFFERENT,
#                                      equally correct fix for this same defect)
# A rule that flagged those would have produced ~58 false positives on code
# that provably cannot hang.
#
# T-GROUND re-measures the lint's own PREMISE rather than trusting it: under a
# bounded watchdog it runs all five shapes and requires the two the lint calls
# dangerous to be KILLED (rc 137) and the three it exempts to exit on their own.
# That is what keeps this file's exclusions from rotting into folklore.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$ROOT/scripts/lint-argloop-shift2.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-argloop-shift2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# fixture <name> <expect: fail|ok> <content>
FIXN=0
FIX_NAME=(); FIX_EXPECT=(); FIX_PATH=()
fixture() {
  FIXN=$((FIXN + 1))
  FIX_NAME[FIXN]="$1"; FIX_EXPECT[FIXN]="$2"
  FIX_PATH[FIXN]="$WORK/$1.sh"
  printf '%s\n' "$3" >"$WORK/$1.sh"
}

# ── T1: the REAL pre-fix input, copied verbatim from
#    workflows/scripts/emit-item-efficiency.sh as it stood on `main`. A lint
#    that does not fire on THIS is not a guard for this class. ───────────────
fixture real_prefix_emit fail '#!/usr/bin/env bash
set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --slug)             slug="${2:-}"; shift 2 ;;
    --repo)             repo="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done'

# ── Must FIRE: every spelling of the spinning shape ─────────────────────────
fixture tolerant_default fail 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:-brief}"; shift 2 ;;
    *) shift ;;
  esac
done'
fixture bare_two_no_setu fail 'set -o pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done'
fixture double_bracket fail 'set -uo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) class="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done'
fixture multiline_arm fail 'set -uo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done'
fixture shift_three fail 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --pair) a="${2:-}"; b="${3:-}"; shift 3 ;;
    *) shift ;;
  esac
done'
fixture no_dollar_two fail 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --skip) shift 2 ;;
    *) shift ;;
  esac
done'
fixture loop_inside_function fail 'set -uo pipefail
parse() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
}'
fixture arith_condition fail 'set -uo pipefail
while (( $# )); do
  case "$1" in
    --limit) limit="${2:-10}"; shift 2 ;;
    *) shift ;;
  esac
done'

# ── Must NOT fire: a FATAL `$2` expansion. Measured in T-GROUND: it EXITS. This
#    is the live shape in every bin/subcommands/*.sh flag; a rule that flagged
#    it would fire on ~58 sites that provably cannot hang. ───────────────────
fixture fatal_colon_question ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) init_dir="${2:?--dir needs a value}"; shift 2 ;;
    *) shift ;;
  esac
done'
fixture bare_two_with_setu ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    *) shift ;;
  esac
done'

# ── Must NOT fire: the sanctioned fix, and the equally-correct preflight
#    alternative that workflows/scripts/emit-session-context.sh uses. ────────
fixture the_fix ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:-brief}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *) shift ;;
  esac
done'
fixture arity_preflight ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --transcript | --session-id)
      if [ $# -lt 2 ]; then
        echo "WARN $1 requires a value (ignored)" >&2
        shift
        continue
      fi
      ;;
  esac
  case "$1" in
    --transcript) transcript="$2"; shift 2 ;;
    --session-id) session_id="$2"; shift 2 ;;
    *) shift ;;
  esac
done'

# ── Must NOT fire: the loop CONDITION already guarantees the arity. Live in
#    workflows/scripts/board/lib/board.sh (_board_issues_create_many). ───────
fixture condition_ge_two ok 'set -uo pipefail
while [ "$#" -ge 2 ]; do
  url="$1"; num="$2"; shift 2
  echo "$url $num"
done'

# ── Must NOT fire: a nested `case` between the FATAL expansion and the shift.
#    Live in bin/subcommands/configure.sh (`--set NAME=VALUE`). ─────────────
fixture nested_case_before_shift ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      kv="${2:?--set needs a NAME=VALUE value}"
      case "$kv" in
        *=*) : ;;
        *) echo "bad" >&2; exit 2 ;;
      esac
      overrides="$overrides$kv"
      shift 2
      ;;
    *) shift ;;
  esac
done'

# ── Must NOT fire: no `$#`-conditioned loop at all, a non-literal count, or
#    prose that merely names the shape (the temperloop#1152 class). ─────────
fixture function_arg_unpack ok 'set -uo pipefail
expect() {
  local label="$1" expected="$2"; shift 2
  printf "%s %s %s\n" "$label" "$expected" "$*"
}'
fixture dynamic_shift_count ok 'set -uo pipefail
while [ $# -gt 0 ]; do
  n="$(consume "$@")"
  shift "$n"
done'
fixture comment_naming_shape ok 'set -uo pipefail
# Never write `--format) f="${2:-}"; shift 2 ;;` here — it spins forever.
while [ $# -gt 0 ]; do
  case "$1" in
    --format) f="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *) shift ;;
  esac
done'
fixture trailing_comment_naming_shape ok 'set -uo pipefail
while [ $# -gt 0 ]; do shift; done  # was shift 2 before temperloop#1342'

echo "── lint-argloop-shift2: fixture verdicts ──"
i=1
while [ "$i" -le "$FIXN" ]; do
  name="${FIX_NAME[$i]}"; expect="${FIX_EXPECT[$i]}"; path="${FIX_PATH[$i]}"
  bash "$LINT" "$path" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -ne 0 ]; then pass "$name — FIRES (rc=$rc), as required"
    else fail "$name — lint exited 0 on a known-spinning option loop"; fi
  else
    if [ "$rc" -eq 0 ]; then pass "$name — silent, as required"
    else fail "$name — FALSE POSITIVE: lint exited $rc on legal code"; fi
  fi
  i=$((i + 1))
done

echo
echo "── the lint names the offending file, line, and the fix ──"
REPORT="$(bash "$LINT" "${FIX_PATH[1]}" 2>&1 1>/dev/null || true)"
case "$REPORT" in
  *real_prefix_emit.sh:*) pass "the report cites the offending file:line" ;;
  *) fail "the report does not cite file:line — got: $REPORT" ;;
esac
case "$REPORT" in
  *'shift 2'*) pass "the report names the offending construct" ;;
  *) fail "the report does not name the offending construct" ;;
esac
case "$REPORT" in
  *'if [ $# -gt 0 ]; then shift; fi'*) pass "the report names the sanctioned fix" ;;
  *) fail "the report does not name the sanctioned fix" ;;
esac
case "$REPORT" in
  *1342*) pass "the report cites the issue" ;;
  *) fail "the report does not cite temperloop#1342" ;;
esac

echo
echo "── the swept tree is clean, and --list resolves a file set ──"
if bash "$LINT" \
  "$ROOT/workflows/scripts/emit-item-efficiency.sh" \
  "$ROOT/workflows/scripts/emit-command-run.sh" \
  "$ROOT/workflows/scripts/emit-issue-touch.sh" \
  "$ROOT/workflows/scripts/emit-diagnose-queue.sh" \
  "$ROOT/workflows/scripts/emit-gh-perf.sh" >/dev/null 2>&1; then
  pass "the five repaired emit-*.sh scripts pass the lint"
else
  fail "a repaired emit-*.sh script still trips the lint"
fi
if [ "$(bash "$LINT" --list 2>/dev/null | wc -l | tr -d ' ')" -gt 10 ]; then
  pass "--list resolves the tracked shell set"
else
  fail "--list resolved an implausibly small file set"
fi
# The lint must never flag ITSELF or this file, both of which carry the shape as
# data — self-exemption is by resolved path, so a vendored copy is covered too.
if bash "$LINT" >/dev/null 2>&1; then
  pass "the whole tracked set is clean (self-exemption holds)"
else
  fail "the lint is not clean over the tracked set"
fi

echo
echo "── T-GROUND: re-measure the lint's PREMISE, bounded so a hang FAILS ──"
# Every one of these runs the shape with the flag as the SOLE argument. A
# watchdog kills anything still alive after 5s, which surfaces as rc 137 — so a
# regression fails this suite instead of hanging CI.
run_bounded() { # $1=secs; rest = command — echoes the rc, never hangs the suite
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local cmd_pid=$!
  ( sleep "$secs" 2>/dev/null; kill -9 "$cmd_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
  local watchdog_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local st=$?
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null
  echo "$st"
}
ground() { # <name> <expect: hang|exits> <body>
  printf '%s\n' "$3" >"$WORK/ground.sh"
  local rc; rc="$(run_bounded 5 bash "$WORK/ground.sh" --flag)"
  if [ "$2" = "hang" ]; then
    if [ "$rc" = "137" ]; then pass "ground truth: $1 SPINS (killed by the watchdog) — the lint is right to flag it"
    else fail "ground truth: $1 exited rc=$rc on its own — this lint flags a shape that no longer hangs"; fi
  else
    if [ "$rc" != "137" ]; then pass "ground truth: $1 exits on its own (rc=$rc) — the lint is right to exempt it"
    else fail "ground truth: $1 HUNG — the lint exempts a shape that spins"; fi
  fi
}
ground 'tolerant ${2:-} + shift 2' hang 'set -uo pipefail
while [ $# -gt 0 ]; do case "$1" in --flag) v="${2:-}"; shift 2 ;; *) shift ;; esac; done'
ground 'bare $2 + shift 2, no set -u' hang 'set -o pipefail
while [ $# -gt 0 ]; do case "$1" in --flag) v="$2"; shift 2 ;; *) shift ;; esac; done'
ground 'fatal ${2:?} + shift 2' exits 'set -uo pipefail
while [ $# -gt 0 ]; do case "$1" in --flag) v="${2:?needs a value}"; shift 2 ;; *) shift ;; esac; done'
ground 'bare $2 + shift 2, WITH set -u' exits 'set -uo pipefail
while [ $# -gt 0 ]; do case "$1" in --flag) v="$2"; shift 2 ;; *) shift ;; esac; done'
ground 'the sanctioned fix' exits 'set -uo pipefail
while [ $# -gt 0 ]; do case "$1" in --flag) v="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;; *) shift ;; esac; done'
ground 'while [ "$#" -ge 2 ] pair consumer' exits 'set -uo pipefail
while [ "$#" -ge 2 ]; do a="$1"; b="$2"; shift 2; done'

echo
if [ "$FAIL" -gt 0 ]; then
  echo "test_lint_argloop_shift2: FAILED $FAIL of $((PASS + FAIL))"
  exit 1
fi
echo "test_lint_argloop_shift2: OK — all $PASS checks passed"
