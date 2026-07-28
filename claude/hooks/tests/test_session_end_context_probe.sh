#!/usr/bin/env bash
# Tests for session-end-log.sh's realized-session-context probe emit
# (temperloop#828, epic #810) — the SessionEnd-hook-seam call site for
# workflows/scripts/emit-session-context.sh. Sibling of test_session_end_log.sh
# (the stub-writing behavior), scoped to just the new emit call.
#
# Synthetic transcript fixtures in a tmpdir — no real sessions, zero network.
#   - opt-out (default): SESSION_CONTEXT_RAW_ENABLED unset -> no
#     session-context-*.jsonl file appears anywhere, ever (stranger-safe default)
#   - opt-in: SESSION_CONTEXT_RAW_ENABLED=1 -> exactly one record appended,
#     with the CORRECT token sum, context_window fields passed through
#     verbatim from the hook's stdin JSON, and session_id/cwd/project set
#   - SEAM CONTRACT: on a compaction rollover, the emitted record's token
#     sum reflects the CONTINUATION transcript (the resolved live end), not
#     the stale original path the hook was handed — proving this emit sits
#     at the already-resolved seam rather than re-deriving the path itself
#   - EVAL_RUN suppression: no record even with the gate on (the hook's
#     eval-guard exits before reaching the emit block at all)
#   - STRUCTURAL PRIVACY: a transcript containing recognizable prose content
#     never leaks into the emitted record
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../session-end-log.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
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

# <session_id> <transcript> <cwd> <raw_dir> [enabled] [cw_size] [cw_remaining] [EVAL_RUN]
run_hook() {
  local sid="$1" t="$2" c="$3" rawdir="$4" enabled="${5:-}" cw_size="${6:-}" cw_rem="${7:-}" eval_run="${8:-}"
  jq -cn --arg s "$sid" --arg t "$t" --arg c "$c" --arg cws "$cw_size" --arg cwr "$cw_rem" '
    {session_id:$s, transcript_path:$t, cwd:$c}
    + (if ($cws == "" and $cwr == "") then {}
       else { context_window: (
                (if $cws == "" then {} else {context_window_size: ($cws|tonumber)} end)
                + (if $cwr == "" then {} else {remaining_percentage: ($cwr|tonumber)} end)
              ) }
       end)
  ' \
    | SESSION_CONTEXT_RAW_ENABLED="$enabled" SESSION_CONTEXT_RAW_DIR="$rawdir" EVAL_RUN="$eval_run" bash "$HOOK"
}

user_rec() { jq -cn --arg ts "$1" --arg x "$2" '{type:"user", timestamp:$ts, message:{role:"user", content:$x}}'; }
asst_rec_usage() { # <ts> <text> <input> <cache_creation> <cache_read> <output>
  jq -cn --arg ts "$1" --arg x "$2" --argjson i "$3" --argjson cc "$4" --argjson cr "$5" --argjson o "$6" \
    '{type:"assistant", timestamp:$ts, message:{role:"assistant", model:"test-model", content:[{type:"text", text:$x}], usage:{input_tokens:$i, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr, output_tokens:$o}}}'
}

TS0="2026-07-27T10:00:00.000Z"

# --- 1. Opt-out (default): no record anywhere, even with a rich transcript --
CWD1="$TMP/proj1"; TD1="$TMP/t1"; RAW1="$TMP/raw1"; mkdir -p "$CWD1" "$TD1"
TR1="$TD1/aaaa1111-0000-0000-0000-000000000000.jsonl"
{ user_rec "$TS0" "hello"
  asst_rec_usage "2026-07-27T10:00:01Z" "reply" 100 0 0 20
} > "$TR1"
run_hook "aaaa1111-0000-0000-0000-000000000000" "$TR1" "$CWD1" "$RAW1" ""
check "opt-out (default): no session-context file created" \
  bash -c "[ ! -d '$RAW1' ] || [ -z \"\$(ls -A '$RAW1' 2>/dev/null)\" ]"

# --- 2. Opt-in: exactly one correct record, context_window passed through --
CWD2="$TMP/proj2"; TD2="$TMP/t2"; RAW2="$TMP/raw2"; mkdir -p "$CWD2" "$TD2"
TR2="$TD2/bbbb2222-0000-0000-0000-000000000000.jsonl"
{ user_rec "$TS0" "hello opt-in"
  asst_rec_usage "2026-07-27T10:00:01Z" "reply opt-in" 1000 100 50 25
} > "$TR2"
run_hook "bbbb2222-0000-0000-0000-000000000000" "$TR2" "$CWD2" "$RAW2" "1" "200000" "42.5"

RAWFILE2="$RAW2/session-context-${MONTH}.jsonl"
check "opt-in: session-context file created" test -f "$RAWFILE2"
check "opt-in: exactly one record" test "$(wc -l < "$RAWFILE2" | tr -d ' ')" = "1"
check "opt-in: transcript_tokens_total correct (1175)" \
  bash -c "jq -r '.transcript_tokens_total' '$RAWFILE2' | grep -qx 1175"
check "opt-in: context_window_size passed through verbatim" \
  bash -c "jq -r '.context_window_size' '$RAWFILE2' | grep -qx 200000"
check "opt-in: context_window_remaining_pct passed through verbatim" \
  bash -c "jq -r '.context_window_remaining_pct' '$RAWFILE2' | grep -qx 42.5"
check "opt-in: session_id correct" \
  bash -c "jq -r '.session_id' '$RAWFILE2' | grep -qx bbbb2222-0000-0000-0000-000000000000"
check "opt-in: cwd correct" \
  bash -c "jq -r '.cwd' '$RAWFILE2' | grep -qF '$CWD2'"
check "opt-in: project (cwd basename) correct" \
  bash -c "jq -r '.project' '$RAWFILE2' | grep -qx proj2"

# --- 3. SEAM CONTRACT: rollover — the emitted sum reflects the CONTINUATION -
CWD3="$TMP/proj3"; TD3="$TMP/t3"; RAW3="$TMP/raw3"; mkdir -p "$CWD3" "$TD3"
ORIG="$TD3/cccc3333-0000-0000-0000-000000000000.jsonl"
CONT="$TD3/dddd4444-0000-0000-0000-000000000000.jsonl"
# Original: preamble + first half (small usage), then stops growing.
{ echo '{"type":"last-prompt","sessionId":"cccc3333"}'
  user_rec "$TS0" "hello rollover"
  asst_rec_usage "2026-07-27T10:00:01Z" "first-half reply" 100 0 0 10
} > "$ORIG"
# Continuation: same first top-level timestamp (TS0), full copied history
# PLUS a tail with substantial additional usage — the whole point of the
# rollover-following contract is that this tail's tokens get counted too.
{ echo '{"type":"custom-title","customTitle":"loop"}'
  user_rec "$TS0" "hello rollover"
  asst_rec_usage "2026-07-27T10:00:01Z" "first-half reply" 100 0 0 10
  asst_rec_usage "2026-07-27T10:05:00Z" "second-half tail after the compact rollover boundary" 9000 500 0 490
} > "$CONT"
run_hook "cccc3333-0000-0000-0000-000000000000" "$ORIG" "$CWD3" "$RAW3" "1"

RAWFILE3="$RAW3/session-context-${MONTH}.jsonl"
check "rollover: record created" test -f "$RAWFILE3"
check "rollover: sum reflects the CONTINUATION (110+9990=10100), not just the stale original (110)" \
  bash -c "jq -r '.transcript_tokens_total' '$RAWFILE3' | grep -qx 10100"

# --- 4. EVAL_RUN suppression: no record even with the gate on --------------
CWD4="$TMP/proj4"; TD4="$TMP/t4"; RAW4="$TMP/raw4"; mkdir -p "$CWD4" "$TD4"
TR4="$TD4/eeee5555-0000-0000-0000-000000000000.jsonl"
{ user_rec "$TS0" "hello eval"
  asst_rec_usage "2026-07-27T10:00:01Z" "reply eval" 500 0 0 10
} > "$TR4"
run_hook "eeee5555-0000-0000-0000-000000000000" "$TR4" "$CWD4" "$RAW4" "1" "" "" "1"
check "EVAL_RUN: no session-context file, even with the opt-in gate on" \
  bash -c "[ ! -d '$RAW4' ] || [ -z \"\$(ls -A '$RAW4' 2>/dev/null)\" ]"

# --- 5. STRUCTURAL PRIVACY: recognizable content never leaks into the record
CWD5="$TMP/proj5"; TD5="$TMP/t5"; RAW5="$TMP/raw5"; mkdir -p "$CWD5" "$TD5"
TR5="$TD5/ffff6666-0000-0000-0000-000000000000.jsonl"
CANARY="SECRET-CANARY-DO-NOT-LEAK-b81f04"
{ user_rec "$TS0" "plan details: $CANARY $CANARY $CANARY repeated for length and realism"
  asst_rec_usage "2026-07-27T10:00:01Z" "reply mentioning $CANARY at length, quoting it back verbatim: $CANARY" 300 0 0 60
} > "$TR5"
run_hook "ffff6666-0000-0000-0000-000000000000" "$TR5" "$CWD5" "$RAW5" "1" "150000" "10"

RAWFILE5="$RAW5/session-context-${MONTH}.jsonl"
check "privacy: record created" test -f "$RAWFILE5"
check "privacy: transcript_tokens_total correct (360) despite recognizable prose in the transcript" \
  bash -c "jq -r '.transcript_tokens_total' '$RAWFILE5' | grep -qx 360"
check "privacy: the canary string never appears anywhere in the emitted record" \
  bash -c "! grep -q '$CANARY' '$RAWFILE5'"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d session-end context-probe checks passed\n' "$pass"
