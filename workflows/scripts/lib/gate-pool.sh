#!/usr/bin/env bash
#
# gate-pool.sh — the BOUNDED-CONCURRENCY scheduler scripts/quality-gates.sh runs
# its gate list through (temperloop#1025).
#
# Sourced, never executed — same seam as its two siblings checkout-freshness.sh
# and gate-retry.sh, which quality-gates.sh already sources. It exists as a lib
# for the same reason gate-retry.sh does: quality-gates.sh's gate LIST is ~109
# hardcoded `make`/`bash` targets, so a scheduling policy embedded in that file
# could not be exercised by a test without running the whole suite. Here it
# takes synthetic worker functions and is testable in milliseconds
# (scripts/tests/test_quality_gates_parallel.sh).
#
# ── The problem ──────────────────────────────────────────────────────────
# The gate set is ~109 INDEPENDENT suites run strictly one after another, and
# the `checks` job's ~5.5 min wall time is almost entirely that serialization:
# the measured 2026-08-02 baseline has no dominant gate (test-try 56s,
# test-build 55s, shellcheck 29s, test-board 21s, prose-budget ~20s, then a long
# tail of 1–5s suites), so no single-gate optimization can recover it. Only
# running them concurrently can.
#
# ── The three hazards, and how each is handled ───────────────────────────
#   1. A LOST VERDICT. The whole point of the gate is its exit code; a non-zero
#      swallowed by a pipe, a subshell, or an unreaped child would make CI green
#      on a real failure. Every safety choice here is FAIL-CLOSED:
#        * each child writes its verdict to its OWN meta file and exits with the
#          gate's own status; the parent reads BOTH and requires them to agree —
#          a disagreement, a missing meta file, an unparseable status, or a child
#          that vanished without writing one is recorded as a FAILURE, never a
#          pass (gate_pool_run's `verdict lost` path);
#        * the parent asserts it recorded exactly as many verdicts as it was
#          handed gates, so a gate cannot be silently dropped from the run;
#        * `wait` is called on every launched pid, so no child is left unreaped
#          and no exit status is discarded.
#      NOTE the deliberate asymmetry: an ERROR in this scheduler degrades toward
#      FAILING the run, never toward passing it. Serial execution is always
#      correct, so gate_pool_init failing (no mktemp) makes the caller fall back
#      to the serial loop rather than proceed on a weaker guarantee.
#   2. UNREADABLE OUTPUT. Interleaved stdout from ~109 concurrent suites is
#      useless on a failure. Each gate's output is captured whole and REPLAYED
#      in the original gate-list order, under the same `=== <gate> ===` header
#      the serial loop prints — so a log diff between a serial and a parallel run
#      shows the same blocks in the same order. A one-line `[ok]`/`[FAIL]`
#      progress marker goes to stderr as each gate is reaped, so a long run is
#      not silent.
#   3. A CHANGED EXECUTION ENVIRONMENT. A gate must observe the SAME process
#      environment it did under the serial loop, or "identical pass/fail
#      semantics" is a claim rather than a fact. One divergence is not obvious
#      and bit this change in CI: bash sets SIGINT and SIGQUIT to SIG_IGN in an
#      ASYNCHRONOUS child when job control is off, and marks them hard-ignored,
#      so the disposition is inherited by the gate's whole process tree and
#      cannot be reset from inside it. Any suite that asserts on signal death
#      then silently sees the wrong answer — test_gh_call_logger.sh's
#      "Ctrl-C -> 130" case observed 0, because its fixture's `kill -INT $$`
#      had become a no-op. _gate_pool_spawn therefore forks under job control
#      (`set -m`), the documented condition under which bash does NOT install
#      that ignore; see its own comment for the full contract.
#   4. SHARED MUTABLE STATE. Gates that contend over one resource (a shared
#      binary cache, a whole-tree scan racing a whole-tree write) must not run
#      concurrently WITH EACH OTHER. Rather than serialize the whole run, this
#      scheduler runs them in ONE dedicated SERIAL LANE: lane gates are mutually
#      exclusive with each other, and still overlap the rest of the pool, so
#      pinning a slow gate serial costs (almost) no wall time. The caller
#      declares which gates are lane gates; see quality-gates.sh's own
#      SERIAL_LANE_PINS for the audited list and the reason for each entry.
#
# ── Interface ────────────────────────────────────────────────────────────
#   gate_pool_resolve_jobs <spec>    — echo the worker count for `auto` | <n>
#   gate_pool_init                   — allocate scratch (returns 1 on failure,
#                                      which the caller MUST treat as "run
#                                      serially instead")
#   gate_pool_run <jobs> <worker_fn> — run the gates in GATE_POOL_GATES
#
# gate_pool_run reads two same-length caller-set arrays (globals, matching the
# way quality-gates.sh already holds its gate list):
#
#   GATE_POOL_GATES[i]   the i-th gate's full command line
#   GATE_POOL_LANE[i]    "serial" — the dedicated mutually-exclusive lane
#                        "slow"   — the pool, but DISPATCHED FIRST
#                        anything else (or unset) — the pool, in list order
#
# `slow` is a pure scheduling hint with no correctness meaning: makespan is
# `max(total/jobs, when-the-longest-gate-starts + its length)`, so a 56s gate
# sitting at position 96 of 109 can straggle past the point every other worker
# has gone idle. Hoisting the handful of known-long gates to the front of the
# dispatch queue is the standard longest-processing-time-first mitigation. It
# does NOT change replay order — output is always replayed in list order.
#
# and invokes `<worker_fn> "<gate>"` once per gate in a forked subshell whose
# stdout+stderr are captured. Before each call it exports two variables the
# worker needs:
#
#   GATE_POOL_META       path the worker MUST write its verdict line to, as
#                        `<status><TAB><attempts><TAB><note>`
#   GATE_POOL_LOG_TAG    a per-gate unique tag (the gate's list index) for any
#                        scratch file the worker keeps — passed straight to
#                        gate_run_with_retry so concurrent gates never share one
#                        attempt-capture file
#
# and sets, on return (all same-length, indexed by the input order):
#
#   GATE_POOL_STATUS[i]    pass | fail | deterministic
#   GATE_POOL_NOTE[i]      the worker's note ('' when it had nothing to explain)
#   GATE_POOL_SECONDS[i]   wall-clock seconds that gate took
#   GATE_POOL_WALL         wall-clock seconds the whole run took
#   GATE_POOL_SERIAL_SUM   sum of the per-gate times = what a SERIAL run of the
#                          same set costs, so the speedup is measured, not
#                          assumed (kernel § Measure the delta, don't assume it)
#
# Returns 0 when every gate passed, 1 otherwise.
#
# ── Portability ──────────────────────────────────────────────────────────
# bash 3.2 (the macOS system bash) has no `wait -n`, so completion is detected
# by polling for a per-child DONE marker that the child creates with an atomic
# `mv` as its very last act — never by `kill -0`, which cannot distinguish a
# running child from an unreaped zombie. Only POSIX tools are used; `date +%s`
# is the clock (no `date +%N`, which BSD `date` prints literally).

set -o pipefail

# PRIVATE state — lowercase-`_`-prefixed on purpose, exactly as gate-retry.sh's
# own scratch dir is: the kernel setting-registry sweep keys "operator-tunable"
# off an ALL-CAPS name, and none of this is operator-tunable.
_gate_pool_tmpdir=""
_gate_pool_running_pids=""
_gate_pool_last_pid=""
_gate_pool_child_idx=""
_gate_pool_child_dir=""

# Poll interval, in seconds, between completion sweeps. A plain constant, not a
# setting: it trades a few milliseconds of latency per gate against parent CPU,
# and no operator has a reason to tune it.
_gate_pool_poll_interval="0.1"

# Hard ceiling on the AUTO-detected worker count. A plain constant, not a
# setting: an operator who wants a different width sets QUALITY_GATES_JOBS
# explicitly, and this is the ceiling on the AUTOMATIC guess only.
#
# The value is MEASURED, not guessed, and going higher is measurably WORSE.
# A gate is not one process — it is usually a `make` target that forks a whole
# multi-process test suite — so N workers is already far more than N concurrent
# processes. Full-suite runs of this repo on a 10-core machine:
#
#   width 8 → 176s wall, and THREE gates failed their first attempt and only
#             passed on retry; the two retried gates were the two slowest gates
#             in the run, i.e. the flakes were themselves setting the makespan
#   width 4 → 162s wall, ZERO retries
#
# So the cap is not a safety-vs-speed trade — past this point oversubscription
# costs BOTH. The mechanism behind the width-8 flakes is documented in
# docs/features/quality-gates.md § Parallel execution ("the SIGPIPE-under-
# pipefail hazard"); it is a latent defect in the test suites themselves that
# concurrency merely exposes, so raising this cap without fixing that first
# would trade real correctness signal for no wall-clock gain.
_gate_pool_auto_cap=4

# gate_pool_resolve_jobs <spec> — echo the concrete worker count.
#   auto | ''  → detected core count, clamped to [1.._gate_pool_auto_cap]
#   <n>        → n (clamped to >= 1)
#   anything else → 1 (SERIAL: an unparseable setting must never silently pick a
#                  concurrency the operator did not ask for)
gate_pool_resolve_jobs() {
  local spec="${1:-auto}" n=""
  case "$spec" in
    auto | AUTO | "")
      if command -v nproc >/dev/null 2>&1; then
        n="$(nproc 2>/dev/null)"
      fi
      if [ -z "$n" ] && command -v sysctl >/dev/null 2>&1; then
        n="$(sysctl -n hw.ncpu 2>/dev/null)"
      fi
      case "$n" in
        '' | *[!0-9]*) n=2 ;;
      esac
      [ "$n" -gt "$_gate_pool_auto_cap" ] && n="$_gate_pool_auto_cap"
      ;;
    *[!0-9]*) n=1 ;;
    *) n="$spec" ;;
  esac
  [ "$n" -lt 1 ] && n=1
  printf '%s\n' "$n"
}

# gate_pool_init — allocate the per-gate capture scratch.
#
# Returns 1 when it cannot (no mktemp): the caller MUST then run serially. This
# is the fail-CLOSED half of hazard 1 above — unlike gate-retry.sh's classifier
# scratch (whose absence only costs an optimization), this dir holds the
# VERDICTS, so a pool run without it could not report them.
#
# Cleanup covers gate-retry.sh's scratch dir too. bash traps are per-signal, not
# stacked, so this EXIT trap REPLACES the one gate_retry_init installs — hence
# it removes both dirs, and hence gate_retry_init must be called FIRST (the
# order quality-gates.sh uses, pinned by this lib's test suite).
gate_pool_init() {
  [ -n "$_gate_pool_tmpdir" ] && return 0
  _gate_pool_tmpdir="$(mktemp -d 2>/dev/null || true)"
  [ -n "$_gate_pool_tmpdir" ] || return 1
  trap '_gate_pool_cleanup' EXIT
  return 0
}

_gate_pool_cleanup() {
  # Kill anything still running first — an interrupted run must not leave
  # orphaned `make` subtrees chewing on the checkout after the parent is gone.
  #
  # The GROUP is killed, not just the child: _gate_pool_spawn forks under job
  # control, so each child leads its own process group and `kill -- -<pid>`
  # reaches the whole `make` subtree beneath it. `kill <pid>` remains as the
  # fallback for the (unexpected) case where the group no longer exists.
  local pid
  # shellcheck disable=SC2086  # deliberate word-split of the space-separated pid list
  for pid in $_gate_pool_running_pids; do
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  [ -n "${_gate_pool_tmpdir:-}" ] && rm -rf "$_gate_pool_tmpdir"
  [ -n "${_gate_retry_tmpdir:-}" ] && rm -rf "$_gate_retry_tmpdir"
  return 0
}

# _gate_pool_child_done <rc> — publish this child's completion marker.
#
# Split out of the child body so it can be driven from an EXIT trap. `mv` is
# what makes the marker atomic: a plain `>` could be observed half-written by
# the parent's poll and read back as a bogus exit status.
_gate_pool_child_done() {
  printf '%s\n' "$1" >"$_gate_pool_child_dir/$_gate_pool_child_idx.done.part"
  mv -f "$_gate_pool_child_dir/$_gate_pool_child_idx.done.part" \
    "$_gate_pool_child_dir/$_gate_pool_child_idx.done"
}

# _gate_pool_child <idx> <worker_fn> <dir> — one gate's child body (runs inside
# the forked subshell; bash resets traps in a subshell, so the parent's cleanup
# trap is NOT inherited here and this child owns its own EXIT trap outright).
#
# The completion marker is published FROM THE EXIT TRAP rather than inline, so a
# worker that dies abruptly — an unbound variable under `set -u`, a `set -e`
# abort, an OOM kill — STILL publishes one. Without that, the parent's poll
# would wait forever on a child that can never finish: a hang is the one failure
# mode worse than a red gate, because it burns the whole CI job's timeout and
# reports nothing.
_gate_pool_child() {
  local idx="$1" worker="$2" dir="$3"
  GATE_POOL_META="$dir/$idx.meta"
  GATE_POOL_LOG_TAG="$idx"
  export GATE_POOL_META GATE_POOL_LOG_TAG
  _gate_pool_child_idx="$idx"
  _gate_pool_child_dir="$dir"
  trap '_gate_pool_child_done $?' EXIT
  "$worker" "${GATE_POOL_GATES[$idx]}" >"$dir/$idx.log" 2>&1
}

# _gate_pool_spawn <idx> <worker_fn> — fork one gate.
#
# JOB CONTROL IS LOAD-BEARING, not a style choice (hazard 3 above). When job
# control is OFF — the default in a script — bash runs every asynchronous
# command with SIGINT and SIGQUIT set to SIG_IGN, *and* marks them hard-ignored,
# so:
#   * the ignore is inherited across fork AND exec, i.e. by `make`, by the
#     suite it forks, and by every fixture below that;
#   * nothing inside the gate can undo it — `trap - INT` cannot restore a
#     disposition bash considers ignored-on-entry.
# A gate that asserts on signal death therefore gets a DIFFERENT answer than it
# did under the serial loop (where gates ran in the foreground and kept the
# default disposition). That is not a hypothetical: it turned
# test_gh_call_logger.sh's `kill -INT $$` fixture into a no-op, so the shim's
# "signal death propagates as 130" case saw 0 and the gate failed in CI —
# deterministically, twice, which is exactly the class of divergence the
# "identical pass/fail semantics" contract exists to forbid.
#
# `set -m` is the fix because bash installs that ignore only in the job-control-
# off branch. Verified on bash 3.2 (macOS system bash) and bash 5.x, with and
# without a controlling terminal: no job-status notices are printed in a
# non-interactive shell, and `wait` still yields the child's exit status.
#
# Two consequences, both handled:
#   * each child becomes its own process-group leader — which is why
#     _gate_pool_cleanup can now kill the child's whole GROUP and finally reap
#     the `make` subtree an interrupted run used to orphan;
#   * a background process group that reads the terminal is stopped by SIGTTIN,
#     which would wedge the poll — so a child's stdin is pinned to /dev/null.
#     No gate reads stdin (in CI it is already /dev/null), and a gate that tried
#     would be unusable under ANY concurrency, competing for the operator's
#     keystrokes with every other worker.
#
# The prior `-m` state is restored so this stays invisible to the caller.
_gate_pool_spawn() {
  local idx="$1" worker="$2" restore_m=""
  case "$-" in
    *m*) ;;
    *) restore_m=1 ;;
  esac
  set -m
  ( _gate_pool_child "$idx" "$worker" "$_gate_pool_tmpdir" ) </dev/null &
  _gate_pool_last_pid=$!
  if [ -n "$restore_m" ]; then set +m; fi
  _gate_pool_running_pids="$_gate_pool_running_pids $_gate_pool_last_pid"
}

# _gate_pool_forget_pid <pid> — drop a reaped child from the kill-on-exit list.
_gate_pool_forget_pid() {
  local keep="" p
  # shellcheck disable=SC2086  # deliberate word-split of the space-separated pid list
  for p in $_gate_pool_running_pids; do
    [ "$p" = "$1" ] && continue
    keep="$keep $p"
  done
  _gate_pool_running_pids="$keep"
}

# GATE_POOL_* are OUT-PARAMS written here and read by the sourcing caller (this
# is a sourced lib, not a program), so the static linter's "appears unused" is a
# false positive for the whole function.
# shellcheck disable=SC2034
gate_pool_run() {
  local jobs="$1" worker="$2"
  local total="${#GATE_POOL_GATES[@]}"
  local dir="$_gate_pool_tmpdir"
  local run_start run_end

  GATE_POOL_STATUS=()
  GATE_POOL_NOTE=()
  GATE_POOL_SECONDS=()
  GATE_POOL_WALL=0
  GATE_POOL_SERIAL_SUM=0

  [ -n "$dir" ] || { echo "gate_pool_run: gate_pool_init was not called" >&2; return 1; }
  [ "$total" -gt 0 ] || return 0

  run_start="$(date +%s)"

  # Dispatch queues over the SAME index space — replay order stays list order
  # regardless of what these do (see the `slow` note in the header).
  local -a lane_q=() slow_q=() pool_q=()
  local i
  for ((i = 0; i < total; i++)); do
    GATE_POOL_STATUS[i]=""
    GATE_POOL_NOTE[i]=""
    GATE_POOL_SECONDS[i]=0
    case "${GATE_POOL_LANE[$i]:-pool}" in
      serial) lane_q+=("$i") ;;
      slow) slow_q+=("$i") ;;
      *) pool_q+=("$i") ;;
    esac
  done
  # Longest-processing-time-first: the `slow` hints lead the pool queue.
  # bash 3.2 errors on "${empty[@]}" under `set -u`, so both splices are
  # count-guarded.
  if [ "${#slow_q[@]}" -gt 0 ]; then
    if [ "${#pool_q[@]}" -gt 0 ]; then
      pool_q=("${slow_q[@]}" "${pool_q[@]}")
    else
      pool_q=("${slow_q[@]}")
    fi
  fi

  # Slot table. An empty slot_pid means the slot is free.
  local -a slot_pid=() slot_idx=() slot_start=()
  local s
  for ((s = 0; s < jobs; s++)); do
    slot_pid[s]=""
    slot_idx[s]=-1
    slot_start[s]=0
  done

  local lane_next=0 pool_next=0 lane_busy=0
  local launched=0 reaped=0 next_print=0
  local -a done_flag=()
  for ((i = 0; i < total; i++)); do done_flag[i]=0; done

  while [ "$reaped" -lt "$total" ]; do
    # --- launch into every free slot -------------------------------------
    for ((s = 0; s < jobs; s++)); do
      [ -n "${slot_pid[$s]}" ] && continue
      local idx=""
      # The dedicated serial lane gets first refusal on a free slot: its gates
      # are the ones that cannot overlap each other, so starting them early
      # keeps the lane off the critical path at the end of the run.
      if [ "$lane_busy" -eq 0 ] && [ "$lane_next" -lt "${#lane_q[@]}" ]; then
        idx="${lane_q[$lane_next]}"
        lane_next=$((lane_next + 1))
        lane_busy=1
      elif [ "$pool_next" -lt "${#pool_q[@]}" ]; then
        idx="${pool_q[$pool_next]}"
        pool_next=$((pool_next + 1))
      fi
      [ -n "$idx" ] || break
      _gate_pool_spawn "$idx" "$worker"
      slot_pid[s]="$_gate_pool_last_pid"
      slot_idx[s]="$idx"
      slot_start[s]="$(date +%s)"
      launched=$((launched + 1))
    done

    # --- reap every finished slot ----------------------------------------
    local progressed=0
    for ((s = 0; s < jobs; s++)); do
      [ -n "${slot_pid[$s]}" ] || continue
      local sidx="${slot_idx[$s]}"
      [ -f "$dir/$sidx.done" ] || continue
      local child_rc=0
      wait "${slot_pid[$s]}" || child_rc=$?
      _gate_pool_forget_pid "${slot_pid[$s]}"
      _gate_pool_record "$sidx" "$child_rc" "$(($(date +%s) - ${slot_start[$s]}))"
      done_flag[sidx]=1
      [ "${GATE_POOL_LANE[$sidx]:-pool}" = "serial" ] && lane_busy=0
      slot_pid[s]=""
      slot_idx[s]=-1
      reaped=$((reaped + 1))
      progressed=1
    done

    # --- replay finished gates, strictly in list order --------------------
    while [ "$next_print" -lt "$total" ] && [ "${done_flag[$next_print]}" -eq 1 ]; do
      printf '\n=== %s ===\n' "${GATE_POOL_GATES[$next_print]}"
      [ -f "$dir/$next_print.log" ] && cat "$dir/$next_print.log"
      next_print=$((next_print + 1))
    done

    [ "$reaped" -lt "$total" ] && [ "$progressed" -eq 0 ] && sleep "$_gate_pool_poll_interval"
  done

  # --- fail-closed accounting ---------------------------------------------
  # Every gate handed in must have produced a verdict. A short count means a
  # gate was silently dropped — the exact failure mode a parallel scheduler must
  # never have, so it is reported as a run failure, not a warning.
  local rc=0 recorded=0
  for ((i = 0; i < total; i++)); do
    [ -n "${GATE_POOL_STATUS[$i]}" ] && recorded=$((recorded + 1))
    [ "${GATE_POOL_STATUS[$i]}" = "pass" ] || rc=1
  done
  if [ "$recorded" -ne "$total" ]; then
    printf 'gate_pool_run: BUG — recorded %d verdict(s) for %d gate(s); failing closed.\n' \
      "$recorded" "$total" >&2
    rc=1
  fi

  run_end="$(date +%s)"
  GATE_POOL_WALL=$((run_end - run_start))
  for ((i = 0; i < total; i++)); do
    GATE_POOL_SERIAL_SUM=$((GATE_POOL_SERIAL_SUM + GATE_POOL_SECONDS[i]))
  done
  return "$rc"
}

# _gate_pool_record <idx> <child_rc> <seconds> — reconcile one child's two
# independent verdict channels into the recorded status.
#
# The meta file is the RICH channel (it carries the retry classification); the
# child's exit status is the CROSS-CHECK. They must agree. Any of: no meta file,
# an unrecognized status, or a status that disagrees with the exit code, records
# a FAILURE — a scheduler bug must never be able to turn a red gate green.
#
# GATE_POOL_* here are the same OUT-PARAMS gate_pool_run documents, and
# `attempts` is read off the meta line for shape-validation only.
# shellcheck disable=SC2034
_gate_pool_record() {
  local idx="$1" child_rc="$2" secs="$3"
  local dir="$_gate_pool_tmpdir"
  local status="" attempts="" note=""

  if [ -f "$dir/$idx.meta" ]; then
    IFS=$'\t' read -r status attempts note <"$dir/$idx.meta"
  fi
  : "${attempts:=}"

  case "$status" in
    pass | fail | deterministic) ;;
    *)
      status="fail"
      note="verdict lost — the worker wrote no usable meta line (exit $child_rc); failing closed"
      ;;
  esac

  if [ "$status" = "pass" ] && [ "$child_rc" -ne 0 ]; then
    status="fail"
    note="verdict MISMATCH — worker reported pass but exited $child_rc; failing closed"
  elif [ "$status" != "pass" ] && [ "$child_rc" -eq 0 ]; then
    note="verdict MISMATCH — worker reported $status but exited 0; failing closed"
  fi

  GATE_POOL_STATUS[idx]="$status"
  GATE_POOL_NOTE[idx]="$note"
  GATE_POOL_SECONDS[idx]="$secs"

  if [ "$status" = "pass" ]; then
    printf '  [ok]   (%3ds) %s\n' "$secs" "${GATE_POOL_GATES[$idx]}" >&2
  else
    printf '  [FAIL] (%3ds) %s\n' "$secs" "${GATE_POOL_GATES[$idx]}" >&2
  fi
}
