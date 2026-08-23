#!/usr/bin/env bash
#
# test_provider_runner_gate.sh — fixture suite for candidate-session.sh's
# provider RUNNER gate (temperloop#1743, epic #1225, ADR 0028).
#
# The gap this gate closes: _CS_PROVIDER_TABLE registers a key var for
# `openai` / `google` / `gemini`, but the live spawn is hardcoded to
# `${CLAUDE_BIN:-claude}`, which speaks Anthropic's API alone. Before this
# gate, selecting a non-default provider passed preflight, caused replay.sh to
# write a disclosure-log entry attesting a cross-vendor send, and then ran the
# Claude CLI anyway — a FALSE ATTESTATION in the log whose entire job is to
# record provider exposure truthfully.
#
# The load-bearing ORDERING this suite pins: candidate-session.sh's preflight
# runs BEFORE replay.sh's pa_disclose call, so a refusal here means no log
# entry is ever written. Test 5 asserts that directly, byte-for-byte, rather
# than reasoning about it from the call order.
#
# Deliberately does NOT set CANDIDATE_PROVIDER_TEST_SEAM — that seam exists so
# test_candidate_session.sh can still reach non-default-provider containment
# behaviour (temperloop#1252), and a suite testing the GATE must run with the
# seam off. Tests 6-7 are the exception: they exercise the seam itself, to pin
# that it fails closed.
#
# Plain mktemp-fixture style, mirroring test_allowlist.sh — no sandbox.sh
# needed, since nothing here reads a $HOME/XDG-derived path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../candidate-session.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}" >&2; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-provider-runner-gate.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# Every invocation below runs with a FAKE key set for the provider under test.
# That is the whole point: before #1743 a set key was all it took to pass
# preflight, so a suite that left the key unset would pass for the wrong
# reason — it would be observing the key gate, not the runner gate.
FAKE_KEY="sk-test-runner-gate-000000000000"

# ── 1-2. a registered-but-runnerless provider is REFUSED, with its key set ───
for prov in openai gemini; do
  var=OPENAI_API_KEY; [ "$prov" = gemini ] && var=GEMINI_API_KEY
  out="$(env "$var=$FAKE_KEY" bash "$SUT" preflight --provider "$prov" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'has no runner registered'; then
    ok "'$prov' is refused at preflight even with $var SET (the runner gate, not the key gate)"
  else
    bad "$prov.refused" "rc=$rc out=$(printf '%s' "$out" | head -1)"
  fi
done

# ── 3. the DEFAULT provider still passes, silently ──────────────────────────
out="$(bash "$SUT" preflight --provider anthropic 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "the default provider (anthropic) still passes preflight silently"
else
  bad "default.pass" "rc=$rc out=$out"
fi

# ── 4. an UNKNOWN provider is refused with a DIFFERENT message ──────────────
# Collapsing "unknown" into "no runner" would tell an operator to register a
# provider that is already registered, and vice versa.
out="$(bash "$SUT" preflight --provider mistral 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unknown provider' \
   && ! printf '%s' "$out" | grep -q 'has no runner registered'; then
  ok "an unregistered provider reports 'unknown provider', NOT the runner message"
else
  bad "unknown.distinct" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# ── 5. THE ACCEPTANCE CHECK: no disclosure-log entry survives the refusal ────
# The refusal must land before anything is written. Asserted byte-for-byte on
# the log file, so this fails if the ordering is ever inverted.
LOG="$TMP/disclosure-log.jsonl"
: > "$LOG"
printf '{"seq":1,"provider":"anthropic","item_ref":"pr:1","hash":"seed"}\n' > "$LOG"
before="$(shasum -a 256 "$LOG" | awk '{print $1}')"
env OPENAI_API_KEY="$FAKE_KEY" PROVIDER_DISCLOSURE_LOG_FILE="$LOG" \
    bash "$SUT" preflight --provider openai >/dev/null 2>&1
after="$(shasum -a 256 "$LOG" | awk '{print $1}')"
if [ "$before" = "$after" ]; then
  ok "the disclosure log is byte-identical after a refused non-default preflight"
else
  bad "log.untouched" "sha changed: $before -> $after"
fi

# ── 6. the test seam FAILS CLOSED: EXTRA alone does not open the gate ───────
out="$(env OPENAI_API_KEY="$FAKE_KEY" CANDIDATE_PROVIDER_RUNNER_EXTRA='openai:stub-runner' \
      bash "$SUT" preflight --provider openai 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'has no runner registered'; then
  ok "CANDIDATE_PROVIDER_RUNNER_EXTRA is IGNORED without the explicit seam flag"
else
  bad "seam.failclosed" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# ── 7. …and WITH the flag it opens, for the named provider only ─────────────
out="$(env OPENAI_API_KEY="$FAKE_KEY" CANDIDATE_PROVIDER_TEST_SEAM=1 \
      CANDIDATE_PROVIDER_RUNNER_EXTRA='openai:stub-runner' \
      bash "$SUT" preflight --provider openai 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "with CANDIDATE_PROVIDER_TEST_SEAM=1 the named provider passes preflight"
else
  bad "seam.on" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi
out="$(env GEMINI_API_KEY="$FAKE_KEY" CANDIDATE_PROVIDER_TEST_SEAM=1 \
      CANDIDATE_PROVIDER_RUNNER_EXTRA='openai:stub-runner' \
      bash "$SUT" preflight --provider gemini 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'has no runner registered'; then
  ok "…and a provider the seam does NOT name is still refused"
else
  bad "seam.scoped" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# ── 8. the committed table ships every non-default provider runner-LESS ─────
# A mutation guard: if someone fills a runner column in without landing an
# actual per-provider dispatch (the second half of #1743, which still execs
# CLAUDE_BIN unconditionally), this test is what catches it.
# The final table row carries the closing shell quote (`gemini:GEMINI_API_KEY:'`),
# so strip a trailing quote before testing for an empty runner field.
bad_rows="$(grep -E "^(openai|google|gemini):" "$SUT" | sed "s/'\$//" | grep -v ':$' || true)"
if [ -z "$bad_rows" ]; then
  ok "the committed _CS_PROVIDER_TABLE registers no runner for any non-default provider"
else
  bad "table.runnerless" "a non-default provider has a runner but spawn still execs CLAUDE_BIN: $bad_rows"
fi

# ── 9-13. the live/recorded execution mode ──────────────────────────────────
# A recorded runner (`--candidate-runner` / `--judge-runner`) IS a runner and
# never reaches a vendor, so the gate must not refuse it — otherwise every
# fixture in the module breaks while nothing is actually protected. The branch
# is security-relevant in BOTH directions, so both are pinned here.
out="$(env OPENAI_API_KEY="$FAKE_KEY" bash "$SUT" preflight --provider openai --execution recorded 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "--execution recorded allows a runnerless provider (the caller supplied a runner)"
else
  bad "recorded.allows" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

out="$(env -u OPENAI_API_KEY bash "$SUT" preflight --provider openai --execution recorded 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'API key is unset'; then
  ok "…but --execution recorded still enforces the KEY gate"
else
  bad "recorded.keygate" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# THE FAIL-SAFE. A call site that forgets --execution must get the STRICT gate,
# so the cost of a missed call site is a refusal to run, never a silent
# unguarded send. Test 1 already covers the omitted case; this pins that the
# omitted case and the explicit `live` case are the SAME case, so the default
# cannot drift away from strict without this failing.
a="$(env OPENAI_API_KEY="$FAKE_KEY" bash "$SUT" preflight --provider openai 2>&1; printf '|rc=%s' "$?")"
b="$(env OPENAI_API_KEY="$FAKE_KEY" bash "$SUT" preflight --provider openai --execution live 2>&1; printf '|rc=%s' "$?")"
if [ "$a" = "$b" ]; then
  ok "an OMITTED --execution is byte-identical to --execution live (fail-safe default)"
else
  bad "default.strict" "omitted and explicit-live differ"
fi

out="$(env OPENAI_API_KEY="$FAKE_KEY" bash "$SUT" preflight --provider openai --execution sometimes 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'live|recorded'; then
  ok "an unrecognized --execution value is rejected (exit 2), never treated as recorded"
else
  bad "execution.invalid" "rc=$rc out=$(printf '%s' "$out" | head -1)"
fi

# spawn is the function that execs $CLAUDE_BIN, so it must take the strict gate
# unconditionally — there is no --execution on spawn to talk it out of that.
out="$(env OPENAI_API_KEY="$FAKE_KEY" bash "$SUT" spawn --provider openai --execution recorded -- -p hi 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "spawn takes the strict gate regardless — it cannot be argued into recorded mode"
else
  bad "spawn.strict" "spawn returned 0 for a runnerless provider"
fi

printf '\ntest_provider_runner_gate.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
