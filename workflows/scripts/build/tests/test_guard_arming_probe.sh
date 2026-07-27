#!/usr/bin/env bash
#
# Tests for worktree.sh's write-jail ARMING self-test (foundation#1352).
#
# `create` drops the `.build-guard` marker — but a marker only arms a hook that
# is actually REACHED. Every real failure of this jail has been a reachability
# failure that exits 0 silently: an unregistered repo, a matcher that never
# selects Bash (the F#932 gap), a stale/inert hook body, a missing `jq`. These
# tests pin the probe that turns each of those into one per-run signal.
#
# Covers:
#   - ARMED: the REAL hook, registered with a Bash-covering matcher, denies
#     both synthetic payloads (this is also the stale-hook-body regression net)
#   - the payload piped at the hook is deny-shaped and is the verbatim F#932
#     command, with the worktree as cwd (Bash arm) + an out-of-jail Write
#   - UNARMED: no registration at all
#   - UNARMED: registered, but the matcher omits Bash (the F#932 shape) — and
#     the REGISTRATION side is asserted independently of hook behavior, since a
#     correct hook can still be unwired
#   - UNARMED: registered and reached, but the hook silently exits 0 (the
#     stale-body / missing-jq shape) — behavior is asserted, not assumed
#   - a consuming repo's own .claude/settings.json is a scanned surface (#72)
#   - LOUD: every non-ARMED verdict prints a banner on stderr
#   - FAIL-OPEN: every verdict, including a HANGING hook, still yields
#     outcome=CREATED and exit 0 — the probe can never block a build
#
# Fixture note: every case pins HOME (and therefore ~/.claude/settings.json) at
# a throwaway dir, so the verdict is a pure function of the fixture and never of
# the developer's or CI runner's real hook registration.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/worktree.sh"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
REAL_HOOK="$REPO_ROOT/claude/hooks/build-worktree-guard.sh"
[ -f "$REAL_HOOK" ] || { echo "FAIL: hook not found at $REAL_HOOK" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init
git clone -q "$TMP/upstream" "$TMP/repo"
REPO="$(cd "$TMP/repo" && pwd -P)"

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude"

# register <matcher> <command> — write the fixture's user-global settings.json.
register() {
  jq -cn --arg m "$1" --arg c "$2" \
    '{hooks:{PreToolUse:[{matcher:$m, hooks:[{type:"command", command:$c}]}]}}' \
    > "$FAKE_HOME/.claude/settings.json"
}

# stub_hook <path> <body…> — a fake build-worktree-guard.sh. The BASENAME is
# what the probe matches on, so a stub stands in for the real hook exactly.
stub_hook() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$path"
  chmod +x "$path"
}

# create <slug> — run create under the fixture HOME; stdout → $OUT, stderr →
# $ERR, exit code → $RC. Never lets a non-zero exit abort the test run, so the
# fail-open property is asserted rather than assumed.
OUT=""; ERR=""; RC=0
create() {
  ERR="$TMP/stderr.$1.txt"
  RC=0
  OUT="$(HOME="$FAKE_HOME" bash "$SCRIPT" create "$REPO" "$1" 2>"$ERR")" || RC=$?
}

guard_of()  { jq -r '.guard'        <<<"$OUT"; }
detail_of() { jq -r '.guard_detail' <<<"$OUT"; }

# assert_fail_open — every case must still produce a usable worktree.
assert_fail_open() {
  [ "$RC" -eq 0 ] || fail "$1: probe blocked create (exit $RC)"
  [ "$(jq -r .outcome <<<"$OUT")" = "CREATED" ] || fail "$1: outcome not CREATED ($OUT)"
  [ -d "$REPO.wt/$2" ] || fail "$1: worktree not created"
  [ -f "$REPO.wt/$2/.build-guard" ] || fail "$1: marker not dropped"
}

# --- ARMED: the REAL hook, correctly registered --------------------------------
# End-to-end: settings.json → the actual shipped hook body → a deny verdict.
# A stale or broken hook body fails HERE, which is the whole point.
register 'Bash|Edit|Write|MultiEdit' "bash $REAL_HOOK"
create armed
assert_fail_open "armed" armed
[ "$(guard_of)" = "ARMED" ] || fail "real hook + Bash matcher should be ARMED (got: $OUT)"
detail="$(detail_of)"
grep -q 'registration=ok' <<<"$detail" || fail "armed: registration not ok ($detail)"
grep -q 'bash_arm=deny'   <<<"$detail" || fail "armed: Bash arm did not deny ($detail)"
grep -q 'write_arm=deny'  <<<"$detail" || fail "armed: Write arm did not deny ($detail)"
grep -q 'build-worktree-guard: ARMED' "$ERR" || fail "armed verdict not surfaced on stderr"
echo "PASS: real hook registered with a Bash-covering matcher probes ARMED"

# --- the payload piped at the resolved hook is deny-shaped and F#932-shaped ----
CAP="$TMP/captured-payloads.jsonl"
stub_hook "$TMP/capture/build-worktree-guard.sh" \
  "cat >> \"$CAP\"" \
  'printf "\n" >> '"\"$CAP\"" \
  'printf %s "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\"}}"'
register 'Bash|Edit|Write|MultiEdit' "$TMP/capture/build-worktree-guard.sh"
create payload
assert_fail_open "payload" payload
[ "$(guard_of)" = "ARMED" ] || fail "denying stub should be ARMED (got: $OUT)"
[ "$(grep -c . "$CAP")" -eq 2 ] || fail "expected 2 probe payloads, got $(grep -c . "$CAP")"
bash_line="$(grep '"Bash"' "$CAP")"
[ -n "$bash_line" ] || fail "no Bash payload piped at the hook"
# shellcheck disable=SC2016  # the $(…) is the literal F#932 incident text, not an expansion
[ "$(jq -r .tool_input.command <<<"$bash_line")" = 'rm -rf "$(dirname "$(pwd)")"' ] \
  || fail "Bash probe is not the verbatim F#932 command ($bash_line)"
[ "$(jq -r .cwd <<<"$bash_line")" = "$(cd "$REPO.wt/payload" && pwd -P)" ] \
  || fail "Bash probe cwd is not the worktree ($bash_line)"
write_line="$(grep '"Write"' "$CAP")"
[ -n "$write_line" ] || fail "no Write payload piped at the hook"
case "$(jq -r .tool_input.file_path <<<"$write_line")" in
  "$REPO.wt/payload"/*) fail "Write probe target is INSIDE the jail — it could never deny" ;;
  /*) ;;
  *) fail "Write probe target is not an absolute path ($write_line)" ;;
esac
echo "PASS: a deny-shaped Bash (verbatim F#932) + out-of-jail Write payload reach the resolved hook"

# --- UNARMED: nothing registered ----------------------------------------------
echo '{}' > "$FAKE_HOME/.claude/settings.json"
create unreg
assert_fail_open "unreg" unreg
[ "$(guard_of)" = "UNARMED" ] || fail "no registration should be UNARMED (got: $OUT)"
grep -q 'registration=missing' <<<"$(detail_of)" || fail "unreg: detail ($(detail_of))"
grep -q 'WRITE-JAIL UNARMED' "$ERR" || fail "unreg: no LOUD banner on stderr"
echo "PASS: an unregistered hook probes UNARMED, loudly, without blocking create"

# --- UNARMED: registered, but the matcher omits Bash (the F#932 shape) ---------
# The hook BODY here is the real, correct one — only the wiring is stale. This
# is the registration half of the probe: behavior alone would have passed.
register 'Edit|Write|MultiEdit' "bash $REAL_HOOK"
create stalematcher
assert_fail_open "stalematcher" stalematcher
[ "$(guard_of)" = "UNARMED" ] || fail "Edit-only matcher should be UNARMED (got: $OUT)"
grep -q 'registration=matcher-lacks-bash' <<<"$(detail_of)" \
  || fail "stalematcher: detail should name the matcher gap ($(detail_of))"
grep -q 'WRITE-JAIL UNARMED' "$ERR" || fail "stalematcher: no LOUD banner on stderr"
grep -q 'matcher includes Bash' "$ERR" || fail "stalematcher: banner does not name the remedy"
echo "PASS: a correct hook behind an Edit|Write|MultiEdit matcher probes UNARMED (the F#932 gap)"

# --- UNARMED: registered and reached, but the hook silently passes -------------
# The stale-body / missing-jq / wrong-file shape: exits 0, emits nothing. This
# is the behavior half — registration alone would have passed.
stub_hook "$TMP/inert/build-worktree-guard.sh" 'exit 0'
register 'Bash|Edit|Write|MultiEdit' "$TMP/inert/build-worktree-guard.sh"
create inert
assert_fail_open "inert" inert
[ "$(guard_of)" = "UNARMED" ] || fail "silently-passing hook should be UNARMED (got: $OUT)"
detail="$(detail_of)"
grep -q 'registration=ok' <<<"$detail" || fail "inert: registration should read ok ($detail)"
grep -q 'bash_arm=allow'  <<<"$detail" || fail "inert: Bash arm should read allow ($detail)"
grep -q 'WRITE-JAIL UNARMED' "$ERR" || fail "inert: no LOUD banner on stderr"
echo "PASS: a registered-but-silently-passing hook probes UNARMED (registration alone is not proof)"

# --- UNARMED: the registered hook FILE is absent / not executable --------------
# Two more of the named silent-failure modes. Both are registration-shaped
# (nothing to probe), so they must be reported before any behavior verdict.
register 'Bash|Edit|Write|MultiEdit' "bash $TMP/nowhere/build-worktree-guard.sh"
create nohookfile
assert_fail_open "nohookfile" nohookfile
[ "$(guard_of)" = "UNARMED" ] || fail "a missing hook file should be UNARMED (got: $OUT)"
grep -q 'registration=hook-file-missing' <<<"$(detail_of)" || fail "nohookfile: detail ($(detail_of))"

stub_hook "$TMP/noexec/build-worktree-guard.sh" 'exit 0'
chmod 644 "$TMP/noexec/build-worktree-guard.sh"
register 'Bash|Edit|Write|MultiEdit' "$TMP/noexec/build-worktree-guard.sh"
create noexec
assert_fail_open "noexec" noexec
[ "$(guard_of)" = "UNARMED" ] || fail "a non-executable bare-path hook should be UNARMED (got: $OUT)"
grep -q 'registration=hook-not-executable' <<<"$(detail_of)" || fail "noexec: detail ($(detail_of))"
echo "PASS: a missing or non-executable registered hook file probes UNARMED"

# --- a consuming repo's project-level settings.json is a scanned surface (#72) --
# TRACKED, so the worktree checkout carries it too — the registration is then
# unambiguously loaded wherever the worker resolves project settings from.
echo '{}' > "$FAKE_HOME/.claude/settings.json"
mkdir -p "$TMP/upstream/.claude"
jq -cn --arg c "bash $REAL_HOOK" \
  '{hooks:{PreToolUse:[{matcher:"Bash|Edit|Write|MultiEdit", hooks:[{type:"command", command:$c}]}]}}' \
  > "$TMP/upstream/.claude/settings.json"
git -C "$TMP/upstream" add .claude/settings.json
git -C "$TMP/upstream" commit -q -m "track project hook registration"
create repolevel
assert_fail_open "repolevel" repolevel
[ -f "$REPO.wt/repolevel/.claude/settings.json" ] || fail "fixture: worktree did not receive the tracked settings"
[ "$(guard_of)" = "ARMED" ] || fail "tracked project-level registration should be ARMED (got: $OUT)"
grep -q "$REPO.wt/repolevel/.claude/settings.json" <<<"$(detail_of)" \
  || fail "repolevel: detail should name the worktree-level source ($(detail_of))"
echo "PASS: a consuming repo's tracked project-level settings.json arms the probe"

# --- UNKNOWN: a registration that exists ONLY in the parent checkout ------------
# .claude/settings.local.json is gitignored, so it is present in the parent and
# ABSENT from a fresh worktree. The hook body is fine and DENIES — but the probe
# cannot prove a worker here loads that registration, and a false ARMED is worse
# than an honest UNKNOWN. This is the case that must never read ARMED.
git -C "$TMP/upstream" rm -q -r --cached .claude >/dev/null
rm -rf "$TMP/upstream/.claude"
git -C "$TMP/upstream" commit -q -m "untrack project hook registration"
mkdir -p "$REPO/.claude"
jq -cn --arg c "bash $REAL_HOOK" \
  '{hooks:{PreToolUse:[{matcher:"Bash|Edit|Write|MultiEdit", hooks:[{type:"command", command:$c}]}]}}' \
  > "$REPO/.claude/settings.local.json"
create parentonly
assert_fail_open "parentonly" parentonly
[ ! -e "$REPO.wt/parentonly/.claude/settings.local.json" ] || fail "fixture: worktree should not carry the parent-only file"
[ "$(guard_of)" != "ARMED" ] || fail "a parent-only registration must NEVER read ARMED (got: $OUT)"
[ "$(guard_of)" = "UNKNOWN" ] || fail "a parent-only registration should be UNKNOWN (got: $OUT)"
detail="$(detail_of)"
grep -q 'registration=parent-only' <<<"$detail" || fail "parentonly: detail ($detail)"
grep -q 'bash_arm=deny' <<<"$detail" || fail "parentonly: the hook itself should still have denied ($detail)"
grep -q 'TRACK' "$ERR" || fail "parentonly: banner does not name the remedy"
rm -rf "$REPO/.claude"
echo "PASS: a parent-checkout-only registration reports UNKNOWN, never a false ARMED"

# --- FAIL-OPEN under a HANGING hook, with stdout CAPTURED ----------------------
# The worst case for a check that runs on every create. Note the capture: the
# orchestrator reads the CREATED line via $(...), and worktree.sh holds its real
# stdout on fd 3 — a hung hook inheriting fd 3 would hold that capture pipe open
# and wedge create for the hook's full duration regardless of any tick budget.
# So this asserts WALL CLOCK, not merely that the case terminates.
# shellcheck disable=SC2016  # these are the stub's OWN source lines, expanded when it runs
stub_hook "$TMP/hang/build-worktree-guard.sh" \
  'payload="$(cat)"' \
  'case "$payload" in *\"Bash\"*) sleep 120 ;; esac' \
  'printf %s "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}"'
register 'Bash|Edit|Write|MultiEdit' "$TMP/hang/build-worktree-guard.sh"
started="$(date +%s)"
create hang
elapsed=$(( $(date +%s) - started ))
assert_fail_open "hang" hang
[ "$elapsed" -lt 60 ] || fail "a hanging hook wedged create for ${elapsed}s — the probe is not bounded"
[ "$(guard_of)" = "UNKNOWN" ] || fail "a hanging hook should be UNKNOWN, not a false ARMED (got: $OUT)"
grep -q 'bash_arm=timeout' <<<"$(detail_of)" || fail "hang: detail ($(detail_of))"
grep -q 'WRITE-JAIL UNKNOWN' "$ERR" || fail "hang: no LOUD banner on stderr"
echo "PASS: a hanging hook is abandoned in ${elapsed}s and reported UNKNOWN — create still succeeds"

echo "ALL PASS: worktree.sh guard-arming self-test"
