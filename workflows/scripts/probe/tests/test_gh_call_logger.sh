#!/usr/bin/env bash
#
# Tests for gh-call-logger.sh (F#988, the v2 TIMED shim). Zero network: every
# case runs the shim against a FAKE real tool on an isolated PATH, never a real
# gh/git-bug binary. Asserts the observable contract the measurement round
# depends on:
#   1. a v2 row lands with the 10-column schema and the injected fields;
#   2. dur_ms reflects the child's wall time (ms resolution when perl present);
#   3. the exit code is propagated verbatim — success, arbitrary code, and a
#      128+N signal death (Ctrl-C -> 130);
#   4. GH_CALL_LOG=0 is a zero-overhead passthrough that logs NOTHING but still
#      runs the real tool;
#   5. GH_CALL_CONTEXT / GH_CALL_OP land in their columns;
#   6. BASENAME-GENERIC: installed as `git-bug`, it logs tool=git-bug and execs
#      the real git-bug (the free after-side instrument);
#   7. an arg containing a newline can never split a row (args sanitized, last);
#   8. the log rotates to <log>.1 past the size cap.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM_SRC="$HERE/../../gh-call-logger.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
[ -f "$SHIM_SRC" ] || fail "shim source not found at $SHIM_SRC"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-call-logger-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture layout ---------------------------------------------------------
# shimbin/<name>  : a COPY of the shim, invoked by explicit path so $0's basename
#                   is the install name (gh or git-bug) exactly as in production.
# realbin/<name>  : the FAKE "real" tool the shim resolves off PATH (first match
#                   that is not the shim itself, by inode).
SHIMBIN="$WORK/shimbin"; REALBIN="$WORK/realbin"
mkdir -p "$SHIMBIN" "$REALBIN"

# Fake real tool: sleeps ~50ms, echoes markers to stdout+stderr, and exits with
# whatever FAKE_EXIT says (default 0). FAKE_EXIT=signal -> kill self with SIGINT.
make_fake() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
sleep 0.05
echo "real-stdout $*"
echo "real-stderr" >&2
case "${FAKE_EXIT:-0}" in
  signal) kill -INT $$; sleep 1 ;;   # die by SIGINT -> parent sees 130
  *) exit "${FAKE_EXIT:-0}" ;;
esac
EOF
  chmod +x "$path"
}

# Install the shim under a given tool name and run it. Uses a minimal PATH so the
# ONLY <name> the shim can resolve as "real" is our fake (never the machine's real
# gh or an installed shim copy). Logs to a per-call file we assert on.
run_shim() {  # <toolname> <logfile> -- <args...>
  local name="$1" logf="$2"; shift 2; [ "$1" = "--" ] && shift
  cp "$SHIM_SRC" "$SHIMBIN/$name"; chmod +x "$SHIMBIN/$name"
  make_fake "$REALBIN/$name"
  GH_CALL_LOG_FILE="$logf" \
  PATH="$REALBIN:/usr/bin:/bin" \
    "$SHIMBIN/$name" "$@"
}

nfields() { awk -F'\t' 'END{print NF}' "$1"; }
field()   { awk -F'\t' -v c="$2" 'END{print $c}' "$1"; }  # last row, column c

# --- 1 + 2: row shape, fields, duration -------------------------------------
L="$WORK/log1.tsv"
out="$(run_shim gh "$L" -- issue list --repo o/r)" || fail "shim exit nonzero on success path"
echo "$out" | grep -q "real-stdout issue list --repo o/r" || fail "real stdout not passed through"
[ -f "$L" ] || fail "no log written"
[ "$(wc -l <"$L")" -eq 1 ] || fail "expected exactly 1 row"
[ "$(nfields "$L")" -eq 10 ] || fail "expected 10 columns, got $(nfields "$L")"
[ "$(field "$L" 3)" = "0" ] || fail "exit column should be 0, got $(field "$L" 3)"
[ "$(field "$L" 6)" = "gh" ] || fail "tool column should be gh, got $(field "$L" 6)"
[ "$(field "$L" 10)" = "issue list --repo o/r" ] || fail "args column wrong: $(field "$L" 10)"
dur="$(field "$L" 2)"
[ "$dur" -ge 0 ] 2>/dev/null || fail "dur_ms not a non-negative integer: $dur"
if [ -x /usr/bin/perl ]; then
  [ "$dur" -ge 40 ] || fail "dur_ms ($dur) should reflect the ~50ms child sleep"
fi
echo "  [ok] v2 row shape, tool, args, dur_ms"

# --- 3a: arbitrary exit code propagation ------------------------------------
L="$WORK/log2.tsv"; code=0
FAKE_EXIT=42 run_shim gh "$L" -- api foo || code=$?
[ "$code" -eq 42 ] || fail "exit code not propagated (got $code, want 42)"
[ "$(field "$L" 3)" = "42" ] || fail "logged exit should be 42, got $(field "$L" 3)"
echo "  [ok] arbitrary exit-code propagation (42)"

# --- 3b: signal death -> 130 ------------------------------------------------
L="$WORK/log3.tsv"; code=0
FAKE_EXIT=signal run_shim gh "$L" -- pr view || code=$?
[ "$code" -eq 130 ] || fail "SIGINT death not propagated as 130 (got $code)"
[ "$(field "$L" 3)" = "130" ] || fail "logged exit should be 130, got $(field "$L" 3)"
echo "  [ok] signal death propagated as 130"

# --- 4: GH_CALL_LOG=0 passthrough, no row -----------------------------------
L="$WORK/log4.tsv"
out="$(GH_CALL_LOG=0 run_shim gh "$L" -- issue list)" || fail "GH_CALL_LOG=0 path exited nonzero"
echo "$out" | grep -q "real-stdout issue list" || fail "GH_CALL_LOG=0 did not run real tool"
[ ! -f "$L" ] || fail "GH_CALL_LOG=0 must not write a log row"
echo "  [ok] GH_CALL_LOG=0 zero-overhead passthrough, no row"

# --- 5: context + op attribution --------------------------------------------
L="$WORK/log5.tsv"
GH_CALL_CONTEXT=funnel-tick GH_CALL_OP="board:_board_item_list_fresh" \
  run_shim gh "$L" -- issue list >/dev/null || fail "attribution run failed"
[ "$(field "$L" 7)" = "funnel-tick" ] || fail "context column wrong: $(field "$L" 7)"
[ "$(field "$L" 8)" = "board:_board_item_list_fresh" ] || fail "op column wrong: $(field "$L" 8)"
echo "  [ok] GH_CALL_CONTEXT + GH_CALL_OP columns"

# --- 6: basename-generic (git-bug) ------------------------------------------
L="$WORK/log6.tsv"
out="$(run_shim git-bug "$L" -- ls)" || fail "git-bug shim exit nonzero"
echo "$out" | grep -q "real-stdout ls" || fail "git-bug real tool not run"
[ "$(field "$L" 6)" = "git-bug" ] || fail "tool column should be git-bug, got $(field "$L" 6)"
echo "  [ok] basename-generic: installed as git-bug logs+dispatches git-bug"

# --- 7: newline in an arg can never split a row -----------------------------
L="$WORK/log7.tsv"
run_shim gh "$L" -- api -f query="$(printf 'line1\nline2')" >/dev/null || fail "newline-arg run failed"
[ "$(wc -l <"$L")" -eq 1 ] || fail "a newline in an arg split the row (got $(wc -l <"$L") lines)"
[ "$(nfields "$L")" -eq 10 ] || fail "newline arg changed column count"
echo "  [ok] newline in arg sanitized (single 10-col row)"

# --- 8: rotation past the size cap ------------------------------------------
L="$WORK/log8.tsv"
GH_CALL_LOG_MAX_BYTES=10 run_shim gh "$L" -- one >/dev/null || fail "rotation run 1 failed"
GH_CALL_LOG_MAX_BYTES=10 run_shim gh "$L" -- two >/dev/null || fail "rotation run 2 failed"
[ -f "$L.1" ] || fail "log did not rotate to $L.1 past the cap"
echo "  [ok] size-cap rotation to <log>.1"

echo "PASS: gh-call-logger v2 shim"
