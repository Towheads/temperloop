#!/usr/bin/env bash
# Tests for session-end-read-summary.sh (temperloop#237, "SessionEnd read
# one-liner"), the SessionEnd hook that tallies "knowledge store: N reads,
# M searches" for the ending session from the script-plane read log
# (workflows/scripts/lib/knowledge_store.sh's _ks_read_log_path()/
# ks__read_log_emit, temperloop#229).
#
# Synthetic read-log fixtures in a tmpdir — no real ~/.local/state, no
# network, no vault. Feeds the hook SessionEnd JSON on stdin (KS_LIB_DIR
# points the hook at THIS checkout's workflows/scripts/lib) and asserts the
# stdout one-liner:
#   - basic: 2 reads + 1 write + 1 list + 1 search for the session -> "4 reads, 1 searches"
#   - other-session lines present in the same log are excluded from the tally
#   - zero activity: log exists, readable, but no lines for this session
#     -> explicit "0 reads, 0 searches" line
#   - fail-open: log file absent -> silent (no stdout at all), exit 0
#   - fail-open: KNOWLEDGE_READ_LOG unset AND KS_LIB_DIR unresolvable
#     (knowledge_store.sh not found) -> silent, exit 0
#   - fail-open: no session_id on stdin -> silent, exit 0
#   - EVAL_RUN set -> silent, exit 0 (even with real matching log lines)
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../session-end-read-summary.sh"
LIB_DIR="$(cd "$HERE/../../../workflows/scripts/lib" && pwd)"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
[ -f "$LIB_DIR/knowledge_store.sh" ] || { echo "FATAL: knowledge_store.sh not found at $LIB_DIR" >&2; exit 1; }
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

DOT="$(printf '\xc2\xb7')"
SEP=" ${DOT} "

log_line() { # <session-id> <plane> <op> <doc>
  printf '2026-07-10T12:00:00Z%s%s%s%s%s%s%s%s\n' \
    "$SEP" "$1" "$SEP" "$2" "$SEP" "$3" "$SEP" "$4"
}

run_hook() { # <session_id-or-empty> <log-path> [EVAL_RUN]
  local sid="$1" log="$2" eval_run="${3:-}"
  local json
  if [ -n "$sid" ]; then
    json="$(jq -cn --arg s "$sid" '{session_id:$s}')"
  else
    json='{}'
  fi
  printf '%s' "$json" \
    | KS_LIB_DIR="$LIB_DIR" KNOWLEDGE_READ_LOG="$log" EVAL_RUN="$eval_run" bash "$HOOK"
}

# --- 1. Basic: mixed ops for the session, plus decoy lines for another session --
LOG1="$TMP/log1.log"
{
  log_line "sess-aaaa" "script" "read" "Decisions/foo"
  log_line "sess-aaaa" "script" "write" "Decisions/foo"
  log_line "sess-bbbb" "script" "search" "unrelated other-session query"
  log_line "sess-aaaa" "script" "search" "widget install guide"
  log_line "sess-aaaa" "script" "read" "Decisions/bar"
  log_line "sess-aaaa" "script" "list" "Decisions"
} > "$LOG1"
OUT1="$(run_hook "sess-aaaa" "$LOG1")"
check "basic: exact one-liner (4 reads: read+write+read+list; 1 search)" \
  test "$OUT1" = "knowledge store: 4 reads, 1 searches"

# --- 2. Other-session lines never leak into the tally --------------------
LOG2="$TMP/log2.log"
{
  log_line "sess-cccc" "script" "read" "Decisions/foo"
  log_line "sess-cccc" "script" "search" "q"
} > "$LOG2"
OUT2="$(run_hook "sess-dddd" "$LOG2")"
check "other-session: a log with only foreign-session lines -> explicit zero" \
  test "$OUT2" = "knowledge store: 0 reads, 0 searches"

# --- 3. Zero activity: log exists/readable, no lines at all --------------
LOG3="$TMP/log3.log"
: > "$LOG3"
OUT3="$(run_hook "sess-eeee" "$LOG3")"
check "zero-activity: empty log -> explicit zero one-liner" \
  test "$OUT3" = "knowledge store: 0 reads, 0 searches"

# --- 4. Fail-open: log file does not exist --------------------------------
LOG4="$TMP/does-not-exist.log"
OUT4="$(run_hook "sess-ffff" "$LOG4")"
check "fail-open: missing log file -> no stdout at all" test -z "$OUT4"

# --- 5. Fail-open: knowledge_store.sh unresolvable ------------------------
LOG5="$TMP/log5.log"
log_line "sess-gggg" "script" "read" "Decisions/foo" > "$LOG5"
OUT5="$(printf '%s' "$(jq -cn --arg s "sess-gggg" '{session_id:$s}')" \
  | KS_LIB_DIR="$TMP/no-such-lib-dir" KNOWLEDGE_READ_LOG="$LOG5" bash "$HOOK")"
check "fail-open: KS_LIB_DIR pointing nowhere -> no stdout, hook still exits cleanly" \
  test -z "$OUT5"

# --- 6. Fail-open: no session_id on stdin ---------------------------------
LOG6="$TMP/log6.log"
log_line "sess-hhhh" "script" "read" "Decisions/foo" > "$LOG6"
OUT6="$(run_hook "" "$LOG6")"
check "fail-open: empty stdin JSON (no session_id) -> no stdout" test -z "$OUT6"

# --- 7. EVAL_RUN suppression ----------------------------------------------
LOG7="$TMP/log7.log"
log_line "sess-iiii" "script" "search" "q" > "$LOG7"
OUT7="$(run_hook "sess-iiii" "$LOG7" 1)"
check "EVAL_RUN: suppressed even with real matching log lines" test -z "$OUT7"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d session-end-read-summary checks passed\n' "$pass"
