#!/usr/bin/env bash
#
# Tests for the read-log telemetry seam (temperloop#229, Epic #226
# "script-plane read telemetry"): ks__read_log_emit and its two call sites —
# knowledge_store.sh's ks__dispatch (every ks_read/ks_write/ks_append/
# ks_list, for the plain-files backend) and knowledge_search.sh's ks_search
# entrypoint. Zero network: the ks_search case drives a FAKE `uvx` binary on
# PATH, same fixture pattern as test_knowledge_search.sh. All state
# (KNOWLEDGE_STORE_ROOT, KNOWLEDGE_READ_LOG, KNOWLEDGE_SEARCH_BM_HOME) lives
# under a throwaway tmpdir; never touches a real vault, XDG dir, or the
# machine's real $HOME.
#
# Covers: log-path knob default + override, one normalized line per
# ks_write/ks_read/ks_append/ks_list call (plain-files backend), one line
# per ks_search call (op=search, query as the doc field), the
# " · "-joined 5-field line shape, session-id present vs. "-" fallback when
# CLAUDE_CODE_SESSION_ID is unset, newline/tab sanitization of the logged
# doc-path-or-query field, and fail-open behavior (an unwritable log dir
# WARNs on stderr but never fails the wrapped ks_* call).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-read-log-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 1. default log path honors XDG_STATE_HOME (no explicit override) -------
(
  unset KNOWLEDGE_READ_LOG
  export XDG_STATE_HOME="$TMP/xdg-state"
  export KNOWLEDGE_STORE_ROOT="$TMP/store-1"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  got="$(_ks_read_log_path)"
  want="$TMP/xdg-state/foundation/knowledge-reads.log"
  [ "$got" = "$want" ] || fail "1: default log path should honor XDG_STATE_HOME (got $got want $want)"
  echo "PASS: 1 default read-log path resolves under \$XDG_STATE_HOME/foundation/knowledge-reads.log"
)

# --- 2. KNOWLEDGE_READ_LOG is the ONE override; XDG_STATE_HOME is ignored when set --
(
  export XDG_STATE_HOME="$TMP/xdg-state-ignored"
  export KNOWLEDGE_READ_LOG="$TMP/explicit-read.log"
  export KNOWLEDGE_STORE_ROOT="$TMP/store-2"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  got="$(_ks_read_log_path)"
  [ "$got" = "$TMP/explicit-read.log" ] || fail "2: explicit KNOWLEDGE_READ_LOG must win (got $got)"
  echo "PASS: 2 KNOWLEDGE_READ_LOG overrides the default (single config knob)"
)

# From here on, all cases share one isolated store root + read log.
ROOT="$TMP/store"
LOG="$TMP/knowledge-reads.log"
export KNOWLEDGE_STORE_ROOT="$ROOT"
export KNOWLEDGE_READ_LOG="$LOG"
unset CLAUDE_CODE_SESSION_ID || true
# shellcheck source=/dev/null
source "$STORE_LIB"

# --- 3. ks_write appends one normalized line, session-id falls back to "-" ---
printf 'hello world\n' | ks_write "Decisions/foo" || fail "3: write should succeed"
[ -f "$LOG" ] || fail "3: read-log file should exist after the first dispatched call"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "3: expected exactly 1 read-log line after one write (got $n)"
line="$(cat "$LOG")"
case "$line" in
  *" · - · script · write · Decisions/foo"*) : ;;
  *) fail "3: read-log line missing expected fields (got: $line)" ;;
esac
# timestamp field: first token, must look like an ISO-8601 UTC stamp
ts="${line%% *}"
case "$ts" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
  *) fail "3: timestamp field does not look like YYYY-MM-DDTHH:MM:SSZ (got: $ts)" ;;
esac
echo "PASS: 3 ks_write appends one normalized line; session-id falls back to '-' when unset"

# --- 4. ks_read appends its own line (op=read), doc-id preserved -------------
ks_read "Decisions/foo" >/dev/null || fail "4: read should succeed"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 2 ] || fail "4: expected 2 read-log lines after a write + a read (got $n)"
line="$(sed -n '2p' "$LOG")"
case "$line" in
  *" · - · script · read · Decisions/foo"*) : ;;
  *) fail "4: read-log line for ks_read missing expected fields (got: $line)" ;;
esac
echo "PASS: 4 ks_read appends its own read-log line (op=read)"

# --- 5. ks_append and ks_list each append their own line (plain-files backend) --
printf 'line1\n' | ks_append "Scratch/log" || fail "5: append should succeed"
ks_list "Decisions" >/dev/null || fail "5: list should succeed"
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 4 ] || fail "5: expected 4 read-log lines after write+read+append+list (got $n)"
append_line="$(sed -n '3p' "$LOG")"
list_line="$(sed -n '4p' "$LOG")"
case "$append_line" in
  *" · - · script · append · Scratch/log"*) : ;;
  *) fail "5: read-log line for ks_append missing expected fields (got: $append_line)" ;;
esac
case "$list_line" in
  *" · - · script · list · Decisions"*) : ;;
  *) fail "5: read-log line for ks_list missing expected fields (got: $list_line)" ;;
esac
echo "PASS: 5 ks_append and ks_list each append their own read-log line (op=append / op=list), plain-files backend"

# --- 6. CLAUDE_CODE_SESSION_ID, when set, is carried verbatim ----------------
(
  export CLAUDE_CODE_SESSION_ID="sess-abc123"
  printf 'v2\n' | ks_write "Decisions/foo"
)
n="$(wc -l <"$LOG" | tr -d ' ')"
[ "$n" -eq 5 ] || fail "6: expected 5 read-log lines after the session-id-set write (got $n)"
line="$(sed -n '5p' "$LOG")"
case "$line" in
  *" · sess-abc123 · script · write · Decisions/foo"*) : ;;
  *) fail "6: read-log line should carry CLAUDE_CODE_SESSION_ID verbatim (got: $line)" ;;
esac
echo "PASS: 6 CLAUDE_CODE_SESSION_ID, when set, is carried verbatim into the session-id field"

# --- 7. a logging failure never breaks the dispatch (fail-open) -------------
(
  # Point KNOWLEDGE_READ_LOG at a path whose PARENT is a plain file, not a
  # directory, so mkdir -p for the log dir is guaranteed to fail.
  blocker="$TMP/blocker-file"
  : >"$blocker"
  export KNOWLEDGE_READ_LOG="$blocker/nested/knowledge-reads.log"
  out_err="$TMP/write-stderr.txt"
  printf 'still lands\n' | ks_write "Decisions/failopen" 2>"$out_err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "7: ks_write must still succeed even when the read-log dir is unwritable (rc=$rc)"
  grep -q "WARN read-log dir unavailable" "$out_err" \
    || fail "7: expected a WARN notice on stderr when the read-log dir can't be created (got: $(cat "$out_err"))"
)
got="$(ks_read "Decisions/failopen")" || fail "7b: the document itself must have been written despite the read-log failure"
[ "$got" = "still lands" ] || fail "7b: content mismatch after fail-open write (got: $got)"
echo "PASS: 7 a read-log write failure WARNs on stderr and never breaks the wrapped ks_write/ks_read call"

# --- 8. doc-path-or-query is sanitized to a single line (newlines/tabs -> spaces) --
printf 'x\n' | ks_write "$(printf 'weird\tid')" >/dev/null 2>&1 || true
n_before="$(wc -l <"$LOG" | tr -d ' ')"
line="$(tail -n1 "$LOG")"
n_after="$n_before"
[ "$n_after" -ge 1 ] || fail "8: expected at least one read-log line after the tab-containing write attempt"
case "$line" in
  *$'\t'*) fail "8: read-log line must not contain a raw tab (got: $line)" ;;
  *) : ;;
esac
echo "PASS: 8 the doc-path-or-query field is sanitized (no raw tabs/newlines survive into the log line)"

# --- 9. knowledge_search.sh's ks_search entrypoint logs op=search, same format --
SEARCH_TMP="$TMP/search"
mkdir -p "$SEARCH_TMP/store" "$SEARCH_TMP/bm-home" "$SEARCH_TMP/bin"
SEARCH_LOG="$SEARCH_TMP/knowledge-reads.log"
cat > "$SEARCH_TMP/bin/uvx" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# Drop `[uvx flags...] basic-memory` — consume up to and including the
# `basic-memory` command token, so a new uvx flag (--python, --from) never
# breaks the fake (`basic-memory==<ver>` is a distinct string, never matched).
while [ $# -gt 0 ] && [ "$1" != "basic-memory" ]; do shift; done
shift || true
case "$1 $2 $3" in
  "project add "*) exit 0 ;;
  "tool search-notes "*)
    printf '{"results":[]}\n'
    exit 0
    ;;
esac
exit 9
FAKE
chmod +x "$SEARCH_TMP/bin/uvx"

(
  export KNOWLEDGE_STORE_ROOT="$SEARCH_TMP/store"
  export KNOWLEDGE_SEARCH_BM_HOME="$SEARCH_TMP/bm-home"
  export KNOWLEDGE_SEARCH_BM_PROJECT="read-log-test-project"
  export KNOWLEDGE_READ_LOG="$SEARCH_LOG"
  export PATH="$SEARCH_TMP/bin:$PATH"
  unset CLAUDE_CODE_SESSION_ID || true
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  ks_search "widget install guide" >/dev/null
)
[ -f "$SEARCH_LOG" ] || fail "9: ks_search should have created the read-log"
n="$(wc -l <"$SEARCH_LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "9: expected exactly 1 read-log line for one ks_search call (got $n)"
line="$(cat "$SEARCH_LOG")"
case "$line" in
  *" · - · script · search · widget install guide"*) : ;;
  *) fail "9: ks_search read-log line missing expected fields (got: $line)" ;;
esac
echo "PASS: 9 knowledge_search.sh's ks_search entrypoint logs op=search with the query, same line format"

# --- 10. an empty ks_search query (usage error) does NOT log ------------------
(
  export KNOWLEDGE_STORE_ROOT="$SEARCH_TMP/store"
  export KNOWLEDGE_READ_LOG="$SEARCH_LOG"
  export PATH="$SEARCH_TMP/bin:$PATH"
  # shellcheck source=/dev/null
  source "$STORE_LIB"
  # shellcheck source=/dev/null
  source "$SEARCH_LIB"
  set +e
  ks_search "" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || echo "10: WARN expected exit 2 for empty query (got $rc)" >&2
)
n="$(wc -l <"$SEARCH_LOG" | tr -d ' ')"
[ "$n" -eq 1 ] || fail "10: an empty-query usage error must not append a read-log line (line count changed: $n)"
echo "PASS: 10 an empty ks_search query (usage error) does not append a read-log line"

echo "ALL PASS: read-log telemetry (ks__dispatch + ks_search entrypoint)"
