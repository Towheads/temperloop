#!/usr/bin/env bash
#
# Tests for workflows/scripts/model-comparison/candidate-session.sh (temperloop#1252).
#
# Kernel principle 3: deterministic, fixture-based, no network, no live model
# call. Every case here drives a CLAUDE_BIN test double instead of a real
# `claude` binary — nothing in this suite spends a token or reaches the
# network. `candidate-session.sh` is always invoked as a SUBPROCESS (`bash
# "$SUT" …`), never sourced, matching its own documented contract — this is
# also what makes the parent-environment-isolation assertions in Part 2
# meaningful rather than vacuous.
#
# Covers (mapped to the item's acceptance bullets):
#   Part 1 (bullet 1) — the settings overlay's EFFECTIVE tool surface, via
#     candidate-session.sh's own real deny-over-allow glob resolver, not a
#     grep for JSON key presence. Denies every knowledge-store/vault MCP
#     namespace and every path/command reaching the host-secrets file, even
#     through Bash-command indirection; allows the ordinary replay surface.
#   Part 2 (bullet 2) — a provider key present at spawn reaches the spawned
#     `claude` CHILD process, is absent from the PARENT (this test script's
#     own) environment both before and after, and never appears in anything
#     candidate-session.sh itself emits (its own stdout/stderr).
#   Part 3 (bullet 3) — a non-default provider with an UNSET key fails at
#     pre-flight, verbatim, naming the exact env var and the concrete
#     host-supply file — and never spawns a child.
#   Part 4 (bullet 4) — the default path (no candidate provider / provider
#     "anthropic") requires no key, is silent, and spawns unaffected.
#   Part 5 — an unknown provider name is a distinct, named, non-zero failure
#     rather than being silently treated as "no key needed".
#   Part 6 — a missing settings overlay refuses to spawn uncontained.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../candidate-session.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/candidate-session-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A SYNTHETIC key, generated here and never persisted to the repo. Long
# enough that a substring search in the leak-check is meaningful.
FAKE_KEY="sk-test-$(date +%s)-0000000000000000000000000000"

# ── The CLAUDE_BIN double ────────────────────────────────────────────────────
# Records PRESENCE and LENGTH of the provider-key env var it was invoked with
# (never the value itself, even in the fixture's own bookkeeping) plus its
# argv, then emits a plain JSON line — no credential is ever echoed by the
# double, matching how a real `claude -p` invocation would behave.
DOUBLE="$TMP/claude-double.sh"
cat > "$DOUBLE" <<'DOUBLE'
#!/usr/bin/env bash
rec="${DOUBLE_REC:?}"
: > "$rec"
if [ -n "${OPENAI_API_KEY:-}" ]; then
  printf 'present=1\nlen=%s\n' "${#OPENAI_API_KEY}" >> "$rec"
else
  printf 'present=0\n' >> "$rec"
fi
printf 'argv=%s\n' "$*" >> "$rec"
printf '{"type":"result","is_error":false,"result":"ok"}\n'
DOUBLE
chmod +x "$DOUBLE"

REC="$TMP/double.rec"

# ── A fake checkout carrying the config ladder ───────────────────────────────
# Mirrors test_pipeline_retro_judge_spawn.sh's fixture shape: a build/ dir
# with build.config.sh, and the gitignored build.config.local.sh that exports
# the synthetic key using its documented `:=`-then-`export` idiom. Copying
# (not symlinking) candidate-session.sh is what makes its own $HERE resolve
# INTO this fixture, so it sources the FIXTURE's ladder, not the real repo's.
CO="$TMP/checkout/workflows/scripts"
mkdir -p "$CO/build" "$CO/model-comparison"
cp "$SUT" "$CO/model-comparison/candidate-session.sh"
chmod +x "$CO/model-comparison/candidate-session.sh"
cp "$HERE/../candidate.settings.json" "$CO/model-comparison/candidate.settings.json"
FIXTURE_SUT="$CO/model-comparison/candidate-session.sh"

cat > "$CO/build/build.config.sh" <<'CONFIG'
#!/usr/bin/env bash
[ -f "$(dirname "${BASH_SOURCE[0]}")/build.config.local.sh" ] \
  && . "$(dirname "${BASH_SOURCE[0]}")/build.config.local.sh"
CONFIG

cat > "$CO/build/build.config.local.sh" <<LOCAL
: "\${OPENAI_API_KEY:=$FAKE_KEY}"
export OPENAI_API_KEY
LOCAL
chmod 600 "$CO/build/build.config.local.sh"

run_fixture() {  # env overrides from caller; args pass through
  DOUBLE_REC="$REC" CLAUDE_BIN="$DOUBLE" bash "$FIXTURE_SUT" "$@"
}

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 1 (bullet 1) — the EFFECTIVE tool surface, via real glob resolution │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 1: effective tool surface (resolve — real matching, not grep) ---"

assert_resolve() {  # $1 call, $2 expected verdict, $3 label
  local got
  got="$(bash "$SUT" resolve "$1")"
  [ "$got" = "$2" ] && ok "$3" || bad "$3" "resolve('$1') = '$got', expected '$2'"
}

assert_resolve "mcp__obsidian__search_vault_smart" "deny" "vault semantic search MCP tool is denied"
assert_resolve "mcp__obsidian-builtin__vault_read" "deny" "vault REST-API MCP tool is denied"
assert_resolve "mcp__obsidian-builtin__vault_write" "deny" "vault write MCP tool is denied"
assert_resolve "mcp__things__get_today" "deny" "the personal Things MCP surface is denied too"
assert_resolve "Read(workflows/scripts/build/build.config.local.sh)" "deny" "direct Read of the secrets file is denied"
assert_resolve "Edit(workflows/scripts/build/build.config.local.sh)" "deny" "direct Edit of the secrets file is denied"
assert_resolve "Bash(cat workflows/scripts/build/build.config.local.sh)" "deny" \
  "Bash-command INDIRECTION at the secrets file is denied (not just the Read tool)"
assert_resolve "Bash(env; cat workflows/scripts/build/build.config.local.sh > /tmp/x)" "deny" \
  "the secrets-file deny still fires when embedded inside a larger command"
assert_resolve "Read(workflows/scripts/build/.env)" "deny" ".env sibling is denied"

# The narrowing must not be accidental over-broad denial of the whole tool —
# ordinary Bash/Read/Edit calls that don't touch the secrets file or vault
# MCP surface stay reachable, proving this is a scoped deny, not "nothing
# works" (which would trivially and uselessly satisfy bullet 1).
assert_resolve "Read(docs/README.md)" "allow" "an ordinary Read call is still reachable"
assert_resolve "Bash(git status)" "allow" "an ordinary Bash call is still reachable"
assert_resolve "Task" "allow" "the Task tool is reachable"
assert_resolve "Write(some/scratch/file.txt)" "allow" "an ordinary Write call is still reachable"
assert_resolve "WebFetch" "unspecified" "a tool named in neither list resolves unspecified, not allow"

# Disconfirming control: prove the resolver is REAL matching, not a
# hardcoded-answer stub — feed it a settings file with an EMPTY deny list and
# confirm the same vault call now resolves allow (the same overlay JSON
# shape, minus the deny entries, changes the verdict).
NO_DENY="$TMP/no-deny.settings.json"
jq '.permissions.deny = []' "$HERE/../candidate.settings.json" > "$NO_DENY"
got_control="$(bash "$SUT" resolve "mcp__obsidian__search_vault_smart" --settings "$NO_DENY")"
[ "$got_control" = "unspecified" ] \
  && ok "control: with the deny list emptied, the same MCP call no longer resolves deny — the resolver is live matching against the file, not a hardcoded stub" \
  || bad "control.live-matching" "got '$got_control', expected 'unspecified' with an emptied deny list"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 2 (bullet 2) — key isolation: reaches the child, absent from parent │
# │ and from every emitted record                                            │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 2: key isolation (spawn) ---"

# Confirm the PARENT (this test script's own process) does not carry the key
# BEFORE the spawn — establishing the baseline the "absent from parent"
# assertion below is actually measuring against.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  bad "t2.baseline" "this test process unexpectedly already has OPENAI_API_KEY set"
else
  ok "baseline: this test process carries no OPENAI_API_KEY before the spawn"
fi

: > "$REC"
SPAWN_OUT="$(run_fixture spawn --provider openai -- -p "hello" 2>"$TMP/spawn.err")"
SPAWN_RC=$?

[ "$SPAWN_RC" -eq 0 ] && ok "spawn exits 0" || bad "t2.rc" "got $SPAWN_RC"
grep -q '^present=1$' "$REC" \
  && ok "the key REACHES the spawned claude child process" \
  || bad "t2.reaches-child" "$(cat "$REC")"
[ "$(sed -n 's/^len=//p' "$REC")" = "${#FAKE_KEY}" ] \
  && ok "it arrives intact (length matches; value never asserted on directly)" \
  || bad "t2.len" "$(cat "$REC")"

# The load-bearing assertion: after the subprocess returns, THIS test
# script's own (parent) environment still carries no OPENAI_API_KEY — the key
# was exported only inside the candidate-session.sh subprocess (and its own
# `env VAR=value` spawn line), which cannot write back into its parent.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  bad "t2.parent-leak" "OPENAI_API_KEY leaked into the PARENT process after spawn returned"
else
  ok "the key is ABSENT from the parent process after the subprocess returns"
fi

# "Absent from every emitted record": candidate-session.sh's own stdout and
# stderr from this invocation carry no occurrence of the key value.
if printf '%s' "$SPAWN_OUT" | grep -F "$FAKE_KEY" >/dev/null; then
  bad "t2.stdout-leak" "the key value appeared in candidate-session.sh's own stdout"
else
  ok "the key value never appears in candidate-session.sh's own stdout"
fi
if grep -qF "$FAKE_KEY" "$TMP/spawn.err" 2>/dev/null; then
  bad "t2.stderr-leak" "the key value appeared in candidate-session.sh's own stderr"
else
  ok "the key value never appears in candidate-session.sh's own stderr"
fi

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 3 (bullet 3) — unset non-default key fails LOUDLY at pre-flight     │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 3: unset-key pre-flight failure ---"

NO_KEY_CO="$TMP/checkout-no-key/workflows/scripts"
mkdir -p "$NO_KEY_CO/build" "$NO_KEY_CO/model-comparison"
cp "$SUT" "$NO_KEY_CO/model-comparison/candidate-session.sh"
chmod +x "$NO_KEY_CO/model-comparison/candidate-session.sh"
cp "$HERE/../candidate.settings.json" "$NO_KEY_CO/model-comparison/candidate.settings.json"
cat > "$NO_KEY_CO/build/build.config.sh" <<'CONFIG'
#!/usr/bin/env bash
[ -f "$(dirname "${BASH_SOURCE[0]}")/build.config.local.sh" ] \
  && . "$(dirname "${BASH_SOURCE[0]}")/build.config.local.sh"
CONFIG
# Deliberately NO build.config.local.sh — this is the "never set it" host.
NO_KEY_SUT="$NO_KEY_CO/model-comparison/candidate-session.sh"

: > "$REC"
set +e
PREFLIGHT_ERR="$(env -u OPENAI_API_KEY -u GEMINI_API_KEY \
  bash "$NO_KEY_SUT" preflight --provider openai 2>&1)"
PREFLIGHT_RC=$?
set -e
[ "$PREFLIGHT_RC" -ne 0 ] && ok "preflight fails (non-zero exit) on an unset key" || bad "t3.rc" "got $PREFLIGHT_RC"
printf '%s' "$PREFLIGHT_ERR" | grep -F "OPENAI_API_KEY" >/dev/null \
  && ok "the message names the EXACT environment variable (OPENAI_API_KEY)" \
  || bad "t3.var" "$PREFLIGHT_ERR"
printf '%s' "$PREFLIGHT_ERR" | grep -F "workflows/scripts/build/build.config.local.sh" >/dev/null \
  && ok "the message names the concrete host-supply location" \
  || bad "t3.location" "$PREFLIGHT_ERR"
printf '%s' "$PREFLIGHT_ERR" | grep -i "unset" >/dev/null \
  && ok "the message states the key is unset (gates on the value, not just names the location)" \
  || bad "t3.gates" "$PREFLIGHT_ERR"

echo "  verbatim message:"
printf '%s\n' "$PREFLIGHT_ERR" | sed 's/^/    /'

# spawn refuses too — never a silent no-op, and the child is never invoked.
: > "$REC"
set +e
SPAWN_UNSET_OUT="$(env -u OPENAI_API_KEY -u GEMINI_API_KEY \
  DOUBLE_REC="$REC" CLAUDE_BIN="$DOUBLE" \
  bash "$NO_KEY_SUT" spawn --provider openai -- -p "hello" 2>"$TMP/spawn-unset.err")"
SPAWN_UNSET_RC=$?
set -e
[ "$SPAWN_UNSET_RC" -ne 0 ] && ok "spawn refuses (non-zero exit) rather than running uncontained" || bad "t3.spawn.rc" "got $SPAWN_UNSET_RC"
[ ! -s "$REC" ] && ok "the claude child process was NEVER invoked (fail-closed, not a silent no-op)" \
  || bad "t3.spawn.noop" "the double ran anyway: $(cat "$REC")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 4 (bullet 4) — the default path is unaffected                       │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 4: default path unaffected ---"

set +e
DEFAULT_OUT="$(env -u OPENAI_API_KEY -u GEMINI_API_KEY bash "$SUT" preflight --provider anthropic 2>&1)"
DEFAULT_RC=$?
set -e
[ "$DEFAULT_RC" -eq 0 ] && ok "preflight for the default provider exits 0 with no key present" || bad "t4.rc" "got $DEFAULT_RC"
[ -z "$DEFAULT_OUT" ] && ok "preflight for the default provider is silent (no message, nothing to gate on)" \
  || bad "t4.silent" "$DEFAULT_OUT"

set +e
DEFAULT_NOPROVIDER_RC=0
env -u OPENAI_API_KEY -u GEMINI_API_KEY bash "$SUT" preflight >/dev/null 2>&1 || DEFAULT_NOPROVIDER_RC=$?
set -e
[ "$DEFAULT_NOPROVIDER_RC" -eq 0 ] && ok "preflight with NO --provider at all also exits 0 (bare 'nothing selected' case)" \
  || bad "t4.no-provider" "got $DEFAULT_NOPROVIDER_RC"

: > "$REC"
DEFAULT_SPAWN_OUT="$(env -u OPENAI_API_KEY -u GEMINI_API_KEY \
  DOUBLE_REC="$REC" CLAUDE_BIN="$DOUBLE" \
  bash "$SUT" spawn --provider anthropic --settings "$HERE/../candidate.settings.json" -- -p "hello" 2>&1)"
DEFAULT_SPAWN_RC=$?
[ "$DEFAULT_SPAWN_RC" -eq 0 ] && ok "the default-provider spawn succeeds unaffected" || bad "t4.spawn.rc" "got $DEFAULT_SPAWN_RC"
grep -q '^present=0$' "$REC" \
  && ok "the default-provider spawn carries no provider-key env var at all (nothing changes)" \
  || bad "t4.spawn.no-key" "$(cat "$REC")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 5 — an unknown provider is a named failure, never a silent no-op    │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 5: unknown provider name ---"
set +e
UNKNOWN_OUT="$(bash "$SUT" preflight --provider not-a-real-provider 2>&1)"
UNKNOWN_RC=$?
set -e
[ "$UNKNOWN_RC" -ne 0 ] && ok "an unregistered provider name fails (non-zero)" || bad "t5.rc" "got $UNKNOWN_RC"
printf '%s' "$UNKNOWN_OUT" | grep -F "not-a-real-provider" >/dev/null \
  && ok "the failure names the offending provider" || bad "t5.name" "$UNKNOWN_OUT"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 6 — a missing settings overlay refuses to spawn uncontained         │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 6: missing overlay fails closed ---"
: > "$REC"
set +e
MISSING_OUT="$(DOUBLE_REC="$REC" CLAUDE_BIN="$DOUBLE" \
  bash "$SUT" spawn --provider anthropic --settings "$TMP/nope-not-here.json" -- -p "hello" 2>&1)"
MISSING_RC=$?
set -e
[ "$MISSING_RC" -ne 0 ] && ok "a missing overlay refuses to spawn (non-zero exit)" || bad "t6.rc" "got $MISSING_RC"
[ ! -s "$REC" ] && ok "the claude child was never invoked without its containment overlay" \
  || bad "t6.spawn" "the double ran anyway: $(cat "$REC")"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "candidate-session.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
