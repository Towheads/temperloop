#!/usr/bin/env bash
#
# batch-pool.sh — the bounded-concurrency scheduler batch.sh runs its corpus
# records through (temperloop#1682).
#
# Sourced, never executed, and flat in this directory rather than under
# workflows/scripts/lib/: both kernel-manifest.txt and feature-manifest.txt
# claim this directory by glob, so a file here is covered by construction
# while one a level up needs its own exact-path claim in both.
#
# ── The problem ──────────────────────────────────────────────────────────
# batch.sh drove legs strictly sequentially. Measured on the second A/A
# validation run (temperloop#1656): 29 min/leg, projecting ~27 hours for a
# 28-record comparison, with ~32% of that not model time at all but the
# in-worktree quality-gates.sh run. Every future A/B paid the same toll,
# which made the module impractical for the repeated comparisons it exists
# to support.
#
# ── THE ONE CONSTRAINT THAT SHAPES EVERYTHING HERE ───────────────────────
# Concurrency is across RECORDS, never within a pair. temperloop#1571 assigns
# each record's arm order by `((record_index + seed) % 2) == 1` and stamps
# every leg with an `execution_order.position` of 1 or 2; that position is
# only meaningful if a record's two legs run sequentially in a defined order.
# Running them concurrently would destroy the order-effect estimate the report
# publishes beside the arm effect — i.e. silently undo temperloop#1571 and
# re-open the confound temperloop#1606 was filed against.
#
# So the unit this file schedules is a WHOLE RECORD. The worker runs both of
# its legs itself, in order. This file never sees a leg.
#
# ── Lineage, and why this is not workflows/scripts/lib/gate-pool.sh ──────
# The mechanics below are gate-pool.sh's, deliberately: the slot table, the
# atomic per-child DONE marker polled rather than `kill -0`'d, the `set -m`
# fork, the child publishing its marker from its own EXIT trap. That file
# earned each of those against real CI failures and its header is worth
# reading for the reasoning.
#
# It is a second implementation rather than a second consumer because three
# of its properties are the opposite of what a spend-bearing batch needs:
#
#   * ITS VERDICT LAYER IS FAIL-CLOSED, and rightly so — it schedules the
#     gates that decide whether CI is green, so `_gate_pool_record` hard-codes
#     `pass|fail|deterministic` and turns anything else into a failure. Here a
#     failed leg is ORDINARY DATA: a record that cannot be replayed is
#     recorded and the batch continues (temperloop#1527's per-leg resilience).
#     Routing that through a fail-closed verdict layer would turn every
#     degraded batch into a failed run.
#   * IT OWNS THE EXIT TRAP outright, and batch.sh's EXIT/INT/TERM traps are
#     load-bearing: they tear down in-flight replay worktrees and re-raise so
#     the process dies OF the signal (temperloop#1527). bash traps are
#     per-signal, not stacked, so a second owner silently replaces the first.
#   * IT HAS NO EARLY ABORT. The circuit breaker (temperloop#1554) must stop
#     dispatch mid-run; gate-pool runs every gate it was handed.
#
# Adapting it would mean changing the fail-closed heart of the scheduler that
# gates every other change in this repo, to serve a module whose failure
# semantics are genuinely different. If a third consumer ever appears, the
# right move is to hoist the shared primitive out of both — not to bend
# either one into the other.
#
# One more deliberate difference: gate-pool CAPTURES each gate's output and
# REPLAYS it in list order, because 109 interleaved fast suites are unreadable.
# Here the workers stream straight to stderr. A leg is minutes long, the
# existing progress lines are self-identifying (`[3/28] baseline pr:1547 —
# scored`), and a multi-hour batch that goes silent until the end is worse
# than one whose lines interleave.
#
# ── Interface ────────────────────────────────────────────────────────────
#   bp_resolve_concurrency <spec> <cap>  — echo the concrete worker count
#   bp_init <scratch-dir>                — allocate the marker dir (1 on fail)
#   bp_run <n> <worker_fn> <abort_fn>    — run BP_UNITS through <worker_fn>
#   bp_kill_running                      — kill every live worker's GROUP
#
# bp_run reads one caller-set array:
#
#   BP_UNITS[i]   the i-th unit, passed verbatim as the worker's only argument
#
# and invokes `<worker_fn> "${BP_UNITS[$i]}"` in a forked subshell. Before
# each launch it consults `<abort_fn>`: a ZERO exit means stop dispatching.
# Units already running are allowed to finish — see the note in bp_run.
#
# On return it sets:
#   BP_LAUNCHED      how many units were actually dispatched
#   BP_SKIPPED       how many were never dispatched because <abort_fn> said stop
#   BP_MAX_INFLIGHT  the high-water mark of simultaneously-running workers
#   BP_INFLIGHT_AT_ABORT
#                    how many units were still RUNNING at the moment the abort
#                    gate first said stop. They are allowed to finish, so this
#                    is what the caller needs to say honestly how much ran
#                    after the stop condition was reached
#   BP_WALL          wall-clock seconds the whole run took
#   BP_SERIAL_SUM    sum of the per-unit times = what a SERIAL run of the same
#                    set costs, so a speedup is MEASURED rather than assumed
#                    (kernel § Measure the delta, don't assume it)
#
# BP_MAX_INFLIGHT is not diagnostics. It is the only honest way to assert that
# concurrency HAPPENED: a pool that silently ran serially would satisfy every
# other property a test can check, including "the two legs of a record never
# overlap", which a serial run satisfies trivially.
#
# Returns 0 always — a unit's outcome is the caller's business, recorded by
# the worker itself. The one thing bp_run refuses to do silently is lose a
# unit: a worker that dies without publishing a marker still publishes one
# from its EXIT trap, and bp_run asserts it reaped exactly what it launched.
#
# ── Portability ──────────────────────────────────────────────────────────
# bash 3.2 (the macOS system bash) has no `wait -n`, so completion is detected
# by polling for a per-child DONE marker the child creates with an atomic `mv`
# as its very last act — never by `kill -0`, which cannot distinguish a running
# child from an unreaped zombie. No mapfile, no associative arrays, no `${v,,}`.
# `date +%s` is the clock (no `date +%N`, which BSD `date` prints literally).

# PRIVATE state — lowercase `_`-prefixed on purpose, exactly as gate-pool.sh's
# is: the kernel setting-registry sweep keys "operator-tunable" off an ALL-CAPS
# name, and none of this is operator-tunable.
_bp_dir=""
_bp_running_pids=""
_bp_last_pid=""
_bp_child_idx=""
_bp_child_dir=""

# Poll interval between completion sweeps, in seconds. A plain constant, not a
# setting: against a unit that runs for minutes it is noise either way, and no
# operator has a reason to tune it.
_bp_poll_interval="0.2"

# bp_resolve_concurrency <spec> <cap> — echo the concrete worker count.
#
#   <n>            → n, clamped to [1..cap]
#   anything else  → 1
#
# An unparseable spec resolves to SERIAL, never to a concurrency nobody asked
# for — the same rule gate_pool_resolve_jobs uses, and for the same reason: a
# typo in a setting must not silently widen a spend-bearing batch.
#
# There is deliberately no `auto`. gate-pool has one because its bound is local
# CPU; the bound here is the PROVIDER'S RATE LIMIT, which no amount of hardware
# detection can read. temperloop#1554's 28-leg outage happened on a strictly
# SEQUENTIAL run — cores were never the ceiling — so guessing a width from
# `nproc` would dress a rate-limit gamble up as a measurement.
bp_resolve_concurrency() {
  local spec="${1:-1}" cap="${2:-1}" n=""
  case "$spec" in
    '' | *[!0-9]*) n=1 ;;
    *) n="$spec" ;;
  esac
  case "$cap" in
    '' | *[!0-9]*) cap=1 ;;
  esac
  [ "$cap" -lt 1 ] && cap=1
  [ "$n" -lt 1 ] && n=1
  [ "$n" -gt "$cap" ] && n="$cap"
  printf '%s\n' "$n"
}

# bp_init <scratch-dir> — allocate the per-unit marker dir under the caller's
# own scratch, so it is torn down by the caller's existing cleanup rather than
# by a trap this file installs (see the header's trap-ownership note).
#
# Returns 1 when it cannot. The caller MUST then run serially: serial execution
# is always correct, so a pool that cannot allocate degrades to the loop it
# replaced rather than proceeding on a weaker guarantee.
bp_init() {
  [ -n "${1:-}" ] || return 1
  _bp_dir="$1/pool"
  mkdir -p "$_bp_dir" || { _bp_dir=""; return 1; }
  return 0
}

# bp_kill_running — kill every live worker's process GROUP.
#
# The GROUP, not the pid: _bp_spawn forks under job control, so each child
# leads its own group and `kill -- -<pid>` reaches the replay.sh /
# quality-gates.sh subtree beneath it. Without that, an interrupted batch
# leaves those chewing on worktrees the parent is about to tear down.
#
# Called by batch.sh's own signal handler, never from a trap installed here.
bp_kill_running() {
  local pid
  # shellcheck disable=SC2086  # deliberate word-split of the pid list
  for pid in $_bp_running_pids; do
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  done
  _bp_running_pids=""
  return 0
}

# _bp_child_done <rc> — publish this child's completion marker.
#
# Split out so it can be driven from an EXIT trap, and `mv` is what makes it
# atomic: a plain `>` could be observed half-written by the parent's poll.
_bp_child_done() {
  printf '%s\n' "$1" >"$_bp_child_dir/$_bp_child_idx.done.part"
  mv -f "$_bp_child_dir/$_bp_child_idx.done.part" "$_bp_child_dir/$_bp_child_idx.done"
}

# _bp_child <idx> <worker_fn> <dir> — one unit's child body.
#
# The marker is published FROM THE EXIT TRAP rather than inline, so a worker
# that dies abruptly — an unbound variable under `set -u`, an OOM kill — still
# publishes one. Without that the parent's poll would wait forever on a child
# that can never finish, and a hang is the one failure mode worse than a failed
# leg: it burns the whole batch's wall clock and reports nothing.
_bp_child() {
  local idx="$1" worker="$2" dir="$3"
  _bp_child_idx="$idx"
  _bp_child_dir="$dir"
  trap '_bp_child_done $?' EXIT
  "$worker" "${BP_UNITS[$idx]}"
}

# _bp_spawn <idx> <worker_fn> — fork one unit.
#
# JOB CONTROL IS LOAD-BEARING, not style (gate-pool.sh hazard 3). With job
# control off — the default in a script — bash runs every asynchronous command
# with SIGINT and SIGQUIT hard-ignored, inherited across fork AND exec and
# un-resettable from inside. Here that would reach replay.sh, the candidate
# runner, and quality-gates.sh beneath them. `set -m` is the fix because bash
# installs that ignore only in the job-control-off branch.
#
# Two consequences, both wanted: each child leads its own process group (which
# is what lets bp_kill_running reap the subtree), and a background group that
# reads the terminal would be stopped by SIGTTIN — so a child's stdin is pinned
# to /dev/null. That also closes the hazard batch.sh's own execute loop already
# guards against by reading its selection on fd 3: a stubbed runner is an
# arbitrary operator command, and one that reads stdin must not compete for the
# operator's keystrokes with every other worker.
#
# The prior `-m` state is restored so this stays invisible to the caller.
_bp_spawn() {
  local idx="$1" worker="$2" restore_m=""
  case "$-" in
    *m*) ;;
    *) restore_m=1 ;;
  esac
  set -m
  ( _bp_child "$idx" "$worker" "$_bp_dir" ) </dev/null &
  _bp_last_pid=$!
  if [ -n "$restore_m" ]; then set +m; fi
  _bp_running_pids="$_bp_running_pids $_bp_last_pid"
}

# _bp_forget_pid <pid> — drop a reaped child from the kill list.
_bp_forget_pid() {
  local keep="" p
  # shellcheck disable=SC2086  # deliberate word-split of the pid list
  for p in $_bp_running_pids; do
    [ "$p" = "$1" ] && continue
    keep="$keep $p"
  done
  _bp_running_pids="$keep"
}

# BP_* here are OUT-PARAMS written for the sourcing caller (this is a sourced
# lib, not a program), so the linter's "appears unused" is a false positive.
# shellcheck disable=SC2034
bp_run() {
  local n="$1" worker="$2" abort="${3:-}"
  local total="${#BP_UNITS[@]}"
  local dir="$_bp_dir"
  local run_start run_end

  BP_LAUNCHED=0
  BP_SKIPPED=0
  BP_MAX_INFLIGHT=0
  BP_INFLIGHT_AT_ABORT=0
  BP_WALL=0
  BP_SERIAL_SUM=0

  [ -n "$dir" ] || { echo "bp_run: bp_init was not called" >&2; return 1; }
  [ "$total" -gt 0 ] || return 0
  [ "$n" -ge 1 ] || n=1

  run_start="$(date +%s)"

  # Slot table. An empty slot_pid means the slot is free.
  local -a slot_pid=() slot_idx=() slot_start=()
  local s
  for ((s = 0; s < n; s++)); do
    slot_pid[s]=""
    slot_idx[s]=-1
    slot_start[s]=0
  done

  local next=0 reaped=0 inflight=0 stopped=0 progressed=0

  while :; do
    # --- launch into every free slot ------------------------------------
    for ((s = 0; s < n; s++)); do
      [ "$stopped" -eq 0 ] || break
      [ "$next" -lt "$total" ] || break
      [ -n "${slot_pid[$s]}" ] && continue
      # ── THE ABORT GATE ───────────────────────────────────────────────
      # Consulted before each launch, never mid-unit. A unit already running
      # is allowed to FINISH: its legs may have spend committed against them
      # already, and killing one would throw that away with no record to show
      # for it. The caller records how many finished after the abort — see
      # batch.sh's `circuit_breaker.in_flight_at_trip`.
      if [ -n "$abort" ] && "$abort"; then
        stopped=1
        BP_INFLIGHT_AT_ABORT="$inflight"
        break
      fi
      _bp_spawn "$next" "$worker"
      slot_pid[s]="$_bp_last_pid"
      slot_idx[s]="$next"
      slot_start[s]="$(date +%s)"
      next=$((next + 1))
      BP_LAUNCHED=$((BP_LAUNCHED + 1))
      inflight=$((inflight + 1))
      [ "$inflight" -gt "$BP_MAX_INFLIGHT" ] && BP_MAX_INFLIGHT="$inflight"
    done

    # --- reap every finished slot ---------------------------------------
    progressed=0
    for ((s = 0; s < n; s++)); do
      [ -n "${slot_pid[$s]}" ] || continue
      local sidx="${slot_idx[$s]}"
      [ -f "$dir/$sidx.done" ] || continue
      wait "${slot_pid[$s]}" 2>/dev/null || true
      _bp_forget_pid "${slot_pid[$s]}"
      # Measured from dispatch to REAP, so it overstates by at most one poll
      # interval. Against units that run for minutes that is noise, and the
      # bias is the same for every unit — which is what matters, since this
      # sum exists to be compared with BP_WALL.
      BP_SERIAL_SUM=$((BP_SERIAL_SUM + $(date +%s) - ${slot_start[$s]}))
      slot_pid[s]=""
      slot_idx[s]=-1
      reaped=$((reaped + 1))
      inflight=$((inflight - 1))
      progressed=1
    done

    # Done when nothing is in flight and there is nothing left to dispatch.
    if [ "$inflight" -eq 0 ]; then
      [ "$stopped" -eq 1 ] && break
      [ "$next" -ge "$total" ] && break
    fi
    [ "$progressed" -eq 0 ] && sleep "$_bp_poll_interval"
  done

  [ "$next" -lt "$total" ] && BP_SKIPPED=$((total - next))

  # --- fail-closed accounting -------------------------------------------
  # A unit that was launched must have been reaped. A short count means a
  # worker vanished without its EXIT trap firing — which should be impossible,
  # and is exactly the kind of impossible that must be said out loud rather
  # than folded into a clean-looking summary.
  if [ "$reaped" -ne "$BP_LAUNCHED" ]; then
    printf 'bp_run: BUG — launched %d unit(s) but reaped %d; the batch summary may under-count.\n' \
      "$BP_LAUNCHED" "$reaped" >&2
  fi

  run_end="$(date +%s)"
  BP_WALL=$((run_end - run_start))
  return 0
}
