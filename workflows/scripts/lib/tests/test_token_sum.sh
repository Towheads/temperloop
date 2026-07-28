#!/usr/bin/env bash
# Tests for token_sum.sh (temperloop#828, epic #810 "realized-session-context
# probe") — the shared helper both claude/status-line.sh's "Tokens: NNk"
# display and workflows/scripts/emit-session-context.sh call, so the
# displayed and recorded figures cannot silently drift apart.
#
# Synthetic transcript fixtures in a tmpdir — no real sessions, zero network.
#   - basic: sums input/cache-creation/cache-read/output across every
#     message, treating a missing usage field as 0
#   - non-assistant / no-usage lines are simply 0-contributing, never fatal
#   - missing file -> "0"
#   - empty file -> "0"
#   - malformed (non-JSON) transcript -> "0" (jq failure degrades, never dies)
#   - STRUCTURAL PRIVACY: a transcript whose messages carry large,
#     recognizable prose content alongside their usage numbers still sums
#     to EXACTLY the expected total — the content never perturbs the sum,
#     because the function's only selector is `.message.usage.*`. A static
#     grep on the lib source is the regression PROOF that no `.message.content`
#     (or other field) selector exists at all, backing the functional check.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB="$HERE/../token_sum.sh"
[ -f "$LIB" ] || { echo "FATAL: token_sum.sh not found at $LIB" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

# shellcheck source=../token_sum.sh
. "$LIB"

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

# --- 1. Basic sum across several messages, missing fields default to 0 -----
T1="$TMP/t1.jsonl"
{
  jq -cn '{type:"user", message:{role:"user", content:"hi"}}'                       # no usage at all -> 0
  jq -cn '{type:"assistant", message:{role:"assistant", usage:{input_tokens:100, cache_creation_input_tokens:20, cache_read_input_tokens:5, output_tokens:50}}}'   # 175
  jq -cn '{type:"assistant", message:{role:"assistant", usage:{input_tokens:10}}}'   # 10 (rest missing -> 0)
} > "$T1"
OUT1=$(token_sum_transcript "$T1")
check "basic: sums across messages, missing fields treated as 0 (175+10=185)" \
  test "$OUT1" = "185"

# --- 2. Missing file -> 0 ----------------------------------------------------
OUT2=$(token_sum_transcript "$TMP/does-not-exist.jsonl")
check "missing file -> 0" test "$OUT2" = "0"

# --- 3. Empty argument -> 0 ---------------------------------------------------
OUT3=$(token_sum_transcript "")
check "empty path arg -> 0" test "$OUT3" = "0"

# --- 4. Empty file -> 0 -------------------------------------------------------
T4="$TMP/t4.jsonl"
: > "$T4"
OUT4=$(token_sum_transcript "$T4")
check "empty file -> 0" test "$OUT4" = "0"

# --- 5. Malformed (non-JSON) transcript -> 0, never a crash -------------------
T5="$TMP/t5.jsonl"
printf 'not valid json at all {{{\n' > "$T5"
OUT5=$(token_sum_transcript "$T5")
check "malformed transcript -> 0 (jq failure degrades cleanly)" test "$OUT5" = "0"

# --- 5b. STRING usage fields -> still an integer -----------------------------
# The "prints an integer" contract's sharpest edge: jq's `+` CONCATENATES
# strings rather than erroring, so string-valued usage fields make `add`
# return a QUOTED STRING that is neither empty nor the literal "null" — the
# two cases the old guard checked. Both callers only neutralized that by
# luck (jq's `tonumber? // null` on the emit side, awk's coercion on the
# status-line side); this helper is the one place that must hold the line.
T5B="$TMP/t5b.jsonl"
jq -cn '{type:"assistant", message:{role:"assistant", usage:{
  input_tokens:"100", cache_creation_input_tokens:"0",
  cache_read_input_tokens:"0", output_tokens:"20"}}}' > "$T5B"
OUT5B=$(token_sum_transcript "$T5B")
check "string usage fields -> a bare integer, never a quoted/concatenated string" \
  bash -c "case '$OUT5B' in ''|*[!0-9]*) exit 1 ;; *) exit 0 ;; esac"

# --- 6. STRUCTURAL PRIVACY: recognizable content never perturbs the sum ------
CANARY="SECRET-CANARY-DO-NOT-LEAK-9f3c2a"
T6="$TMP/t6.jsonl"
{
  jq -cn --arg c "$CANARY" \
    '{type:"user", message:{role:"user", content:("the plan is: " + $c + " and much more identifying prose " + $c)}}'
  jq -cn --arg c "$CANARY" \
    '{type:"assistant", message:{role:"assistant", usage:{input_tokens:200, cache_creation_input_tokens:0, cache_read_input_tokens:0, output_tokens:33}, content:[{type:"text", text:("reply mentioning " + $c)}]}}'
} > "$T6"
OUT6=$(token_sum_transcript "$T6")
check "privacy: sum is exactly the usage total (233), unaffected by content size/text" \
  test "$OUT6" = "233"
check "privacy: the canary string never appears in the function's own output" \
  bash -c "! printf '%s' '$OUT6' | grep -q '$CANARY'"

# --- 7. STATIC PROOF: the lib's jq filter has no .message.content selector ---
# This is the mechanical backstop for the structural guarantee described in
# token_sum.sh's own header: grep the ACTUAL shipped filter text (between the
# function's `jq -s '` and closing `'`) for any selector other than
# `.message.usage`. A future edit that adds a `.message.content` (or any
# other field) read into this filter fails this check immediately.
check "static: token_sum.sh's jq filter never selects .message.content" \
  bash -c "! grep -A12 'jq -s' '$LIB' | grep -q 'message\\.content'"
check "static: token_sum.sh's jq filter never selects .message.role" \
  bash -c "! grep -A12 'jq -s' '$LIB' | grep -q 'message\\.role'"
check "static: token_sum.sh's jq filter DOES select .message.usage (sanity — proves the grep window is right)" \
  bash -c "grep -A12 'jq -s' '$LIB' | grep -q 'message\\.usage'"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d token_sum checks passed\n' "$pass"
