#!/usr/bin/env bash
#
# test_quality_gates_parallel.sh — regression tests for the BOUNDED-CONCURRENCY
# scheduler scripts/quality-gates.sh runs its gate set through
# (workflows/scripts/lib/gate-pool.sh — temperloop#1025).
#
# Third sibling of test_quality_gates_freshness.sh and test_quality_gates_retry.sh,
# which cover the other two libs quality-gates.sh sources. Hermetic and fast:
# every "gate" here is a throwaway script under a tmpdir whose verdict, output
# and duration are scripted — no `make`, no network, and never this repo's real
# 109-target gate list (which is exactly why the scheduling policy lives in a
# sourceable lib: it could not otherwise be exercised without running the whole
# suite, which is the very cost this change exists to remove).
#
# The load-bearing property under test is EXIT-CODE INTEGRITY. A parallel runner
# whose worst failure mode is "a lost non-zero" would make CI green on a real
# failure — strictly worse than the slow serial loop it replaces. So the suite
# leans on the fail-closed paths (2, 3, 8, 9, 10) at least as hard as on the
# speedup (7).
#
# Covers, one case per contract clause:
#   1. every gate runs exactly once, and the replay is in LIST order regardless
#      of completion order (a fast gate finishing first must not jump the log)
#   2. one failing gate among passing ones → run returns non-zero, that gate and
#      only that gate is marked failed
#   3. FAIL-CLOSED: a worker that exits 0 but writes no verdict is recorded as a
#      FAILURE, not a pass
#   4. a worker's `deterministic` verdict survives the meta-file channel intact
#   5. SERIAL LANE: two lane-pinned gates never overlap each other, while still
#      overlapping the pool
#   6. `slow` gates are dispatched before ordinary pool gates
#   7. the pool really is concurrent — N one-second gates at width N finish in
#      about one second, not N
#   8. a worker that dies abruptly (unbound variable under `set -u`) still
#      completes the run — no hang — and is recorded as a failure
#   9. jobs resolution: `auto` is a sane positive integer, an explicit integer is
#      honored, and garbage degrades to 1 (serial) rather than to a guess
#  10. WIRING: quality-gates.sh really sources this lib, drives it, keeps a
#      serial fallback, and keeps CI on a single non-matrix job
#
# Usage: scripts/tests/test_quality_gates_parallel.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/workflows/scripts/lib/gate-pool.sh"
QG="$REPO_ROOT/scripts/quality-gates.sh"
CI="$REPO_ROOT/.github/workflows/ci.yml"

[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-pool-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=workflows/scripts/lib/gate-pool.sh
source "$LIB"

# ---------------------------------------------------------------------------
# A scripted worker. Each "gate" command line is `sh -c :`-shaped only in name;
# the worker below interprets the FIRST word as a directive so a case can script
# a verdict, a duration, and an interleaving trace without writing files.
#
#   pass:<name>[:<sleep>]   → verdict pass
#   fail:<name>[:<sleep>]   → verdict fail
#   det:<name>              → verdict deterministic
#   nometa:<name>           → exits 0 having written NO verdict (fail-closed)
#   boom:<name>             → dies on an unbound variable under `set -u`
#
# Every invocation appends `<name> start`/`<name> end` to $WORK/trace with a
# timestamp, which is how the overlap assertions below are made.
# ---------------------------------------------------------------------------
tw() {
  local spec="$1"
  local kind name secs
  kind="${spec%%:*}"
  name="${spec#*:}"
  secs="${name#*:}"
  name="${name%%:*}"
  case "$secs" in '' | "$name") secs=0 ;; esac

  printf '%s %s start %s\n' "$(date +%s)" "$name" "$$" >>"$WORK/trace"
  echo "output of $name"
  [ "$secs" != 0 ] && sleep "$secs"
  printf '%s %s end %s\n' "$(date +%s)" "$name" "$$" >>"$WORK/trace"

  case "$kind" in
    pass) printf 'pass\t1\t\n' >"$GATE_POOL_META"; return 0 ;;
    fail) printf 'fail\t3\t\n' >"$GATE_POOL_META"; return 1 ;;
    det) printf 'deterministic\t1\tsignature match\n' >"$GATE_POOL_META"; return 1 ;;
    nometa) return 0 ;;
    boom) echo "${THIS_IS_NOT_SET_ON_PURPOSE}"; return 0 ;;
  esac
}

# run_case <jobs> <lanes-csv> <gate>... — set up the pool arrays, run, capture
# stdout. <lanes-csv> is a comma-separated lane per gate, positionally ("" =
# all pool). Parallel arrays rather than an associative one on purpose: bash 3.2
# (the macOS system bash the nightly leg may run on) has no `declare -A`.
# Leaves the replayed log at $WORK/out and the verdicts in the GATE_POOL_*
# arrays.
run_case() {
  local jobs="$1" lanes_csv="$2"; shift 2
  GATE_POOL_GATES=("$@")
  GATE_POOL_LANE=()
  local i=0 g lane rest="$lanes_csv"
  for g in "$@"; do
    lane="${rest%%,*}"
    case "$rest" in *,*) rest="${rest#*,}" ;; *) rest="" ;; esac
    [ -n "$lane" ] || lane="pool"
    GATE_POOL_LANE+=("$lane")
    i=$((i + 1))
  done
  : >"$WORK/trace"
  _gate_pool_tmpdir=""
  gate_pool_init || { fail "gate_pool_init failed"; return 1; }
  gate_pool_run "$jobs" tw >"$WORK/out" 2>"$WORK/err"
  CASE_RC=$?
  return 0
}

# ---------------------------------------------------------------------------
# 1. Every gate runs once; replay is in LIST order regardless of finish order.
#    The first gate is the SLOWEST, so a naive "print as they finish" scheduler
#    would emit its block last and this assertion would catch it.
# ---------------------------------------------------------------------------
run_case 4 "" "pass:slowest:2" "pass:beta" "pass:gamma"
order="$(grep -c '^=== ' "$WORK/out")"
replayed="$(grep '^=== ' "$WORK/out" | tr '\n' '|')"
if [ "$order" = "3" ] && [ "$replayed" = "=== pass:slowest:2 ===|=== pass:beta ===|=== pass:gamma ===|" ]; then
  pass "every gate replayed exactly once, in LIST order (not completion order)"
else
  fail "replay order/count wrong: count=$order order=[$replayed]"
fi
if grep -q 'output of beta' "$WORK/out" && grep -q 'output of gamma' "$WORK/out"; then
  pass "each gate's captured output is replayed whole"
else
  fail "a gate's captured output is missing from the replay"
fi
if [ "$CASE_RC" -eq 0 ]; then
  pass "an all-passing run returns 0"
else
  fail "an all-passing run returned $CASE_RC"
fi

# ---------------------------------------------------------------------------
# 2. One failure among passes → non-zero, and only that gate is marked failed.
# ---------------------------------------------------------------------------
run_case 4 "" "pass:a" "fail:b" "pass:c"
if [ "$CASE_RC" -ne 0 ]; then
  pass "a run with one failing gate returns non-zero"
else
  fail "a run with a failing gate returned 0 — a LOST non-zero, the worst failure mode"
fi
if [ "${GATE_POOL_STATUS[0]}" = "pass" ] && [ "${GATE_POOL_STATUS[1]}" = "fail" ] \
  && [ "${GATE_POOL_STATUS[2]}" = "pass" ]; then
  pass "exactly the failing gate is marked failed"
else
  fail "verdicts misattributed: [${GATE_POOL_STATUS[0]} ${GATE_POOL_STATUS[1]} ${GATE_POOL_STATUS[2]}]"
fi

# ---------------------------------------------------------------------------
# 3. FAIL-CLOSED: a worker that exits 0 without writing a verdict is a FAILURE.
#    (A scheduler that treated "no news" as good news is exactly how a suite
#    silently stops gating.)
# ---------------------------------------------------------------------------
run_case 2 "" "pass:x" "nometa:y"
if [ "${GATE_POOL_STATUS[1]}" = "fail" ] && [ "$CASE_RC" -ne 0 ]; then
  pass "a verdict-less worker is recorded as a FAILURE, not a pass"
else
  fail "verdict-less worker recorded as [${GATE_POOL_STATUS[1]}], run rc=$CASE_RC"
fi
case "${GATE_POOL_NOTE[1]}" in
  *"verdict lost"* | *MISMATCH*) pass "the lost verdict is NAMED in the note, not silently swallowed" ;;
  *) fail "lost-verdict note is unhelpful: [${GATE_POOL_NOTE[1]}]" ;;
esac

# ---------------------------------------------------------------------------
# 4. A `deterministic` verdict survives the meta-file channel intact — the
#    retry classification must not be flattened to a plain fail by the pool.
# ---------------------------------------------------------------------------
run_case 2 "" "det:d"
if [ "${GATE_POOL_STATUS[0]}" = "deterministic" ] && [ "${GATE_POOL_NOTE[0]}" = "signature match" ]; then
  pass "a deterministic verdict + its note round-trip through the pool"
else
  fail "deterministic verdict lost: [${GATE_POOL_STATUS[0]}] note=[${GATE_POOL_NOTE[0]}]"
fi

# ---------------------------------------------------------------------------
# 5. SERIAL LANE: lane gates never overlap EACH OTHER, but do overlap the pool.
# ---------------------------------------------------------------------------
run_case 4 "serial,serial,pool,pool" "pass:lane1:2" "pass:lane2:2" "pass:p1:2" "pass:p2:2"
lane1_end="$(awk '$2=="lane1" && $3=="end" {print $1}' "$WORK/trace")"
lane2_start="$(awk '$2=="lane2" && $3=="start" {print $1}' "$WORK/trace")"
p1_start="$(awk '$2=="p1" && $3=="start" {print $1}' "$WORK/trace")"
lane1_start="$(awk '$2=="lane1" && $3=="start" {print $1}' "$WORK/trace")"
if [ -n "$lane1_end" ] && [ -n "$lane2_start" ] && [ "$lane2_start" -ge "$lane1_end" ]; then
  pass "two serial-lane gates never overlap each other"
else
  fail "serial-lane gates overlapped: lane1 ended $lane1_end, lane2 started $lane2_start"
fi
if [ -n "$p1_start" ] && [ -n "$lane1_start" ] && [ "$p1_start" -lt "$lane1_end" ]; then
  pass "a pool gate still overlaps the serial lane (pinning costs no wall time)"
else
  fail "the serial lane serialized the whole run: p1 started $p1_start, lane1 ended $lane1_end"
fi

# ---------------------------------------------------------------------------
# 6. `slow` gates are dispatched FIRST (longest-processing-time-first), so a
#    long gate at the end of the list cannot straggle past an idle pool.
# ---------------------------------------------------------------------------
run_case 1 "pool,pool,slow" "pass:head1" "pass:head2" "pass:tail"
first_started="$(awk '$3=="start" {print $2; exit}' "$WORK/trace")"
if [ "$first_started" = "tail" ]; then
  pass "a 'slow'-hinted gate is dispatched before ordinary pool gates"
else
  fail "'slow' hint ignored — first dispatched was [$first_started], expected tail"
fi
if [ "$(grep -c '^=== ' "$WORK/out")" = "3" ] \
  && [ "$(grep '^=== ' "$WORK/out" | head -1)" = "=== pass:head1 ===" ]; then
  pass "the 'slow' dispatch hint does NOT reorder the replay"
else
  fail "'slow' hint leaked into replay order"
fi

# ---------------------------------------------------------------------------
# 7. The pool is genuinely concurrent: 4 one-second gates at width 4 take about
#    a second, not four. This is the whole point of the change, so it is
#    asserted rather than assumed.
# ---------------------------------------------------------------------------
t0="$(date +%s)"
run_case 4 "" "pass:c1:1" "pass:c2:1" "pass:c3:1" "pass:c4:1"
elapsed=$(($(date +%s) - t0))
if [ "$elapsed" -le 2 ]; then
  pass "4x 1s gates at width 4 finished in ${elapsed}s (concurrent, not serialized)"
else
  fail "4x 1s gates at width 4 took ${elapsed}s — the pool is not running them concurrently"
fi
if [ "$GATE_POOL_SERIAL_SUM" -ge 4 ] && [ "$GATE_POOL_WALL" -le 2 ]; then
  pass "the measured serial-equivalent (${GATE_POOL_SERIAL_SUM}s) vs wall (${GATE_POOL_WALL}s) speedup is reported"
else
  fail "timing accounting wrong: serial_sum=$GATE_POOL_SERIAL_SUM wall=$GATE_POOL_WALL"
fi

# ---------------------------------------------------------------------------
# 8. A worker that dies ABRUPTLY still completes the run. The child publishes
#    its completion marker from an EXIT trap precisely so this cannot hang — a
#    hang would burn the whole CI job timeout and report nothing, which is worse
#    than any red gate. Guarded by a hard timeout so a regression FAILS rather
#    than wedging this suite.
# ---------------------------------------------------------------------------
(
  run_case 2 "" "pass:ok" "boom:dead"
  printf '%s\n' "$CASE_RC" >"$WORK/boom.rc"
  printf '%s\n' "${GATE_POOL_STATUS[1]}" >"$WORK/boom.status"
) &
boom_pid=$!
boom_waited=0
while kill -0 "$boom_pid" 2>/dev/null && [ "$boom_waited" -lt 20 ]; do
  sleep 1
  boom_waited=$((boom_waited + 1))
done
if kill -0 "$boom_pid" 2>/dev/null; then
  kill -9 "$boom_pid" 2>/dev/null
  fail "an abruptly-dying worker HUNG the pool (no completion marker published)"
else
  wait "$boom_pid" 2>/dev/null
  if [ "$(cat "$WORK/boom.status" 2>/dev/null)" = "fail" ] \
    && [ "$(cat "$WORK/boom.rc" 2>/dev/null)" != "0" ]; then
    pass "an abruptly-dying worker is recorded as a failure and never hangs the pool"
  else
    fail "abrupt worker death mis-recorded: status=[$(cat "$WORK/boom.status" 2>/dev/null)] rc=[$(cat "$WORK/boom.rc" 2>/dev/null)]"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Jobs resolution.
# ---------------------------------------------------------------------------
auto="$(gate_pool_resolve_jobs auto)"
case "$auto" in
  '' | *[!0-9]*) fail "gate_pool_resolve_jobs auto returned non-numeric [$auto]" ;;
  *)
    if [ "$auto" -ge 1 ] && [ "$auto" -le 4 ]; then
      pass "auto resolves to a sane clamped worker count ($auto)"
    else
      fail "auto resolved to $auto, outside the measured clamp (see gate-pool.sh's _gate_pool_auto_cap: width 8 was both slower AND flakier than width 4 on a 10-core box)"
    fi
    ;;
esac
[ "$(gate_pool_resolve_jobs 6)" = "6" ] \
  && pass "an explicit integer is honored" \
  || fail "explicit integer not honored (the cap must apply to auto only, never to an explicit request): [$(gate_pool_resolve_jobs 6)]"
[ "$(gate_pool_resolve_jobs banana)" = "1" ] \
  && pass "an unparseable setting degrades to SERIAL, never to a guessed width" \
  || fail "unparseable jobs setting resolved to [$(gate_pool_resolve_jobs banana)]"
[ "$(gate_pool_resolve_jobs 0)" = "1" ] \
  && pass "0 workers clamps to 1" \
  || fail "0 resolved to [$(gate_pool_resolve_jobs 0)]"

# ---------------------------------------------------------------------------
# 10. WIRING. Guards against a future refactor that quietly re-inlines a loop
#     (leaving this whole suite testing dead code), drops the serial fallback,
#     or "simplifies" CI into a matrix — which would rename the required
#     `checks (ubuntu-latest)` status context and silently un-gate the branch.
# ---------------------------------------------------------------------------
if grep -q 'workflows/scripts/lib/gate-pool.sh' "$QG" \
  && grep -q 'gate_pool_run' "$QG" \
  && grep -q 'gate_pool_init' "$QG" \
  && grep -q 'gate_pool_resolve_jobs' "$QG"; then
  pass "quality-gates.sh sources gate-pool.sh and drives the scheduler"
else
  fail "quality-gates.sh no longer wires gate-pool.sh — the scheduler this suite covers is not the one that runs"
fi
if grep -q 'SERIAL_LANE_PINS' "$QG" && grep -q 'gate_lane_of' "$QG"; then
  pass "the audited serial-lane pin list is still wired into the classification"
else
  fail "SERIAL_LANE_PINS / gate_lane_of missing — shared-state gates would run concurrently"
fi
if grep -q 'gate_pool_ready' "$QG" && grep -q 'gate_run_with_retry "$gate" ||' "$QG"; then
  pass "the serial fallback loop is still present (QUALITY_GATES_JOBS=1 / no scratch)"
else
  fail "the serial fallback loop is gone — there is no always-correct path left"
fi
if grep -q 'QUALITY_GATES_JOBS' "$REPO_ROOT/workflows/scripts/build/build.config.sh"; then
  pass "the worker count is a config-named setting, not a literal in the loop"
else
  fail "QUALITY_GATES_JOBS is not declared in build.config.sh"
fi
if [ -f "$CI" ]; then
  if grep -q 'os: \[ubuntu-latest\]' "$CI" && [ "$(grep -c '^  [a-z-]*:$' "$CI")" -le 2 ]; then
    pass "CI still runs ONE job on a single-entry matrix (required context unchanged)"
  else
    fail "CI's job/matrix shape changed — the required 'checks (ubuntu-latest)' context may have moved"
  fi
fi

echo "---"
if [ "$fail_count" -eq 0 ]; then
  echo "OK — all gate-pool checks passed"
else
  echo "$fail_count check(s) failed"
fi
[ "$fail_count" -eq 0 ]
