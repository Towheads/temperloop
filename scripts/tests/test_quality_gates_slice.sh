#!/usr/bin/env bash
#
# test_quality_gates_slice.sh — unit tests for scripts/quality-gates.sh's SLICED
# execution seam (temperloop#1021): QUALITY_GATES_START_AT /
# QUALITY_GATES_BUDGET_SECS, the `QUALITY_GATES_RESUME_AT=` /
# `QUALITY_GATES_FAILED=` stdout markers, and the exit-75 partial protocol.
#
# WHY THIS SEAM EXISTS. /build's §3e.5 acceptance gate runs this suite inside ONE
# executor-agent Bash invocation, whose tool ceiling is ~10 minutes and cannot be
# raised. The pre-#1021 design gave that call a single flat timeout, so a suite
# that outgrew it was SIGTERM'd mid-run and reported as a GATE FAILURE on a green
# tree — twice (temperloop#115 raised the number 2min -> 8min; #1021 is the same
# decay again at 8min). Slicing removes the ceiling from the equation: the budget
# bounds ONE invocation, the caller resumes where the previous slice stopped, and
# total suite runtime is unbounded — so gate-list growth can no longer manufacture
# a false failure. These tests pin the protocol the caller depends on.
#
# HERMETIC. Every case runs a PATCHED COPY of the real quality-gates.sh in a
# throwaway repo root whose gate list is replaced with synthetic one-second
# scripts — so the REAL loop, budget arithmetic, marker emission and exit codes
# are exercised, but none of this repo's actual (minutes-scale) gates run. No
# network, no git, never this repo's own checkout.
#
# Usage: scripts/tests/test_quality_gates_slice.sh

set -uo pipefail

# Control our own env. This suite may itself run AS A GATE inside a sliced
# quality-gates.sh run, which sets these as a command-prefix assignment and so
# exports them to every gate it spawns — leaking the parent's indices into every
# fixture invocation below. quality-gates.sh now unsets them after reading them
# for exactly this reason; clearing them here too keeps this suite hermetic even
# against an older caller that doesn't. (Same shape as
# test_quality_gates_freshness.sh's QUALITY_GATES_SKIP_FRESHNESS unset.)
unset QUALITY_GATES_START_AT QUALITY_GATES_BUDGET_SECS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/scripts/quality-gates.sh"

[ -f "$SRC" ] || { echo "FAIL: quality-gates.sh not found at $SRC" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-slice-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKE="$WORK/repo"
mkdir -p "$FAKE/scripts" "$FAKE/workflows/scripts/lib"
cp "$REPO_ROOT/workflows/scripts/lib/checkout-freshness.sh" "$FAKE/workflows/scripts/lib/"
cp "$REPO_ROOT/workflows/scripts/lib/gate-retry.sh" "$FAKE/workflows/scripts/lib/"
# quality-gates.sh sources this one too (temperloop#1024's diff-scoped selection),
# so the hermetic copy needs it for the same reason it needs the two above. With
# no GITHUB_EVENT_NAME in this fixture's environment the selector resolves to
# mode=full, so every case below still sees all six synthetic gates — this file
# tests the SLICE seam, and scoping is deliberately inert here.
cp "$REPO_ROOT/workflows/scripts/lib/gate-selection.sh" "$FAKE/workflows/scripts/lib/"
# gate-pool.sh too (temperloop#1025). Without it the fixture's `source` fails and
# every gate_pool_* call is a `command not found`, so the script silently
# degrades to the serial loop — and this suite would pass while exercising NONE
# of the parallel path it now shares its run loop with. Copying it is what makes
# the budget cases below run the real chunked-pool code instead of a
# broken-install fallback.
cp "$REPO_ROOT/workflows/scripts/lib/gate-pool.sh" "$FAKE/workflows/scripts/lib/"

# Six synthetic gates: each records that it ran, then sleeps ~1s so a wall-clock
# budget is actually reachable in a test. g4 is the one a case can turn RED by
# creating the $FAKE/g4.red sentinel.
N_GATES=6
for i in 1 2 3 4 5 6; do
  cat >"$FAKE/g$i.sh" <<EOF
#!/usr/bin/env bash
echo "g$i" >> "\$QG_SLICE_MARK"
# Record what THIS gate inherited of the harness's slicing state — case 11
# asserts it is nothing (see the unset in quality-gates.sh).
echo "start=\${QUALITY_GATES_START_AT-unset} budget=\${QUALITY_GATES_BUDGET_SECS-unset}" >> "\$QG_SLICE_MARK.env"
sleep 1
if [ "$i" = 4 ] && [ -f "\$(dirname "\$0")/g4.red" ]; then echo "g4 is red"; exit 1; fi
exit 0
EOF
  chmod +x "$FAKE/g$i.sh"
done

# Patch the real script: replace the whole hardcoded gate-list region (from
# `KERNEL_GATES=(` through the last conditional registration, i.e. everything
# before the overlay block) with the synthetic list. Everything AFTER that —
# the overlay union, --list, the slice arithmetic, the run loop, the markers and
# the exit codes — is the production code under test, byte for byte.
awk '
  /^KERNEL_GATES=\($/ { skipping = 1;
    print "KERNEL_GATES=("
    print "  \"bash g1.sh\""
    print "  \"bash g2.sh\""
    print "  \"bash g3.sh\""
    print "  \"bash g4.sh\""
    print "  \"bash g5.sh\""
    print "  \"bash g6.sh\""
    print ")"
    print "SKIPPED_KERNEL_GATES=()"
    next }
  skipping && /^# The overlay gate set/ { skipping = 0 }
  !skipping { print }
' "$SRC" >"$FAKE/scripts/quality-gates.sh"
chmod +x "$FAKE/scripts/quality-gates.sh"

bash -n "$FAKE/scripts/quality-gates.sh" \
  || { echo "FAIL: patched fixture does not parse — the awk splice needs updating" >&2; exit 1; }

# run_qg <mark-file> [ENV=VAL ...] — run the fixture, capture stdout+stderr and
# the exit code into RUN_OUT / RUN_RC.
RUN_OUT=""; RUN_RC=0
run_qg() {
  local mark="$1"; shift
  RUN_RC=0
  RUN_OUT="$(env QG_SLICE_MARK="$mark" QUALITY_GATES_SKIP_FRESHNESS=1 \
    GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 "$@" \
    bash "$FAKE/scripts/quality-gates.sh" 2>&1)" || RUN_RC=$?
}
marker() { sed -n "s/^$1=//p" <<<"$RUN_OUT" | tail -1; }
ran_count() { [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || printf '0'; }

# --------------------------------------------------------------------------
# 1. BARE invocation is unchanged: every gate runs, exit 0, no partial marker.
#    This is the byte-identical-when-unset contract CI and humans depend on.
# --------------------------------------------------------------------------
M="$WORK/m1"; : >"$M"
run_qg "$M"
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = "$N_GATES" ] \
   && ! grep -q 'QUALITY_GATES_RESUME_AT=' <<<"$RUN_OUT" \
   && grep -q "OK — all $N_GATES quality gate(s) passed in" <<<"$RUN_OUT"; then
  pass "bare run: all $N_GATES gates run, exit 0, no resume marker"
else
  fail "bare run: rc=$RUN_RC ran=$(ran_count "$M") out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 2. The green run REPORTS ITS ELAPSED TIME — the decay signal. This is what
#    makes suite growth against any caller's budget observable BEFORE it
#    becomes a blown deadline (the #115 -> #1021 recurrence).
# --------------------------------------------------------------------------
if grep -qE 'OK — all [0-9]+ quality gate\(s\) passed in [0-9]+s' <<<"$RUN_OUT"; then
  pass "green run reports elapsed seconds (decay-margin signal)"
else
  fail "green run does not report elapsed seconds: $RUN_OUT"
fi

# --------------------------------------------------------------------------
# 3. BUDGETED run stops cleanly between gates: exit 75, resume marker in range,
#    zero failures reported, and only the gates up to the stop point ran.
#
#    Pinned to JOBS=1 on purpose. This case is about the slice ARITHMETIC and
#    the partial protocol, which are width-independent; at the default width the
#    pool finishes all six 1s gates well inside a 2s budget, so no partial fires
#    and the case would be asserting a stop that correctly never happened. The
#    chunked-pool partial is covered separately in case 12.
# --------------------------------------------------------------------------
M="$WORK/m3"; : >"$M"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=2 QUALITY_GATES_JOBS=1
resume="$(marker QUALITY_GATES_RESUME_AT)"
if [ "$RUN_RC" -eq 75 ] && [ -n "$resume" ] && [ "$resume" -gt 0 ] && [ "$resume" -lt "$N_GATES" ] \
   && [ "$(marker QUALITY_GATES_FAILED)" = "0" ] \
   && [ "$(ran_count "$M")" = "$resume" ]; then
  pass "budgeted run: exit 75, RESUME_AT=$resume, 0 failures, $resume gate(s) ran"
else
  fail "budgeted run: rc=$RUN_RC resume='$resume' ran=$(ran_count "$M") out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 4. RESUME runs exactly the tail: START_AT skips the already-run prefix.
# --------------------------------------------------------------------------
M="$WORK/m4"; : >"$M"
run_qg "$M" QUALITY_GATES_START_AT="$resume"
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = "$(( N_GATES - resume ))" ] \
   && ! grep -q '^g1$' "$M" && grep -q "^g$N_GATES\$" "$M" \
   && grep -q "final slice" <<<"$RUN_OUT"; then
  pass "resume run: START_AT=$resume runs exactly the remaining $(( N_GATES - resume )) gate(s)"
else
  fail "resume run: rc=$RUN_RC ran=$(ran_count "$M") out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 5. The FULL SLICE LOOP — the caller's real algorithm. Driving slices until a
#    non-75 exit must run every gate EXACTLY ONCE, in order, with no gap and no
#    repeat. This is the property that makes total suite runtime unbounded by
#    any single invocation's ceiling.
#
#    JOBS=1 (cases 3/7's reason): this case additionally asserts the loop took
#    more than ONE slice, and at the default width the pool finishes all six
#    gates inside the budget — a correct outcome that would fail a `slices > 1`
#    assertion. Case 13 drives the same exactly-once property through the pool.
# --------------------------------------------------------------------------
M="$WORK/m5"; : >"$M"
start=0; slices=0
while :; do
  run_qg "$M" QUALITY_GATES_BUDGET_SECS=2 QUALITY_GATES_START_AT="$start" QUALITY_GATES_JOBS=1
  slices=$(( slices + 1 ))
  [ "$RUN_RC" -eq 75 ] || break
  start="$(marker QUALITY_GATES_RESUME_AT)"
  [ -n "$start" ] || { fail "slice loop: exit 75 with no RESUME_AT marker"; break; }
  [ "$slices" -lt 20 ] || { fail "slice loop: did not terminate"; break; }
done
expected="$(printf 'g%s\n' 1 2 3 4 5 6)"
if [ "$RUN_RC" -eq 0 ] && [ "$slices" -gt 1 ] && [ "$(cat "$M")" = "$expected" ]; then
  pass "slice loop: $slices slices ran all $N_GATES gates exactly once, in order, final rc=0"
else
  fail "slice loop: rc=$RUN_RC slices=$slices ran='$(cat "$M")'"
fi

# --------------------------------------------------------------------------
# 6. A GENUINELY RED suite still fails — unsliced. The whole point of #1021 is
#    to stop calling a TIMEOUT a failure; it must not weaken the real failure.
# --------------------------------------------------------------------------
: >"$FAKE/g4.red"
M="$WORK/m6"; : >"$M"
run_qg "$M"
if [ "$RUN_RC" -eq 1 ] && [ "$(marker QUALITY_GATES_FAILED)" = "1" ] \
   && grep -q 'FAILED 1/6 quality gate(s)' <<<"$RUN_OUT"; then
  pass "red suite (unsliced): exit 1 and QUALITY_GATES_FAILED=1"
else
  fail "red suite (unsliced): rc=$RUN_RC out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 7. A RED gate found inside a PARTIAL slice is reported, not lost: the slice
#    still exits 75 (so the remaining gates still run — collect-all-failures is
#    preserved across a sliced run) but carries QUALITY_GATES_FAILED=1 so the
#    caller can accumulate it and fail at the end.
#
#    JOBS=1 for the same reason as case 3: the property under test is that a
#    failure found in a PARTIAL slice is carried rather than masked, and forcing
#    the partial deterministically is what makes the assertion meaningful.
# --------------------------------------------------------------------------
M="$WORK/m7"; : >"$M"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=1 QUALITY_GATES_START_AT=3 QUALITY_GATES_JOBS=1
if [ "$RUN_RC" -eq 75 ] && [ "$(marker QUALITY_GATES_FAILED)" = "1" ] \
   && [ "$(marker QUALITY_GATES_RESUME_AT)" = "4" ]; then
  pass "red gate in a partial slice: exit 75 with QUALITY_GATES_FAILED=1 (failure carried, not masked)"
else
  fail "red gate in a partial slice: rc=$RUN_RC out=$RUN_OUT"
fi
rm -f "$FAKE/g4.red"

# --------------------------------------------------------------------------
# 8. A budget spent on the LAST gate is a COMPLETED run, not a partial one —
#    no resume marker, exit 0. (Off-by-one guard: never ask a caller to resume
#    at an index past the end of the list.)
# --------------------------------------------------------------------------
M="$WORK/m8"; : >"$M"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=1 QUALITY_GATES_START_AT=5
if [ "$RUN_RC" -eq 0 ] && ! grep -q 'QUALITY_GATES_RESUME_AT=' <<<"$RUN_OUT"; then
  pass "budget spent on the last gate completes the run (no phantom resume index)"
else
  fail "budget spent on the last gate: rc=$RUN_RC out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 9. Garbage env values degrade to "unset" rather than crashing under `set -u`
#    arithmetic — a consuming repo can pass junk and still get today's behavior.
# --------------------------------------------------------------------------
M="$WORK/m9"; : >"$M"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=abc QUALITY_GATES_START_AT=-3
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = "$N_GATES" ]; then
  pass "non-numeric env values degrade to the unsliced default"
else
  fail "non-numeric env values: rc=$RUN_RC ran=$(ran_count "$M") out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 10. `--list` is unaffected by the slice seam (it must never consume a budget
#     or emit a marker — CI and the worker's path-scoping both call it).
# --------------------------------------------------------------------------
RUN_RC=0
RUN_OUT="$(env QUALITY_GATES_BUDGET_SECS=1 QUALITY_GATES_START_AT=3 \
  bash "$FAKE/scripts/quality-gates.sh" --list 2>&1)" || RUN_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$(grep -c '^\[kernel\]' <<<"$RUN_OUT")" = "$N_GATES" ] \
   && ! grep -q 'QUALITY_GATES_RESUME_AT=' <<<"$RUN_OUT"; then
  pass "--list ignores the slice seam and lists every gate"
else
  fail "--list: rc=$RUN_RC out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 11. The harness's slicing state does NOT leak into the gates it runs. The
#     caller sets these as a command-prefix assignment, which exports them to
#     every descendant — so a gate that itself exercises this seam would run
#     against the PARENT's indices. Caught live: this very suite, running as a
#     gate inside a sliced run, inherited START_AT=50 and failed. Same
#     hermeticity concern as the build.config.sh scrub (temperloop#1241).
# --------------------------------------------------------------------------
M="$WORK/m11"; : >"$M"; rm -f "$M.env"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=2 QUALITY_GATES_START_AT=1
if [ -s "$M.env" ] && ! grep -qv 'start=unset budget=unset' "$M.env"; then
  pass "the harness's slice state is unset for every gate it spawns (no leak into nested runs)"
else
  fail "slice state leaked into a gate's environment: $(cat "$M.env" 2>/dev/null)"
fi

# --------------------------------------------------------------------------
# 12. The slice seam composes with the PARALLEL pool (temperloop#1021 x #1025).
#     The budget is checked between CHUNKS rather than between gates, so a
#     partial must still stop on a gate boundary, report a resume index that is
#     a whole number of gates in, and never report a gate it did not run.
#     Width 2 with a 1s budget over six 1s gates: chunk 1 (g1,g2) lands at ~1s,
#     the budget is spent, four gates remain -> partial at index 2.
# --------------------------------------------------------------------------
M="$WORK/m12"; : >"$M"
run_qg "$M" QUALITY_GATES_BUDGET_SECS=1 QUALITY_GATES_JOBS=2
resume12="$(marker QUALITY_GATES_RESUME_AT)"
if [ "$RUN_RC" -eq 75 ] && [ -n "$resume12" ] \
   && [ "$resume12" -gt 0 ] && [ "$resume12" -lt "$N_GATES" ] \
   && [ "$(ran_count "$M")" = "$resume12" ] \
   && grep -q 'parallel worker(s) in chunks of 2' <<<"$RUN_OUT"; then
  pass "pooled partial: chunked run stops on a gate boundary, RESUME_AT=$resume12, $resume12 gate(s) ran"
else
  fail "pooled partial: rc=$RUN_RC resume='$resume12' ran=$(ran_count "$M") out=$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 13. The full slice loop AT POOL WIDTH still covers every gate exactly once.
#     This is case 5's property — no gap, no repeat — but driven through the
#     chunked pool, which is the path /build's §3e.5 slice loop actually takes
#     now. A chunk boundary that mis-reported its resume index would show up
#     here as a duplicated or skipped gate.
# --------------------------------------------------------------------------
M="$WORK/m13"; : >"$M"
start=0; slices=0
while :; do
  run_qg "$M" QUALITY_GATES_BUDGET_SECS=1 QUALITY_GATES_START_AT="$start" QUALITY_GATES_JOBS=2
  slices=$(( slices + 1 ))
  [ "$RUN_RC" -eq 75 ] || break
  start="$(marker QUALITY_GATES_RESUME_AT)"
  [ -n "$start" ] || { fail "pooled slice loop: exit 75 with no RESUME_AT marker"; break; }
  [ "$slices" -lt 20 ] || { fail "pooled slice loop: did not terminate"; break; }
done
expected13="$(printf 'g%s\n' 1 2 3 4 5 6)"
if [ "$RUN_RC" -eq 0 ] && [ "$slices" -gt 1 ] \
   && [ "$(sort "$M" | tr -d ' ')" = "$(printf '%s\n' "$expected13" | sort | tr -d ' ')" ]; then
  pass "pooled slice loop: $slices slices ran all $N_GATES gates exactly once (no gap, no repeat)"
else
  fail "pooled slice loop: rc=$RUN_RC slices=$slices ran='$(cat "$M")'"
fi

echo
if [ "$fail_count" -gt 0 ]; then
  echo "FAILED $fail_count check(s) — quality-gates.sh sliced execution (temperloop#1021)" >&2
  exit 1
fi
echo "OK — quality-gates.sh sliced execution (temperloop#1021)"
