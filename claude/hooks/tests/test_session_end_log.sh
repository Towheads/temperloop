#!/usr/bin/env bash
# Tests for session-end-log.sh (foundation #984).
#
# Synthetic transcript fixtures in a tmpdir — no real sessions, zero network.
# Feeds the hook SessionEnd JSON on stdin and asserts the stub on disk:
#   - basic: user+assistant transcript              -> stub with both turns
#   - rollover: larger sibling jsonl sharing the first top-level record
#     timestamp (a compact rollover copies history with original timestamps)
#     -> stub dumped from the continuation, transcript_given: frontmatter
#   - decoy: a larger sibling with a DIFFERENT first timestamp is NOT followed
#   - dedupe: an existing stub for the same session id is overwritten in
#     place, never duplicated
#   - no user turns -> no stub;  EVAL_RUN set -> no stub
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

run_hook() { # <session_id> <transcript> <cwd> [EVAL_RUN]
  jq -cn --arg s "$1" --arg t "$2" --arg c "$3" \
    '{session_id:$s, transcript_path:$t, cwd:$c}' \
    | EVAL_RUN="${4:-}" bash "$HOOK"
}

user_rec() { # <ts> <text>
  jq -cn --arg ts "$1" --arg x "$2" \
    '{type:"user", timestamp:$ts, message:{role:"user", content:$x}}'
}
asst_rec() { # <ts> <text>
  jq -cn --arg ts "$1" --arg x "$2" \
    '{type:"assistant", timestamp:$ts, message:{role:"assistant", model:"test-model", content:[{type:"text", text:$x}]}}'
}

only_stub() { # <cwd> <project> <id8>  -> prints the single matching stub path
  local matches=("$1"/.mind/*-"$2"-"$3".md)
  [ "${#matches[@]}" -eq 1 ] && [ -f "${matches[0]}" ] || return 1
  printf '%s' "${matches[0]}"
}

TS0="2026-07-03T22:44:52.064Z"

# --- 1. Basic: user+assistant transcript -> stub with both turns ------------
CWD1="$TMP/proj1"; TD1="$TMP/t1"; mkdir -p "$CWD1" "$TD1"
TR1="$TD1/aaaa1111-0000-0000-0000-000000000000.jsonl"
{ echo '{"type":"mode","mode":"normal"}'
  user_rec "$TS0" "hello basic"
  asst_rec "2026-07-03T22:44:53.000Z" "reply basic"
} > "$TR1"
run_hook "aaaa1111-0000-0000-0000-000000000000" "$TR1" "$CWD1"

STUB1=$(only_stub "$CWD1" proj1 aaaa1111) || STUB1=""
check "basic: exactly one stub written" test -n "$STUB1"
check "basic: stub carries user turn" grep -q "hello basic" "$STUB1"
check "basic: stub carries assistant turn" grep -q "reply basic" "$STUB1"
check "basic: no transcript_given when no rollover" \
  bash -c "! grep -q '^transcript_given:' '$STUB1'"

# --- 2. Rollover: follow to the larger same-first-timestamp sibling ---------
CWD2="$TMP/proj2"; TD2="$TMP/t2"; mkdir -p "$CWD2" "$TD2"
ORIG="$TD2/bbbb2222-0000-0000-0000-000000000000.jsonl"
CONT="$TD2/cccc3333-0000-0000-0000-000000000000.jsonl"
DECOY="$TD2/dddd9999-0000-0000-0000-000000000000.jsonl"
# Original: preamble (no top-level timestamp) + first half, then stops growing.
{ echo '{"type":"last-prompt","sessionId":"bbbb2222"}'
  user_rec "$TS0" "hello rollover"
  asst_rec "2026-07-03T22:44:53.000Z" "first-half reply"
} > "$ORIG"
# Continuation: DIFFERENT preamble (incl. a nested timestamp that must be
# ignored), full copied history with ORIGINAL timestamps, plus the tail.
{ echo '{"type":"custom-title","customTitle":"loop"}'
  echo '{"type":"file-history-snapshot","snapshot":{"timestamp":"2026-07-04T01:37:17.201Z"}}'
  user_rec "$TS0" "hello rollover"
  asst_rec "2026-07-03T22:44:53.000Z" "first-half reply"
  asst_rec "2026-07-04T06:10:00.000Z" "second-half tail after the compact rollover boundary"
} > "$CONT"
# Decoy: even larger, but a different first timestamp -> must NOT be followed.
{ user_rec "2026-07-01T00:00:00.000Z" "unrelated session"
  asst_rec "2026-07-01T00:00:01.000Z" "unrelated padding unrelated padding unrelated padding unrelated padding"
} > "$DECOY"
run_hook "bbbb2222-0000-0000-0000-000000000000" "$ORIG" "$CWD2"

STUB2=$(only_stub "$CWD2" proj2 bbbb2222) || STUB2=""
check "rollover: exactly one stub, keyed by the ORIGINAL session id" test -n "$STUB2"
check "rollover: stub carries the post-rollover tail" \
  grep -q "second-half tail" "$STUB2"
check "rollover: transcript: points at the continuation" \
  grep -q "^transcript: $CONT" "$STUB2"
check "rollover: transcript_given: preserves the handed-in path" \
  grep -q "^transcript_given: $ORIG" "$STUB2"
check "rollover: larger different-timestamp decoy NOT followed" \
  bash -c "! grep -q 'unrelated session' '$STUB2'"

# --- 3. Dedupe: an existing stub for the session id is overwritten in place -
CWD3="$TMP/proj3"; TD3="$TMP/t3"; mkdir -p "$CWD3/.mind" "$TD3"
TR3="$TD3/eeee5555-0000-0000-0000-000000000000.jsonl"
OLD_STUB="$CWD3/.mind/2020-01-01-0000-proj3-eeee5555.md"
printf 'OLD STUB CONTENT\n' > "$OLD_STUB"
{ user_rec "$TS0" "hello dedupe"
  asst_rec "2026-07-03T22:44:53.000Z" "reply dedupe"
} > "$TR3"
run_hook "eeee5555-0000-0000-0000-000000000000" "$TR3" "$CWD3"

STUB3=$(only_stub "$CWD3" proj3 eeee5555) || STUB3=""
check "dedupe: still exactly one stub for the session id" test -n "$STUB3"
check "dedupe: the pre-existing filename was reused" test "$STUB3" = "$OLD_STUB"
check "dedupe: content was replaced by the fresh dump" grep -q "hello dedupe" "$STUB3"
check "dedupe: old content gone" bash -c "! grep -q 'OLD STUB CONTENT' '$STUB3'"

# --- 4. No user turns -> no stub ---------------------------------------------
CWD4="$TMP/proj4"; TD4="$TMP/t4"; mkdir -p "$CWD4" "$TD4"
TR4="$TD4/ffff6666-0000-0000-0000-000000000000.jsonl"
asst_rec "$TS0" "assistant only" > "$TR4"
run_hook "ffff6666-0000-0000-0000-000000000000" "$TR4" "$CWD4"
check "no user turns: no stub written" \
  bash -c "! ls '$CWD4'/.mind/*-proj4-ffff6666.md"

# --- 5. EVAL_RUN suppression -> no stub --------------------------------------
CWD5="$TMP/proj5"; TD5="$TMP/t5"; mkdir -p "$CWD5" "$TD5"
TR5="$TD5/abab7777-0000-0000-0000-000000000000.jsonl"
{ user_rec "$TS0" "hello eval"
  asst_rec "2026-07-03T22:44:53.000Z" "reply eval"
} > "$TR5"
run_hook "abab7777-0000-0000-0000-000000000000" "$TR5" "$CWD5" 1
check "EVAL_RUN: no stub written" \
  bash -c "! ls '$CWD5'/.mind/*-proj5-abab7777.md 2>/dev/null"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d session-end-log checks passed\n' "$pass"
