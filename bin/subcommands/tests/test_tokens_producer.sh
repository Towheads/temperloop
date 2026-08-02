#!/usr/bin/env bash
#
# Tests for the `.temperloop/report.d/tokens` LOCATOR SHIM (temperloop#980
# "producer-kernel-side-relocation") — the shim's own reachability, not the
# corpus/render concerns owned by sibling items #983/#981/#984 (see this
# item's own "Gate scope" acceptance bullet).
#
# RESOLUTION ORDER under test (see the shim's own header for the full
# rationale): 1. $TEMPERLOOP_HOME  2. self-checkout ($(dirname "$0")/../..)
# 3. `command -v temperloop`  4. skip.
#
# Covers:
#   1. SELF-CHECKOUT (resolver 2) — THE REGRESSION TEST. The shim, run from
#      its REAL in-place location inside this checkout, with $TEMPERLOOP_HOME
#      unset and no `temperloop` on PATH, still resolves and matches the
#      kernel checkout's own control output. An earlier cut of this shim
#      dropped this resolver entirely, silently degrading `temperloop
#      report` in this repo (and any other checkout carrying its own
#      producer) on any host with no installed CLI — this is the exact case
#      the prior orphan-fixture-only suite could never reach.
#   2. resolution ORDER 2>3: self-checkout wins over a DIFFERENT
#      PATH-discoverable `temperloop` when $TEMPERLOOP_HOME is unset.
#   3. a copy of the shim placed at <tmp-repo>/.temperloop/report.d/tokens,
#      in a repo with NO workflows/ directory (so self-checkout fails
#      closed), resolves the kernel via $TEMPERLOOP_HOME and emits the SAME
#      JSON object the kernel checkout's own
#      workflows/scripts/report-producers/tokens emits directly.
#   4. the same, resolved instead via `command -v temperloop`
#      (symlink-resolved to its checkout root) when $TEMPERLOOP_HOME is
#      unset — the documented resolver-3 fallback path.
#   5. resolution ORDER 1>3: $TEMPERLOOP_HOME wins over a DIFFERENT
#      PATH-discoverable `temperloop` (orphan copy, self-checkout n/a).
#   6. resolution ORDER 1>2: $TEMPERLOOP_HOME (pointed at a distinct fake
#      kernel) wins over self-checkout, even when the shim runs from its
#      REAL in-place location (where self-checkout would otherwise resolve
#      to this checkout's own real producer).
#   7. a stale/invalid $TEMPERLOOP_HOME (missing the producer, orphan copy
#      so self-checkout is n/a) falls through to the `command -v temperloop`
#      fallback rather than failing.
#   8. no kernel resolvable at all (orphan copy, unset $TEMPERLOOP_HOME, no
#      `temperloop` on PATH) -> the contract's skip line, exit 0.
#   9. STATIC: the shim itself contains no transcript-parsing / jq-shaping
#      code (comments mentioning the words are fine; only non-comment lines
#      are checked) — the implementation lives kernel-side, this file is
#      locator + exec only.
#  10. STATIC: the shim does not hardcode a fourth copy of the
#      TEMPERLOOP_HOME default install-path literal (bin/bootstrap.sh's
#      header names the three existing hand-synced copies).
#  11. ARGS PASSTHROUGH: the shim execs with "$@" (static grep on the exec
#      line) and an extra CLI arg does not break resolution (dynamic).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SHIM="$REPO_ROOT/.temperloop/report.d/tokens"
IMPL="$REPO_ROOT/workflows/scripts/report-producers/tokens"
REAL_TEMPERLOOP_BIN="$REPO_ROOT/bin/temperloop"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$SHIM" ] || fail "shim not found at $SHIM"
[ -x "$SHIM" ] || fail "shim not executable at $SHIM"
[ -f "$IMPL" ] || fail "kernel-side implementation not found at $IMPL"
[ -x "$IMPL" ] || fail "kernel-side implementation not executable at $IMPL"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tokens-producer-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

control_out="$("$IMPL")" || fail "control run of the kernel-side implementation failed"
echo "$control_out" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null \
  || fail "control run's stdout did not parse as {tokens_spent: <number>}"

# --- fixture: a second, DISTINCT fake kernel checkout, so the ORDER tests
# can prove which resolver won by checking whose marker output appears. -----
FAKEKERNEL2="$WORK/fake-kernel-2"
mkdir -p "$FAKEKERNEL2/bin" "$FAKEKERNEL2/workflows/scripts/report-producers"
cat > "$FAKEKERNEL2/bin/temperloop" <<'EOF'
#!/usr/bin/env bash
echo "fake-kernel-2 dispatcher -- not exercised by this test"
EOF
chmod +x "$FAKEKERNEL2/bin/temperloop"
cat > "$FAKEKERNEL2/workflows/scripts/report-producers/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent":424242}'
EOF
chmod +x "$FAKEKERNEL2/workflows/scripts/report-producers/tokens"
FAKEBIN2="$WORK/fakebin2"
mkdir -p "$FAKEBIN2"
ln -s "$FAKEKERNEL2/bin/temperloop" "$FAKEBIN2/temperloop"

# --- 1: SELF-CHECKOUT (resolver 2) — THE REGRESSION TEST --------------------
# The shim at its REAL in-place location, $TEMPERLOOP_HOME unset, no
# `temperloop` anywhere on PATH. This is the exact scenario an earlier cut
# of this shim regressed on (no self-checkout resolver at all -> permanent
# skip in this repo on any host with no installed CLI).
out1="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$SHIM")" \
  || fail "1: shim invocation (self-checkout) failed"
[ "$out1" = "$control_out" ] || fail "1: shim in place (self-checkout, no \$TEMPERLOOP_HOME, no PATH temperloop) did not match the control output.
  control: $control_out
  shim:    $out1"
echo "PASS: 1 SELF-CHECKOUT — shim in place resolves with no \$TEMPERLOOP_HOME and no PATH temperloop, matches the kernel checkout's own output"

# --- 2: resolution ORDER 2>3 — self-checkout wins over a different
# PATH-discoverable temperloop. ----------------------------------------------
out2="$(env -i HOME="$HOME" PATH="$FAKEBIN2:/usr/bin:/bin" "$SHIM")" \
  || fail "2: shim invocation failed"
[ "$out2" = "$control_out" ] || fail "2: self-checkout should win over a different PATH-found kernel, but output was: $out2"
echo "$out2" | grep -q 424242 && fail "2: self-checkout should have won over the PATH-found fake-kernel-2, but fake-kernel-2's output leaked through"
echo "PASS: 2 resolution order 2>3 — self-checkout wins over a different PATH-found kernel"

# --- fixture: an orphan repo (NO workflows/ dir) so self-checkout fails
# closed and the remaining tests can isolate resolvers 1/3/4 cleanly. -------
ORPHAN="$WORK/orphan-repo"
mkdir -p "$ORPHAN/.temperloop/report.d"
cp "$SHIM" "$ORPHAN/.temperloop/report.d/tokens"
chmod +x "$ORPHAN/.temperloop/report.d/tokens"
[ -d "$ORPHAN/workflows" ] && fail "test setup bug: orphan repo must have no workflows/ dir"

# --- 3: copy in a workflows/-less repo, resolved via $TEMPERLOOP_HOME ------
out3="$(cd "$ORPHAN" && env -u TEMPERLOOP_BIN_DIR TEMPERLOOP_HOME="$REPO_ROOT" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "3: shim invocation failed"
[ "$out3" = "$control_out" ] || fail "3: shim (via \$TEMPERLOOP_HOME) output did not match the kernel checkout's own control output.
  control: $control_out
  shim:    $out3"
echo "PASS: 3 shim in a workflows/-less repo resolves via \$TEMPERLOOP_HOME and matches the kernel checkout's own output"

# --- 4: resolved via \`command -v temperloop\` when \$TEMPERLOOP_HOME unset --
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
ln -s "$REAL_TEMPERLOOP_BIN" "$FAKEBIN/temperloop"

out4="$(cd "$ORPHAN" && env -i HOME="$HOME" PATH="$FAKEBIN:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "4: shim invocation (PATH fallback) failed"
[ "$out4" = "$control_out" ] || fail "4: shim (via 'command -v temperloop' PATH fallback) output did not match the control output.
  control: $control_out
  shim:    $out4"
echo "PASS: 4 shim with no \$TEMPERLOOP_HOME resolves via 'command -v temperloop', symlink-resolved to its checkout root"

# --- 5: resolution ORDER 1>3 — $TEMPERLOOP_HOME (real checkout) wins over a
# DIFFERENT PATH-found kernel. ------------------------------------------------
out5="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$REPO_ROOT" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "5: shim invocation failed"
[ "$out5" = "$control_out" ] || fail "5: with BOTH \$TEMPERLOOP_HOME (real) and a different PATH-found kernel set, \$TEMPERLOOP_HOME should win, but output was: $out5"
echo "$out5" | grep -q 424242 && fail "5: \$TEMPERLOOP_HOME should have won over the PATH-found fake-kernel-2, but fake-kernel-2's output leaked through"
echo "PASS: 5 resolution order 1>3 — \$TEMPERLOOP_HOME wins over a different PATH-found kernel"

# --- 6: resolution ORDER 1>2 — $TEMPERLOOP_HOME (a DIFFERENT fake kernel)
# wins over self-checkout, even with the shim run from its REAL in-place
# location (where self-checkout alone would resolve to THIS checkout). ------
out6="$(env -i HOME="$HOME" TEMPERLOOP_HOME="$FAKEKERNEL2" PATH="/usr/bin:/bin" "$SHIM")" \
  || fail "6: shim invocation failed"
echo "$out6" | jq -e '.tokens_spent == 424242' >/dev/null \
  || fail "6: \$TEMPERLOOP_HOME (fake-kernel-2) should win over self-checkout even when the shim runs in place; got: $out6"
echo "PASS: 6 resolution order 1>2 — \$TEMPERLOOP_HOME wins over self-checkout, even when the shim runs from its real in-place location"

# --- 7: a stale/invalid $TEMPERLOOP_HOME (no producer there, orphan copy so
# self-checkout is n/a) falls through to the PATH fallback. ------------------
STALE="$WORK/stale-home"
mkdir -p "$STALE"
out7="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$STALE" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "7: shim invocation failed"
echo "$out7" | jq -e '.tokens_spent == 424242' >/dev/null \
  || fail "7: a stale \$TEMPERLOOP_HOME (missing the producer) should fall through to the PATH fallback (fake-kernel-2, tokens_spent=424242); got: $out7"
echo "PASS: 7 a stale/invalid \$TEMPERLOOP_HOME falls through to the 'command -v temperloop' fallback"

# --- 8: no kernel resolvable at all (orphan copy: no self-checkout, no
# $TEMPERLOOP_HOME, no PATH temperloop). --------------------------------------
out8rc=0
out8="$(cd "$ORPHAN" && env -i HOME="$HOME" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" || out8rc=$?
[ "$out8rc" -eq 0 ] || fail "8: shim with no kernel resolvable must still exit 0; got rc=$out8rc"
[ "$out8" = "skipped -- tokens: producer unavailable" ] || fail "8: shim with no kernel resolvable should print exactly the contract's skip line; got: $out8"
echo "PASS: 8 no kernel resolvable -> exactly the contract's skip line, exit 0"

# --- 9: STATIC — no transcript-parsing / jq-shaping code in the shim -------
# (comments mentioning "jq" or "tokens_spent" are fine and expected — this
# checks CODE lines only, same convention as
# workflows/scripts/tests/test_pipeline_spend_report.sh's egress checks.)
if grep -nE '\bjq\b' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "9: the shim contains a non-comment 'jq' reference -- transcript/JSON shaping belongs kernel-side only"
fi
echo "PASS: 9a shim has no non-comment jq reference"

if grep -nE 'select\(|with_entries|by_model' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "9: the shim contains jq-shaping-looking code (select/with_entries/by_model) outside comments"
fi
echo "PASS: 9b shim has no jq-shaping code outside comments"

# --- 10: STATIC — no fourth hardcoded install-path literal ------------------
if grep -qF '.local/share/temperloop' "$SHIM"; then
  fail "10: the shim hardcodes the TEMPERLOOP_HOME default install-path literal -- bin/bootstrap.sh's header names the three existing hand-synced copies; this shim must not add a fourth (rely on 'command -v temperloop' instead)"
fi
echo "PASS: 10 shim does not hardcode a fourth copy of the install-path literal"

# --- 11: ARGS PASSTHROUGH ----------------------------------------------------
# Static: the exec line forwards "$@" (a non-comment occurrence).
if ! grep -nE '^[^#]*exec .*"\$@"' "$SHIM" | grep -q .; then
  fail "11: the shim's exec line does not forward \"\$@\" -- args passthrough regressed"
fi
echo "PASS: 11a shim's exec line forwards \"\$@\""

# Dynamic: an extra CLI arg (the contract is "invoked with no arguments"
# today, so this just proves passthrough doesn't break resolution -- the
# kernel-side implementation takes no flags and silently ignores it).
out11="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" "$SHIM" --an-arg-nobody-asked-for)" \
  || fail "11: shim invocation with an extra arg failed"
[ "$out11" = "$control_out" ] || fail "11: shim invoked with an extra arg should still match the control output; got: $out11"
echo "PASS: 11b shim invoked with an extra arg still resolves and matches the control output"

echo "ALL PASS: test_tokens_producer.sh"
