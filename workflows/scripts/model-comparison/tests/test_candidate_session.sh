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
# ── WHY PART 2 LOOKS THE WAY IT DOES (temperloop#1252 review, BLOCKING 1/2) ──
# The first version of this suite asserted key isolation by checking that the
# ONE intended key reached the child. That assertion could not fail: deleting
# candidate-session.sh's entire key-passing mechanism left all 37 assertions
# green, because the key reached the child ANYWAY — inherited, along with every
# OTHER provider key the config ladder exports. The suite was measuring the
# leak as if it were the fix.
#
# So the double now dumps the child's ACTUAL environment (variable NAMES only,
# never a value) and the fixture's config ladder exports FIVE secrets, not one:
# two foreign provider keys, a non-provider host secret, and a plain canary.
# The load-bearing assertions are the ABSENCE ones. Removing the `env -i`
# construction from candidate-session.sh turns them red immediately, which is
# the property the previous suite lacked.
#
# Covers (mapped to the item's acceptance bullets, then the review findings):
#   Part 1 (bullet 1) — the settings overlay's EFFECTIVE tool surface, via
#     candidate-session.sh's own real deny-over-allow glob resolver, not a
#     grep for JSON key presence. Includes the BLOCKING-5 regression set: the
#     bare-filename and any-directory forms of every denied path, which the
#     original `**/`-anchored patterns silently resolved ALLOW under the real
#     `case`-glob matcher (no globstar in shell `case`).
#   Part 2 (bullet 2) — key isolation, asserted against the child's dumped
#     environment: the selected provider's key is PRESENT and every other
#     registered provider key, the non-provider host secret, and the canary
#     are ABSENT. Plus: absent from the PARENT before and after, and from
#     everything candidate-session.sh itself emits.
#   Part 3 (bullet 3) — a non-default provider with an UNSET key fails at
#     pre-flight, verbatim, naming the exact env var and the concrete
#     host-supply file — and never spawns a child.
#   Part 4 (bullet 4) — the default path requires no key and spawns
#     unaffected, and is contained by the same construction (no foreign
#     provider key reaches an Anthropic candidate session either).
#   Part 5 — an unknown provider name is a distinct, named, non-zero failure.
#   Part 6 — the overlay fails CLOSED: absent / unreadable / malformed each
#     give a distinct non-zero exit and a legible message, never
#     `unspecified` at 0 (review BLOCKING 6).
#   Part 7 — the empty-passthrough path runs on stock macOS bash 3.2, where an
#     empty array expansion under `set -u` is an unbound-variable ABORT
#     (review BLOCKING 3).
#   Part 8 — every operand-taking flag, given as the FINAL argument, exits
#     non-zero instead of spinning forever on a failed `shift 2` (review
#     BLOCKING 4). Bounded by the repo's portable-timeout shim, so a
#     regression shows up as a failed assertion, not a hung CI job.
#   Part 9 — a permission-overriding passthrough argument is REFUSED rather
#     than forwarded, and the env-passthrough escape hatch cannot be used to
#     re-open the cross-provider leak (review advisory).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../candidate-session.sh"

# The repo's bounded-subprocess shim (temperloop#256) — stock macOS ships no
# GNU `timeout`, so Part 8's hang guard must not assume one.
# shellcheck source=../../lib/portable-timeout.sh
. "$HERE/../../lib/portable-timeout.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; fail=$((fail+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/candidate-session-test-XXXXXX")"
# chmod before rm so a failed run can never leave a mode-000 fixture behind
# (Part 6 deliberately creates one).
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# SYNTHETIC secrets, generated here and never persisted to the repo. Long
# enough that a substring search in the leak-check is meaningful.
_stamp="$(date +%s)-$$"
FAKE_OPENAI="sk-test-openai-$_stamp-000000000000000000"
FAKE_GEMINI="sk-test-gemini-$_stamp-000000000000000000"
FAKE_ANTHROPIC="sk-test-anthropic-$_stamp-000000000000000000"
FAKE_SENTRY="sntrys-test-$_stamp-000000000000000000"
FAKE_CANARY="canary-$_stamp"

# ── The CLAUDE_BIN double ────────────────────────────────────────────────────
# Dumps the NAMES of every environment variable it was invoked with (never a
# value — not even in the fixture's own bookkeeping), the intended key's
# LENGTH, and its argv. Name-level detail is exactly enough to discriminate
# "the intended key reached the child" from "every key reached the child",
# which is the distinction the previous suite could not make.
DOUBLE="$TMP/claude-double.sh"
REC="$TMP/double.rec"
cat > "$DOUBLE" <<DOUBLE_EOF
#!/usr/bin/env bash
rec="$REC"
: > "\$rec"
env | sed -e 's/=.*//' -e 's/^/ENV /' | sort >> "\$rec"
printf 'OPENAI_LEN=%s\n' "\${#OPENAI_API_KEY}" >> "\$rec"
printf 'ARGV=%s\n' "\$*" >> "\$rec"
printf '{"type":"result","is_error":false,"result":"ok"}\n'
DOUBLE_EOF
chmod +x "$DOUBLE"

# Unpiped `grep -q` against a file — the form scripts/lint-pipe-grep-q.sh
# explicitly sanctions (there is no upstream writer to SIGPIPE).
child_env_has() { grep -qxF "ENV $1" "$REC"; }

assert_child_has() {  # $1 var, $2 label
  if child_env_has "$1"; then ok "$2"; else bad "$2" "child env did NOT carry $1"; fi
}
assert_child_lacks() {  # $1 var, $2 label
  if child_env_has "$1"; then
    bad "$2" "child env LEAKED $1 — the child inherited an environment instead of being handed one"
  else
    ok "$2"
  fi
}

# ── A fake checkout carrying the config ladder ───────────────────────────────
# Mirrors test_pipeline_retro_judge_spawn.sh's fixture shape: a build/ dir with
# build.config.sh, and the gitignored build.config.local.sh that exports the
# synthetic secrets using its documented `:=`-then-`export` idiom. Copying (not
# symlinking) candidate-session.sh is what makes its own $HERE resolve INTO
# this fixture, so it sources the FIXTURE's ladder, not the real repo's.
#
# FIVE exports, not one, and that is the point: two FOREIGN provider keys, a
# non-provider host secret, and a plain canary all land in candidate-session.sh's
# own process exactly as the real ladder's idiom would. Part 2 then asserts
# none of them reaches the child.
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
: "\${OPENAI_API_KEY:=$FAKE_OPENAI}"
: "\${GEMINI_API_KEY:=$FAKE_GEMINI}"
: "\${ANTHROPIC_API_KEY:=$FAKE_ANTHROPIC}"
: "\${SENTRY_AUTH_TOKEN:=$FAKE_SENTRY}"
: "\${CANDIDATE_LEAK_CANARY:=$FAKE_CANARY}"
export OPENAI_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY SENTRY_AUTH_TOKEN CANDIDATE_LEAK_CANARY
LOCAL
chmod 600 "$CO/build/build.config.local.sh"

# Every fixture invocation starts from a host that carries none of the five, so
# the ladder — not this test process — is what puts them into the script's
# environment.
CLEAN_ENV=(env -u OPENAI_API_KEY -u GEMINI_API_KEY -u ANTHROPIC_API_KEY \
               -u SENTRY_AUTH_TOKEN -u CANDIDATE_LEAK_CANARY)

run_fixture() {  # args pass through to the fixture copy of the SUT
  "${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" bash "$FIXTURE_SUT" "$@"
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

# ── BLOCKING-5 regression set ────────────────────────────────────────────────
# The matcher is shell `case`, which has NO globstar: a `**/`-anchored pattern
# collapses to `*/` and therefore requires a literal `/` in the subject. Under
# the original patterns EVERY assertion below measured ALLOW — the deny list
# did not deny the two credential files it exists for, in their most obvious
# form. Each of these fails again the moment a `**/`-anchored pattern comes back.
assert_resolve "Read(.env)" "deny" "BLOCKING-5: a BARE .env (no directory) is denied"
assert_resolve "Read(build.config.local.sh)" "deny" "BLOCKING-5: a BARE build.config.local.sh is denied"
assert_resolve "Read(./.env)" "deny" "BLOCKING-5: a ./-relative .env is denied"
assert_resolve "Read(./build.config.local.sh)" "deny" "BLOCKING-5: a ./-relative build.config.local.sh is denied"
assert_resolve "Read(some/dir/.env)" "deny" "BLOCKING-5: a nested .env is denied"
assert_resolve "Read(/Users/x/repo/.env)" "deny" "BLOCKING-5: an ABSOLUTE .env path is denied"
assert_resolve "Read(/Users/x/repo/workflows/scripts/build/build.config.local.sh)" "deny" \
  "BLOCKING-5: an ABSOLUTE secrets-file path is denied"
assert_resolve "Read(.env.local)" "deny" "BLOCKING-5: a bare .env.local is denied"
assert_resolve "Edit(.env)" "deny" "BLOCKING-5: Edit of a bare .env is denied"
assert_resolve "Write(.env)" "deny" "BLOCKING-5: Write of a bare .env is denied (the allow list carries Write)"
assert_resolve "Write(build.config.local.sh)" "deny" "BLOCKING-5: Write of a bare secrets file is denied"
assert_resolve "Grep(build.config.local.sh)" "deny" "BLOCKING-5: Grep at the secrets file is denied (Grep can print contents)"
assert_resolve "Read(build.config.machine.sh)" "deny" "BLOCKING-5: the machine.sh sibling is denied as a Read target, not only via Bash"
assert_resolve "Bash(cat .env)" "deny" "BLOCKING-5: Bash indirection at a bare .env is denied"

# The narrowing must not be accidental over-broad denial of the whole tool —
# ordinary Bash/Read/Edit calls that don't touch the secrets file or vault
# MCP surface stay reachable, proving this is a scoped deny, not "nothing
# works" (which would trivially and uselessly satisfy bullet 1).
assert_resolve "Read(docs/README.md)" "allow" "an ordinary Read call is still reachable"
assert_resolve "Bash(git status)" "allow" "an ordinary Bash call is still reachable"
assert_resolve "Task" "allow" "the Task tool is reachable"
assert_resolve "Write(some/scratch/file.txt)" "allow" "an ordinary Write call is still reachable"
assert_resolve "Grep(src/main.ts)" "allow" "an ordinary Grep call is still reachable"
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

# Per-rule mutation control: drop ONE deny entry and the corresponding
# assertion must flip. This is the "remove a rule, watch it go red" property
# the review asked for, run as a permanent assertion rather than a one-off.
DROP_ENV_DENY="$TMP/drop-env-deny.settings.json"
jq '.permissions.deny |= map(select(test("\\.env") | not))' \
  "$HERE/../candidate.settings.json" > "$DROP_ENV_DENY"
got_drop="$(bash "$SUT" resolve "Read(.env)" --settings "$DROP_ENV_DENY")"
[ "$got_drop" = "allow" ] \
  && ok "mutation control: with the .env deny rules removed, Read(.env) flips deny -> allow — the deny verdict comes from those rules and nothing else" \
  || bad "control.drop-env-deny" "got '$got_drop', expected 'allow' with the .env deny rules removed"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 2 (bullet 2) — key isolation: the child is HANDED an environment,   │
# │ never inherits one                                                       │
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

[ "$SPAWN_RC" -eq 0 ] && ok "spawn exits 0" || bad "t2.rc" "got $SPAWN_RC ($(cat "$TMP/spawn.err"))"

# Sanity: the fixture ladder really did export all five into candidate-session.sh's
# own process. Without this, every ABSENCE assertion below could pass vacuously
# because the secret was never there to leak in the first place.
# shellcheck disable=SC2016  # the single-quoted script body is bash -c's, not ours
LADDER_PROBE="$("${CLEAN_ENV[@]}" bash -c '. "$1" >/dev/null 2>&1; env | sed "s/=.*//" | sort' _ "$CO/build/build.config.sh")"
LADDER_MISSING=""
for v in OPENAI_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY SENTRY_AUTH_TOKEN CANDIDATE_LEAK_CANARY; do
  printf '%s\n' "$LADDER_PROBE" | grep -xF "$v" >/dev/null || LADDER_MISSING="$LADDER_MISSING $v"
done
[ -z "$LADDER_MISSING" ] \
  && ok "precondition: the fixture config ladder exports all five secrets into the sourcing process (so the absence assertions below are not vacuous)" \
  || bad "t2.ladder-precondition" "ladder did not export:$LADDER_MISSING"

# The intended key reaches the child…
assert_child_has OPENAI_API_KEY "the SELECTED provider's key REACHES the spawned claude child process"
[ "$(sed -n 's/^OPENAI_LEN=//p' "$REC")" = "${#FAKE_OPENAI}" ] \
  && ok "it arrives intact (length matches; value never asserted on directly)" \
  || bad "t2.len" "$(grep '^OPENAI_LEN=' "$REC")"

# …and NOTHING ELSE the config ladder exported does. These are the load-bearing
# assertions: `env VAR=value cmd` ADDS to the inherited environment, so under the
# pre-fix construction every one of these was PRESENT in the child.
assert_child_lacks GEMINI_API_KEY "the OTHER registered provider key (Gemini) is ABSENT from the child"
assert_child_lacks ANTHROPIC_API_KEY "the DEFAULT provider's key is ABSENT from an OpenAI candidate session"
assert_child_lacks SENTRY_AUTH_TOKEN "a NON-provider host secret the same ladder exports is ABSENT from the child"
assert_child_lacks CANDIDATE_LEAK_CANARY "an arbitrary ladder-exported variable is ABSENT — the child env is constructed, not inherited"
assert_child_lacks CANDIDATE_SETTINGS "candidate-session.sh's own config vars do not reach the child either"

# …while the child still gets what it legitimately needs to run at all.
assert_child_has PATH "the child still receives PATH (the allowlist is a narrowing, not a lobotomy)"
assert_child_has HOME "the child still receives HOME"

# The load-bearing parent assertion: after the subprocess returns, THIS test
# script's own (parent) environment still carries no key — the ladder's exports
# lived only inside the candidate-session.sh subprocess, which cannot write back
# into its parent.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  bad "t2.parent-leak" "OPENAI_API_KEY leaked into the PARENT process after spawn returned"
else
  ok "the key is ABSENT from the parent process after the subprocess returns"
fi

# "Absent from every emitted record": candidate-session.sh's own stdout and
# stderr from this invocation carry no occurrence of any key value.
if printf '%s' "$SPAWN_OUT" | grep -F "$FAKE_OPENAI" >/dev/null; then
  bad "t2.stdout-leak" "the key value appeared in candidate-session.sh's own stdout"
else
  ok "the key value never appears in candidate-session.sh's own stdout"
fi
if grep -qF "$FAKE_OPENAI" "$TMP/spawn.err" 2>/dev/null; then
  bad "t2.stderr-leak" "the key value appeared in candidate-session.sh's own stderr"
else
  ok "the key value never appears in candidate-session.sh's own stderr"
fi

# The overlay is actually handed to the child, and is the FIRST thing on its
# argv — a passthrough arg can no longer precede or replace it (Part 9).
# Globbed on the middle path segment: macOS resolves $TMPDIR's /var symlink to
# /private/var inside the script's own `cd -P`, so the literal $FIXTURE_SETTINGS
# string is not what the child sees.
CHILD_ARGV="$(sed -n 's/^ARGV=//p' "$REC")"
case "$CHILD_ARGV" in
  "--settings "*"/model-comparison/candidate.settings.json -p hello")
    ok "the child is invoked with the containment overlay FIRST, then the caller's passthrough args" ;;
  *) bad "t2.argv" "ARGV=$CHILD_ARGV" ;;
esac

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
PREFLIGHT_ERR="$("${CLEAN_ENV[@]}" bash "$NO_KEY_SUT" preflight --provider openai 2>&1)"
PREFLIGHT_RC=$?
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
SPAWN_UNSET_OUT="$("${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" \
  bash "$NO_KEY_SUT" spawn --provider openai -- -p "hello" 2>"$TMP/spawn-unset.err")"
SPAWN_UNSET_RC=$?
[ "$SPAWN_UNSET_RC" -ne 0 ] && ok "spawn refuses (non-zero exit) rather than running uncontained" || bad "t3.spawn.rc" "got $SPAWN_UNSET_RC"
[ -z "$SPAWN_UNSET_OUT" ] && ok "the refusal emits nothing on stdout" || bad "t3.spawn.stdout" "$SPAWN_UNSET_OUT"
[ ! -s "$REC" ] && ok "the claude child process was NEVER invoked (fail-closed, not a silent no-op)" \
  || bad "t3.spawn.noop" "the double ran anyway: $(cat "$REC")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 4 (bullet 4) — the default path is unaffected, and equally contained│
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 4: default path unaffected ---"

DEFAULT_OUT="$("${CLEAN_ENV[@]}" bash "$SUT" preflight --provider anthropic 2>&1)"
DEFAULT_RC=$?
[ "$DEFAULT_RC" -eq 0 ] && ok "preflight for the default provider exits 0 with no key present" || bad "t4.rc" "got $DEFAULT_RC"
[ -z "$DEFAULT_OUT" ] && ok "preflight for the default provider is silent (no message, nothing to gate on)" \
  || bad "t4.silent" "$DEFAULT_OUT"

DEFAULT_NOPROVIDER_RC=0
"${CLEAN_ENV[@]}" bash "$SUT" preflight >/dev/null 2>&1 || DEFAULT_NOPROVIDER_RC=$?
[ "$DEFAULT_NOPROVIDER_RC" -eq 0 ] && ok "preflight with NO --provider at all also exits 0 (bare 'nothing selected' case)" \
  || bad "t4.no-provider" "got $DEFAULT_NOPROVIDER_RC"

# Run the default-provider spawn against the FIXTURE (not the real repo), so
# the assertion is hermetic and can measure containment: the fixture host has
# an OpenAI and a Gemini key exported, and an Anthropic candidate session must
# receive neither.
: > "$REC"
DEFAULT_SPAWN_OUT="$(run_fixture spawn --provider anthropic -- -p "hello" 2>&1)"
DEFAULT_SPAWN_RC=$?
[ "$DEFAULT_SPAWN_RC" -eq 0 ] && ok "the default-provider spawn succeeds unaffected" || bad "t4.spawn.rc" "got $DEFAULT_SPAWN_RC ($DEFAULT_SPAWN_OUT)"
assert_child_lacks OPENAI_API_KEY "the default-provider spawn carries NO OpenAI key (the reverse-direction leak is closed too)"
assert_child_lacks GEMINI_API_KEY "the default-provider spawn carries no Gemini key either"
assert_child_lacks SENTRY_AUTH_TOKEN "the default-provider spawn carries no non-provider host secret"
assert_child_has ANTHROPIC_API_KEY "the default provider's OWN key is the one thing forwarded, when the host has it set"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 5 — an unknown provider is a named failure, never a silent no-op    │
# ╰──────────────────────────────────────────────────────────────────────────╯
echo "--- Part 5: unknown provider name ---"
UNKNOWN_OUT="$(bash "$SUT" preflight --provider not-a-real-provider 2>&1)"
UNKNOWN_RC=$?
[ "$UNKNOWN_RC" -ne 0 ] && ok "an unregistered provider name fails (non-zero)" || bad "t5.rc" "got $UNKNOWN_RC"
printf '%s' "$UNKNOWN_OUT" | grep -F "not-a-real-provider" >/dev/null \
  && ok "the failure names the offending provider" || bad "t5.name" "$UNKNOWN_OUT"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 6 — the overlay fails CLOSED, with a DISTINCT exit per cause        │
# ╰──────────────────────────────────────────────────────────────────────────╯
# "I could not determine the restriction" must never be reported as "no
# restriction applies" at exit 0 (review BLOCKING 6). 3 = absent, 4 =
# unreadable, 5 = malformed — for BOTH `resolve` and `spawn`.
echo "--- Part 6: overlay fails closed (absent / unreadable / malformed) ---"

ABSENT="$TMP/nope-not-here.json"
UNREADABLE="$TMP/unreadable.settings.json"
MALFORMED="$TMP/malformed.settings.json"
NOPERMS="$TMP/no-permissions.settings.json"
cp "$HERE/../candidate.settings.json" "$UNREADABLE"
printf '{ this is not json\n' > "$MALFORMED"
printf '{"model":"x"}\n' > "$NOPERMS"

assert_resolve_fails() {  # $1 settings, $2 expected rc, $3 message needle, $4 label
  local out rc
  out="$(bash "$SUT" resolve "Read(docs/README.md)" --settings "$1" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$2" ]; then
    bad "$4" "expected exit $2, got $rc (output: $out)"
    return
  fi
  if printf '%s' "$out" | grep -F "$3" >/dev/null; then
    if printf '%s' "$out" | grep -xF "unspecified" >/dev/null; then
      bad "$4" "exited $rc but ALSO printed 'unspecified' — the fail-open verdict must not be emitted"
    else
      ok "$4"
    fi
  else
    bad "$4" "exit $rc was right but the message did not name '$3': $out"
  fi
}

assert_resolve_fails "$ABSENT" 3 "ABSENT" \
  "resolve on an ABSENT overlay exits 3 and says so (never 'unspecified' at 0)"
assert_resolve_fails "$MALFORMED" 5 "MALFORMED" \
  "resolve on a MALFORMED overlay exits 5 and says so"
assert_resolve_fails "$NOPERMS" 5 "MALFORMED" \
  "resolve on valid JSON with no .permissions object exits 5 (a settings file that restricts nothing is not a containment overlay)"

if [ "$(id -u)" -eq 0 ]; then
  ok "SKIP (running as root): an UNREADABLE overlay cannot be simulated — root reads mode-000 files"
else
  chmod 000 "$UNREADABLE"
  assert_resolve_fails "$UNREADABLE" 4 "UNREADABLE" \
    "resolve on an UNREADABLE overlay exits 4 and says so"
  chmod 644 "$UNREADABLE"
  [ -r "$UNREADABLE" ] && ok "the unreadable fixture's permissions were restored by the test itself" \
    || bad "t6.restore" "fixture left unreadable"
fi

# spawn fails closed on each cause too, and never invokes the child.
assert_spawn_fails_closed() {  # $1 settings, $2 expected rc, $3 label
  local out rc
  : > "$REC"
  out="$(run_fixture spawn --provider anthropic --settings "$1" -- -p "hello" 2>&1)"
  rc=$?
  if [ "$rc" -ne "$2" ]; then
    bad "$3" "expected exit $2, got $rc (output: $out)"
  elif [ -s "$REC" ]; then
    bad "$3" "the claude child ran anyway: $(cat "$REC")"
  else
    ok "$3"
  fi
}
assert_spawn_fails_closed "$ABSENT" 3 "a missing overlay refuses to spawn (exit 3) and the child is never invoked"
assert_spawn_fails_closed "$MALFORMED" 5 "a malformed overlay refuses to spawn (exit 5) and the child is never invoked"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$UNREADABLE"
  assert_spawn_fails_closed "$UNREADABLE" 4 "an unreadable overlay refuses to spawn (exit 4) and the child is never invoked"
  chmod 644 "$UNREADABLE"
fi

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 7 — the empty-passthrough path runs on stock macOS bash 3.2         │
# ╰──────────────────────────────────────────────────────────────────────────╯
# On bash 3.2 an EMPTY array expansion under `set -u` is an unbound-variable
# error, so `spawn` with no passthrough args aborted before it spawned
# anything (review BLOCKING 3). Asserted twice: through whatever bash runs
# this suite, and explicitly through /bin/bash, which on macOS IS 3.2.
echo "--- Part 7: empty passthrough under set -u (bash 3.2) ---"

: > "$REC"
NOARG_ERR="$TMP/noargs.err"
run_fixture spawn --provider openai >/dev/null 2>"$NOARG_ERR"
NOARG_RC=$?
[ "$NOARG_RC" -eq 0 ] && ok "spawn with NO passthrough args exits 0 (empty array expansion does not abort)" \
  || bad "t7.rc" "got $NOARG_RC: $(cat "$NOARG_ERR")"
grep -qF "unbound variable" "$NOARG_ERR" \
  && bad "t7.unbound" "$(cat "$NOARG_ERR")" \
  || ok "no 'unbound variable' abort on the empty-passthrough path"
[ -s "$REC" ] && ok "the child WAS invoked on the empty-passthrough path" || bad "t7.child" "the double never ran"

: > "$REC"
"${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" /bin/bash "$FIXTURE_SUT" spawn --provider openai \
  >/dev/null 2>"$TMP/noargs-bin-bash.err"
NOARG_BB_RC=$?
[ "$NOARG_BB_RC" -eq 0 ] && ok "same path under /bin/bash ($(/bin/bash -c 'echo $BASH_VERSION')) exits 0" \
  || bad "t7.bin-bash" "got $NOARG_BB_RC: $(cat "$TMP/noargs-bin-bash.err")"
[ -s "$REC" ] && ok "the child WAS invoked under /bin/bash too" || bad "t7.bin-bash.child" "the double never ran"

# The `--` form with an EMPTY tail is the other empty-array site.
: > "$REC"
run_fixture spawn --provider openai -- >/dev/null 2>"$TMP/emptytail.err"
EMPTYTAIL_RC=$?
[ "$EMPTYTAIL_RC" -eq 0 ] && ok "spawn with a bare trailing '--' (empty passthrough tail) exits 0" \
  || bad "t7.empty-tail" "got $EMPTYTAIL_RC: $(cat "$TMP/emptytail.err")"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 8 — a trailing operand-taking flag errors, never hangs              │
# ╰──────────────────────────────────────────────────────────────────────────╯
# `shift 2` with only one argument left FAILS; with no `set -e` the failure is
# ignored, `$#` never decreases, and the parse loop spins forever (review
# BLOCKING 4). Bounded by the repo's portable-timeout shim — a regression is a
# failed assertion, not a hung CI job. run_with_timeout normalizes a timeout
# kill to 137, so 137 is the specific "it hung again" signal.
echo "--- Part 8: trailing flag with no operand errors instead of hanging ---"

assert_no_hang() {  # $1 label, rest = argv for the fixture SUT
  local label="$1"; shift
  local rc=0
  run_with_timeout 15 "${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" \
    bash "$FIXTURE_SUT" "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 137 ]; then
    bad "$label" "HUNG (killed at the 15s bound) — the arg-parse loop is spinning on a failed shift"
  elif [ "$rc" -eq 0 ]; then
    bad "$label" "exited 0 — a flag with no value must be an error, not a silent default"
  else
    ok "$label (exit $rc)"
  fi
}

assert_no_hang "spawn --provider as the FINAL arg errors, does not hang"  spawn --provider
assert_no_hang "spawn --settings as the FINAL arg errors, does not hang"  spawn --settings
assert_no_hang "preflight --provider as the FINAL arg errors, does not hang" preflight --provider
assert_no_hang "resolve --settings as the FINAL arg errors, does not hang" resolve "Read(x)" --settings

# The old `${2:-anthropic}` default silently masked a missing operand as a
# VALID choice. A missing --provider value must be an error, not a fallback.
# Bounded like the assertions above, and for the same reason: an unbounded call
# here hangs the WHOLE suite (and CI) under exactly the regression it tests for
# — observed while mutation-testing this file, which is why no invocation of a
# trailing operand-taking flag in this suite is left unbounded.
MISSING_OPERAND_OUT="$(run_with_timeout 15 "${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" \
  bash "$FIXTURE_SUT" preflight --provider 2>&1)"
MISSING_OPERAND_RC=$?
[ "$MISSING_OPERAND_RC" -eq 2 ] \
  && ok "a missing --provider operand is a usage error (exit 2), NOT a silent fallback to the default provider" \
  || bad "t8.no-silent-default" "got $MISSING_OPERAND_RC: $MISSING_OPERAND_OUT"
printf '%s' "$MISSING_OPERAND_OUT" | grep -F -- "--provider requires a value" >/dev/null \
  && ok "the missing-operand message names the flag" || bad "t8.msg" "$MISSING_OPERAND_OUT"

# ╭──────────────────────────────────────────────────────────────────────────╮
# │ Part 9 — passthrough cannot defeat the containment overlay              │
# ╰──────────────────────────────────────────────────────────────────────────╯
# A caller's `-- <claude args…>` tail is forwarded verbatim, so a
# permission-affecting flag there would override the overlay this script
# installs. These flag names are DATA describing the hole; spawn REFUSES them.
echo "--- Part 9: permission-overriding passthrough args are refused ---"

assert_passthrough_refused() {  # $1.. = the passthrough tail
  local label="passthrough '$1' is refused (exit 2) and the child never runs"
  local out rc
  : > "$REC"
  out="$(run_fixture spawn --provider openai -- "$@" 2>&1)"
  rc=$?
  if [ "$rc" -ne 2 ]; then
    bad "$label" "expected exit 2, got $rc ($out)"
  elif [ -s "$REC" ]; then
    bad "$label" "the child ran anyway with the overriding flag: $(cat "$REC")"
  else
    ok "$label"
  fi
}

assert_passthrough_refused --settings /tmp/wide-open.json
assert_passthrough_refused --settings=/tmp/wide-open.json
assert_passthrough_refused --permission-mode acceptEdits
assert_passthrough_refused --dangerously-skip-permissions
assert_passthrough_refused --allowedTools "Read"
assert_passthrough_refused --allowed-tools "Read"
assert_passthrough_refused --disallowedTools "Read"
assert_passthrough_refused --permission-prompt-tool foo
assert_passthrough_refused --add-dir /etc
assert_passthrough_refused --mcp-config /tmp/mcp.json
assert_passthrough_refused --setting-sources user

# …while an ordinary passthrough arg is still forwarded (this must stay a
# narrow refusal, not "no passthrough works").
: > "$REC"
run_fixture spawn --provider openai -- -p "hello" --model sonnet >/dev/null 2>&1
BENIGN_RC=$?
[ "$BENIGN_RC" -eq 0 ] && ok "an ordinary passthrough tail is still forwarded untouched" || bad "t9.benign" "got $BENIGN_RC"
grep -qF -- "-p hello --model sonnet" "$REC" \
  && ok "the benign passthrough args reached the child verbatim" || bad "t9.benign.argv" "$(grep '^ARGV=' "$REC")"

# The env-passthrough escape hatch cannot re-open the cross-provider leak.
: > "$REC"
EXTRA_OUT="$("${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" CANDIDATE_ENV_PASSTHROUGH_EXTRA=GEMINI_API_KEY \
  bash "$FIXTURE_SUT" spawn --provider openai -- -p "hello" 2>&1)"
EXTRA_RC=$?
[ "$EXTRA_RC" -eq 2 ] && [ ! -s "$REC" ] \
  && ok "CANDIDATE_ENV_PASSTHROUGH_EXTRA naming a registered provider key var is REFUSED (exit 2), child never runs" \
  || bad "t9.extra-provider-key" "got $EXTRA_RC, rec=$(cat "$REC") ($EXTRA_OUT)"

# …but a legitimate extra var IS forwarded, so the hatch is real.
: > "$REC"
"${CLEAN_ENV[@]}" CLAUDE_BIN="$DOUBLE" MY_HOST_VAR=1 CANDIDATE_ENV_PASSTHROUGH_EXTRA=MY_HOST_VAR \
  bash "$FIXTURE_SUT" spawn --provider openai -- -p "hello" >/dev/null 2>&1
EXTRA_OK_RC=$?
[ "$EXTRA_OK_RC" -eq 0 ] && ok "a legitimate CANDIDATE_ENV_PASSTHROUGH_EXTRA var spawns normally" || bad "t9.extra-ok.rc" "got $EXTRA_OK_RC"
assert_child_has MY_HOST_VAR "a legitimate CANDIDATE_ENV_PASSTHROUGH_EXTRA var IS forwarded to the child"
assert_child_lacks GEMINI_API_KEY "…and forwarding it does not drag the rest of the environment along"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "candidate-session.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
