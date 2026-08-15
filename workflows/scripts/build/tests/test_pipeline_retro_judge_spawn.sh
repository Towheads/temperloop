#!/usr/bin/env bash
#
# Tests for pipeline-retro-judge-spawn.sh — the credential-bearing, ONE-HOP
# spawn site for the overlay `/retro --pending` judge (temperloop#1148).
#
# The property under test is the credential SEAM, never a real retro run:
# these tests deliberately do NOT depend on a working `/retro` (there isn't
# one on a kernel checkout, and #1150's capability gate means the real action
# would not even fire here). Every case drives a CLAUDE_BIN test double that
# records what environment reached the process that actually invokes
# `claude -p`, and asserts on that.
#
# SECURITY CONTRACT OF THIS SUITE: no real credential is ever read, and the
# synthetic one this suite plants is asserted on by PRESENCE and LENGTH only —
# never by value, never written to a tracked fixture. The `_redact` case below
# proves the wrapper strips a credential value out of pass-through child
# output, so a leaky judge cannot launder one into a log through this seam.
#
# Covers:
#   1. the credential exported by build.config.local.sh REACHES the process
#      that invokes `claude -p` (the whole bug), and is EXPORTED there;
#   2. it reaches it even when the caller's own environment carries nothing —
#      i.e. re-derived from the ladder, not inherited (the second-hop fix);
#   3. --dry-run reports credential presence/source without spawning;
#   4. an auth-shaped failure is classified `auth-failed`, exits 3, fires the
#      operator notify channel, and carries the durable `retro-judge-auth-failed`
#      token the health detector reads back;
#   5. an auth failure is caught even when the judge exits ZERO (the "exits
#      success having done nothing" class);
#   6. a plain non-zero exit is `spawn-failed` (exit 4), not mislabelled auth;
#   7. a clean run is `ok` (exit 0) and passes the judge's own output through;
#   8. a credential VALUE never appears in anything the wrapper emits;
#   9. the board argument is validated, and reaches the judge prompt.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../pipeline-retro-judge-spawn.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/retro-spawn-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# temperloop#1255: every non-dry-run spawn below now calls emit-model-usage.sh
# (via model-usage-envelope.sh) after invoking the judge double — a REAL side
# effect (an append to the model-usage raw lake) that, left unpointed, lands
# in THIS checkout's actual (gitignored but real) meta/data/raw/. Point it at
# a throwaway dir under $TMP for the whole suite.
export MODEL_USAGE_RAW_DIR="$TMP/model-usage-raw"

# A SYNTHETIC credential, generated here and never persisted to the repo. Long
# enough that a substring match in the redaction test is meaningful.
FAKE_TOKEN="sk-test-$(date +%s)-0000000000000000000000000000"

# ── The CLAUDE_BIN double ────────────────────────────────────────────────────
# Records the environment it was invoked with (PRESENCE and LENGTH only — the
# value is never written) plus its argv, then emits whatever the case asked for.
# $DOUBLE_MODE selects the emitted shape; $DOUBLE_OUT / $DOUBLE_RC override it.
mk_double() {
  cat > "$TMP/claude-double.sh" <<'DOUBLE'
#!/usr/bin/env bash
rec="${DOUBLE_REC:?}"
: > "$rec"
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf 'oauth_present=1\noauth_len=%s\n' "${#CLAUDE_CODE_OAUTH_TOKEN}" >> "$rec"
else
  printf 'oauth_present=0\noauth_len=0\n' >> "$rec"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  printf 'apikey_present=1\n' >> "$rec"
else
  printf 'apikey_present=0\n' >> "$rec"
fi
printf 'argv=%s\n' "$*" >> "$rec"
# temperloop#1565 (review follow-up): record what THIS CHILD's environment says
# about the model-usage sink. The parent resolves a pin for the emitter; if it
# ever exports it instead of scoping it to the emit command, the pin lands here
# — and the real child (a `claude -p` session) runs quality gates that read this
# same variable. <unset> is the correct answer.
printf 'mu_raw_dir=%s\n' "${MODEL_USAGE_RAW_DIR:-<unset>}" >> "$rec"
# …and, when a case asks for it, ACT on that environment the way any child that
# resolves a lake dir does: write a row into ${MODEL_USAGE_RAW_DIR:-<own default>}.
# This is what gives t11's "nothing but model-usage files in the pinned dir"
# assertion something real to catch — an exported pin diverts this write into
# the pinned lake, a scoped one leaves it in the child's own dir.
if [ -n "${RETRO_RUNS_PROBE_FALLBACK:-}" ]; then
  probe_dir="${MODEL_USAGE_RAW_DIR:-$RETRO_RUNS_PROBE_FALLBACK}"
  mkdir -p "$probe_dir" 2>/dev/null || true
  printf '{"event":"retro-run","judged":1}\n' >> "$probe_dir/retro-runs-probe.jsonl"
fi
case "${DOUBLE_MODE:-clean}" in
  clean)      printf '{"type":"result","is_error":false,"result":"judged 2 trackers"}\n'; exit 0 ;;
  auth-zero)  printf '{"type":"result","is_error":true,"result":"Invalid API key - please run /login"}\n'; exit 0 ;;
  auth-fail)  printf 'OAuth token has expired\n' >&2; exit 1 ;;
  boom)       printf 'segfault in the judge\n' >&2; exit 7 ;;
  leak)       printf '{"type":"result","result":"token was %s"}\n' "${CLAUDE_CODE_OAUTH_TOKEN:-none}"; exit 0 ;;
esac
exit 0
DOUBLE
  chmod +x "$TMP/claude-double.sh"
}
mk_double

# ── The notify double ────────────────────────────────────────────────────────
NOTIFY_REC="$TMP/notify.log"
cat > "$TMP/notify.sh" <<'NOTIFY'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${NOTIFY_REC:?}"
NOTIFY
chmod +x "$TMP/notify.sh"

# ── A fake cron checkout carrying the config ladder ──────────────────────────
# Mirrors the real layout: a build/ dir holding the script under test, a
# build.config.sh, and the gitignored build.config.local.sh that exports the
# credential. Copying the script (rather than symlinking) is what makes $HERE
# resolve to THIS fixture, so the wrapper sources the FIXTURE's ladder.
CO="$TMP/checkout/workflows/scripts/build"
mkdir -p "$CO"
cp "$SCRIPT" "$CO/pipeline-retro-judge-spawn.sh"
chmod +x "$CO/pipeline-retro-judge-spawn.sh"
SUT="$CO/pipeline-retro-judge-spawn.sh"

# temperloop#1255: the real script sources ../lib/model-usage-envelope.sh
# relative to $HERE, which resolves to THIS fixture's $CO once the script is
# copied (not symlinked) above — mirror that same relative layout, or the
# fixture silently exercises a DIFFERENT code path than production (the
# source guard's `[ -f ... ] &&` no-ops, and the later
# model_usage_emit_from_envelope call becomes an unguarded "command not
# found" instead of the real extraction).
mkdir -p "$TMP/checkout/workflows/scripts/lib"
cp "$HERE/../../lib/model-usage-envelope.sh" "$TMP/checkout/workflows/scripts/lib/model-usage-envelope.sh"

cat > "$CO/build.config.sh" <<CONFIG
#!/usr/bin/env bash
: "\${RETRO_JUDGE_MODEL:=claude-sonnet-5}"
[ -f "\$(dirname "\${BASH_SOURCE[0]}")/build.config.local.sh" ] \\
  && . "\$(dirname "\${BASH_SOURCE[0]}")/build.config.local.sh"
CONFIG

# The mode-600 local override — the file the real host keeps the token in.
# Deliberately written with the documented `:=`-then-`export` idiom.
cat > "$CO/build.config.local.sh" <<LOCAL
: "\${CLAUDE_CODE_OAUTH_TOKEN:=$FAKE_TOKEN}"
export CLAUDE_CODE_OAUTH_TOKEN
LOCAL
chmod 600 "$CO/build.config.local.sh"

REC="$TMP/double.rec"
run_sut() {  # env overrides come from the caller; args pass through
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" \
  CLAUDE_BIN="$TMP/claude-double.sh" PIPELINE_NOTIFY_CMD="$TMP/notify.sh" \
  DOUBLE_MODE="${MODE:-clean}" \
  bash "$SUT" "$@"
}

echo "--- test 1: the credential from build.config.local.sh REACHES the claude -p process ---"
: > "$REC"
MODE=clean OUT="$(run_sut --board 3)"; RC=$?
[ "$RC" -eq 0 ] && ok "clean run exits 0" || bad "t1.rc" "got $RC"
grep -q '^oauth_present=1$' "$REC" \
  && ok "CLAUDE_CODE_OAUTH_TOKEN is present in the spawn process's environment" \
  || bad "t1.present" "$(cat "$REC")"
[ "$(sed -n 's/^oauth_len=//p' "$REC")" = "${#FAKE_TOKEN}" ] \
  && ok "it arrives intact (length matches; value never asserted on)" \
  || bad "t1.len" "$(cat "$REC")"

echo "--- test 2: it is RE-DERIVED, not inherited — a caller with an empty env still works ---"
# THE BUG: session A's Bash tool hands its child no credential. Simulate that
# exactly by scrubbing the variable from the caller's environment. If the
# wrapper only inherited, this case would report oauth_present=0.
: > "$REC"
OUT2="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" DOUBLE_MODE=clean \
  CLAUDE_BIN="$TMP/claude-double.sh" PIPELINE_NOTIFY_CMD="$TMP/notify.sh" \
  bash "$SUT" --board 3)"
grep -q '^oauth_present=1$' "$REC" \
  && ok "credential re-derived from the ladder even with an empty caller env (the #1148 fix)" \
  || bad "t2.present" "$(cat "$REC")"
[ "$(jq -r '.credential_source' <<<"$OUT2")" = "oauth-token" ] \
  && ok "credential_source names the source, never the value" || bad "t2.source" "$OUT2"
[ "$(jq -r '.credential_present' <<<"$OUT2")" = "true" ] \
  && ok "credential_present=true" || bad "t2.present.json" "$OUT2"

echo "--- test 2b: control — with the ladder file GONE, the credential is absent and said so ---"
# The disconfirming half of test 2: if some ambient environment were quietly
# supplying the token, test 2 would pass for the wrong reason. Move the local
# config aside and the same invocation must report credential_present=false and
# WARN — proving the fixture ladder really is what test 2 measured.
mv "$CO/build.config.local.sh" "$TMP/local.stashed"
: > "$REC"
set +e
OUT2B="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" DOUBLE_MODE=clean \
  CLAUDE_BIN="$TMP/claude-double.sh" PIPELINE_NOTIFY_CMD="$TMP/notify.sh" \
  bash "$SUT" --board 3 2>"$TMP/err2b")"
set -e
[ "$(jq -r '.credential_present' <<<"$OUT2B")" = "false" ] \
  && ok "no ladder file ⇒ credential_present=false (test 2 measured the ladder, not the ambient env)" \
  || bad "t2b.present" "$OUT2B"
[ "$(jq -r '.credential_source' <<<"$OUT2B")" = "interactive-session" ] \
  && ok "falls back to the interactive-session source label" || bad "t2b.source" "$OUT2B"
grep -qi 'NO host credential in scope' "$TMP/err2b" \
  && ok "and WARNS before the spawn instead of refusing (an attended host still works)" \
  || bad "t2b.warn" "$(cat "$TMP/err2b")"
grep -q '^oauth_present=0$' "$REC" \
  && ok "the spawn still happened, with nothing exported" || bad "t2b.spawn" "$(cat "$REC")"
mv "$TMP/local.stashed" "$CO/build.config.local.sh"

echo "--- test 3: --dry-run reports the resolved credential WITHOUT spawning ---"
rm -f "$REC"
OUT3="$(run_sut --board 4 --dry-run)"; RC=$?
[ "$RC" -eq 0 ] && ok "dry-run exits 0" || bad "t3.rc" "got $RC"
[ "$(jq -r '.status' <<<"$OUT3")" = "dry-run" ] \
  && ok "status=dry-run" || bad "t3.status" "$OUT3"
[ ! -f "$REC" ] && ok "no claude was spawned" || bad "t3.spawn" "the double ran: $(cat "$REC")"
[ "$(jq -r '.credential_present' <<<"$OUT3")" = "true" ] \
  && ok "dry-run still answers the credential question (the operator probe)" || bad "t3.cred" "$OUT3"

echo "--- test 4: an auth failure is classified, exits 3, and is LOUD ---"
: > "$NOTIFY_REC"
set +e
OUT4="$(MODE=auth-fail run_sut --board 3 2>"$TMP/err4")"; RC=$?
set -e
[ "$RC" -eq 3 ] && ok "exit 3 distinguishes auth-failed from every other outcome" || bad "t4.rc" "got $RC"
[ "$(jq -r '.status' <<<"$OUT4")" = "auth-failed" ] \
  && ok "status=auth-failed" || bad "t4.status" "$OUT4"
jq -e '.note | test("retro-judge-auth-failed")' <<<"$OUT4" >/dev/null \
  && ok "the note carries the durable token pipeline-retro-health.sh reads back" || bad "t4.token" "$OUT4"
grep -qi 'AUTH FAILURE' "$NOTIFY_REC" \
  && ok "the operator notify channel fired (not just a counter)" || bad "t4.notify" "$(cat "$NOTIFY_REC")"
grep -qi 'AUTH FAILURE' "$TMP/err4" \
  && ok "and it is on stderr too, so a headless cron log carries it" || bad "t4.stderr" "$(cat "$TMP/err4")"

echo "--- test 5: an auth failure that exits ZERO is still caught (shape, not exit code) ---"
set +e
OUT5="$(MODE=auth-zero run_sut --board 3 2>/dev/null)"; RC=$?
set -e
[ "$RC" -eq 3 ] && ok "a success-exiting auth error is still auth-failed" || bad "t5.rc" "got $RC"
[ "$(jq -r '.exit' <<<"$OUT5")" = "0" ] \
  && ok "and the judge's own exit code is reported honestly (0)" || bad "t5.exit" "$OUT5"

echo "--- test 6: a plain non-zero exit is spawn-failed, never mislabelled auth ---"
set +e
OUT6="$(MODE=boom run_sut --board 3 2>/dev/null)"; RC=$?
set -e
[ "$RC" -eq 4 ] && ok "exit 4 for a non-auth failure" || bad "t6.rc" "got $RC"
[ "$(jq -r '.status' <<<"$OUT6")" = "spawn-failed" ] \
  && ok "status=spawn-failed" || bad "t6.status" "$OUT6"
jq -e '.note | test("retro-judge-auth-failed") | not' <<<"$OUT6" >/dev/null \
  && ok "the auth token is NOT emitted for a non-auth failure" || bad "t6.token" "$OUT6"

echo "--- test 7: a clean run passes the judge's own output through ---"
OUT7="$(MODE=clean run_sut --board 3)"
[ "$(jq -r '.status' <<<"$OUT7")" = "ok" ] && ok "status=ok" || bad "t7.status" "$OUT7"
jq -e '.judge | test("judged 2 trackers")' <<<"$OUT7" >/dev/null \
  && ok "the judge's stdout is carried through for the driver to judge" || bad "t7.judge" "$OUT7"

echo "--- test 8: a credential VALUE never appears in anything the wrapper emits ---"
# The double deliberately LEAKS the token into its own stdout. The wrapper must
# redact it on the way out — belt and braces over never printing it itself.
OUT8="$(MODE=leak run_sut --board 3 2>"$TMP/err8")"
grep -qF "$FAKE_TOKEN" <<<"$OUT8" \
  && bad "t8.leak" "the credential value survived into stdout" \
  || ok "no credential value in stdout (a leaking child is redacted)"
grep -qF "$FAKE_TOKEN" "$TMP/err8" \
  && bad "t8.leak.err" "the credential value survived into stderr" \
  || ok "no credential value in stderr"
jq -e '.judge | test("<redacted>")' <<<"$OUT8" >/dev/null \
  && ok "the leak is visibly redacted rather than silently dropped" || bad "t8.marker" "$OUT8"

echo "--- test 9: --board is required and reaches the judge prompt ---"
set +e
bash "$SUT" --model x >/dev/null 2>&1; RC=$?
set -e
[ "$RC" -eq 2 ] && ok "a missing --board is a usage error (exit 2)" || bad "t9.rc" "got $RC"
: > "$REC"
MODE=clean run_sut --board 6 >/dev/null
grep -q -- '--board 6' "$REC" \
  && ok "the board reaches the /retro --pending prompt" || bad "t9.argv" "$(cat "$REC")"

# ── 10-13: the model-usage lake sink is CALLER-PINNED (temperloop#1565) ───────
# THE BUG this fixture models EXACTLY. emit-model-usage.sh derives its lake
# root by climbing two levels from its OWN file location. The pipeline runs the
# kernel copy VENDORED under a consuming checkout — which is precisely what
# $TMP/checkout is here — so the climb landed on the vendored root and every
# judge-spawn record went to <vendored>/meta/data/raw/ instead of a real lake.
#
# Copying the real emitter into the fixture (the sibling files above are copied
# for the same reason) is what makes these cases exercise the production path:
# without it model_usage_emit_from_envelope finds no executable emit script and
# returns early, and the sink is never resolved at all.
cp "$HERE/../../emit-model-usage.sh" "$TMP/checkout/workflows/scripts/emit-model-usage.sh"
chmod +x "$TMP/checkout/workflows/scripts/emit-model-usage.sh"
MU_MONTH="$(date -u +%Y-%m)"
MU_VENDORED_LAKE="$TMP/checkout/meta/data/raw"     # where the UNFIXED climb landed

echo "--- test 10: with MODEL_USAGE_RAW_DIR unset, the record lands in PIPELINE_RAW_DIR, not the vendored checkout (temperloop#1565) ---"
MU_LAKE="$TMP/canonical-lake"
: > "$REC"
# BSD env(1): every -u precedes the NAME=VALUE assignments.
MU_OUT10="$(env -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$MU_LAKE" \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" CLAUDE_BIN="$TMP/claude-double.sh" \
  PIPELINE_NOTIFY_CMD="$TMP/notify.sh" DOUBLE_MODE=clean bash "$SUT" --board 3)" || true
[ "$(jq -r '.status' <<<"$MU_OUT10")" = "ok" ] && ok "the judge spawn still reports ok" || bad "t10.status" "$MU_OUT10"
[ -s "$MU_LAKE/model-usage-$MU_MONTH.jsonl" ] \
  && ok "the model-usage record landed in the CANONICAL lake (\$PIPELINE_RAW_DIR)" \
  || bad "t10.sink" "no record at $MU_LAKE/model-usage-$MU_MONTH.jsonl (dir: $(ls -A "$MU_LAKE" 2>/dev/null || echo MISSING))"
grep -F '"seat":"retro-judge"' "$MU_LAKE/model-usage-$MU_MONTH.jsonl" >/dev/null 2>&1 \
  && ok "…and it is this wrapper's own retro-judge seat record" \
  || bad "t10.seat" "$(cat "$MU_LAKE/model-usage-$MU_MONTH.jsonl" 2>/dev/null)"
[ ! -e "$MU_VENDORED_LAKE/model-usage-$MU_MONTH.jsonl" ] \
  && ok "and NOTHING was written to the VENDORED checkout's own meta/data/raw (the pre-fix destination)" \
  || bad "t10.vendored" "the vendored stub lake was written: $(cat "$MU_VENDORED_LAKE/model-usage-$MU_MONTH.jsonl" 2>/dev/null)"

echo "--- test 11: RETRO-RUNS is untouched — the pin moves the model-usage stream ONLY (temperloop#1565) ---"
# pipeline-retro-health.sh resolves the retro-runs stream CHECKOUT-RELATIVE on
# the documented ground that THIS wrapper sets no retro-runs override. That
# ground must survive the model-usage pin.
#
# The first half of this test used to be vacuous: it listed the pinned dir and
# asserted no non-model-usage file was there, but nothing in the fixture ever
# wrote a second stream, so it passed in every possible world — including one
# where the property is violated. Fix it by giving it something real to catch:
# RETRO_RUNS_PROBE_FALLBACK makes the CLAUDE_BIN double write a retro-runs row
# into `${MODEL_USAGE_RAW_DIR:-<its own dir>}`, i.e. it behaves like any child
# that resolves a lake dir out of its inherited environment. With the pin
# correctly scoped to the emit command the row lands in the child's own dir;
# with the pin exported it is diverted into the pinned lake and this fails.
MU_PROBE_HOME="$TMP/child-own-lake"
: > "$REC"
env -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$MU_LAKE" \
  RETRO_RUNS_PROBE_FALLBACK="$MU_PROBE_HOME" \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" CLAUDE_BIN="$TMP/claude-double.sh" \
  PIPELINE_NOTIFY_CMD="$TMP/notify.sh" DOUBLE_MODE=clean bash "$SUT" --board 3 >/dev/null || true
[ -s "$MU_PROBE_HOME/retro-runs-probe.jsonl" ] \
  && ok "the child's own retro-runs row landed in the CHILD's dir (its environment carried no pin to follow)" \
  || bad "t11.probe" "no probe row at $MU_PROBE_HOME (dir: $(ls -A "$MU_PROBE_HOME" 2>/dev/null || echo MISSING))"
[ ! -e "$MU_LAKE/retro-runs-probe.jsonl" ] \
  && ok "…and it was NOT diverted into the pinned model-usage lake" \
  || bad "t11.diverted" "a retro-runs row was written into the pinned lake $MU_LAKE"
grep -E 'RETRO_RUNS_RAW_DIR|TELEMETRY_RAW_DIR' "$SCRIPT" >/dev/null \
  && bad "t11.vars" "the wrapper now names a retro-runs/telemetry raw-dir variable" \
  || ok "the wrapper still names NO retro-runs or telemetry raw-dir variable (pipeline-retro-health.sh's stated premise holds)"

echo "--- test 12: an explicitly-set MODEL_USAGE_RAW_DIR still wins (the pin is a default, not a clobber) ---"
MU_OVERRIDE="$TMP/explicit-override-lake"
: > "$REC"
env MODEL_USAGE_RAW_DIR="$MU_OVERRIDE" PIPELINE_RAW_DIR="$TMP/decoy-lake" \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" CLAUDE_BIN="$TMP/claude-double.sh" \
  PIPELINE_NOTIFY_CMD="$TMP/notify.sh" DOUBLE_MODE=clean bash "$SUT" --board 3 >/dev/null || true
[ -s "$MU_OVERRIDE/model-usage-$MU_MONTH.jsonl" ] \
  && ok "an already-set MODEL_USAGE_RAW_DIR passes through untouched (the live test seam this suite itself relies on)" \
  || bad "t12.override" "no record at $MU_OVERRIDE"
[ ! -e "$TMP/decoy-lake/model-usage-$MU_MONTH.jsonl" ] \
  && ok "…and PIPELINE_RAW_DIR does NOT override it" || bad "t12.precedence" "the decoy lake was written"

echo "--- test 13: the \$HOME expansion is guarded, and the literal matches pipeline-cron.sh's ---"
# This wrapper runs under `set -u`, where a bare $HOME in the pinned default is
# an immediate abort. With HOME unset the script already dies later, inside
# build.config.sh (a pre-existing, unrelated condition), so assert on the
# SHIPPED bytes of the guard block itself — that is what discriminates a
# guarded seam from an unguarded one.
MU_GS="$(grep -n -F 'if [ -n "${MODEL_USAGE_RAW_DIR:-}" ]' "$SCRIPT" | head -n1 | cut -d: -f1)"
MU_GE="$((MU_GS + 2))"
MU_GUARD="$(sed -n "${MU_GS},${MU_GE}p" "$SCRIPT")"
[ -n "$MU_GS" ] && [ "$(sed -n "${MU_GE}p" "$SCRIPT")" = "fi" ] \
  && ok "located the guarded pin block in the shipped script" || bad "t13.locate" "block not found at $MU_GS"
MU_G1="$(env -u HOME -u PIPELINE_RAW_DIR -u MODEL_USAGE_RAW_DIR bash -c \
  'set -uo pipefail; '"$MU_GUARD"'; printf "SURVIVED:%s" "${_MODEL_USAGE_SINK_DIR:-<unset>}"' 2>&1)" || MU_G1="ABORTED:$MU_G1"
[ "$MU_G1" = "SURVIVED:<unset>" ] \
  && ok "HOME/PIPELINE_RAW_DIR/MODEL_USAGE_RAW_DIR all unset → the seam sets nothing and does not abort" \
  || bad "t13.unset-home" "got '$MU_G1'"
MU_G2="$(env -u PIPELINE_RAW_DIR -u MODEL_USAGE_RAW_DIR HOME="$TMP/fakehome" bash -c \
  'set -uo pipefail; '"$MU_GUARD"'; printf "%s" "$_MODEL_USAGE_SINK_DIR"' 2>&1)" || MU_G2="ABORTED:$MU_G2"
[ "$MU_G2" = "$TMP/fakehome/dev/foundation/meta/data/raw" ] \
  && ok "with HOME set and no overrides, the pin resolves to the canonical absolute sink" || bad "t13.home-set" "got '$MU_G2'"
MU_CRON_LIT="$(grep -F 'RAW_DIR="${PIPELINE_RAW_DIR:-' "$HERE/../pipeline-cron.sh" | head -n1 | sed -E 's/.*\$\{PIPELINE_RAW_DIR:-(.*)\}".*/\1/')"
MU_SUT_LIT="$(grep -F 'MODEL_USAGE_RAW_DIR:-${PIPELINE_RAW_DIR:-' "$SCRIPT" | grep -v '^[[:space:]]*#' | head -n1 | sed -E 's/.*\$\{PIPELINE_RAW_DIR:-(.*)\}\}".*/\1/')"
[ -n "$MU_CRON_LIT" ] && [ "$MU_CRON_LIT" = "$MU_SUT_LIT" ] \
  && ok "the pinned default ($MU_SUT_LIT) equals pipeline-cron.sh's RAW_DIR literal verbatim" \
  || bad "t13.equal" "cron='$MU_CRON_LIT' sut='$MU_SUT_LIT'"

echo "--- test 14: the SPAWNED CHILD does not inherit the sink pin (temperloop#1565 review) ---"
# THE REGRESSION THIS GUARDS. Handing the emitter its sink via
# `export MODEL_USAGE_RAW_DIR` at the top of this wrapper works for the emitter
# and is wrong for everything else: an export is process-wide and inherited, so
# the `claude -p` judge spawned below receives it too. That session's own
# quality gates read the same variable — validate-model-usage-emit.sh and
# validate-provider-disclosure.sh both do — which would silently turn two
# repo-scoped gates into production-data gates. The pin is therefore applied as
# a per-command prefix on the emitter alone; the child must see NOTHING.
: > "$REC"
env -u MODEL_USAGE_RAW_DIR PIPELINE_RAW_DIR="$TMP/lake14" \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" CLAUDE_BIN="$TMP/claude-double.sh" \
  PIPELINE_NOTIFY_CMD="$TMP/notify.sh" DOUBLE_MODE=clean bash "$SUT" --board 3 >/dev/null || true
[ "$(sed -n 's/^mu_raw_dir=//p' "$REC")" = "<unset>" ] \
  && ok "the spawned judge's environment carries NO MODEL_USAGE_RAW_DIR (its gates keep reading their own checkout)" \
  || bad "t14.inherited" "the child inherited MODEL_USAGE_RAW_DIR=$(sed -n 's/^mu_raw_dir=//p' "$REC")"
[ -s "$TMP/lake14/model-usage-$MU_MONTH.jsonl" ] \
  && ok "…while the emitter still wrote to the pinned canonical lake (the pin works, it just does not leak)" \
  || bad "t14.emit" "no record at $TMP/lake14"

echo "--- test 15: a caller that DID export it is passed through to the child unchanged ---"
# The complement, so t14 cannot be satisfied by scrubbing the variable: when the
# OPERATOR's own environment exports MODEL_USAGE_RAW_DIR, that is their choice
# and this wrapper neither adds nor removes it. t14 proves we introduce no leak;
# this proves we do not silently strip an inherited one either.
: > "$REC"
env MODEL_USAGE_RAW_DIR="$TMP/lake15" \
  DOUBLE_REC="$REC" NOTIFY_REC="$NOTIFY_REC" CLAUDE_BIN="$TMP/claude-double.sh" \
  PIPELINE_NOTIFY_CMD="$TMP/notify.sh" DOUBLE_MODE=clean bash "$SUT" --board 3 >/dev/null || true
[ "$(sed -n 's/^mu_raw_dir=//p' "$REC")" = "$TMP/lake15" ] \
  && ok "an operator-exported value reaches the child untouched (we neither inject nor strip)" \
  || bad "t15.passthrough" "got $(sed -n 's/^mu_raw_dir=//p' "$REC")"

echo
printf 'pipeline-retro-judge-spawn: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
