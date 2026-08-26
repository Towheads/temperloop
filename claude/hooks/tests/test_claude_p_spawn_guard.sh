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
fixn=0

run_hook() { # <command-text> [extra env assignments handled by caller]
  # PIPE-FED ON PURPOSE, and safe on two independent counts: `EVAL_RUN=''` takes
  # the hook PAST its EVAL_RUN early exit into `INPUT=$(cat …)`, which drains
  # stdin to EOF so the upstream jq is never signalled — and, decisively, every
  # caller asserts only on STDOUT. No `$?` is measured here, so even a failed
  # writer could not reach a verdict. See fixture() for the shape that is NOT
  # safe (temperloop#1844).
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | EVAL_RUN='' bash "$HOOK" 2>/dev/null
}

# fixture: write a PreToolUse payload to a FILE and print its path, so a call
# site can feed the hook by REDIRECT instead of through a pipe (temperloop#1844).
#
# THE BUG THIS EXISTS FOR. The hook's EVAL_RUN arm is its first executable line
# and exits WITHOUT draining stdin — deliberately, because an unanswerable
# interactive `ask` would hang a headless eval run. Feed it through a pipe and
# the upstream writer is still writing into a read end that just closed, so it
# takes EPIPE/SIGPIPE; under this file's `set -o pipefail` that UPSTREAM status
# becomes the pipeline's status. An assertion that then reads `$?` measures the
# writer, not the hook. CI's shape was `jq: error: writing output failed: Broken
# pipe` followed by `✗ EVAL_RUN exits 0 (got rc=2)`; locally the same race
# surfaces as rc=141. It is a race on the 64 KiB pipe buffer, so it fires when
# the host is busiest — which is how it ejected PR #1842 from the merge queue on
# a diff that never touched this file.
#
# THE RULE, and what §7's structural guard mechanically enforces: an assertion
# that measures the hook's EXIT STATUS must be fed by `<file`, never by `|`.
fixture() { # <command-text> -> prints the path of a file holding the payload
  local f
  fixn=$((fixn + 1))
  f="$TMP/fixture.$fixn.json"
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' > "$f"
  printf '%s' "$f"
}

# probe_eval_run: the EVAL_RUN contract as ONE indivisible triple — stdout
# EMPTY, stderr EMPTY, exit status 0. check()'s ask/silent comparison cannot see
# the middle of that (it classifies any non-`ask` output as "silent"), so a hook
# that PRINTED something before its EVAL_RUN exit would still read as silent.
# Shared by the live assertions and by the mutation proofs below, so the two can
# never drift apart.
probe_eval_run() { # <hook> <fixture-file> -> "rc=<n>;out=<stdout>;err=<stderr>"
  local hook="$1" f="$2" o rc
  o=$(EVAL_RUN=1 bash "$hook" <"$f" 2>"$TMP/evalrun.err"); rc=$?
  printf 'rc=%s;out=%s;err=%s' "$rc" "$o" "$(cat "$TMP/evalrun.err")"
}
EVAL_RUN_CLEAN='rc=0;out=;err='

check_eval_run_clean() { # <desc> <hook> <fixture>
  local desc="$1" got
  got=$(probe_eval_run "$2" "$3")
  if [ "$got" = "$EVAL_RUN_CLEAN" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want %q got %q)\n' "$desc" "$EVAL_RUN_CLEAN" "$got"
  fi
}

check_eval_run_dirty() { # <desc> <mutant-hook> <fixture> — the mutation proof's half
  local desc="$1" got
  got=$(probe_eval_run "$2" "$3")
  if [ "$got" != "$EVAL_RUN_CLEAN" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (mutant still produced a CLEAN triple: %q)\n' "$desc" "$got"
  fi
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

# --- 4d. QUOTE-GATED FLAG RECOGNITION ----------------------------------------
# Regression, temperloop#1836 review round 2: quote state was tracked and wired
# to the SEPARATOR break, but flag recognition below it still ran
# UNCONDITIONALLY. So a flag-shaped word sitting in PROMPT TEXT was read as a
# real command flag. That is one bug with two faces, and these pin both.
#
# Face 1, the false NEGATIVE and the dangerous one: the prompt merely MENTIONS
# --model, the invocation passes none, and the guard went silent on a genuinely
# bare spawn — exactly the spawn it exists to catch.
check "quoted prompt MENTIONING --model is still bare -> ask" ask \
  "$(run_hook 'claude -p "explain the --model flag"')"
check "single-quoted prompt MENTIONING --model is still bare -> ask" ask \
  "$(run_hook "claude -p 'we should pass --model here'")"
# Face 2, the false ASK: no print flag anywhere in the invocation, only the
# word `-p` inside a quoted system prompt, and the guard fired on it.
check "quoted prompt MENTIONING -p, no real print flag -> silent" silent \
  "$(run_hook 'claude --append-system-prompt "always use -p mode" --output-format json')"
# The value-slot capture needs the same gate: a `--settings` named inside a
# quoted prompt must not consume the next word as its settings value (which
# would resolve as an unreadable path and fail open to silent).
check "quoted prompt MENTIONING --settings does not consume a value -> ask" ask \
  "$(run_hook 'claude -p "use --settings foo.json please"')"
# The discriminating negative, and the reason this is a GATE and not a blanket
# refusal to read flags: the SAME prompt text, plus a REAL --model after the
# quote closes, must still go silent. If the gate leaked past the closing quote
# this would be a false ask.
check "same prompt + a REAL --model after the quote closes -> silent" silent \
  "$(run_hook 'claude -p "explain the --model flag" --model sonnet')"

# ATTACHED FLAG FORM: `-p"hi"` with no space. clean() strips the TRAILING quote
# but the LEADING one survives, so the exact `-p` / `--print` comparisons missed
# it and a real bare spawn went silent. Now MATCHED rather than documented as a
# blind spot — it is a legitimate shell spelling of the very thing this guard
# exists to catch, and the fix is a prefix test, not a new mechanism.
check "attached short form (-p\"hi\") -> ask" ask "$(run_hook 'claude -p"hi"')"
check "attached long form (--print'hi') -> ask" ask "$(run_hook "claude --print'hi'")"
check "attached form WITH --model -> silent" silent \
  "$(run_hook 'claude -p"hi" --model sonnet')"

# The gate's cost, pinned rather than left accidental: an UNBALANCED quote
# between `claude` and its `-p` leaves the region open, so the rest of that
# invocation reads as prompt text and the spawn goes silent. That input is a
# shell SYNTAX ERROR and cannot execute, so this is the hook's documented
# fail-open-on-malformed-input rule, not a coverage gap.
check "MALFORMED: unbalanced quote before -p -> silent (fails open)" silent \
  "$(run_hook "claude --agents don't -p \"hi\"")"
# And the bound on that cost, which is what keeps it acceptable: quote state
# RESETS per invocation, so an apostrophe BEFORE the `claude` token cannot
# suppress anything — including in a heredoc comment, which is the guard's
# most load-bearing interception point.
check "apostrophe in a heredoc comment BEFORE the spawn -> still ask" ask \
  "$(run_hook "cat > x.sh <<'S'
# don't skip this
claude -p \"review\"
S")"
check "apostrophe inside a DOUBLE-quoted value, then -p -> ask" ask \
  "$(run_hook 'claude --append-system-prompt "you'"'"'re a reviewer" -p "review"')"

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
        | EVAL_RUN='' bash "$HOOK" 2>&1 >/dev/null)
if [ -z "$err" ]; then
  pass=$((pass + 1)); printf '  ✓ hook emits nothing on stderr (no masked internal error)\n'
else
  fail=$((fail + 1)); printf '  ✗ hook wrote to stderr: %s\n' "$err"
fi

# --- 6. suppression and fail-open --------------------------------------------
# EVERY assertion below measures the hook's EXIT STATUS, so every one of them is
# fed by REDIRECT, never a pipe (temperloop#1844 — see fixture()). A pipe here
# would let the upstream writer's EPIPE status masquerade as the hook's.
EVAL_FIXTURE=$(fixture "$INLINE")
out=$(EVAL_RUN=1 bash "$HOOK" <"$EVAL_FIXTURE" 2>/dev/null; echo "rc=$?")
check "EVAL_RUN=1 -> silent" silent "$out"
case "$out" in *"rc=0"*) pass=$((pass + 1)); printf '  ✓ EVAL_RUN exits 0\n' ;;
  *) fail=$((fail + 1)); printf '  ✗ EVAL_RUN exits 0 (got %s)\n' "$out" ;; esac

BADF="$TMP/malformed.json"
for bad in 'not json at all' '{"tool_name":' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  printf '%s' "$bad" > "$BADF"
  out=$(EVAL_RUN='' bash "$HOOK" <"$BADF" 2>/dev/null; echo "rc=$?")
  check "malformed input fails open: $bad" silent "$out"
  case "$out" in *"rc=0"*) pass=$((pass + 1)); printf '  ✓ rc=0 on: %s\n' "$bad" ;;
    *) fail=$((fail + 1)); printf '  ✗ rc=0 on: %s (got %s)\n' "$bad" "$out" ;; esac
done

: > "$TMP/empty.json"
out=$(EVAL_RUN='' bash "$HOOK" <"$TMP/empty.json" 2>/dev/null; echo "rc=$?")
check "empty stdin fails open" silent "$out"

# PIPE-FED, and safe for the same two reasons run_hook() is: `EVAL_RUN=''`
# reaches the draining `cat`, and only STDOUT is asserted — no `$?` is read.
check "non-Bash tool -> silent" silent \
  "$(jq -cn '{tool_name:"Edit",tool_input:{file_path:"/x",new_string:"claude -p hi"}}' | EVAL_RUN='' bash "$HOOK" 2>/dev/null)"

# --- 6a. EVAL_RUN asserted STRICTLY, and proven immune to the pipe race ------
# temperloop#1844. Three things this section pins that §6's pair cannot:
#
#  (1) STRICT silence. check() reads any non-`ask` output as "silent", so a hook
#      that printed noise before its EVAL_RUN exit would still pass §6.
#      probe_eval_run() asserts the whole contract at once: stdout EMPTY,
#      stderr EMPTY, rc 0.
#  (2) IMMUNITY to the race, made DETERMINISTIC. Whether the old pipe-fed shape
#      failed was a function of the 64 KiB pipe buffer: a small payload fits, so
#      the writer finishes before the hook exits and rc is 0 — that is the size
#      that ALWAYS passed and therefore proves nothing. A payload larger than
#      the buffer leaves the writer mid-write, and the race becomes a certainty
#      (rc=141 locally, rc=2 in CI where jq reports the failed write). The same
#      case is run at BOTH sizes and both must report the HOOK's own rc=0.
#  (3) DISCRIMINATION. Two mutants of the hook — built in $TMP, never the real
#      file — prove the assertion still goes red if the early exit is REMOVED or
#      made NON-SILENT.
check_eval_run_clean "EVAL_RUN=1 is strictly silent (stdout+stderr empty, rc 0)" \
  "$HOOK" "$EVAL_FIXTURE"

# A payload comfortably past the 64 KiB pipe buffer. Under the pre-fix pipe-fed
# shape this is a reliable red; fed from a file it cannot be.
BIG_PROMPT=$(head -c 200000 /dev/zero | tr '\0' 'x')
BIG_FIXTURE=$(fixture "claude -p \"$BIG_PROMPT\"")
check_eval_run_clean "EVAL_RUN=1 stays clean on a payload LARGER than the pipe buffer (the #1844 race, made deterministic)" \
  "$HOOK" "$BIG_FIXTURE"

# MUTATION PROOF (a): delete the EVAL_RUN early exit. The hook then runs its
# scan and emits an `ask` for the bare spawn in the fixture -> not silent.
MUT_NOEXIT="$TMP/hook-mutant-no-eval-exit.sh"
awk '!/EVAL_RUN:-/' "$HOOK" > "$MUT_NOEXIT"
check_eval_run_dirty "MUTATION PROOF: removing the EVAL_RUN early exit turns the case RED" \
  "$MUT_NOEXIT" "$EVAL_FIXTURE"

# MUTATION PROOF (b): keep the early exit but make it NON-SILENT. §6's check()
# would still read this as "silent" (it is not an `ask`); the strict triple does
# not. This is why the assertion was strengthened rather than merely re-fed.
MUT_NOISY="$TMP/hook-mutant-noisy-eval-exit.sh"
awk '/EVAL_RUN:-/ { print "[ -n \"${EVAL_RUN:-}\" ] && { echo \"eval-run noise\"; exit 0; }"; next } { print }' \
  "$HOOK" > "$MUT_NOISY"
check_eval_run_dirty "MUTATION PROOF: a NON-SILENT EVAL_RUN early exit turns the case RED" \
  "$MUT_NOISY" "$EVAL_FIXTURE"

# --- 7. STRUCTURAL GUARD: no exit-status assertion may be PIPE-FED ------------
# temperloop#1844 lived because the rule it broke existed nowhere but in a
# reviewer's head. The shape is statically recognisable, so recognise it: an
# assertion in THIS file that measures the hook's exit status (`rc=$?`) must be
# fed by `<file`, never through a `|`.
#
# The guard is deliberately SCOPED TO rc-MEASURING call sites rather than
# banning pipes into the hook outright. run_hook() and the two stdout-only
# assertions above are pipe-fed and correct — they read no `$?`, so no upstream
# status can reach a verdict — and a blanket ban would force a pointless rewrite
# of ~60 call sites while teaching the wrong rule.
scan_for_pipe_fed_rc_assertions() { # <file> -> one "PIPE-FED-RC: <line>" per finding
  awk -v sut='bash "$HOOK"' '
    {
      raw = $0
      t = raw; sub(/^[ \t]+/, "", t)
      if (buf == "" && t ~ /^#/) next          # prose NAMING the shape is not a call site
      buf = (buf == "" ? raw : buf " " raw)
      if (raw ~ /\\[ \t]*$/) next              # backslash continuation: keep accumulating
      line = buf; buf = ""
      i = index(line, sut)
      if (i == 0) next                         # not a SUT invocation
      if (line !~ /rc=[$][?]/) next            # does not measure the exit status
      pre = substr(line, 1, i - 1)
      gsub(/\|\|/, "", pre)                    # || is a logical operator, not a pipe
      if (index(pre, "|") == 0) next           # fed by redirect: correct
      sub(/^[ \t]+/, "", line)
      print "PIPE-FED-RC: " line
    }
  ' "$1"
}

offenders=$(scan_for_pipe_fed_rc_assertions "${BASH_SOURCE[0]}")
if [ -z "$offenders" ]; then
  pass=$((pass + 1))
  printf '  ✓ STRUCTURAL GUARD: no exit-status assertion in this suite is pipe-fed (temperloop#1844)\n'
else
  fail=$((fail + 1))
  printf '  ✗ STRUCTURAL GUARD: an assertion here measures the hook exit status through a PIPE.\n'
  printf '     The hook exits under EVAL_RUN WITHOUT draining stdin, so the upstream writer takes\n'
  printf '     EPIPE and pipefail hands you ITS status. Feed it from a file: bash "$HOOK" <"$(fixture …)"\n'
  printf '%s\n' "$offenders" | sed 's/^/     /'
fi

# 7m. MUTATION PROOF for the guard: the SAME detector, run over a throwaway file
# carrying both shapes. The offending bytes are assembled through printf with a
# split sigil so this file never contains them contiguously — otherwise test 7,
# which scans this very file, would flag its own fixture.
SIGIL='$'
SYNTH="$TMP/synthetic-pipe-fed-suite.sh"
{
  printf '%s\n' 'out=$(printf x | EVAL_RUN=1 bash "'"$SIGIL"'HOOK" 2>/dev/null; echo "rc='"$SIGIL"'?")'
  printf '%s\n' 'out=$(EVAL_RUN=1 bash "'"$SIGIL"'HOOK" <"'"$SIGIL"'f" 2>/dev/null; echo "rc='"$SIGIL"'?")'
  printf '%s\n' 'plain=$(jq -cn . | EVAL_RUN='"''"' bash "'"$SIGIL"'HOOK" 2>/dev/null)'
} > "$SYNTH"
synth_out=$(scan_for_pipe_fed_rc_assertions "$SYNTH")
synth_n=$(printf '%s\n' "$synth_out" | grep -c 'PIPE-FED-RC:' || true)
if [ "$synth_n" = "1" ] && printf '%s' "$synth_out" | grep 'printf x |' >/dev/null; then
  pass=$((pass + 1))
  printf '  ✓ MUTATION PROOF: the guard'"'"'s detector catches a pipe-fed rc assertion, and only that one\n'
else
  fail=$((fail + 1))
  printf '  ✗ MUTATION PROOF: detector found %s finding(s), expected exactly the pipe-fed one:\n%s\n' \
    "$synth_n" "$synth_out"
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d claude-p-spawn-guard checks passed\n' "$pass"
