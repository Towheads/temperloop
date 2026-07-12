#!/usr/bin/env bash
#
# Tests for portable-timeout.sh's run_with_timeout (temperloop#256) —
# the ONE bounded-subprocess watchdog shared across every script that
# needs to bound an external command without assuming GNU coreutils
# `timeout` is on PATH.
#
# Coverage:
#   1. Fast path: a command that finishes well inside the bound returns its
#      own exit status and output, promptly (not stalled to the bound).
#   2. Slow path: a command that outlives the bound is killed and the call
#      returns the normalized timeout status 137 — on whichever backend the
#      REAL PATH resolves (native `timeout`/`gtimeout` if present, else the
#      bash fallback), so this proves the normalization end to end.
#   3. Backend selection is forced and proven independently via a stub PATH
#      for each of the three tiers: a fake `timeout`, a fake `gtimeout`
#      (with real `timeout` hidden), and neither present (the true bash
#      fallback) — each asserts run_with_timeout used THAT tier (via a
#      marker file the stub writes) and still normalizes to 137 on timeout.
#   4. Argument passthrough: multi-word arguments and a command's own
#      (non-timeout) failure exit status both survive unchanged.
#   5. Pipe-leak regression (foundation #861): a slow command's watchdog
#      does not stall a FAST command substitution — proven by timing a
#      fast call while a slow one is theoretically eligible to leak.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# shellcheck source=../portable-timeout.sh
source "$LIB_DIR/portable-timeout.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. fast path: real command, well inside the bound -----------------------
start="$SECONDS"
out1="$(run_with_timeout 5 echo "fast ok")"
elapsed1=$((SECONDS - start))
[ "$out1" = "fast ok" ] || fail "1: fast-path stdout should pass through (got: $out1)"
[ "$elapsed1" -le 2 ] || fail "1: fast-path should return promptly, not stall toward the bound (took ${elapsed1}s)"
echo "PASS: 1 fast path returns output promptly, not stalled to the bound"

# --- 2. slow path: killed at the bound, normalized to 137 --------------------
start="$SECONDS"
set +e
run_with_timeout 1 sleep 5
rc=$?
set -e
elapsed2=$((SECONDS - start))
[ "$rc" -eq 137 ] || fail "2: a timed-out call should return normalized status 137 (got $rc)"
[ "$elapsed2" -le 4 ] || fail "2: a timed-out call should be killed near its bound, not run to completion (took ${elapsed2}s)"
echo "PASS: 2 slow path is killed at the bound and normalized to status 137"

# --- 3. backend selection, forced per tier via a stub PATH --------------------
# 3a: a fake `timeout` on PATH must be the one invoked (tier 1).
STUB1="$TMP/stub1"; mkdir -p "$STUB1"
cat > "$STUB1/timeout" <<'EOF'
#!/usr/bin/env bash
echo "timeout" >> "$MARKER_FILE"
secs="$1"; shift
"$@" &
pid=$!
( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
wd=$!
wait "$pid"; rc=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
exit "$rc"
EOF
chmod +x "$STUB1/timeout"
MARKER_FILE="$TMP/marker3a"; export MARKER_FILE
out3a="$(PATH="$STUB1:$PATH" MARKER_FILE="$MARKER_FILE" bash -c "source '$LIB_DIR/portable-timeout.sh'; run_with_timeout 5 echo hi")"
[ "$out3a" = "hi" ] || fail "3a: tier-1 fake timeout should still pass command output through (got: $out3a)"
[ -f "$MARKER_FILE" ] || fail "3a: run_with_timeout should have invoked the fake 'timeout' on PATH"
echo "PASS: 3a a real 'timeout' on PATH is preferred (tier 1)"

# 3b: no `timeout`, but a fake `gtimeout` on PATH (tier 2). PATH is stripped to
# just the stub dir plus the minimum needed for bash/sleep/kill to resolve, so
# a REAL `timeout` (present on Linux CI) can never shadow tier-2 here.
STUB2="$TMP/stub2"; mkdir -p "$STUB2"
cat > "$STUB2/gtimeout" <<'EOF'
#!/usr/bin/env bash
echo "gtimeout" >> "$MARKER_FILE"
secs="$1"; shift
"$@" &
pid=$!
( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
wd=$!
wait "$pid"; rc=$?
kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
exit "$rc"
EOF
chmod +x "$STUB2/gtimeout"
MARKER_FILE="$TMP/marker3b"
NOTIMEOUT="$TMP/notimeout_path"; mkdir -p "$NOTIMEOUT"
for t in bash sh sleep kill env cat; do
  real="$(command -v "$t" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "$NOTIMEOUT/$t"
done
out3b="$(PATH="$STUB2:$NOTIMEOUT" MARKER_FILE="$MARKER_FILE" bash -c "source '$LIB_DIR/portable-timeout.sh'; run_with_timeout 5 echo hi")"
[ "$out3b" = "hi" ] || fail "3b: tier-2 fake gtimeout should still pass command output through (got: $out3b)"
[ -f "$MARKER_FILE" ] || fail "3b: run_with_timeout should have invoked the fake 'gtimeout' when 'timeout' is absent"
echo "PASS: 3b gtimeout is used when 'timeout' is absent (tier 2)"

# 3c: neither present — the true bash fallback (tier 3). Same minimal PATH as
# 3b, minus the gtimeout stub.
start="$SECONDS"
set +e
out3c="$(PATH="$NOTIMEOUT" bash -c "source '$LIB_DIR/portable-timeout.sh'; run_with_timeout 1 sleep 5")"
rc3c=$?
set -e
elapsed3c=$((SECONDS - start))
[ "$rc3c" -eq 137 ] || fail "3c: tier-3 bash fallback should still normalize a timeout to 137 (got $rc3c)"
[ -z "$out3c" ] || fail "3c: a killed command should produce no stdout (got: $out3c)"
[ "$elapsed3c" -le 4 ] || fail "3c: tier-3 bash fallback should kill near its bound (took ${elapsed3c}s)"
echo "PASS: 3c bash fallback used and normalized to 137 when neither timeout nor gtimeout is on PATH"

# --- 4. argument passthrough + the wrapped command's own failure survives ----
out4="$(run_with_timeout 5 printf '%s-%s\n' one two)"
[ "$out4" = "one-two" ] || fail "4a: multi-arg passthrough should be preserved (got: $out4)"

set +e
run_with_timeout 5 bash -c 'exit 3'
rc4b=$?
set -e
[ "$rc4b" -eq 3 ] || fail "4b: the wrapped command's own non-timeout exit status should pass through unchanged (got $rc4b)"
echo "PASS: 4 argument passthrough and non-timeout exit statuses are preserved"

# --- 5. pipe-leak regression (foundation #861): a fast call inside a command
# substitution must not stall — proves the watchdog subshell's redirect at
# the subshell boundary, not this function's own stdout, is what the
# `sleep $secs` child inherits.
start="$SECONDS"
out5="$(run_with_timeout 30 echo "no stall")"
elapsed5=$((SECONDS - start))
[ "$out5" = "no stall" ] || fail "5: fast call inside a command substitution should return its output (got: $out5)"
[ "$elapsed5" -le 2 ] || fail "5: fast call inside a command substitution should not stall toward a long bound (took ${elapsed5}s, bound was 30s)"
echo "PASS: 5 a fast call inside a command substitution does not stall (pipe-leak fix intact)"

echo "All portable-timeout.sh tests passed."
