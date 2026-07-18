#!/usr/bin/env bash
#
# Tests for workflows/scripts/lib/knowledge_store.sh — the document-I/O
# interface (foundation #771) and its plain-files backend. Zero network, all
# storage under a throwaway tmpdir; never touches a real vault or the
# machine's real XDG data dir.
#
# Covers: root resolution (default + override, ONE knob), doc-id
# normalization (.md append, absolute/".." rejection, empty rejection),
# write/read round-trip, write's default-overwrite vs --no-clobber
# semantics, atomic write (no stray temp file survives), append
# create-or-append semantics, list (empty root, whole-root, prefix-scoped),
# read-missing exit code, and an unknown-backend dispatch error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$HERE/.." && pwd)/knowledge_store.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 1. default root resolution (XDG_DATA_HOME override, no explicit ROOT) ---
(
  unset KNOWLEDGE_STORE_ROOT
  export XDG_DATA_HOME="$TMP/xdg"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root)"
  want="$TMP/xdg/temperloop/knowledge"
  [ "$got" = "$want" ] || fail "1: default root should honor XDG_DATA_HOME (got $got want $want)"
  echo "PASS: 1 default root resolves under \$XDG_DATA_HOME/temperloop/knowledge"
)

# --- 2. default root resolution falls back to \$HOME/.local/share when XDG unset --
(
  unset KNOWLEDGE_STORE_ROOT
  unset XDG_DATA_HOME
  HOME="$TMP/home"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root)"
  want="$TMP/home/.local/share/temperloop/knowledge"
  [ "$got" = "$want" ] || fail "2: fallback root should be \$HOME/.local/share/... (got $got want $want)"
  echo "PASS: 2 default root falls back to \$HOME/.local/share/temperloop/knowledge"
)

# --- 2b. rename window (temperloop#165): an EXISTING store at the legacy
# foundation/ default is still found when nothing exists at the new default —
# with a NOTE on stderr — and a fresh install (neither dir) resolves new. ----
(
  unset KNOWLEDGE_STORE_ROOT
  export XDG_DATA_HOME="$TMP/xdg-legacy"
  mkdir -p "$TMP/xdg-legacy/foundation/knowledge"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root 2>"$TMP/2b-note.txt")"
  want="$TMP/xdg-legacy/foundation/knowledge"
  [ "$got" = "$want" ] || fail "2b: legacy store should be found through the window (got $got want $want)"
  grep -q 'legacy store root' "$TMP/2b-note.txt" || fail "2b: legacy fallback must print a NOTE naming the legacy root"
  grep -q 'v0.16.0' "$TMP/2b-note.txt" || fail "2b: the NOTE must state the removal version (v0.16.0)"
  echo "PASS: 2b legacy foundation/knowledge store found through the rename window, with removal-version NOTE"
)

# --- 2c. rename window: when BOTH defaults exist, the NEW one wins ----------
(
  unset KNOWLEDGE_STORE_ROOT
  export XDG_DATA_HOME="$TMP/xdg-both"
  mkdir -p "$TMP/xdg-both/foundation/knowledge" "$TMP/xdg-both/temperloop/knowledge"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root 2>/dev/null)"
  want="$TMP/xdg-both/temperloop/knowledge"
  [ "$got" = "$want" ] || fail "2c: new default must win when both stores exist (got $got want $want)"
  echo "PASS: 2c new temperloop/knowledge default wins when both exist"
)

# --- 2d. window closed (TEMPERLOOP_LEGACY_WINDOW_CLOSED=1 simulation): the
# legacy store is NOT silently used — resolution goes to the new default and
# a legible NOTE names the stranded legacy store + the migration. -----------
(
  unset KNOWLEDGE_STORE_ROOT
  export XDG_DATA_HOME="$TMP/xdg-closed"
  export TEMPERLOOP_LEGACY_WINDOW_CLOSED=1
  mkdir -p "$TMP/xdg-closed/foundation/knowledge"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root 2>"$TMP/2d-note.txt")"
  want="$TMP/xdg-closed/temperloop/knowledge"
  [ "$got" = "$want" ] || fail "2d: closed window must resolve to the new default (got $got want $want)"
  grep -q 'removed in v0.16.0' "$TMP/2d-note.txt" || fail "2d: closed-window resolution must name the removal legibly"
  grep -q 'KNOWLEDGE_STORE_ROOT' "$TMP/2d-note.txt" || fail "2d: closed-window NOTE must name the migration/override knob"
  echo "PASS: 2d closed window degrades legibly (new default + NOTE naming the stranded legacy store)"
)

# --- 3. KNOWLEDGE_STORE_ROOT is the ONE override; XDG_DATA_HOME is ignored when set --
(
  export XDG_DATA_HOME="$TMP/xdg-ignored"
  export KNOWLEDGE_STORE_ROOT="$TMP/explicit-root"
  # shellcheck source=/dev/null
  source "$LIB"
  got="$(ks_root)"
  [ "$got" = "$TMP/explicit-root" ] || fail "3: explicit KNOWLEDGE_STORE_ROOT must win (got $got)"
  echo "PASS: 3 KNOWLEDGE_STORE_ROOT overrides the default (single config knob)"
)

# From here on, all cases share one isolated store root.
ROOT="$TMP/store"
export KNOWLEDGE_STORE_ROOT="$ROOT"
unset XDG_DATA_HOME || true
# Isolate the read-log (temperloop#229) under the throwaway tmpdir too — every
# ks_write/ks_read/ks_append/ks_list call below goes through ks__read_log_emit
# (knowledge_store.sh); without this override it would default to the real
# machine's $XDG_STATE_HOME/foundation/knowledge-reads.log.
export KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log"
# shellcheck source=/dev/null
source "$LIB"

# --- 4. write + read round-trip; parent dirs auto-created --------------------
printf 'hello world\n' | ks_write "Decisions/foo" || fail "4: write should succeed"
[ -f "$ROOT/Decisions/foo.md" ] || fail "4: write should create Decisions/foo.md (doc-id sans .md)"
got="$(ks_read "Decisions/foo")" || fail "4: read should succeed"
[ "$got" = "hello world" ] || fail "4: round-trip content mismatch (got: $got)"
# reading with explicit .md reaches the same document
got2="$(ks_read "Decisions/foo.md")" || fail "4b: read with explicit .md should succeed"
[ "$got2" = "hello world" ] || fail "4b: .md-suffixed doc-id should reach the same document"
echo "PASS: 4 write/read round-trip + doc-id .md-suffix equivalence"

# --- 5. write default overwrites; no stray temp file survives ----------------
printf 'v2 content\n' | ks_write "Decisions/foo" || fail "5: overwrite should succeed by default"
got="$(ks_read "Decisions/foo")" || fail "5: read after overwrite should succeed"
[ "$got" = "v2 content" ] || fail "5: default write should overwrite (got: $got)"
# mktemp expands XXXXXX to random chars in the write's temp file
# (path.XXXXXX); confirm none of those residues survived the rename.
strays="$(find "$ROOT/Decisions" -maxdepth 1 -name 'foo.md.*' 2>/dev/null || true)"
[ -z "$strays" ] || fail "5: atomic write left a stray temp file: $strays"
echo "PASS: 5 write overwrites by default and leaves no stray temp file"

# --- 6. write --no-clobber refuses an existing doc (exit 3), content untouched --
set +e
printf 'should not land\n' | ks_write "Decisions/foo" --no-clobber
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "6: --no-clobber on existing doc should exit 3 (got $rc)"
got="$(ks_read "Decisions/foo")"
[ "$got" = "v2 content" ] || fail "6: --no-clobber refusal must not touch existing content (got: $got)"
echo "PASS: 6 write --no-clobber refuses to touch an existing doc (exit 3)"

# --- 7. write --no-clobber succeeds for a genuinely new doc -------------------
printf 'brand new\n' | ks_write "Decisions/bar" --no-clobber || fail "7: --no-clobber create should succeed"
got="$(ks_read "Decisions/bar")" || fail "7: read new doc should succeed"
[ "$got" = "brand new" ] || fail "7: content mismatch on new doc (got: $got)"
echo "PASS: 7 write --no-clobber succeeds when the doc does not yet exist"

# --- 8. append creates when absent, then appends on subsequent calls ---------
printf 'line1\n' | ks_append "Scratch/log" || fail "8: append-create should succeed"
printf 'line2\n' | ks_append "Scratch/log" || fail "8: append-existing should succeed"
got="$(ks_read "Scratch/log")" || fail "8: read appended doc should succeed"
want="$(printf 'line1\nline2')"
[ "$got" = "$want" ] || fail "8: append semantics wrong (got: [$got] want: [$want])"
echo "PASS: 8 append creates on first call, appends on subsequent calls"

# --- 9. read a missing document -> exit 1, nothing on stdout -----------------
set +e
out="$(ks_read "Nope/does-not-exist" 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "9: read of missing doc should exit 1 (got $rc)"
[ -z "$out" ] || fail "9: read of missing doc should print nothing to stdout (got: $out)"
echo "PASS: 9 read of a missing document exits 1 with no stdout"

# --- 10. doc-id validation: empty / absolute / ".." all exit 2 ---------------
set +e
ks_read "" 2>/dev/null; rc_empty=$?
ks_read "/etc/passwd" 2>/dev/null; rc_abs=$?
ks_read "../escape" 2>/dev/null; rc_dotdot=$?
ks_read "a/../../escape" 2>/dev/null; rc_dotdot2=$?
set -e
[ "$rc_empty" -eq 2 ] || fail "10: empty doc-id should exit 2 (got $rc_empty)"
[ "$rc_abs" -eq 2 ] || fail "10: absolute doc-id should exit 2 (got $rc_abs)"
[ "$rc_dotdot" -eq 2 ] || fail "10: leading .. doc-id should exit 2 (got $rc_dotdot)"
[ "$rc_dotdot2" -eq 2 ] || fail "10: embedded .. doc-id should exit 2 (got $rc_dotdot2)"
echo "PASS: 10 doc-id validation rejects empty/absolute/traversal ids (exit 2)"

# --- 11. list: empty (sub)root prints nothing, exit 0 -------------------------
EMPTY_ROOT="$TMP/empty-store"
set +e
out="$(KNOWLEDGE_STORE_ROOT="$EMPTY_ROOT" ks_list)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "11: list of a non-existent root should exit 0 (got $rc)"
[ -z "$out" ] || fail "11: list of a non-existent root should print nothing (got: $out)"
echo "PASS: 11 list on a not-yet-created root exits 0 and prints nothing"

# --- 12. list: whole-root and prefix-scoped, sorted ---------------------------
whole="$(ks_list)" || fail "12: whole-root list should succeed"
want_whole="$(printf 'Decisions/bar.md\nDecisions/foo.md\nScratch/log.md')"
[ "$whole" = "$want_whole" ] || fail "12: whole-root list mismatch (got:\n$whole\nwant:\n$want_whole)"
scoped="$(ks_list "Decisions")" || fail "12b: prefix-scoped list should succeed"
want_scoped="$(printf 'Decisions/bar.md\nDecisions/foo.md')"
[ "$scoped" = "$want_scoped" ] || fail "12b: prefix-scoped list mismatch (got:\n$scoped\nwant:\n$want_scoped)"
echo "PASS: 12 list enumerates whole-root and prefix-scoped, sorted"

# --- 13. unknown backend -> dispatch error, exit 2 ----------------------------
set +e
out="$(KNOWLEDGE_STORE_BACKEND="does-not-exist" ks_read "Decisions/foo" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "13: unknown backend should exit 2 (got $rc)"
case "$out" in
  *does-not-exist*) : ;;
  *) fail "13: error message should name the unknown backend (got: $out)" ;;
esac
echo "PASS: 13 selecting an unimplemented backend fails dispatch with exit 2"

echo "ALL PASS: knowledge_store.sh (interface + plain-files backend)"
