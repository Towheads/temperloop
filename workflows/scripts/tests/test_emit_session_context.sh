#!/usr/bin/env bash
# Tests for emit-session-context.sh (temperloop#828, epic #810
# "realized-session-context probe").
#
# Synthetic transcript fixtures in a tmpdir — no real sessions, zero network.
#   - print-only: prints the record to stdout, appends NOTHING to the lake,
#     and works regardless of the passive opt-in gate (this script itself
#     has no opinion on that gate — the caller checks it)
#   - normal mode: appends exactly one JSONL record to
#     SESSION_CONTEXT_RAW_DIR/session-context-<YYYY-MM>.jsonl
#   - record shape: schema_version/ts/session_id/host/project/cwd/
#     transcript_tokens_total/context_window_size/context_window_remaining_pct
#   - missing --transcript -> transcript_tokens_total is null, script still
#     emits (warn-don't-drop), never fails
#   - jq missing -> WARN to stderr, exit 0, no record  (skipped: can't easily
#     hide jq from PATH portably here without risking other tool calls; the
#     `command -v jq` guard mirrors emit-command-run.sh's identical shape by
#     code inspection)
#   - always exits 0 regardless of outcome
#   - STRUCTURAL PRIVACY: a transcript containing recognizable prose content
#     never leaks into the emitted record — only the numeric token sum does
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../emit-session-context.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: emit-session-context.sh not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <condition-command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s\n' "$desc"
  fi
}

MONTH="$(date -u +%Y-%m)"

# --- 1. print-only: prints a record, writes NOTHING to the lake -------------
RAWDIR1="$TMP/raw1"
T1="$TMP/t1.jsonl"
jq -cn '{type:"assistant", message:{role:"assistant", usage:{input_tokens:100, cache_creation_input_tokens:0, cache_read_input_tokens:0, output_tokens:20}}}' > "$T1"

OUT1=$(SESSION_CONTEXT_RAW_DIR="$RAWDIR1" bash "$SCRIPT" \
  --transcript "$T1" --session-id "sess-print" --project "demo" --cwd "/home/dev/demo" \
  --context-window-size 200000 --context-window-remaining-pct 55.5 \
  --print-only)
RC1=$?

check "print-only: exits 0" test "$RC1" -eq 0
check "print-only: prints valid JSON" bash -c "printf '%s' '$OUT1' | jq -e . >/dev/null"
check "print-only: transcript_tokens_total correct (120)" \
  test "$(printf '%s' "$OUT1" | jq -r '.transcript_tokens_total')" = "120"
check "print-only: context_window_size passed through" \
  test "$(printf '%s' "$OUT1" | jq -r '.context_window_size')" = "200000"
check "print-only: context_window_remaining_pct passed through" \
  test "$(printf '%s' "$OUT1" | jq -r '.context_window_remaining_pct')" = "55.5"
check "print-only: session_id/project/cwd carried through" \
  bash -c "printf '%s' '$OUT1' | jq -e '.session_id == \"sess-print\" and .project == \"demo\" and .cwd == \"/home/dev/demo\"' >/dev/null"
check "print-only: schema_version is \"1\"" \
  test "$(printf '%s' "$OUT1" | jq -r '.schema_version')" = "1"
check "print-only: writes NOTHING to the raw lake dir" \
  bash -c "[ ! -d '$RAWDIR1' ] || [ -z \"\$(ls -A '$RAWDIR1' 2>/dev/null)\" ]"

# --- 2. Normal mode: appends exactly one record to the raw lake -------------
RAWDIR2="$TMP/raw2"
T2="$TMP/t2.jsonl"
jq -cn '{type:"assistant", message:{role:"assistant", usage:{input_tokens:5000, cache_creation_input_tokens:500, cache_read_input_tokens:1000, output_tokens:250}}}' > "$T2"

SESSION_CONTEXT_RAW_DIR="$RAWDIR2" bash "$SCRIPT" \
  --transcript "$T2" --session-id "sess-write" --project "proj2" --cwd "/home/dev/proj2" \
  --context-window-size 180000 --context-window-remaining-pct 12 \
  >/dev/null
RC2=$?

RAWFILE2="$RAWDIR2/session-context-${MONTH}.jsonl"
check "normal mode: exits 0" test "$RC2" -eq 0
check "normal mode: raw file created" test -f "$RAWFILE2"
check "normal mode: exactly one line appended" test "$(wc -l < "$RAWFILE2" | tr -d ' ')" = "1"
check "normal mode: transcript_tokens_total correct (6750)" \
  bash -c "jq -r '.transcript_tokens_total' '$RAWFILE2' | grep -qx 6750"
check "normal mode: session_id correct" \
  bash -c "jq -r '.session_id' '$RAWFILE2' | grep -qx sess-write"

# Run it again -> a SECOND line is appended (append-only, never overwritten).
SESSION_CONTEXT_RAW_DIR="$RAWDIR2" bash "$SCRIPT" \
  --transcript "$T2" --session-id "sess-write-2" \
  >/dev/null
check "normal mode: second call appends (2 lines total, never truncates)" \
  test "$(wc -l < "$RAWFILE2" | tr -d ' ')" = "2"

# --- 3. Missing --transcript -> null total, still emits, never fails -------
RAWDIR3="$TMP/raw3"
OUT3=$(SESSION_CONTEXT_RAW_DIR="$RAWDIR3" bash "$SCRIPT" --session-id "sess-no-transcript" --print-only)
RC3=$?
check "no --transcript: still exits 0" test "$RC3" -eq 0
check "no --transcript: transcript_tokens_total is null" \
  test "$(printf '%s' "$OUT3" | jq -r '.transcript_tokens_total')" = "null"

# --- 4. Nonexistent transcript path -> null total (token_sum_transcript's ---
#        own missing-file fallback), never fails.
OUT4=$(bash "$SCRIPT" --transcript "$TMP/does-not-exist.jsonl" --print-only)
check "nonexistent transcript: exits 0" test $? -eq 0
check "nonexistent transcript: total is 0 (token_sum_transcript's own fallback)" \
  test "$(printf '%s' "$OUT4" | jq -r '.transcript_tokens_total')" = "0"

# --- 5. STRUCTURAL PRIVACY: recognizable content never leaks into the record
CANARY="SECRET-CANARY-DO-NOT-LEAK-7e21bd"
T5="$TMP/t5.jsonl"
{
  jq -cn --arg c "$CANARY" '{type:"user", message:{role:"user", content:("plan details: " + $c)}}'
  jq -cn --arg c "$CANARY" '{type:"assistant", message:{role:"assistant", usage:{input_tokens:42, cache_creation_input_tokens:0, cache_read_input_tokens:0, output_tokens:8}, content:[{type:"text", text:("about " + $c)}]}}'
} > "$T5"
OUT5=$(bash "$SCRIPT" --transcript "$T5" --session-id "$CANARY-in-session-id-not-content" --print-only)
check "privacy: transcript_tokens_total correct (50) despite recognizable content in the transcript" \
  test "$(printf '%s' "$OUT5" | jq -r '.transcript_tokens_total')" = "50"
check "privacy: the canary string appears ONLY where the caller explicitly put it (session_id), never elsewhere in the record" \
  bash -c "printf '%s' '$OUT5' | jq -r 'del(.session_id) | tostring' | grep -qv '$CANARY'"

# --- 6. Unknown argument -> warns, ignored, never fails ---------------------
STDERR6="$TMP/test6.stderr"
bash "$SCRIPT" --print-only --bogus-flag >/dev/null 2>"$STDERR6"
RC6=$?
check "unknown arg: still exits 0" test "$RC6" -eq 0
check "unknown arg: WARN on stderr" grep -q WARN "$STDERR6"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d emit-session-context checks passed\n' "$pass"
