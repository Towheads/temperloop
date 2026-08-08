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

# --- fake claude: logs every argv element (mirrors test_try.sh), emits an
# --output-format json ENVELOPE whose .result is the canned {"path",
# "content"} fix, serialized as a JSON STRING (mirrors the real CLI's
# envelope shape, where .result is always a string, never an object). ----
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
if [ "${FAKE_CLAUDE_BAD_ENVELOPE:-0}" = "1" ]; then
  printf 'not-json-at-all {{{'
  exit "${FAKE_CLAUDE_RC:-0}"
fi
if [ "${FAKE_CLAUDE_NO_RESULT:-0}" = "1" ]; then
  # A structurally VALID envelope that simply carries NO .result key --
  # exercises the INNER unwrap arm (jq exits 0, output empty), which the
  # outer FAKE_CLAUDE_BAD_ENVELOPE mode above cannot reach.
  printf '{"usage":{"input_tokens":100,"output_tokens":50},"total_cost_usd":0.01,"duration_ms":500,"num_turns":1}'
  exit "${FAKE_CLAUDE_RC:-0}"
fi
# FAKE_FIX_RESULT_RAW, when set, is placed in .result VERBATIM (still a JSON
# string, so the envelope itself stays valid) -- lets a test drive .result to
# a non-JSON blob or to a JSON SCALAR, both of which reach `fromjson?`'s own
# failure arms rather than the outer envelope parse.
#
# The default fix body is assigned on its OWN line, deliberately NOT inside a
# `${FAKE_FIX_JSON:-...}` default-word. A JSON object embedded in a `:-` word
# has no spelling that is correct in both cases and on both shells:
#
#   `...\"fixed\"}}`   set:   value + a SPURIOUS trailing `}` (expansion ends
#                             at the first unescaped brace) -- both shells
#                      unset: correct -- both shells
#   `...\"fixed\"\}}`  set:   correct -- both shells
#                      unset: a trailing literal BACKSLASH under bash 3.2
#                             (stock macOS): `..."fixed"\}` -- invalid JSON
#
# Both spellings are therefore latent bugs, in DIFFERENT cells, and neither
# is safe to prefer: every call site below sets FAKE_FIX_JSON, so the SET row
# is the one under test today (the unescaped spelling breaks the happy path
# outright, on both shells) while the UNSET row is a trap armed for whoever
# next adds a case that omits FAKE_FIX_JSON -- and since
# `.github/workflows/ci.yml` pins ubuntu-latest, that trap could only ever be
# sprung on a contributor's own stock-macOS box, never in CI. Keeping the
# brace out of the expansion entirely is correct in all four cells, so
# neither row can regress.
if [ -n "${FAKE_FIX_JSON:-}" ]; then
  fake_result="$FAKE_FIX_JSON"
else
  fake_result='{"path":"greet.sh","content":"fixed"}'
fi
fake_result="${FAKE_FIX_RESULT_RAW:-$fake_result}"
jq -cn --arg result "$fake_result" \
  '{result: $result, usage: {input_tokens: 100, output_tokens: 50}, total_cost_usd: 0.01, duration_ms: 500, num_turns: 1}'
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
# post-TemperLoop-rename branding: banner + done line say temperloop, not foundation.
case "$out" in
  *"== temperloop try --demo =="*) ;;
  *) fail "expected the temperloop --demo banner (got: $out)" ;;
esac
case "$out" in
  *"temperloop try --demo: done"*) ;;
  *) fail "expected the temperloop --demo done line (got: $out)" ;;
esac
case "$out" in
  *"foundation try"*) fail "output must not carry stale 'foundation try' branding (got: $out)" ;;
  *) ;;
esac
git -C "$BARE" show-ref --verify --quiet refs/heads/demo/issue-5 \
  || fail "proposal branch was not pushed to the bare upstream"
git -C "$BARE" show refs/heads/demo/issue-5:greet.sh 2>/dev/null | grep 'Hello,' >/dev/null \
  || fail "pushed greet.sh does not carry the fix"
echo "PASS: happy path -- claims #5, drives a real (fake) claude judgment call, opens PR_OPENED"

# --- structural proof: --tools "" / --max-budget-usd / no-session-persistence
[ "$(claude_flag_value --tools)" = "" ] \
  || fail "claude must be invoked with --tools \"\" (zero tool access), got: $(claude_flag_value --tools)"
[ "$(claude_flag_value --max-budget-usd)" = "2.00" ] \
  || fail "expected --max-budget-usd 2.00 (the --demo-cap-usd default), got: $(claude_flag_value --max-budget-usd)"
[ "$(claude_flag_value --output-format)" = "json" ] \
  || fail "expected --output-format json (envelope capture), got: $(claude_flag_value --output-format)"
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

# =============================================================================
# T6 -- unparseable envelope: claude exits 0 but its stdout is not valid
# JSON at all (a corrupted/truncated envelope) -- the fix call fails the
# same "could not parse a fix" way it would for a malformed {"path",
# "content"} body, never a PR, never a merge. A DIFFERENT issue number
# than T4/T5 (a fresh branch name) for the same fast-forward-safe reason.
# =============================================================================
: > "$GH_LOG"
rm -rf "$CLAUDE_ARGS_DIR"
FAKE_ISSUES_JSON_T6='[{"number":7,"title":"greet.sh misspells its own greeting","labels":[{"name":"demo-seed"}]}]'
rc=0
out="$(PATH="$BIN:$PATH" \
  FAKE_AUTH_RC=0 \
  FAKE_ISSUES_JSON="$FAKE_ISSUES_JSON_T6" \
  FAKE_ISSUE_BODY="$FAKE_ISSUE_BODY" \
  FAKE_ISSUE_API_JSON="$FAKE_ISSUE_API_JSON" \
  FAKE_CLAUDE_BAD_ENVELOPE=1 \
  DEMO_REPO_ENV="$DEMO_REPO" \
  GH_LOG="$GH_LOG" \
  CLAUDE_ARGS_DIR="$CLAUDE_ARGS_DIR" \
  TRY_DEMO_CLONE_URL="$BARE" \
  TRY_DEMO_BOARD_NUM=903 \
  bash "$TRY" --demo --demo-repo "$DEMO_REPO" --yes 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "unparseable-envelope run should exit 1 (got $rc: $out)"
case "$out" in
  *"could not parse a fix from the judgment call's output"*) ;;
  *) fail "expected the parse-failure message (got: $out)" ;;
esac
case "$out" in
  *"not-json-at-all"*) ;;
  *) fail "expected the raw (unparseable) envelope echoed for debugging (got: $out)" ;;
esac
if grep -Eq '^gh pr (create|merge)' "$GH_LOG" 2>/dev/null; then
  fail "unparseable-envelope run must never open or merge a PR: $(cat "$GH_LOG")"
fi
echo "PASS: unparseable envelope — fix call fails gracefully (exit 1, no PR), same as a malformed fix body"

# =============================================================================
# T7 -- the INNER unwrap arms. T6 above only covers "stdout is not JSON at
# all", which fails on the OUTER envelope parse. These three cases keep the
# envelope structurally VALID and break `.result` itself, which is where
# `fromjson?` and the `|| fix_path=""` guard actually earn their keep:
#
#   a. no .result key      -> jq rc 0, empty  (`// empty` arm)
#   b. .result not JSON    -> jq rc 0, empty  (`fromjson?` arm)
#   c. .result a SCALAR    -> jq rc 5         (`.path` on a string ERRORS;
#                                              `?` does NOT cover this, only
#                                              the `|| fix_path=""` does)
#
# Every case must land on the same graceful "could not parse a fix" exit-1
# with no PR. Each also asserts the debug line's disclosure contract: the
# model's own .result is echoed when it exists, and the full envelope (with
# its total_cost_usd / usage internals) ONLY when there is no readable
# .result to show instead. Each gets a DISTINCT issue + board number for the
# same fresh-branch-name reason as T6.
# =============================================================================
demo_parse_failure_case() {
  # $1 label · $2 issue# · $3 board# · $4 NAME=VALUE env · $5 must-appear
  # substring · $6 must-NOT-appear substring ("" to skip)
  local label="$1" issue="$2" board="$3" envkv="$4" must="$5" mustnot="$6"
  local out rc=0
  : > "$GH_LOG"
  rm -rf "$CLAUDE_ARGS_DIR"
  out="$(PATH="$BIN:$PATH" \
    env "$envkv" \
    FAKE_AUTH_RC=0 \
    FAKE_ISSUES_JSON="[{\"number\":$issue,\"title\":\"greet.sh misspells its own greeting\",\"labels\":[{\"name\":\"demo-seed\"}]}]" \
    FAKE_ISSUE_BODY="$FAKE_ISSUE_BODY" \
    FAKE_ISSUE_API_JSON="$FAKE_ISSUE_API_JSON" \
    DEMO_REPO_ENV="$DEMO_REPO" \
    GH_LOG="$GH_LOG" \
    CLAUDE_ARGS_DIR="$CLAUDE_ARGS_DIR" \
    TRY_DEMO_CLONE_URL="$BARE" \
    TRY_DEMO_BOARD_NUM="$board" \
    bash "$TRY" --demo --demo-repo "$DEMO_REPO" --yes 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "$label: should exit 1 (got $rc: $out)"
  case "$out" in
    *"could not parse a fix from the judgment call's output"*) ;;
    *) fail "$label: expected the parse-failure message (got: $out)" ;;
  esac
  case "$out" in
    *"$must"*) ;;
    *) fail "$label: expected [$must] in the debug output (got: $out)" ;;
  esac
  if [ -n "$mustnot" ]; then
    case "$out" in
      *"$mustnot"*) fail "$label: [$mustnot] must NOT be disclosed (got: $out)" ;;
      *) ;;
    esac
  fi
  if grep -Eq '^gh pr (create|merge)' "$GH_LOG" 2>/dev/null; then
    fail "$label: must never open or merge a PR: $(cat "$GH_LOG")"
  fi
}

# a. Envelope is valid but carries NO .result at all -> nothing of the
#    model's to echo, so the FULL envelope is the debug surface.
demo_parse_failure_case "missing .result" 11 904 "FAKE_CLAUDE_NO_RESULT=1" \
  '"total_cost_usd"' ""
echo "PASS: a valid envelope with no .result fails gracefully (exit 1, no PR), echoing the envelope"

# b. .result present but not itself valid JSON -> the model's own output is
#    echoed and the envelope's cost/usage internals stay UNdisclosed.
demo_parse_failure_case ".result not JSON" 12 905 \
  "FAKE_FIX_RESULT_RAW=I could not find the bug, sorry." \
  'I could not find the bug, sorry.' '"total_cost_usd"'
echo "PASS: a .result that is not valid JSON fails gracefully, echoing .result and NOT the envelope internals"

# c. .result is a valid JSON SCALAR (a bare string), so `fromjson` succeeds
#    and `.path` then ERRORS on a non-object -- the arm `?` does not cover.
demo_parse_failure_case ".result a JSON scalar" 13 906 \
  'FAKE_FIX_RESULT_RAW="just-a-string"' \
  'just-a-string' '"total_cost_usd"'
echo "PASS: a .result that is a JSON scalar fails gracefully (the || guard, not ?), echoing .result only"

echo "OK: test_try_demo.sh"
