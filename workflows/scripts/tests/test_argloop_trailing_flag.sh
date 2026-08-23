#!/usr/bin/env bash
#
# test_argloop_trailing_flag.sh — the RUNTIME half of temperloop#1342.
#
# THE DEFECT. `--flag) v="${2:-}"; shift 2 ;;` inside a `while [ $# -gt 0 ]`
# loop spins at 100% CPU forever when `--flag` is the FINAL argument: bash's
# `shift 2` FAILS (count out of range) with only one positional left, a FAILED
# shift does not shift, `$#` never decreases, and the same arm re-matches. 112
# sites across 26 files carried it; `emit-item-efficiency.sh --slug` was
# confirmed hanging for >8s before being killed.
#
# WHAT THIS ASSERTS, and why it is shaped this way.
#
#   scripts/lint-argloop-shift2.sh is the STATIC guard for the class — it is
#   what stops the shape being re-derived in new code (which is exactly how
#   this defect reappeared in workflows/scripts/async-workflow-health.sh,
#   written by someone who had never seen the emit-*.sh sites). This file is
#   the complementary RUNTIME proof that the repaired loops actually terminate:
#   a lint proves the text changed, only execution proves the spin stopped.
#
#   Coverage is DERIVED, not hand-listed: every tracked shell file carrying the
#   sanctioned fix idiom is discovered by grep, so a new adopter is covered the
#   day it lands and nobody has to remember to extend a registry. Floors below
#   (>= 20 files, >= 100 arms) make a silent collapse to zero coverage fail.
#
#   Each loop is extracted VERBATIM from the shipped file and executed in a
#   minimal harness rather than by invoking the script itself. That is what
#   makes this suite deterministic and free of side effects — no lake writes,
#   no `gh`, no `git`, no network (kernel principle 3) — while still running
#   the exact loop text that ships. Extraction failure is a LOUD failure, never
#   a silent skip: every block is `bash -n`-checked before it is trusted.
#
#   The harness deliberately runs WITHOUT `set -u`, for two reasons: an
#   outer-scope variable the arm references (`lookback="${2:-$lookback}"`)
#   would otherwise abort before the shift is reached, and no-`set -u` is the
#   strictly more adversarial condition for this defect — it removes the
#   unbound-variable crash that would otherwise have broken the spin.
#
# EVERY RUN IS BOUNDED. A 10s watchdog kills anything still alive, which
# surfaces as rc 137. This matters more than usual here: an UNBOUNDED assertion
# for THIS defect hangs the suite instead of failing it, which is worse than no
# test at all. Same pattern, same reason, as case 15 of
# workflows/scripts/tests/test_async_workflow_health.sh.
#
# T-CONTROL is the discrimination proof. It takes a real repaired loop, undoes
# the fix in memory (`shift; if [ $# -gt 0 ]; then shift; fi` -> `shift 2`) and
# requires THAT to be killed by the watchdog. Without it, a harness that could
# never detect a hang would report a clean sweep either way.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/argloop-trailing-flag.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FIX_IDIOM='shift; if [ $# -gt 0 ]; then shift; fi'

# run_bounded <secs> <cmd...> — echoes the rc; never hangs the suite. rc 137
# means the watchdog had to kill it, i.e. it spun.
run_bounded() {
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

# extract_loops <file> <outdir> — writes each `while|until … $# … do … done`
# block found in <file> to <outdir>/loop-N.frag and prints their paths. The
# closing `done` is matched by INDENTATION against its own `while`, which is
# exact for every arg loop in this tree and is verified downstream by `bash -n`.
extract_loops() {
  awk -v OUT="$2" '
    depth == 0 && /^[[:space:]]*(while|until)[[:space:]]/ && /\$["\047]?#/ && /[[:space:]]do([[:space:]]|$)/ {
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
      depth = 1; n++; f = OUT "/loop-" n ".frag"
      print $0 > f
      next
    }
    depth == 1 {
      print $0 > f
      if ($0 == indent "done" || $0 ~ "^" indent "done[[:space:]]*$") { close(f); print f; depth = 0 }
    }
  ' "$1"
}

# arm_flags <fragment> — every `-`-leading case-arm pattern in the block, one
# per line, alternations split. These are the tokens a caller can pass last.
arm_flags() {
  sed -nE 's/^[[:space:]]*(-[^)]*)\).*/\1/p' "$1" \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E '^-' \
    | sort -u
}

echo "── coverage: files carrying the temperloop#1342 fix idiom ──"
# The three files below carry the fix idiom as EXAMPLE TEXT (in prose, usage
# output, or a fixture) rather than as a live option loop, so the extractor
# cannot and should not find a loop in them.
#
# The boundary is `(^|/)`, not `^` (temperloop#1734). This suite is vendored
# into consuming repos as a git subtree, where these same three files live at
# `kernel/scripts/lint-argloop-shift2.sh` and friends — anchoring at `^` matched
# none of them there, so all three were walked and all three failed extraction,
# turning a healthy composed tree red. Matching the path SUFFIX at a component
# boundary excludes the vendored copies too, and is still an exact three-path
# list: it can only ever exclude a file whose full path ENDS with one of these,
# never a broad prefix or glob, so a real option loop elsewhere is untouched.
FILES="$(git -C "$REPO" grep -lF "$FIX_IDIOM" -- '*.sh' 2>/dev/null \
  | grep -vE '(^|/)(scripts/lint-argloop-shift2\.sh|scripts/tests/test_lint_argloop_shift2\.sh|workflows/scripts/tests/test_argloop_trailing_flag\.sh)$' \
  | sort)"
NFILES="$(printf '%s\n' "$FILES" | grep -c . || true)"
if [ "$NFILES" -ge 20 ]; then
  pass "$NFILES files carry the fix idiom (floor: 20)"
else
  fail "only $NFILES files carry the fix idiom — the sweep regressed, or the idiom drifted"
  echo "test_argloop_trailing_flag: FAILED — no coverage to run"
  exit 1
fi

echo
echo "── every repaired arg loop terminates on a trailing value-flag ──"
CHECKED=0
FRAGN=0
CONTROL_FRAG=""
for rel in $FILES; do
  d="$WORK/f$FRAGN"; FRAGN=$((FRAGN + 1)); mkdir -p "$d"
  frags="$(extract_loops "$REPO/$rel" "$d")"
  if [ -z "$frags" ]; then
    fail "$rel — could not extract any arg loop (extraction is not allowed to skip silently)"
    continue
  fi
  for frag in $frags; do
    h="$frag.sh"
    {
      echo '#!/usr/bin/env bash'
      echo 'set -o pipefail'
      # The block is wrapped in a FUNCTION, not spliced at top level. Several of
      # these loops ship inside one (ks_search, push_testbed_branch, …) and use
      # `return`/`local`, both of which are errors at top level — and because
      # these loops correctly run without `set -e`, that error would not stop
      # the loop, so an unwrapped harness reports a SPIN for code that is
      # perfectly correct in situ. Measured: ks_search's `--limit` arm, which
      # already carries a `[ $# -lt 2 ] … return 2` guard, read as hung until
      # the wrapper was added.
      echo '_argloop_under_test() {'
      cat "$frag"
      echo '}'
      echo '_argloop_under_test "$@"'
      echo 'exit 0'
    } >"$h"
    if ! bash -n "$h" 2>/dev/null; then
      fail "$rel — extracted loop is not valid bash; extraction is wrong, not the code"
      continue
    fi
    [ -n "$CONTROL_FRAG" ] || CONTROL_FRAG="$h"
    bad=""
    for flag in $(arm_flags "$frag"); do
      rc="$(run_bounded 10 bash "$h" "$flag")"
      CHECKED=$((CHECKED + 1))
      [ "$rc" = "137" ] && bad="$bad $flag"
    done
    if [ -z "$bad" ]; then
      pass "$rel — every arm terminates with the flag last"
    else
      fail "$rel — SPUN on trailing:$bad (rc 137 = killed by the watchdog)"
    fi
  done
done

if [ "$CHECKED" -ge 100 ]; then
  pass "$CHECKED trailing-flag invocations exercised (floor: 100)"
else
  fail "only $CHECKED trailing-flag invocations exercised — coverage collapsed"
fi

echo
echo "── the five emit-*.sh scripts the issue names, end to end ──"
# Highest-fidelity check for the family whose own headers promise "a telemetry
# emit must never fail or block the calling spawn site" — a hang there hangs the
# SPAWN SITE, and no `emit-… || true` call shape can prevent it. Each is run as
# the real script with its raw-lake sink redirected into the tmpdir, so nothing
# outside $WORK is written.
SINK="$WORK/lake"; mkdir -p "$SINK"
emit_case() { # <script> <flag> <sink-env-name>
  local script="$1" flag="$2" envname="$3" rc
  rc="$(run_bounded 10 env "$envname=$SINK" HOME="$WORK" \
    bash "$REPO/workflows/scripts/$script" "$flag")"
  if [ "$rc" != "137" ]; then
    pass "$script $flag — exits promptly (rc=$rc)"
  else
    fail "$script $flag — HUNG (killed by the watchdog after 10s)"
  fi
}
emit_case emit-item-efficiency.sh --slug  ITEM_EFFICIENCY_RAW_DIR
emit_case emit-item-efficiency.sh --repo  ITEM_EFFICIENCY_RAW_DIR
emit_case emit-command-run.sh     --command CMD_RUN_RAW_DIR
emit_case emit-issue-touch.sh     --issue  ISSUE_TOUCHES_RAW_DIR
emit_case emit-diagnose-queue.sh  --repo   DIAGNOSE_QUEUE_RAW_DIR
emit_case emit-gh-perf.sh         --phase  GH_PERF_RAW_DIR

echo
echo "── T-CONTROL: the harness can actually DETECT a spin ──"
# Re-break a real repaired loop in memory and require the watchdog to kill it.
# A green suite means nothing if this control cannot go red.
if [ -z "$CONTROL_FRAG" ]; then
  fail "no fragment available to re-break — the discrimination control did not run"
else
  broken="$WORK/rebroken.sh"
  sed "s/shift; if \[ \$# -gt 0 \]; then shift; fi/shift 2/g" "$CONTROL_FRAG" >"$broken"
  if cmp -s "$CONTROL_FRAG" "$broken"; then
    fail "re-break was a no-op — the control proves nothing"
  else
    cflag="$(arm_flags "$broken" | head -n 1)"
    rc="$(run_bounded 10 bash "$broken" "$cflag")"
    if [ "$rc" = "137" ]; then
      pass "a reintroduced \`shift 2\` SPINS and is caught (rc=137) — this suite discriminates"
    else
      fail "a reintroduced \`shift 2\` exited rc=$rc — this suite cannot detect the defect it guards"
    fi
  fi
  # …and the static lint must catch the same reintroduction.
  if bash "$REPO/scripts/lint-argloop-shift2.sh" "$broken" >/dev/null 2>&1; then
    fail "lint-argloop-shift2 stayed GREEN on a reintroduced \`shift 2\`"
  else
    pass "lint-argloop-shift2 goes RED on the same reintroduced \`shift 2\`"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "test_argloop_trailing_flag: FAILED $FAIL of $((PASS + FAIL))"
  exit 1
fi
echo "test_argloop_trailing_flag: OK — all $PASS checks passed ($CHECKED invocations)"
