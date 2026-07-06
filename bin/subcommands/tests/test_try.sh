#!/usr/bin/env bash
#
# Tests for try.sh (foundation #765 Epic D, item foundation-try / #852).
# Zero network — a fake `gh` and a fake `claude` sit on PATH ahead of the
# real ones, mirroring the board/demo toolkits' test convention (e.g.
# workflows/scripts/demo/tests/test_seed_demo_repo.sh). This is the
# WRITE-INTERCEPTING WRAPPER the item's acceptance criterion asks for:
#   - the fake `gh` logs every call it sees (asserted to contain ONLY
#     read-shaped calls: `issue list`, `auth status` — never a mutation
#     verb like create/edit/close/comment, never `-X POST/PATCH/DELETE`)
#   - the fake `claude` logs every argv element it receives (asserted to
#     carry `--tools` immediately followed by an EMPTY string — the
#     structural zero-tool-access proof — plus `--no-session-persistence`)
#   - the fixture repo's file tree is diffed byte-for-byte before/after
#     every run (proves try.sh itself never writes to the target tree)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRY="$HERE/../try.sh"
TEST_REPO="test-owner/test-demo"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/try-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture git repo -------------------------------------------------------
REPO="$WORK/fixture-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo one > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: seed fixture"

# --- fake gh: logs every call; answers only read-shaped calls --------------
BIN="$WORK/bin"
mkdir -p "$BIN"
CALL_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  auth)
    case "$2" in
      status) exit "${FAKE_AUTH_RC:-0}" ;;
    esac
    exit 0
    ;;
  issue)
    case "$2" in
      list)
        printf '%s' "$FAKE_OPEN_ISSUES_JSON"
        exit 0
        ;;
    esac
    exit 0
    ;;
  api)
    # Answers the PROBE's own two network-gated sections (branch protection,
    # labels) so a T4-style live-gh happy-path run doesn't trip over an
    # unhandled `gh api` call — this fake is a stand-in for the probe's
    # dependency too, not just try.sh's own issue-list call.
    case "$2" in
      */branches/*/protection)
        echo "HTTP 404" >&2
        exit 1
        ;;
      */labels)
        printf '[]'
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

# --- fake claude: logs every argv element (one file per index), echoes a
# canned marker report ---------------------------------------------------
CLAUDE_ARGS_DIR="$WORK/claude-args"
cat > "$BIN/claude" <<'FAKE_CLAUDE_EOF'
#!/usr/bin/env bash
rm -rf "$CLAUDE_ARGS_DIR"
mkdir -p "$CLAUDE_ARGS_DIR"
i=0
for a in "$@"; do
  printf '%s' "$a" > "$CLAUDE_ARGS_DIR/arg_$i"
  i=$((i + 1))
done
echo "$i" > "$CLAUDE_ARGS_DIR/argc"
echo "FAKE-TRIAGE-REPORT-MARKER: ${FAKE_TRIAGE_OUTPUT:-shadow triage report}"
exit "${FAKE_CLAUDE_RC:-0}"
FAKE_CLAUDE_EOF
chmod +x "$BIN/claude"

export CALL_LOG CLAUDE_ARGS_DIR

# claude_arg N — prints the Nth (0-based) argv element the fake claude saw.
claude_arg() { cat "$CLAUDE_ARGS_DIR/arg_$1" 2>/dev/null || true; }
claude_argc() { cat "$CLAUDE_ARGS_DIR/argc" 2>/dev/null || echo 0; }

# claude_flag_value FLAG — 0-based scan of every logged claude arg for a
# literal match of FLAG; echoes the NEXT arg (its value), or nothing if the
# flag was never passed. Exits non-zero (via caller's fail) if not found.
claude_flag_value() {
  local flag="$1" n i
  n="$(claude_argc)"
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(claude_arg "$i")" = "$flag" ]; then
      claude_arg "$((i + 1))"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# run WANT_RC ARGS... — invoke try.sh with the fakes on PATH ahead of the
# real one; sets $out to combined stdout+stderr, asserts exit code.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  rm -rf "$CLAUDE_ARGS_DIR"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    FAKE_AUTH_RC="${FAKE_AUTH_RC:-0}" \
    FAKE_OPEN_ISSUES_JSON="${FAKE_OPEN_ISSUES_JSON:-[]}" \
    FAKE_TRIAGE_OUTPUT="${FAKE_TRIAGE_OUTPUT:-}" \
    FAKE_CLAUDE_RC="${FAKE_CLAUDE_RC:-0}" \
    CALL_LOG="$CALL_LOG" \
    CLAUDE_ARGS_DIR="$CLAUDE_ARGS_DIR" \
    bash "$TRY" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected exit $want for [$*], got $rc (out: $out)"
}

assert_contains() {
  case "$out" in
    *"$1"*) ;;
    *) fail "expected output to contain: $1 (got: $out)" ;;
  esac
}

assert_not_contains() {
  case "$out" in
    *"$1"*) fail "expected output to NOT contain: $1 (got: $out)" ;;
    *) ;;
  esac
}

assert_order() {
  # assert_order A B — A must appear in $out strictly before B.
  case "$out" in
    *"$1"*"$2"*) ;;
    *) fail "expected '$1' to appear before '$2' (got: $out)" ;;
  esac
}

gh_log_has_only_reads() {
  # Fail if any logged gh call looks like a mutation.
  if grep -Eq '(^| )(create|edit|close|comment|delete|-X[[:space:]]+(POST|PATCH|DELETE))( |$)' "$CALL_LOG" 2>/dev/null; then
    fail "gh call log contains a mutation-shaped call: $(cat "$CALL_LOG")"
  fi
}

# =============================================================================
# T1 -- --help / -h: usage, exit 0, zero gh/claude calls.
# =============================================================================
run 0 --help
assert_contains "usage: try.sh"
[ ! -s "$CALL_LOG" ] || fail "--help reached gh"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "--help reached claude"
echo "PASS: --help prints usage, exit 0, zero gh/claude calls"

run 0 -h
assert_contains "usage: try.sh"
[ ! -s "$CALL_LOG" ] || fail "-h reached gh"
echo "PASS: -h prints usage, exit 0, zero gh/claude calls"

# =============================================================================
# T2 -- unknown flag: exit 2, zero gh/claude calls.
# =============================================================================
run 2 --bogus-flag
[ ! -s "$CALL_LOG" ] || fail "unknown flag reached gh"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "unknown flag reached claude"
echo "PASS: unknown flag exits 2, zero gh/claude calls"

# =============================================================================
# T3 -- non-git --dir: propagates the probe's exit 1, zero gh/claude calls.
# =============================================================================
NOTGIT="$WORK/not-a-repo"
mkdir -p "$NOTGIT"
run 1 --dir "$NOTGIT" --gh-repo "$TEST_REPO"
[ ! -s "$CALL_LOG" ] || fail "non-git --dir reached gh"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "non-git --dir reached claude"
echo "PASS: non-git --dir propagates probe's exit 1, zero gh/claude calls"

# =============================================================================
# T4 -- happy path: probe + issues + estimate BEFORE triage + a real (fake)
# claude shadow-triage call with structural zero-tool-access proof.
# =============================================================================
before="$(cd "$REPO" && find . -type f | sort)"
FAKE_OPEN_ISSUES_JSON='[{"number":1,"title":"bug one","url":"https://x/1","labels":[],"body":"body one"},{"number":2,"title":"bug two","url":"https://x/2","labels":[],"body":"body two"}]'
FAKE_TRIAGE_OUTPUT="cull 0, group 1, priority set"
run 0 --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5
after="$(cd "$REPO" && find . -type f | sort)"
[ "$before" = "$after" ] || fail "try.sh run must never write to the target tree"
[ ! -e "$REPO/.foundation" ] || fail "try.sh must never create .foundation/ (zero writes)"

assert_contains '"schema": 1'
assert_contains '"probe": "conventions-probe"'
assert_contains "Open issues: 2"
assert_contains "Cost estimate"
assert_contains "FAKE-TRIAGE-REPORT-MARKER: cull 0, group 1, priority set"
assert_order "Cost estimate" "FAKE-TRIAGE-REPORT-MARKER"

# post-TemperLoop-rename branding: banner + done line say temperloop, not foundation.
assert_contains "== temperloop try =="
assert_contains "temperloop try: done (zero writes)"
assert_not_contains "foundation try"

gh_log_has_only_reads
grep -q '^issue list ' "$CALL_LOG" || fail "expected a gh issue list call, got: $(cat "$CALL_LOG")"

[ "$(claude_flag_value --tools)" = "" ] || fail "claude must be invoked with --tools \"\" (zero tool access), got: $(claude_flag_value --tools)"
n="$(claude_argc)"
i=0
found_no_persist=0
while [ "$i" -lt "$n" ]; do
  [ "$(claude_arg "$i")" = "--no-session-persistence" ] && found_no_persist=1
  i=$((i + 1))
done
[ "$found_no_persist" -eq 1 ] || fail "claude must be invoked with --no-session-persistence"
[ "$(claude_flag_value -p)" != "" ] || fail "claude must be invoked with a non-empty -p prompt"
[ "$(claude_flag_value --max-budget-usd)" = "1.00" ] || fail "expected --max-budget-usd 1.00 (cost-estimates.conf), got: $(claude_flag_value --max-budget-usd)"
echo "PASS: happy path — probe + estimate-before-triage + zero-tool claude call, zero writes to target tree"

# =============================================================================
# T5 -- gh absent entirely: issues + triage both gracefully skip; exit 0.
# =============================================================================
NOGH="$WORK/no-gh-bin"
mkdir -p "$NOGH"
for tool in git jq awk sed grep sort mktemp date find cut printf cat sleep bash dirname basename; do
  b="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$b" ] && ln -sf "$b" "$NOGH/$tool"
done
BASH_BIN="$(command -v bash)"
: > "$CALL_LOG"
out="$(PATH="$NOGH" "$BASH_BIN" "$TRY" --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5 2>&1)" || fail "gh-absent run should exit 0 (got: $out)"
assert_contains "gh CLI not found on PATH"
assert_contains "Cost estimate: unavailable"
echo "PASS: gh absent — graceful skip, exit 0"

# =============================================================================
# T6 -- gh present but unauthenticated: skip with the auth reason.
# =============================================================================
FAKE_AUTH_RC=1
FAKE_OPEN_ISSUES_JSON='[]'
run 0 --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5
assert_contains "not authenticated"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "unauthenticated gh should never reach claude"
echo "PASS: gh unauthenticated — graceful skip, exit 0, claude never invoked"
FAKE_AUTH_RC=0

# =============================================================================
# T7 -- claude absent, gh present: estimate still prints, triage skips.
# =============================================================================
NOCLAUDE="$WORK/no-claude-bin"
mkdir -p "$NOCLAUDE"
for tool in git jq awk sed grep sort mktemp date find cut printf cat sleep bash dirname basename; do
  b="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$b" ] && ln -sf "$b" "$NOCLAUDE/$tool"
done
ln -sf "$BIN/gh" "$NOCLAUDE/gh"
FAKE_OPEN_ISSUES_JSON='[{"number":1,"title":"bug one","url":"https://x/1","labels":[],"body":"body one"}]'
: > "$CALL_LOG"
out="$(PATH="$NOCLAUDE" FAKE_AUTH_RC=0 FAKE_OPEN_ISSUES_JSON="$FAKE_OPEN_ISSUES_JSON" CALL_LOG="$CALL_LOG" "$BASH_BIN" "$TRY" --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5 2>&1)" || fail "claude-absent run should exit 0 (got: $out)"
case "$out" in
  *"Open issues: 1"*) ;;
  *) fail "expected the open-issue count even with claude absent (got: $out)" ;;
esac
case "$out" in
  *"claude CLI not found on PATH"*) ;;
  *) fail "expected a claude-absent skip reason (got: $out)" ;;
esac
echo "PASS: claude absent — estimate still printed, triage skips, exit 0"

# =============================================================================
# T8 -- --no-network: both issues + triage skip with the network reason,
# and NEITHER gh nor claude is ever invoked (not even a probe-side call).
# =============================================================================
FAKE_OPEN_ISSUES_JSON='[{"number":1,"title":"x","url":"y","labels":[],"body":""}]'
run 0 --dir "$REPO" --gh-repo "$TEST_REPO" --no-network
assert_contains "network disabled (--no-network)"
[ ! -s "$CALL_LOG" ] || fail "--no-network must never invoke gh, got: $(cat "$CALL_LOG")"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "--no-network must never invoke claude"
echo "PASS: --no-network — zero gh/claude calls, graceful skip, exit 0"

# =============================================================================
# T9 -- zero open issues: estimate reports 0, triage skips as "no open
# issues", claude never invoked.
# =============================================================================
FAKE_OPEN_ISSUES_JSON='[]'
run 0 --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5
assert_contains "Open issues: 0"
assert_contains "no open issues to triage"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "zero open issues should never reach claude"
echo "PASS: zero open issues — no LLM call, exit 0"

# =============================================================================
# T10 -- --max-issues caps what's fed to the prompt (cost estimate still
# reflects the FULL open-issue count).
# =============================================================================
FAKE_OPEN_ISSUES_JSON='[{"number":1,"title":"one","url":"u","labels":[],"body":""},{"number":2,"title":"two","url":"u","labels":[],"body":""},{"number":3,"title":"three","url":"u","labels":[],"body":""}]'
run 0 --dir "$REPO" --gh-repo "$TEST_REPO" --timeout 5 --max-issues 2
assert_contains "Open issues: 3"
prompt="$(claude_flag_value -p)"
case "$prompt" in
  *"Showing 2 of 3"*) ;;
  *) fail "expected the prompt to note capping (Showing 2 of 3), got: $prompt" ;;
esac
echo "PASS: --max-issues caps the prompt while the estimate covers all open issues"

echo "OK: test_try.sh"
