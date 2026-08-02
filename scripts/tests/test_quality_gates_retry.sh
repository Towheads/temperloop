#!/usr/bin/env bash
#
# test_quality_gates_retry.sh — regression tests for the CLASSIFIED, CAPPED,
# BACKED-OFF per-gate retry policy scripts/quality-gates.sh runs
# (workflows/scripts/lib/gate-retry.sh — temperloop#403, temperloop#976,
# Towheads/foundation#1297).
#
# Sibling of test_quality_gates_freshness.sh, which covers the other lib
# quality-gates.sh sources. Hermetic: every "gate" here is a throwaway script
# under a tmpdir whose pass/fail behavior and output are scripted per attempt —
# no `make`, no network, and never this repo's real ~100-target gate list (which
# is exactly why the retry policy lives in a sourceable lib: it could not
# otherwise be exercised without running the whole suite).
#
# Covers, one case per contract clause:
#   1. transient flake — fails then passes → retried, verdict pass, note names
#      the attempt it went green on (temperloop#403 behavior, preserved)
#   2. BYTE-IDENTICAL second failure short-circuits (temperloop#976, the epic
#      #1443 regression): a gate whose 2nd attempt prints exactly what its 1st
#      did is NOT run a 3rd time, even with attempts to spare
#   3. non-identical repeated failure still uses the full cap — the
#      short-circuit must not swallow a genuine, differently-failing flake
#   4. deterministic SIGNATURE (a shellcheck finding code) fails fast on
#      attempt 1 — no retry at all
#   5. an empty $GATE_DETERMINISTIC_PATTERN disables classifier 1 while the
#      byte-identical short-circuit keeps working
#   6. BACKOFF (Towheads/foundation#1297): a retried gate's attempts are
#      actually SPACED — a run with a real backoff takes measurably longer than
#      the same run at backoff 0, which is what the pre-fix loop did
#   7. GATE_MAX_ATTEMPTS=1 still disables retries entirely
#   8. quality-gates.sh really sources this lib and calls it (the wiring, so a
#      future refactor that inlines the loop again fails here)
#
# Usage: scripts/tests/test_quality_gates_retry.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/workflows/scripts/lib/gate-retry.sh"
QG="$REPO_ROOT/scripts/quality-gates.sh"

[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-retry-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# make_gate <name> <body> — write an executable throwaway "gate" script that
# counts its own invocations in $WORK/<name>.count. The body may read $n (the
# 1-based attempt number) and must exit with the verdict it wants to report.
make_gate() {
  local name="$1" body="$2" path="$WORK/$1"
  cat > "$path" <<EOF
#!/usr/bin/env bash
n=0
[ -f "$WORK/$name.count" ] && n="\$(cat "$WORK/$name.count")"
n=\$((n + 1)); echo "\$n" > "$WORK/$name.count"
$body
EOF
  chmod +x "$path"
  printf '%s' "$path"
}
attempts_of() { cat "$WORK/$1.count" 2>/dev/null || echo 0; }

# run_gate <gate-path> — source the lib FRESH in a subshell-free child bash so
# each case gets its own settings, and print "status|attempts|note".
# Running it in a child `bash -c` (rather than sourcing here) is what makes the
# per-case GATE_* settings independent: the lib binds them with `:-` at source
# time, so a second source in this same shell would see the first case's values.
run_gate() {
  bash -c '
    set -uo pipefail
    . "$1"
    gate_retry_init
    gate_run_with_retry "$2" >/dev/null 2>&1
    printf "%s|%s|%s\n" "$GATE_RUN_STATUS" "$GATE_RUN_ATTEMPTS" "$GATE_RUN_NOTE"
  ' _ "$LIB" "$2"
}

# ---------------------------------------------------------------------------
# 1. transient flake: fails once, then passes → retried, verdict pass
# ---------------------------------------------------------------------------
g="$(make_gate flake 'if [ "$n" -lt 2 ]; then echo "boom $n" >&2; exit 1; fi; echo ok')"
out="$(GATE_MAX_ATTEMPTS=3 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g")"
status="${out%%|*}"; rest="${out#*|}"; attempts="${rest%%|*}"; note="${rest#*|}"
if [ "$status" = "pass" ] && [ "$attempts" = "2" ] && [ "$(attempts_of flake)" = "2" ]; then
  pass "transient flake retried once and went green (verdict pass, 2 attempts)"
else
  fail "transient flake: expected pass/2 attempts, got status=$status attempts=$attempts runs=$(attempts_of flake)"
fi
case "$note" in
  *"green on attempt 2"*) pass "transient flake note names the attempt it went green on" ;;
  *) fail "transient flake note should name the green attempt, got: $note" ;;
esac

# ---------------------------------------------------------------------------
# 2. THE #1443 REGRESSION: a byte-identical second failure short-circuits.
#    Deliberately uses a NON-signature message so classifier 1 cannot fire —
#    this proves the byte-identical net alone, with attempts still to spare.
# ---------------------------------------------------------------------------
g="$(make_gate identical 'echo "the same failure every time"; exit 1')"
out="$(GATE_MAX_ATTEMPTS=5 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g")"
status="${out%%|*}"; rest="${out#*|}"; attempts="${rest%%|*}"; note="${rest#*|}"
if [ "$status" = "deterministic" ] && [ "$(attempts_of identical)" = "2" ]; then
  pass "byte-identical second failure short-circuits at 2 attempts (cap was 5) — the epic #1443 regression"
else
  fail "byte-identical short-circuit: expected deterministic after exactly 2 runs, got status=$status runs=$(attempts_of identical)"
fi
case "$note" in
  *"byte-identical"*) pass "byte-identical short-circuit note explains WHY no retry was spent" ;;
  *) fail "byte-identical note should say byte-identical, got: $note" ;;
esac

# ---------------------------------------------------------------------------
# 3. a repeatedly-but-DIFFERENTLY failing gate still spends the full cap — the
#    short-circuit must not swallow a genuine flake whose output varies.
# ---------------------------------------------------------------------------
g="$(make_gate varying 'echo "failure number $n"; exit 1')"
out="$(GATE_MAX_ATTEMPTS=3 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g")"
status="${out%%|*}"
if [ "$status" = "fail" ] && [ "$(attempts_of varying)" = "3" ]; then
  pass "differently-failing gate still spends the full GATE_MAX_ATTEMPTS cap (no false short-circuit)"
else
  fail "varying failure: expected fail after 3 runs, got status=$status runs=$(attempts_of varying)"
fi

# ---------------------------------------------------------------------------
# 4. deterministic SIGNATURE fails fast on attempt 1 (the shellcheck case)
# ---------------------------------------------------------------------------
g="$(make_gate lint 'echo "  ^-- SC2031 (info): var was modified in a subshell"; exit 1')"
out="$(GATE_MAX_ATTEMPTS=3 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g")"
status="${out%%|*}"; rest="${out#*|}"; attempts="${rest%%|*}"; note="${rest#*|}"
if [ "$status" = "deterministic" ] && [ "$(attempts_of lint)" = "1" ]; then
  pass "deterministic signature (SC2031) fails fast on attempt 1 — zero retries spent"
else
  fail "signature classifier: expected deterministic after exactly 1 run, got status=$status runs=$(attempts_of lint)"
fi
case "$note" in
  *"deterministic signature"*) pass "signature short-circuit note names the classifier" ;;
  *) fail "signature note should name the classifier, got: $note" ;;
esac

# ---------------------------------------------------------------------------
# 5. an EMPTY pattern disables classifier 1; classifier 2 still applies
# ---------------------------------------------------------------------------
g="$(make_gate lintoff 'echo "  ^-- SC2031 (info): var was modified in a subshell"; exit 1')"
out="$(GATE_MAX_ATTEMPTS=5 GATE_RETRY_BACKOFF=0 GATE_DETERMINISTIC_PATTERN= run_gate "$LIB" "$g")"
status="${out%%|*}"
if [ "$status" = "deterministic" ] && [ "$(attempts_of lintoff)" = "2" ]; then
  pass "empty GATE_DETERMINISTIC_PATTERN disables the signature classifier; byte-identical net still caps at 2"
else
  fail "empty pattern: expected deterministic after 2 runs (byte-identical net), got status=$status runs=$(attempts_of lintoff)"
fi

# ---------------------------------------------------------------------------
# 6. BACKOFF is real (Towheads/foundation#1297). The pre-fix loop fired its
#    whole budget inside a fraction of a second; a retried gate must now be
#    measurably SLOWER with a backoff than without one. Uses a gate whose
#    output varies so it actually reaches the cap, and `date +%s` (whole
#    seconds — BSD-portable, no GNU %N) with a 1s backoff => >=2s of sleep.
# ---------------------------------------------------------------------------
g="$(make_gate backoff 'echo "failure number $n"; exit 1')"
t0="$(date +%s)"
GATE_MAX_ATTEMPTS=3 GATE_RETRY_BACKOFF=1 run_gate "$LIB" "$g" >/dev/null
elapsed=$(( $(date +%s) - t0 ))
if [ "$elapsed" -ge 2 ]; then
  pass "retries are SPACED by the graduated backoff (3 attempts at backoff 1 took ${elapsed}s >= 2s)"
else
  fail "backoff: 3 attempts at GATE_RETRY_BACKOFF=1 should sleep >=2s total, took ${elapsed}s"
fi
g="$(make_gate nobackoff 'echo "failure number $n"; exit 1')"
t0="$(date +%s)"
GATE_MAX_ATTEMPTS=3 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g" >/dev/null
elapsed0=$(( $(date +%s) - t0 ))
if [ "$elapsed0" -lt 2 ]; then
  pass "GATE_RETRY_BACKOFF=0 restores the immediate-retry behavior (${elapsed0}s)"
else
  fail "backoff 0 should not sleep, took ${elapsed0}s"
fi

# ---------------------------------------------------------------------------
# 7. GATE_MAX_ATTEMPTS=1 disables retries entirely
# ---------------------------------------------------------------------------
g="$(make_gate once 'echo "failure number $n"; exit 1')"
out="$(GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 run_gate "$LIB" "$g")"
status="${out%%|*}"
if [ "$status" = "fail" ] && [ "$(attempts_of once)" = "1" ]; then
  pass "GATE_MAX_ATTEMPTS=1 disables retries (exactly 1 run)"
else
  fail "cap=1: expected fail after 1 run, got status=$status runs=$(attempts_of once)"
fi

# ---------------------------------------------------------------------------
# 8. WIRING: quality-gates.sh must actually source this lib and drive its
#    entry point. Guards against a future refactor quietly re-inlining the loop
#    (which would leave this whole suite testing dead code).
# ---------------------------------------------------------------------------
if grep -q 'workflows/scripts/lib/gate-retry.sh' "$QG" \
  && grep -q 'gate_run_with_retry' "$QG" \
  && grep -q 'gate_retry_init' "$QG"; then
  pass "quality-gates.sh sources gate-retry.sh and drives gate_run_with_retry"
else
  fail "quality-gates.sh no longer wires gate-retry.sh — the retry policy this suite covers is not the one that runs"
fi

# The three settings must resolve from the build.config.sh declarations
# (the kernel Named-setting convention) — never be bare literals in the loop.
if grep -q 'GATE_MAX_ATTEMPTS' "$REPO_ROOT/workflows/scripts/build/build.config.sh" \
  && grep -q 'GATE_RETRY_BACKOFF' "$REPO_ROOT/workflows/scripts/build/build.config.sh" \
  && grep -q 'GATE_DETERMINISTIC_PATTERN' "$REPO_ROOT/workflows/scripts/build/build.config.sh"; then
  pass "every cap/backoff/pattern is declared in build.config.sh (config-named settings)"
else
  fail "a retry setting is missing its build.config.sh declaration"
fi

echo
if [ "$fail_count" -gt 0 ]; then
  echo "FAILED: $fail_count assertion(s)" >&2
  exit 1
fi
echo "OK — gate-retry cap / classification / backoff contract holds"
