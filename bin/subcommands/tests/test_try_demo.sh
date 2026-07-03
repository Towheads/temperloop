#!/usr/bin/env bash
#
# Tests for try.sh's --demo mode (foundation #765 Epic D, item
# foundation-try-demo). Board/proposal-toolkit fixture style: a throwaway
# real-git bare "upstream" standing in for the scratch demo repo (clone
# source AND push target, via TRY_DEMO_CLONE_URL), a single flexible fake
# `gh` on PATH answering every call run_demo's issues-only tracker adapter
# path + proposal-pr.sh need (issue list/view/edit, label create, api
# issues/<n>, pr create — logged to $GH_LOG so a test can assert NO
# merge-shaped call ever fires), and a fake `claude` that logs its argv
# (the --tools ""/--max-budget-usd structural proof, mirroring
# test_try.sh's own convention) and emits a canned {"path","content"} fix.
# Zero network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRY="$HERE/../try.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/try-demo-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

DEMO_REPO="test-owner/test-demo"

# --- fixture: a BARE "upstream" seeded with the ONE defect-carrying file,
# so a real (local, no-network) `git clone`/push round-trips against it. ---
BARE="$WORK/upstream.git"
git init -q --bare --initial-branch=main "$BARE"
SEED="$WORK/seed"
git clone -q "$BARE" "$SEED" 2>/dev/null
cat > "$SEED/greet.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="${1:-World}"
echo "Helllo, ${name}!"
EOF
git -C "$SEED" add -A
git -C "$SEED" commit -q -m seed
git -C "$SEED" push -q origin main 2>/dev/null

# --- fake gh: logs every call; answers the issues-only adapter + proposal-pr
# reads/writes this scenario needs. ---------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
GH_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$GH_LOG"
case "$1" in
  auth)
    case "$2" in
      status) exit "${FAKE_AUTH_RC:-0}" ;;
      setup-git) exit 0 ;;
    esac
    exit 0 ;;
  issue)
    case "$2" in
      list) printf '%s' "$FAKE_ISSUES_JSON" ;;
      view) printf '%s' "$FAKE_ISSUE_BODY" ;;
      edit) : ;;
      *) echo "fake gh: unhandled 'issue $2'" >&2; exit 3 ;;
    esac
    exit 0 ;;
  api)
    case "$2" in
      repos/*/issues/*) printf '%s' "$FAKE_ISSUE_API_JSON" ;;
      *) echo "fake gh: unhandled 'api $2'" >&2; exit 3 ;;
    esac
    exit 0 ;;
  label)
    case "$2" in create) exit 0 ;; esac
    exit 0 ;;
  pr)
    case "$2" in
      create) echo "https://github.com/$DEMO_REPO_ENV/pull/501" ;;
      *) echo "fake gh: unhandled 'pr $2' — this scenario must never merge" >&2; exit 3 ;;
    esac
    exit 0 ;;
  *)
    echo "fake gh: unexpected subcommand '$1'" >&2
    exit 3 ;;
esac
GHEOF
chmod +x "$BIN/gh"

# --- fake claude: logs every argv element (mirrors test_try.sh), emits a
# canned {"path","content"} fix on stdout. --------------------------------
CLAUDE_ARGS_DIR="$WORK/claude-args"
cat > "$BIN/claude" <<'CLAUDEEOF'
#!/usr/bin/env bash
rm -rf "$CLAUDE_ARGS_DIR"
mkdir -p "$CLAUDE_ARGS_DIR"
i=0
for a in "$@"; do
  printf '%s' "$a" > "$CLAUDE_ARGS_DIR/arg_$i"
  i=$((i + 1))
done
echo "$i" > "$CLAUDE_ARGS_DIR/argc"
printf '%s' "${FAKE_FIX_JSON:-{\"path\":\"greet.sh\",\"content\":\"fixed\"}}"
exit "${FAKE_CLAUDE_RC:-0}"
CLAUDEEOF
chmod +x "$BIN/claude"

export GH_LOG CLAUDE_ARGS_DIR
export DEMO_REPO_ENV="$DEMO_REPO"

claude_arg() { cat "$CLAUDE_ARGS_DIR/arg_$1" 2>/dev/null || true; }
claude_argc() { cat "$CLAUDE_ARGS_DIR/argc" 2>/dev/null || echo 0; }
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

FIXED_GREET='#!/usr/bin/env bash
set -euo pipefail
name="${1:-World}"
echo "Hello, ${name}!"'

# =============================================================================
# T1 -- --demo-cap-usd rejects a non-numeric value before touching anything.
# =============================================================================
: > "$GH_LOG"
rc=0
out="$(PATH="$BIN:$PATH" bash "$TRY" --demo --demo-cap-usd abc 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "non-numeric --demo-cap-usd should exit 1 (got $rc: $out)"
[ ! -s "$GH_LOG" ] || fail "non-numeric --demo-cap-usd reached gh"
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "non-numeric --demo-cap-usd reached claude"
echo "PASS: --demo-cap-usd rejects a non-numeric value, zero gh/claude calls"

# =============================================================================
# T2 -- no --yes, non-tty stdin: refuses to proceed, exit 1, no mutating call.
# =============================================================================
: > "$GH_LOG"
rc=0
out="$(PATH="$BIN:$PATH" FAKE_AUTH_RC=0 bash "$TRY" --demo --demo-repo "$DEMO_REPO" \
  < /dev/null 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "no --yes on non-tty should exit 1 (got $rc: $out)"
case "$out" in
  *"--yes to confirm"*) ;;
  *) fail "expected the --yes refusal message (got: $out)" ;;
esac
if grep -Eq '^gh (issue (edit|create)|label create|pr )' "$GH_LOG" 2>/dev/null; then
  fail "no-confirmation run reached a mutating gh call: $(cat "$GH_LOG")"
fi
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "no-confirmation run reached claude"
echo "PASS: no --yes + non-tty stdin refuses to run, exit 1, no mutation, claude never invoked"

# =============================================================================
# T3 -- no available demo-seed issue: graceful skip, exit 0, claude never
# invoked, no mutating gh call.
# =============================================================================
: > "$GH_LOG"
FAKE_ISSUES_JSON='[{"number":9,"title":"unrelated, unlabeled issue","labels":[]}]'
out="$(PATH="$BIN:$PATH" FAKE_AUTH_RC=0 FAKE_ISSUES_JSON="$FAKE_ISSUES_JSON" \
  TRY_DEMO_CLONE_URL="$BARE" TRY_DEMO_BOARD_NUM=900 \
  bash "$TRY" --demo --demo-repo "$DEMO_REPO" --yes 2>&1)" || fail "no-available-issue run should exit 0 (got: $out)"
case "$out" in
  *"no available demo-seed issue"*) ;;
  *) fail "expected the no-available-issue skip message (got: $out)" ;;
esac
if grep -Eq '^gh (issue (edit|create)|label create|pr )' "$GH_LOG" 2>/dev/null; then
  fail "no-available-issue run reached a mutating gh call: $(cat "$GH_LOG")"
fi
[ ! -d "$CLAUDE_ARGS_DIR" ] || fail "no-available-issue run reached claude"
echo "PASS: no available demo-seed issue -- graceful skip, exit 0, no mutation, claude never invoked"

# =============================================================================
# T4 -- happy path: claims the one demo-seed issue, drives a real (fake)
# claude judgment call, and opens a PR via proposal-pr.sh (real local push
# to the bare upstream) -- issue -> PR, zero merges.
# =============================================================================
: > "$GH_LOG"
rm -rf "$CLAUDE_ARGS_DIR"
FAKE_ISSUES_JSON='[{"number":5,"title":"greet.sh misspells its own greeting","labels":[{"name":"demo-seed"}]}]'
FAKE_ISSUE_BODY='greet.sh prints Helllo instead of Hello.'
FAKE_ISSUE_API_JSON='{"state":"open","labels":[{"name":"demo-seed"}]}'
FAKE_FIX_JSON="$(jq -cn --arg p "greet.sh" --arg c "$FIXED_GREET" '{path:$p, content:$c}')"

out="$(PATH="$BIN:$PATH" \
  FAKE_AUTH_RC=0 \
  FAKE_ISSUES_JSON="$FAKE_ISSUES_JSON" \
  FAKE_ISSUE_BODY="$FAKE_ISSUE_BODY" \
  FAKE_ISSUE_API_JSON="$FAKE_ISSUE_API_JSON" \
  FAKE_FIX_JSON="$FAKE_FIX_JSON" \
  DEMO_REPO_ENV="$DEMO_REPO" \
  GH_LOG="$GH_LOG" \
  CLAUDE_ARGS_DIR="$CLAUDE_ARGS_DIR" \
  TRY_DEMO_CLONE_URL="$BARE" \
  TRY_DEMO_BOARD_NUM=901 \
  bash "$TRY" --demo --demo-repo "$DEMO_REPO" --yes 2>&1)" \
  || fail "happy-path run should exit 0 (got: $out)"

case "$out" in
  *"Claimed #5"*) ;;
  *) fail "expected the claim line (got: $out)" ;;
esac
case "$out" in
  *"PR: https://github.com/$DEMO_REPO/pull/501"*) ;;
  *) fail "expected the PR URL line (got: $out)" ;;
esac
case "$out" in
  *"PR_OPENED"*) ;;
  *) fail "expected a PR_OPENED outcome (got: $out)" ;;
esac
git -C "$BARE" show-ref --verify --quiet refs/heads/demo/issue-5 \
  || fail "proposal branch was not pushed to the bare upstream"
git -C "$BARE" show refs/heads/demo/issue-5:greet.sh 2>/dev/null | grep -q 'Hello,' \
  || fail "pushed greet.sh does not carry the fix"
echo "PASS: happy path -- claims #5, drives a real (fake) claude judgment call, opens PR_OPENED"

# --- structural proof: --tools "" / --max-budget-usd / no-session-persistence
[ "$(claude_flag_value --tools)" = "" ] \
  || fail "claude must be invoked with --tools \"\" (zero tool access), got: $(claude_flag_value --tools)"
[ "$(claude_flag_value --max-budget-usd)" = "2.00" ] \
  || fail "expected --max-budget-usd 2.00 (the --demo-cap-usd default), got: $(claude_flag_value --max-budget-usd)"
n="$(claude_argc)"
i=0
found_no_persist=0
while [ "$i" -lt "$n" ]; do
  [ "$(claude_arg "$i")" = "--no-session-persistence" ] && found_no_persist=1
  i=$((i + 1))
done
[ "$found_no_persist" -eq 1 ] || fail "claude must be invoked with --no-session-persistence"
echo "PASS: claude invoked with --tools \"\" + --max-budget-usd 2.00 + --no-session-persistence"

# --- SAFE-TIER: no merge-shaped gh call fires anywhere in the log ----------
if grep -Eq '^gh pr merge' "$GH_LOG" 2>/dev/null; then
  fail "a 'gh pr merge' call fired -- --demo must never merge: $(cat "$GH_LOG")"
fi
echo "PASS: zero 'gh pr merge' calls -- safe-tier boundary (PR opened, never merged) holds"

# =============================================================================
# T5 -- --demo-cap-usd threads through to --max-budget-usd. A DIFFERENT
# issue number than T4 (a fresh branch name), so the local push against the
# same bare upstream is a fast-forward, not a re-run of T4's own branch.
# =============================================================================
: > "$GH_LOG"
rm -rf "$CLAUDE_ARGS_DIR"
FAKE_ISSUES_JSON_T5='[{"number":6,"title":"greet.sh misspells its own greeting","labels":[{"name":"demo-seed"}]}]'
out="$(PATH="$BIN:$PATH" \
  FAKE_AUTH_RC=0 \
  FAKE_ISSUES_JSON="$FAKE_ISSUES_JSON_T5" \
  FAKE_ISSUE_BODY="$FAKE_ISSUE_BODY" \
  FAKE_ISSUE_API_JSON="$FAKE_ISSUE_API_JSON" \
  FAKE_FIX_JSON="$FAKE_FIX_JSON" \
  DEMO_REPO_ENV="$DEMO_REPO" \
  GH_LOG="$GH_LOG" \
  CLAUDE_ARGS_DIR="$CLAUDE_ARGS_DIR" \
  TRY_DEMO_CLONE_URL="$BARE" \
  TRY_DEMO_BOARD_NUM=902 \
  bash "$TRY" --demo --demo-repo "$DEMO_REPO" --demo-cap-usd 0.50 --yes 2>&1)" \
  || fail "custom --demo-cap-usd run should exit 0 (got: $out)"
[ "$(claude_flag_value --max-budget-usd)" = "0.50" ] \
  || fail "expected --max-budget-usd 0.50 to thread through, got: $(claude_flag_value --max-budget-usd)"
echo "PASS: --demo-cap-usd threads through to the live call's --max-budget-usd"

echo "OK: test_try_demo.sh"
