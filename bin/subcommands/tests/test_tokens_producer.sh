#!/usr/bin/env bash
#
# Tests for the `.temperloop/report.d/tokens` LOCATOR SHIM (temperloop#980
# "producer-kernel-side-relocation") — the shim's own reachability, not the
# corpus/render concerns owned by sibling items #983/#981/#984 (see this
# item's own "Gate scope" acceptance bullet).
#
# Covers:
#   1. a copy of the shim placed at <tmp-repo>/.temperloop/report.d/tokens,
#      in a repo with NO workflows/ directory, resolves the kernel via
#      $TEMPERLOOP_HOME and emits the SAME JSON object the kernel checkout's
#      own workflows/scripts/report-producers/tokens emits directly.
#   2. the same, resolved instead via `command -v temperloop`
#      (symlink-resolved to its checkout root) when $TEMPERLOOP_HOME is
#      unset — the documented fallback path.
#   3. resolution ORDER: $TEMPERLOOP_HOME is the PRIMARY resolver — when
#      both it and a PATH-discoverable `temperloop` resolve to DIFFERENT
#      kernel checkouts, $TEMPERLOOP_HOME wins.
#   4. a stale/invalid $TEMPERLOOP_HOME (missing the producer) falls through
#      to the `command -v temperloop` fallback rather than failing.
#   5. no kernel resolvable at all (unset $TEMPERLOOP_HOME, no `temperloop`
#      on PATH) -> the contract's skip line, exit 0.
#   6. STATIC: the shim itself contains no transcript-parsing / jq-shaping
#      code (comments mentioning the words are fine; only non-comment lines
#      are checked) — the implementation lives kernel-side, this file is
#      locator + exec only.
#   7. STATIC: the shim does not hardcode a fourth copy of the
#      TEMPERLOOP_HOME default install-path literal (bin/bootstrap.sh's
#      header names the three existing hand-synced copies).
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

# --- 1: copy in a workflows/-less repo, resolved via $TEMPERLOOP_HOME -------
ORPHAN="$WORK/orphan-repo"
mkdir -p "$ORPHAN/.temperloop/report.d"
cp "$SHIM" "$ORPHAN/.temperloop/report.d/tokens"
chmod +x "$ORPHAN/.temperloop/report.d/tokens"
[ -d "$ORPHAN/workflows" ] && fail "test setup bug: orphan repo must have no workflows/ dir"

control_out="$("$IMPL")" || fail "control run of the kernel-side implementation failed"
echo "$control_out" | jq -e 'type == "object" and (.tokens_spent | type) == "number"' >/dev/null \
  || fail "control run's stdout did not parse as {tokens_spent: <number>}"

out1="$(cd "$ORPHAN" && env -u TEMPERLOOP_BIN_DIR TEMPERLOOP_HOME="$REPO_ROOT" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "1: shim invocation failed"
[ "$out1" = "$control_out" ] || fail "1: shim (via \$TEMPERLOOP_HOME) output did not match the kernel checkout's own control output.
  control: $control_out
  shim:    $out1"
echo "PASS: 1 shim in a workflows/-less repo resolves via \$TEMPERLOOP_HOME and matches the kernel checkout's own output"

# --- 2: resolved via \`command -v temperloop\` when \$TEMPERLOOP_HOME unset --
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
ln -s "$REAL_TEMPERLOOP_BIN" "$FAKEBIN/temperloop"

out2="$(cd "$ORPHAN" && env -i HOME="$HOME" PATH="$FAKEBIN:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "2: shim invocation (PATH fallback) failed"
[ "$out2" = "$control_out" ] || fail "2: shim (via 'command -v temperloop' PATH fallback) output did not match the control output.
  control: $control_out
  shim:    $out2"
echo "PASS: 2 shim with no \$TEMPERLOOP_HOME resolves via 'command -v temperloop', symlink-resolved to its checkout root"

# --- fixture: a second, DISTINCT fake kernel checkout, so tests 3/4 can
# prove resolution ORDER by checking which one's output won. -----------------
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

# --- 3: $TEMPERLOOP_HOME (real checkout) wins over a DIFFERENT PATH-found
# kernel -- proves resolution order, not just that SOME resolution works. ---
out3="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$REPO_ROOT" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "3: shim invocation failed"
[ "$out3" = "$control_out" ] || fail "3: with BOTH \$TEMPERLOOP_HOME (real) and a different PATH-found kernel set, \$TEMPERLOOP_HOME should win, but output was: $out3"
echo "$out3" | grep -q 424242 && fail "3: \$TEMPERLOOP_HOME should have won over the PATH-found fake-kernel-2, but fake-kernel-2's output leaked through"
echo "PASS: 3 \$TEMPERLOOP_HOME is the PRIMARY resolver -- wins over a different PATH-found kernel"

# --- 4: a stale/invalid $TEMPERLOOP_HOME (no producer there) falls through
# to the PATH fallback rather than skipping outright. ------------------------
STALE="$WORK/stale-home"
mkdir -p "$STALE"
out4="$(cd "$ORPHAN" && env -i HOME="$HOME" TEMPERLOOP_HOME="$STALE" PATH="$FAKEBIN2:/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" \
  || fail "4: shim invocation failed"
echo "$out4" | jq -e '.tokens_spent == 424242' >/dev/null \
  || fail "4: a stale \$TEMPERLOOP_HOME (missing the producer) should fall through to the PATH fallback (fake-kernel-2, tokens_spent=424242); got: $out4"
echo "PASS: 4 a stale/invalid \$TEMPERLOOP_HOME falls through to the 'command -v temperloop' fallback"

# --- 5: no kernel resolvable at all -----------------------------------------
out5rc=0
out5="$(cd "$ORPHAN" && env -i HOME="$HOME" PATH="/usr/bin:/bin" "$ORPHAN/.temperloop/report.d/tokens")" || out5rc=$?
[ "$out5rc" -eq 0 ] || fail "5: shim with no kernel resolvable must still exit 0; got rc=$out5rc"
[ "$out5" = "skipped -- tokens: producer unavailable" ] || fail "5: shim with no kernel resolvable should print exactly the contract's skip line; got: $out5"
echo "PASS: 5 no kernel resolvable -> exactly the contract's skip line, exit 0"

# --- 6: STATIC — no transcript-parsing / jq-shaping code in the shim -------
# (comments mentioning "jq" or "tokens_spent" are fine and expected — this
# checks CODE lines only, same convention as
# workflows/scripts/tests/test_pipeline_spend_report.sh's egress checks.)
if grep -nE '\bjq\b' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "6: the shim contains a non-comment 'jq' reference -- transcript/JSON shaping belongs kernel-side only"
fi
echo "PASS: 6a shim has no non-comment jq reference"

if grep -nE 'select\(|with_entries|by_model' "$SHIM" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
  fail "6: the shim contains jq-shaping-looking code (select/with_entries/by_model) outside comments"
fi
echo "PASS: 6b shim has no jq-shaping code outside comments"

# --- 7: STATIC — no fourth hardcoded install-path literal ------------------
if grep -qF '.local/share/temperloop' "$SHIM"; then
  fail "7: the shim hardcodes the TEMPERLOOP_HOME default install-path literal -- bin/bootstrap.sh's header names the three existing hand-synced copies; this shim must not add a fourth (rely on 'command -v temperloop' instead)"
fi
echo "PASS: 7 shim does not hardcode a fourth copy of the install-path literal"

echo "ALL PASS: test_tokens_producer.sh"
