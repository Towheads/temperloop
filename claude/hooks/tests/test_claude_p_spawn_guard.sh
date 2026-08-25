#!/usr/bin/env bash
# Tests for claude-p-spawn-guard.sh (temperloop#1836).
#
# No git fixtures, no network — the hook is a pure text scan, so every case is
# a crafted PreToolUse JSON payload plus an expected decision:
#   - inline bare `claude -p` / `--print`                    -> ask
#   - the same invocation carrying --model                   -> silent
#   - a HEREDOC-authored bare spawn                          -> ask  (LOAD-BEARING)
#   - `bash some-script.sh &` (the incident's dispatch form)  -> silent, and that
#     silence is asserted here as a DOCUMENTED BLIND SPOT, not assumed coverage
#   - --settings pinning a model (file or inline JSON)       -> silent
#   - --settings resolvable but NOT pinning a model          -> ask
#   - `-p` in the value slot of another flag                 -> silent
#   - searching for the literal (`grep "claude -p"`)         -> silent
#   - EVAL_RUN / malformed input / non-Bash tool             -> silent, rc 0
#
# The heredoc case is the one that matters most: temperloop#1836 probed and
# DISCONFIRMED the naive design (keying on the invocation's argv head), because
# the 2026-08-24 incident dispatched its 57 spawns as `bash review-one.sh … &`.
# The heredoc that AUTHORED that script is the earliest Bash tool call carrying
# the literal `claude -p`, so a hook that misses it is theater.
#
# shellcheck disable=SC2016
# ^ Every fixture below is LITERAL command text fed to the hook as data. A
#   `$(…)` or `$VAR` inside a fixture must reach the hook unexpanded — that is
#   precisely what the hook has to parse — so single quotes are correct here.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../claude-p-spawn-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0

run_hook() { # <command-text> [extra env assignments handled by caller]
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null
}

check() { # <desc> <expected: ask|silent> <actual-stdout>
  local desc="$1" want="$2" out="$3" got
  if grep -q '"permissionDecision":"ask"' <<<"$out"; then got=ask; else got=silent; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want=%s got=%s)\n     out=%s\n' "$desc" "$want" "$got" "$out"
  fi
}

# check_reason: asserts BOTH that the decision is `ask` AND that the reason text
# carries an expected substring — the "naming the inherited-default risk" half
# of the acceptance criterion that check()'s ask/silent comparison misses.
check_reason() { # <desc> <expected-substring> <actual-stdout>
  local desc="$1" want="$2" out="$3" reason
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ -n "$reason" ] && [[ "$reason" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (reason did not contain %q)\n     reason=%s\n' "$desc" "$want" "$reason"
  fi
}

echo "== claude-p-spawn-guard =="

# --- 1. the incident's inline smoke test (interception point (a)) -------------
INLINE='cd /tmp/sweep2 && time claude -p "$(bash /tmp/sweep2/mkreview.sh 1 2)" --append-system-prompt "you are a reviewer" --output-format json'
check "inline bare claude -p (incident smoke test) -> ask" ask "$(run_hook "$INLINE")"
check_reason "reason names the missing --model" "--model" "$(run_hook "$INLINE")"
check_reason "reason names the machine-default inherit risk" "MACHINE's saved default" "$(run_hook "$INLINE")"

INLINE_MODEL='cd /tmp/sweep2 && time claude -p "$(bash /tmp/sweep2/mkreview.sh 1 2)" --model "$PIPELINE_DRIVE_MODEL" --append-system-prompt "you are a reviewer" --output-format json'
check "same invocation carrying --model -> silent" silent "$(run_hook "$INLINE_MODEL")"
check "--model=<value> form -> silent" silent "$(run_hook 'claude -p "hi" --model=sonnet')"

# --- 2. THE LOAD-BEARING CASE: the heredoc that AUTHORED the script ----------
read -r -d '' HEREDOC <<'OUTER' || true
cat > /tmp/sweep2/review-one.sh <<'SCRIPT'
#!/usr/bin/env bash
p="$1"; l="$2"
claude -p "$(bash /tmp/sweep2/mkreview.sh "$p" "$l")" --append-system-prompt "reviewer" --output-format json
SCRIPT
chmod +x /tmp/sweep2/review-one.sh
OUTER
check "HEREDOC-authored bare spawn -> ask (load-bearing)" ask "$(run_hook "$HEREDOC")"

read -r -d '' HEREDOC_MODEL <<'OUTER' || true
cat > /tmp/sweep2/review-one.sh <<'SCRIPT'
#!/usr/bin/env bash
claude -p "$(bash /tmp/sweep2/mkreview.sh "$1" "$2")" --model "$PIPELINE_DRIVE_MODEL" --output-format json
SCRIPT
OUTER
check "HEREDOC-authored spawn WITH --model -> silent" silent "$(run_hook "$HEREDOC_MODEL")"

# --- 3. the DOCUMENTED BLIND SPOT, asserted rather than assumed --------------
# The incident's actual dispatch form. The hook cannot see inside an
# already-written script invoked by path; this test pins that as known and
# intentional, so the coverage claim in the header stays honest.
check "BLIND SPOT: bash <already-written-script> & -> silent (documented)" silent \
  "$(run_hook 'while read -r p l s r; do bash /tmp/sweep2/review-one.sh "$p" "$l" "$s" "$r" & done < /tmp/sweep2/work.tsv')"

# --- 4. flag-spelling and parsing edge cases ---------------------------------
check "--print long form, bare -> ask" ask "$(run_hook 'claude --print "summarize this"')"
check "-p as the VALUE of another flag -> silent" silent "$(run_hook 'claude --output-format -p')"
check "--fallback-model alone does NOT count as pinned -> ask" ask \
  "$(run_hook 'claude -p "hi" --fallback-model haiku')"
check "no print flag at all -> silent" silent "$(run_hook 'claude --version')"
check "searching for the literal (grep) -> silent" silent \
  "$(run_hook 'grep -rn "claude -p" workflows/scripts')"
check "command substitution X=\$(claude -p …) -> ask" ask "$(run_hook 'OUT=$(claude -p "hi")')"
check "env VAR=1 claude -p -> ask" ask "$(run_hook 'env FOO=1 claude -p "hi"')"
check "sh -c \"claude -p …\" -> ask" ask "$(run_hook 'bash -c "claude -p hi"')"
check "absolute path /usr/local/bin/claude -p -> ask" ask "$(run_hook '/usr/local/bin/claude -p "hi"')"
check "plain assignment FOO=claude is not an invocation -> silent" silent \
  "$(run_hook 'FOO=claude; echo "$FOO" -p')"
# Continuation handling, proven by a discriminating PAIR: the same two-line
# shape asks without --model and is silent with it, so the silent half cannot
# be passing merely because the parser gave up at the newline.
check "line continuation keeps --model in the same invocation -> silent" silent \
  "$(run_hook "$(printf 'claude -p "hi" \\\n  --model sonnet')")"
check "line continuation, still bare -> ask" ask \
  "$(run_hook "$(printf 'claude -p "hi" \\\n  --output-format json')")"
# A newline with NO continuation ends the invocation: an unrelated later
# --model on its own line must not silence a bare spawn above it.
check "unrelated --model on a later line does not silence -> ask" ask \
  "$(run_hook "$(printf 'claude -p "hi"\nother-tool --model sonnet')")"

# multiple invocations in one command string: one pinned, one bare
MULTI='claude -p "a" --model sonnet ; claude -p "b"'
check "multiple invocations, one bare -> ask" ask "$(run_hook "$MULTI")"
check_reason "multi: reason quotes the BARE invocation, not the pinned one" 'claude -p "b"' "$(run_hook "$MULTI")"
check_reason "two bare invocations are counted" "2 headless" \
  "$(run_hook 'claude -p "a" ; claude --print "b"')"

# --- 4b. QUOTE STATE: a separator inside a quoted PROMPT is not a command break
# Regression, temperloop#1836 review round 1: parity was tracked for `"` only,
# so a `;` / `&&` / `&` inside a SINGLE-quoted prompt ended the flag scan before
# a later --model was reached and the hook fired on the COMPLIANT form it exists
# to promote. A false ask on correct usage is the worst failure mode available
# to an advisory guard — it trains reflexive approval and erodes the real ask.
check "single-quoted prompt containing ';' + --model -> silent" silent \
  "$(run_hook "claude -p 'Review this; be brief' --model sonnet")"
check "single-quoted prompt containing '&&' + --model -> silent" silent \
  "$(run_hook "claude -p 'a && b' --model sonnet")"
check "single-quoted prompt containing '&' + --model -> silent" silent \
  "$(run_hook "claude -p 'foo & bar' --model sonnet")"
check "double-quoted prompt containing ';' + --model -> silent" silent \
  "$(run_hook 'claude -p "line one; line two" --model sonnet')"
# The discriminating negatives: the quoted separator must not swallow the whole
# rest of the command either, or the fix above would be a false NEGATIVE that
# silences genuinely bare spawns.
check "single-quoted prompt containing ';', still bare -> ask" ask \
  "$(run_hook "claude -p 'be brief; be kind'")"
# An apostrophe inside a DOUBLE-quoted prompt is a shell literal, not a quote
# opener. Two independent parities get this wrong (they would leave a phantom
# single-quote region open and let the unrelated later --model silence the bare
# spawn); one shell-accurate quote state gets it right.
check "apostrophe inside a double-quoted prompt does not open a quote -> ask" ask \
  "$(run_hook 'claude -p "do not stop; it'"'"'s fine" ; other-tool --model sonnet')"

# --- 4c. LAUNCHER PREFIXES: command position through an argument-taking wrapper
# Regression, temperloop#1836 review round 1: command-position detection only
# accepted `claude` when the PRECEDING token was a separator, an assignment or a
# bare modifier. A launcher that takes its own argument puts a non-modifier
# token in between, so every one of these was a silent FALSE NEGATIVE. xargs and
# parallel are the two most likely ways someone re-implements the 2026-08-24
# fan-out, and this repo's own build machinery wraps long calls in timeouts.
check "timeout <n> claude -p -> ask" ask "$(run_hook 'timeout 900 claude -p "hi"')"
check "gtimeout <n> claude -p -> ask" ask "$(run_hook 'gtimeout 900 claude -p "hi"')"
check "xargs -I{} claude -p -> ask" ask "$(run_hook 'xargs -I{} claude -p {}')"
check "parallel claude -p ::: -> ask" ask "$(run_hook 'parallel claude -p ::: a b')"
check "modifier + launcher chain (time timeout N claude -p) -> ask" ask \
  "$(run_hook 'time timeout 900 claude -p "hi"')"
check "launcher inside a substitution (OUT=\$(timeout 5 claude -p …)) -> ask" ask \
  "$(run_hook 'OUT=$(timeout 5 claude -p "x")')"
# Discriminating negatives: the launcher rule must not fire on a pinned spawn,
# and must not turn every token after a non-launcher head into command position.
check "timeout <n> claude -p WITH --model -> silent" silent \
  "$(run_hook 'timeout 900 claude -p "hi" --model sonnet')"
check "non-launcher head (grep) still not command position -> silent" silent \
  "$(run_hook 'grep -rn "timeout claude -p" workflows/scripts')"
# BLIND SPOT, asserted: the launcher list is BOUNDED and NAMED. An unlisted
# argument-taking wrapper is NOT covered — pinned here so the header's
# blind-spot claim stays honest rather than aspirational.
check "BLIND SPOT: unlisted launcher prefix (nice -n) -> silent (documented)" silent \
  "$(run_hook 'nice -n 10 claude -p "hi"')"

# --- 5. --settings dispositions ----------------------------------------------
printf '{"model":"claude-sonnet-4-5"}\n' > "$TMP/pinned.json"
printf '{"permissions":{"allow":[]}}\n' > "$TMP/unpinned.json"
check "--settings <file pinning .model> -> silent" silent \
  "$(run_hook "claude -p \"hi\" --settings $TMP/pinned.json")"
check "--settings <file WITHOUT .model> -> ask" ask \
  "$(run_hook "claude -p \"hi\" --settings $TMP/unpinned.json")"
check "--settings=<file pinning .model> (= form) -> silent" silent \
  "$(run_hook "claude -p \"hi\" --settings=$TMP/pinned.json")"
check "--settings inline JSON mentioning model -> silent" silent \
  "$(run_hook 'claude -p "hi" --settings '"'"'{"model":"sonnet"}'"'"'')"
check "--settings <unresolvable \$VAR> -> silent (fail open)" silent \
  "$(run_hook 'claude -p "hi" --settings "$EVAL_SETTINGS"')"
check "--settings <nonexistent path> -> silent (fail open)" silent \
  "$(run_hook "claude -p \"hi\" --settings $TMP/does-not-exist.json")"
# temperloop#1836 FIX D: awk hands the shell half a sentinel meaning "no
# --settings was passed". A literal `-` would have COLLIDED with a real
# `--settings -` value and been decoded back to "no settings"; the sentinel now
# used cannot be a real value. Pinned so a future edit cannot regress to `-`.
check "--settings - (a literal dash) is treated as a VALUE, not 'no settings'" silent \
  "$(run_hook 'claude -p "hi" --settings -')"

# --- 5b. no SILENT INTERNAL FAILURE ------------------------------------------
# The hook fails open on ANY internal error, which is right for an advisory
# guard but makes a BROKEN hook indistinguishable from a CLEAN one: a syntax
# error in the embedded awk program silences every case while the suite still
# reports rc 0 on all the `silent` expectations. (That is not hypothetical — an
# apostrophe inside an awk comment closed the shell quoting during this very
# change and turned the whole guard into a no-op.) So assert the absence of
# internal noise directly, on a payload that MUST produce a finding.
err=$(jq -cn --arg c 'claude -p "hi"' '{tool_name:"Bash",tool_input:{command:$c}}' \
        | bash "$HOOK" 2>&1 >/dev/null)
if [ -z "$err" ]; then
  pass=$((pass + 1)); printf '  ✓ hook emits nothing on stderr (no masked internal error)\n'
else
  fail=$((fail + 1)); printf '  ✗ hook wrote to stderr: %s\n' "$err"
fi

# --- 6. suppression and fail-open --------------------------------------------
out=$(jq -cn --arg c "$INLINE" '{tool_name:"Bash",tool_input:{command:$c}}' | EVAL_RUN=1 bash "$HOOK" 2>/dev/null; echo "rc=$?")
check "EVAL_RUN=1 -> silent" silent "$out"
case "$out" in *"rc=0"*) pass=$((pass + 1)); printf '  ✓ EVAL_RUN exits 0\n' ;;
  *) fail=$((fail + 1)); printf '  ✗ EVAL_RUN exits 0 (got %s)\n' "$out" ;; esac

for bad in 'not json at all' '{"tool_name":' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  out=$(printf '%s' "$bad" | bash "$HOOK" 2>/dev/null; echo "rc=$?")
  check "malformed input fails open: $bad" silent "$out"
  case "$out" in *"rc=0"*) pass=$((pass + 1)); printf '  ✓ rc=0 on: %s\n' "$bad" ;;
    *) fail=$((fail + 1)); printf '  ✗ rc=0 on: %s (got %s)\n' "$bad" "$out" ;; esac
done

out=$(printf '' | bash "$HOOK" 2>/dev/null; echo "rc=$?")
check "empty stdin fails open" silent "$out"

check "non-Bash tool -> silent" silent \
  "$(jq -cn '{tool_name:"Edit",tool_input:{file_path:"/x",new_string:"claude -p hi"}}' | bash "$HOOK" 2>/dev/null)"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d claude-p-spawn-guard checks passed\n' "$pass"
