#!/usr/bin/env bash
# Tests for the sandbox ROOT-LEAK GUARD (temperloop#1723) —
# workflows/scripts/tests/lib/sandbox.sh's sandbox_up-installed EXIT/signal
# traps, the SANDBOX_KEEP escape, and the stale-root sweeper
# workflows/scripts/tests/lib/sandbox-sweep.sh.
#
# WHY A FIXTURE-DRIVEN SUITE. The property under test is "the root is gone
# after the suite process DIES", which cannot be asserted from inside the
# process that owns the trap. So every scenario runs a generated fixture
# suite as a SEPARATE bash process with $TMPDIR re-pointed at a throwaway
# scan directory, and the assertion is made from the outside, against what
# that directory holds once the fixture is dead — never by reading the
# library's source.
#
# Covers:
#   1. `fail()`-shaped mid-run death (exit 1 before the trailing
#      sandbox_down) leaves NO root behind — the leak the guard exists for.
#   2. SIGTERM (the CI-cancellation / timeout path) leaves no root behind,
#      and the process reports the conventional 143.
#   3. SANDBOX_KEEP=1 RETAINS the root; the SAME fixture without it REMOVES
#      the root. Both directions, so the escape cannot silently become the
#      default.
#   4. A caller's own EXIT trap installed BEFORE sandbox_up still runs (it is
#      chained, never clobbered), and the root is still reclaimed.
#   5. A caller's own EXIT trap installed AFTER sandbox_up (the harness's own
#      test_sandbox.sh interferer idiom) is re-chained by the next
#      sandbox_up, and EVERY root the shell created — not just the latest —
#      is reclaimed.
#   6. A signal the caller deliberately IGNORES (`trap '' TERM`) stays
#      ignored: the guard does not silently make the suite killable.
#   7. IDEMPOTENCE: an explicit sandbox_down followed by the EXIT trap is a
#      clean exit 0 with nothing on stderr — never a double-remove error.
#      This is the property test_install_lifecycle.sh's trailing "the root is
#      gone" assertion depends on.
#   8. sandbox-sweep.sh: finds a marker-bearing leaked root AND a pre-guard
#      legacy-layout root; skips a live-pid root, a too-recent root and an
#      unrelated directory; removes nothing without --apply and exactly the
#      stale set with it.
#
# Every path this suite touches is under its own mktemp scratch root — it
# never reads or writes the real $HOME, and its fixtures' sandbox roots land
# in a scratch scan dir, never the machine's real $TMPDIR.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../sandbox.sh"
SWEEP="$HERE/../sandbox-sweep.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

[ -f "$LIB" ] || fail "sandbox.sh not found at $LIB"
[ -f "$SWEEP" ] || fail "sandbox-sweep.sh not found at $SWEEP"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-trap-test-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

FIXTURES="$SCRATCH/fixtures"
mkdir -p "$FIXTURES"

# fresh_scan_dir <name> — a throwaway stand-in for $TMPDIR that a fixture's
# sandbox roots land in, so "did anything leak?" is a directory listing.
fresh_scan_dir() {
  local d="$SCRATCH/scan-$1"
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s' "$d"
}

# count_entries <dir> — entries in <dir> (leaked roots, if any).
count_entries() {
  local n
  n="$(find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
  printf '%s' "$n"
}

# wait_for_file <path> [tries] — poll until <path> appears.
wait_for_file() {
  local p="$1" tries="${2:-200}" i=0
  while [ "$i" -lt "$tries" ]; do
    [ -e "$p" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# =============================================================================
# 1. A mid-run `fail()`-shaped death leaves no root behind.
# =============================================================================
cat >"$FIXTURES/mid_fail.sh" <<'FIXTURE_EOF'
set -uo pipefail
# shellcheck source=/dev/null
source "$SANDBOX_LIB"
sandbox_up trapfix-midfail
printf '%s' "$SANDBOX_ROOT" >"$ROOT_OUT"
# The failure path every suite's fail() takes: exit BEFORE the trailing
# sandbox_down on the last line.
echo "simulated assertion failure" >&2
exit 1
FIXTURE_EOF

SCAN="$(fresh_scan_dir midfail)"
ROOT_OUT="$SCRATCH/root-midfail.txt"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" \
  bash "$FIXTURES/mid_fail.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] || fail "1: fixture should have exited 1 (the fail() shape), got $rc"
leaked_root="$(cat "$ROOT_OUT")"
[ -n "$leaked_root" ] || fail "1: fixture never recorded its \$SANDBOX_ROOT"
[ ! -e "$leaked_root" ] \
  || fail "1: a mid-run failure LEAKED its sandbox root ($leaked_root still exists)"
[ "$(count_entries "$SCAN")" = "0" ] \
  || fail "1: \$TMPDIR is not empty after a failed run:\n$(ls -A "$SCAN")"
pass "1: a suite that dies mid-run via the fail() shape (exit 1, trailing sandbox_down never reached) leaves no sandbox root behind"

# =============================================================================
# 2. SIGTERM — the CI-cancellation / timeout path.
# =============================================================================
cat >"$FIXTURES/signal.sh" <<'FIXTURE_EOF'
set -uo pipefail
# shellcheck source=/dev/null
source "$SANDBOX_LIB"
[ -n "${IGNORE_TERM:-}" ] && trap '' TERM
sandbox_up trapfix-signal
printf '%s' "$SANDBOX_ROOT" >"$ROOT_OUT"
: >"$READY"
# Short sleeps, so a delivered signal is handled promptly (bash runs a trap
# between commands, never inside one).
for _ in $(seq 1 "${LOOPS:-200}"); do sleep 0.1; done
sandbox_down
exit 0
FIXTURE_EOF

SCAN="$(fresh_scan_dir sigterm)"
ROOT_OUT="$SCRATCH/root-sigterm.txt"
READY="$SCRATCH/ready-sigterm"
rm -f "$READY"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" READY="$READY" \
  bash "$FIXTURES/signal.sh" >/dev/null 2>&1 &
sig_pid=$!
wait_for_file "$READY" || fail "2: fixture never signalled ready"
kill -TERM "$sig_pid" 2>/dev/null || fail "2: could not SIGTERM the fixture"
wait "$sig_pid"
rc=$?
[ "$rc" -eq 143 ] || fail "2: expected the conventional 128+15=143 on SIGTERM, got $rc"
killed_root="$(cat "$ROOT_OUT")"
[ ! -e "$killed_root" ] \
  || fail "2: a SIGTERM'd suite LEAKED its sandbox root ($killed_root still exists)"
[ "$(count_entries "$SCAN")" = "0" ] \
  || fail "2: \$TMPDIR is not empty after a SIGTERM'd run:\n$(ls -A "$SCAN")"
pass "2: a suite killed by SIGTERM (the CI-cancellation / timeout path) leaves no sandbox root behind and reports 143"

# =============================================================================
# 3. SANDBOX_KEEP — both directions.
# =============================================================================
SCAN="$(fresh_scan_dir keep)"
ROOT_OUT="$SCRATCH/root-keep.txt"
keep_err="$SCRATCH/keep.err"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" SANDBOX_KEEP=1 \
  bash "$FIXTURES/mid_fail.sh" >/dev/null 2>"$keep_err"
kept_root="$(cat "$ROOT_OUT")"
[ -d "$kept_root" ] \
  || fail "3a: SANDBOX_KEEP=1 did not retain the root ($kept_root is gone) — the debuggability escape is dead"
grep -q 'SANDBOX_KEEP' "$keep_err" \
  || fail "3a: retaining a root must say so on stderr; got:\n$(cat "$keep_err")"

# Same fixture, same scan dir, KEEP absent: the root must go.
ROOT_OUT2="$SCRATCH/root-nokeep.txt"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT2" \
  bash "$FIXTURES/mid_fail.sh" >/dev/null 2>&1
nokeep_root="$(cat "$ROOT_OUT2")"
[ "$nokeep_root" != "$kept_root" ] || fail "3b: the two runs reused one root — the comparison would be vacuous"
[ ! -e "$nokeep_root" ] \
  || fail "3b: without SANDBOX_KEEP the root must be removed, but $nokeep_root survived"
[ -d "$kept_root" ] || fail "3b: the KEEP-retained root was removed by an unrelated later run"
rm -rf "$kept_root"
pass "3: SANDBOX_KEEP=1 retains the root (loudly) and its absence removes it — both directions asserted, so the escape cannot become the default"

# =============================================================================
# 4. A caller's own EXIT trap installed BEFORE sandbox_up is chained, not
#    clobbered.
# =============================================================================
cat >"$FIXTURES/prior_trap.sh" <<'FIXTURE_EOF'
set -uo pipefail
# shellcheck source=/dev/null
source "$SANDBOX_LIB"
# Installed BEFORE sandbox_up, so the guard chains it. The handler records
# whether the root was still present when it ran: the caller's handler must
# run FIRST, while the root it may need is still inspectable.
trap 'echo "prior-ran rc=$? root_present=$([ -d "${SANDBOX_ROOT:-/nonexistent}" ] && echo yes || echo no)" >>"$LOG"' EXIT
sandbox_up trapfix-prior
printf '%s' "$SANDBOX_ROOT" >"$ROOT_OUT"
exit 4
FIXTURE_EOF

SCAN="$(fresh_scan_dir prior)"
ROOT_OUT="$SCRATCH/root-prior.txt"
LOG="$SCRATCH/prior.log"
: >"$LOG"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" LOG="$LOG" \
  bash "$FIXTURES/prior_trap.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 4 ] || fail "4: chaining must not change the script's exit status (expected 4, got $rc)"
grep -q 'prior-ran rc=4' "$LOG" \
  || fail "4: the caller's own EXIT handler was clobbered (log: $(cat "$LOG"))"
grep -q 'root_present=yes' "$LOG" \
  || fail "4: the caller's handler ran AFTER the root was removed — it must run first, while the root is still inspectable"
prior_root="$(cat "$ROOT_OUT")"
[ ! -e "$prior_root" ] || fail "4: the root was not reclaimed once the chained handler had run ($prior_root)"
pass "4: a caller's own EXIT trap is chained (runs first, sees the root, exit status preserved) and the root is still reclaimed"

# =============================================================================
# 5. A trap installed AFTER sandbox_up is re-chained by the next sandbox_up,
#    and EVERY root the shell created is reclaimed — not just the latest.
# =============================================================================
cat >"$FIXTURES/late_trap.sh" <<'FIXTURE_EOF'
set -uo pipefail
# shellcheck source=/dev/null
source "$SANDBOX_LIB"
sandbox_up trapfix-late-a
printf '%s\n' "$SANDBOX_ROOT" >"$ROOT_OUT"
# The harness's own test_sandbox.sh idiom: a caller installs its interferer
# trap between two sandbox_up calls, clobbering whatever was bound.
trap 'echo late-ran >>"$LOG"' EXIT
sandbox_up trapfix-late-b
printf '%s\n' "$SANDBOX_ROOT" >>"$ROOT_OUT"
exit 1
FIXTURE_EOF

SCAN="$(fresh_scan_dir late)"
ROOT_OUT="$SCRATCH/root-late.txt"
LOG="$SCRATCH/late.log"
: >"$LOG"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" LOG="$LOG" \
  bash "$FIXTURES/late_trap.sh" >/dev/null 2>&1
grep -q 'late-ran' "$LOG" \
  || fail "5: the caller's late-installed EXIT handler did not run (log: $(cat "$LOG"))"
while IFS= read -r r; do
  [ -n "$r" ] || continue
  [ ! -e "$r" ] || fail "5: root $r survived — only the LATEST root was reclaimed"
done <"$ROOT_OUT"
[ "$(wc -l <"$ROOT_OUT" | tr -d ' ')" = "2" ] || fail "5: expected the fixture to record 2 roots"
[ "$(count_entries "$SCAN")" = "0" ] \
  || fail "5: \$TMPDIR is not empty:\n$(ls -A "$SCAN")"
pass "5: a trap installed after sandbox_up is re-chained by the next sandbox_up, and every root the shell created is reclaimed"

# =============================================================================
# 6. A deliberately IGNORED signal stays ignored.
# =============================================================================
SCAN="$(fresh_scan_dir ignore)"
ROOT_OUT="$SCRATCH/root-ignore.txt"
READY="$SCRATCH/ready-ignore"
rm -f "$READY"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" READY="$READY" \
  IGNORE_TERM=1 LOOPS=15 \
  bash "$FIXTURES/signal.sh" >/dev/null 2>&1 &
ign_pid=$!
wait_for_file "$READY" || fail "6: fixture never signalled ready"
kill -TERM "$ign_pid" 2>/dev/null
sleep 0.3
kill -0 "$ign_pid" 2>/dev/null \
  || fail "6: the fixture set 'trap \"\" TERM' but SIGTERM still killed it — the guard overrode a deliberate ignore"
wait "$ign_pid"
rc=$?
[ "$rc" -eq 0 ] || fail "6: the ignoring fixture should have finished normally (0), got $rc"
[ "$(count_entries "$SCAN")" = "0" ] || fail "6: \$TMPDIR is not empty:\n$(ls -A "$SCAN")"
pass "6: a signal the caller deliberately ignores (trap '' TERM) stays ignored — the guard never makes a suite killable that was not"

# =============================================================================
# 7. IDEMPOTENCE — explicit sandbox_down plus the trap, together.
# =============================================================================
cat >"$FIXTURES/happy.sh" <<'FIXTURE_EOF'
set -uo pipefail
# shellcheck source=/dev/null
source "$SANDBOX_LIB"
sandbox_up trapfix-happy
printf '%s' "$SANDBOX_ROOT" >"$ROOT_OUT"
snapshot="$SANDBOX_ROOT"
sandbox_down
# The assertion every install-surface suite already carries on its last line.
[ ! -e "$snapshot" ] || { echo "sandbox_down did not remove the throwaway root ($snapshot)" >&2; exit 1; }
exit 0
FIXTURE_EOF

SCAN="$(fresh_scan_dir happy)"
ROOT_OUT="$SCRATCH/root-happy.txt"
happy_err="$SCRATCH/happy.err"
TMPDIR="$SCAN" SANDBOX_LIB="$LIB" ROOT_OUT="$ROOT_OUT" \
  bash "$FIXTURES/happy.sh" >/dev/null 2>"$happy_err"
rc=$?
[ "$rc" -eq 0 ] \
  || fail "7: the happy path (explicit sandbox_down, then the EXIT trap) must exit 0, got $rc — stderr:\n$(cat "$happy_err")"
[ ! -s "$happy_err" ] \
  || fail "7: the trap firing after an explicit sandbox_down must be silent (a double-remove would complain); stderr:\n$(cat "$happy_err")"
[ "$(count_entries "$SCAN")" = "0" ] || fail "7: \$TMPDIR is not empty:\n$(ls -A "$SCAN")"
pass "7: an explicit sandbox_down and the EXIT trap are idempotent together — the existing 'root is gone' assertion still passes, exit 0, no stderr"

# =============================================================================
# 8. sandbox-sweep.sh
# =============================================================================
SWEEPDIR="$(fresh_scan_dir sweep)"

# A leaked, marker-bearing root whose recorded pid is long dead.
mk_marker_root() {
  local d="$1" pid="$2"
  mkdir -p "$d/home" "$d/bin" "$d/xdg/config" "$d/xdg/state" "$d/xdg/data" "$d/xdg/cache"
  {
    printf '# temperloop test sandbox root\n'
    printf 'prefix=swept\n'
    printf 'pid=%s\n' "$pid"
    printf 'created=1970-01-01T00:00:00Z\n'
  } >"$d/.sandbox-root"
}
# A pre-guard leak: sandbox_up's directory signature, no marker file.
mk_legacy_root() {
  local d="$1"
  mkdir -p "$d/home" "$d/bin" "$d/xdg/config" "$d/xdg/state" "$d/xdg/data" "$d/xdg/cache"
}

DEAD_PID=99999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID - 1)); done

mk_marker_root "$SWEEPDIR/leaked-marker" "$DEAD_PID"
mk_legacy_root "$SWEEPDIR/leaked-legacy"
mk_marker_root "$SWEEPDIR/live-suite" "$$"        # this very process: alive
mk_marker_root "$SWEEPDIR/fresh-run" "$DEAD_PID"  # dead pid, but brand new
mkdir -p "$SWEEPDIR/not-a-sandbox/some/dir"
echo "precious" >"$SWEEPDIR/not-a-sandbox/keep-me.txt"

# Age the three that must qualify on mtime; leave `fresh-run` at "now".
touch -t 200001010000 "$SWEEPDIR/leaked-marker" "$SWEEPDIR/leaked-legacy" \
  "$SWEEPDIR/live-suite" "$SWEEPDIR/not-a-sandbox"

dry="$SCRATCH/sweep-dry.txt"
bash "$SWEEP" --dir "$SWEEPDIR" --older-than 1 >"$dry" 2>&1 \
  || fail "8: sweeper dry run exited non-zero:\n$(cat "$dry")"
grep -q "STALE $SWEEPDIR/leaked-marker" "$dry" \
  || fail "8a: the sweeper missed the marker-bearing leaked root:\n$(cat "$dry")"
grep -q "STALE $SWEEPDIR/leaked-legacy" "$dry" \
  || fail "8a: the sweeper missed the pre-guard legacy-layout root (no marker) — already-leaked roots would stay unreclaimable:\n$(cat "$dry")"
grep -q "SKIP  $SWEEPDIR/live-suite" "$dry" \
  || fail "8b: the sweeper did not skip a root whose marker pid is still alive:\n$(cat "$dry")"
grep -q "SKIP  $SWEEPDIR/fresh-run" "$dry" \
  || fail "8b: the sweeper did not skip a root newer than --older-than:\n$(cat "$dry")"
grep -q "not-a-sandbox" "$dry" \
  && fail "8c: the sweeper considered an unrelated directory:\n$(cat "$dry")"
[ -d "$SWEEPDIR/leaked-marker" ] \
  || fail "8d: a DRY RUN removed a root — nothing may be removed without --apply"

apply="$SCRATCH/sweep-apply.txt"
bash "$SWEEP" --dir "$SWEEPDIR" --older-than 1 --apply >"$apply" 2>&1 \
  || fail "8: sweeper --apply exited non-zero:\n$(cat "$apply")"
[ ! -e "$SWEEPDIR/leaked-marker" ] || fail "8e: --apply did not remove the marker-bearing leaked root"
[ ! -e "$SWEEPDIR/leaked-legacy" ] || fail "8e: --apply did not remove the legacy-layout leaked root"
[ -d "$SWEEPDIR/live-suite" ] || fail "8e: --apply removed a LIVE suite's root"
[ -d "$SWEEPDIR/fresh-run" ] || fail "8e: --apply removed a root newer than --older-than"
[ -f "$SWEEPDIR/not-a-sandbox/keep-me.txt" ] || fail "8e: --apply removed an unrelated directory"
grep -q 'removed 2 of 2 stale root(s)' "$apply" \
  || fail "8e: expected a 'removed 2 of 2' summary, got:\n$(cat "$apply")"
pass "8: sandbox-sweep.sh finds marker-bearing AND pre-guard legacy roots, skips live/recent ones and unrelated directories, and removes nothing until --apply"

echo
echo "ALL PASS: test_sandbox_trap.sh"
