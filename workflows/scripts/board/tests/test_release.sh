#!/usr/bin/env bash
#
# Contract tests for scripts/release.sh's per-window claim-marker semantics —
# above all the K#275 NON-LATEST REFUSAL, which temperloop#748's marker-repair
# path must leave completely untouched.
#
# K#275 ratified that release.sh is ONE-MARKER-PER-WINDOW: in a multi-claim
# window the marker holds only the LATEST claim, so `release.sh <n>` for a
# NON-latest issue must REFUSE (non-zero, nothing cleared) rather than release a
# different item. reconcile.sh --fix (temperloop#748) adds a second, narrower
# caller of the same `claim_marker_clear` primitive; this file pins the refusal
# so that addition can never quietly erode it.
#
# HERMETIC: no real tmux server, no network. release.sh reaches tmux through
# lib/claim_marker.sh's `_claim_marker_tmux`, which invokes a bare `tmux` — so a
# fake `tmux` shim first on $PATH intercepts every call. The shim is file-backed
# (marker value in, clears recorded out), so assertions survive the subprocess.
# It therefore also runs identically on a machine with no tmux installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
RELEASE="$SCRIPTS_DIR/release.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-release-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# --- the fake tmux shim -------------------------------------------------------
# Emulates just the two window-option calls lib/claim_marker.sh makes:
#   show-options -t <pane> -wqv @claimed_issue   -> print $FAKE_MARKER_FILE
#   set-option   -t <pane> -wu  @claimed_issue   -> record a clear, empty the store
mkdir -p "$WORK/bin"
cat >"$WORK/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  show-options) cat "$FAKE_MARKER_FILE" ;;
  set-option)
    case " $* " in
      *" -wu "*)
        printf 'cleared:%s\n' "$(cat "$FAKE_MARKER_FILE")" >>"$FAKE_CLEARS_FILE"
        : >"$FAKE_MARKER_FILE" ;;
    esac ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

FAKE_MARKER_FILE="$WORK/claimed_issue"; export FAKE_MARKER_FILE
FAKE_CLEARS_FILE="$WORK/clears";        export FAKE_CLEARS_FILE

# Inside "tmux" with an identifiable pane, outside cmux — the state in which
# _claim_marker_targetable is true and the cmux branch is a no-op.
export TMUX="$WORK/fake.sock,0,0"
export TMUX_PANE="%0"
unset CMUX_WORKSPACE_ID

set_marker()    { printf '%s' "$1" >"$FAKE_MARKER_FILE"; : >"$FAKE_CLEARS_FILE"; }
cleared_count() { grep -c '^cleared:' "$FAKE_CLEARS_FILE" 2>/dev/null || true; }

# Run release.sh capturing stdout+stderr and its exit status (never aborting the
# test run under `set -e`).
run_release() {
  RC=0
  OUT="$("$RELEASE" "$@" 2>&1)" || RC=$?
}

# --- case 1: NON-LATEST refusal (the K#275 contract) --------------------------
# This window's marker holds #502; a caller asks to release #27 (the item it was
# actually driving). release must REFUSE, clear nothing, and exit non-zero.
set_marker '#502 Claim target'
run_release 27
[ "$RC" -ne 0 ] || fail "case1: releasing a non-latest claim must exit non-zero (got $RC)\n$OUT"
printf '%s' "$OUT" | grep -q "this window holds a claim for #502, not #27 — refusing." \
  || fail "case1: expected the K#275 refusal message\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "case1: a refusal must clear NOTHING (got $(cleared_count))"
[ "$(cat "$FAKE_MARKER_FILE")" = '#502 Claim target' ] \
  || fail "case1: the marker must survive a refusal (got '$(cat "$FAKE_MARKER_FILE")')"
echo "PASS: release case 1 non-latest claim refused, nothing cleared (K#275)"

# --- case 2: matching arg releases --------------------------------------------
# The same marker, asked for by its own number, clears normally.
set_marker '#502 Claim target'
run_release 502
[ "$RC" -eq 0 ] || fail "case2: releasing the held claim should succeed (got $RC)\n$OUT"
printf '%s' "$OUT" | grep -q "Released \[#502 Claim target\]" \
  || fail "case2: expected the release confirmation\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "case2: expected exactly one clear (got $(cleared_count))"
echo "PASS: release case 2 matching issue number releases this window's claim"

# --- case 3: no argument releases whatever this window holds ------------------
set_marker '#502 Claim target'
run_release
[ "$RC" -eq 0 ] || fail "case3: argument-less release should succeed (got $RC)\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "case3: expected exactly one clear (got $(cleared_count))"
[ -z "$(cat "$FAKE_MARKER_FILE")" ] || fail "case3: the marker should be gone"
echo "PASS: release case 3 argument-less release clears this window's marker"

# --- case 4: no marker at all is a benign no-op -------------------------------
set_marker ''
run_release 27
[ "$RC" -eq 0 ] || fail "case4: no marker + an arg should exit 0 (got $RC)\n$OUT"
printf '%s' "$OUT" | grep -q "no claim marker set in this window" \
  || fail "case4: expected the nothing-to-release notice\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "case4: nothing to clear (got $(cleared_count))"
echo "PASS: release case 4 no marker set is a benign no-op"

echo
echo "=== The board half: a PARKED claim stamp on an issues-only board (temperloop#979) ==="
#
# Pre-#979, `release.sh <n> --board <b>` ACCEPTED AND IGNORED --board: it
# cleared the local marker and left the `fnd:host/session:*` claim stamp on an
# open, parked issue, which then read as claimed by a session that is gone.
# These cases pin the new board half AND the guards that keep it safe.
#
# Still hermetic: board.sh routes every call through `_board_gh` -> a bare
# `gh`, so the same $WORK/bin PATH trick that fakes tmux above fakes gh too.
# Board 7 (the kernel tracker) resolves to the issues-only backend from the
# built-in map once both boards.conf discovery paths are pinned at nonexistent
# files (same convention as test_reconcile_labels.sh).
export BOARDS_CONF_MACHINE="/no-such-machine-conf-$$"
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"
BOARD_CACHE_DIR="$WORK/board-cache"; export BOARD_CACHE_DIR

FAKE_ISSUE_FILE="$WORK/issue.json";  export FAKE_ISSUE_FILE
FAKE_EDITS_FILE="$WORK/gh-edits";    export FAKE_EDITS_FILE
FAKE_GH_CALLS="$WORK/gh-calls";      export FAKE_GH_CALLS

cat >"$WORK/bin/gh" <<'GHSHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
case "${1:-} ${2:-}" in
  "api "*) cat "$FAKE_ISSUE_FILE" ;;
  "issue edit")
    # record `<issue#>\t<removed-label>` for every --remove-label write
    n="$3"; want=0; rm_lbl=""
    for a in "$@"; do
      if [ "$want" = 1 ]; then rm_lbl="$a"; want=0; continue; fi
      [ "$a" = "--remove-label" ] && want=1
    done
    [ -n "$rm_lbl" ] && printf '%s\t%s\n' "$n" "$rm_lbl" >>"$FAKE_EDITS_FILE"
    ;;
esac
exit 0
GHSHIM
chmod +x "$WORK/bin/gh"

# This session's identity — the stamp claim.sh would have written, and the ONLY
# stamp value release.sh's own-stamp guard will clear.
export SUBSET_HOST_LABEL="mini"
export CLAUDE_CODE_SESSION_ID="9f90bef1-1111-2222-3333-444455556666"
OWN_STAMP="fnd:host/session:mini:9f90bef1"
OTHER_STAMP="fnd:host/session:mini:deadbeef"

# Seed the issue the fake gh will serve: set_issue <state> <status-label> <stamp-label|"">
set_issue() {
  local state="$1" status_label="$2" stamp="$3" labels
  labels='{"name":"'"$status_label"'"},{"name":"bug"}'
  [ -n "$stamp" ] && labels="$labels,{\"name\":\"$stamp\"}"
  printf '{"number":1483,"state":"%s","title":"parked item","labels":[%s]}' "$state" "$labels" >"$FAKE_ISSUE_FILE"
  : >"$FAKE_EDITS_FILE"; : >"$FAKE_GH_CALLS"
}
edits_count() { grep -c . "$FAKE_EDITS_FILE" 2>/dev/null || true; }
gh_calls()    { grep -c . "$FAKE_GH_CALLS" 2>/dev/null || true; }

# --- case 5: the temperloop#979 repro — claim -> Ready -> release -------------
# The exact sequence from the issue body: the item was claimed (stamp written,
# status In Progress), parked back to Ready, and released. The stamp must be
# GONE from the still-OPEN issue afterwards.
set_marker '#1483 parked item'
set_issue open "fnd:status:ready" "$OWN_STAMP"
run_release 1483 --board 7
[ "$RC" -eq 0 ] || fail "case5: the release should succeed (got $RC)\n$OUT"
grep -qF "$(printf '1483\t%s' "$OWN_STAMP")" "$FAKE_EDITS_FILE" \
  || fail "case5: expected the parked claim stamp removed from the OPEN issue\n$(cat "$FAKE_EDITS_FILE")\n$OUT"
printf '%s' "$OUT" | grep -qF "Cleared #1483's claim stamp [mini:9f90bef1]" \
  || fail "case5: expected the board-side clear confirmation\n$OUT"
printf '%s' "$OUT" | grep -q "Released \[#1483 parked item\]" \
  || fail "case5: the local marker half must still run\n$OUT"
[ "$(cleared_count)" = "1" ] || fail "case5: expected exactly one marker clear (got $(cleared_count))"
echo "PASS: release case 5 claim -> Ready -> release clears the parked claim stamp (temperloop#979)"

# --- case 6: In Progress — a LIVE claim held until Done is never cleared ------
set_marker '#1483 parked item'
set_issue open "fnd:status:in-progress" "$OWN_STAMP"
run_release 1483 --board 7
[ "$RC" -eq 0 ] || fail "case6: the release should still succeed (got $RC)\n$OUT"
[ "$(edits_count)" = "0" ] \
  || fail "case6: an In-Progress claim is HELD until Done (K#275) — nothing may be stripped\n$(cat "$FAKE_EDITS_FILE")"
printf '%s' "$OUT" | grep -q "still In Progress" \
  || fail "case6: expected the claim-held-until-Done notice\n$OUT"
echo "PASS: release case 6 an In-Progress item's live claim stamp is left in place (K#275)"

# --- case 7: a FOREIGN stamp is reported, never erased ------------------------
set_marker '#1483 parked item'
set_issue open "fnd:status:ready" "$OTHER_STAMP"
run_release 1483 --board 7
[ "$RC" -eq 0 ] || fail "case7: the release should still succeed (got $RC)\n$OUT"
[ "$(edits_count)" = "0" ] \
  || fail "case7: another session's stamp must never be erased from here\n$(cat "$FAKE_EDITS_FILE")"
printf '%s' "$OUT" | grep -q "another session's claim stamp" \
  || fail "case7: expected the foreign-stamp notice\n$OUT"
printf '%s' "$OUT" | grep -q "reconcile.sh --board 7 --labels" \
  || fail "case7: expected the pointer at the reconcile sweep that owns this case\n$OUT"
echo "PASS: release case 7 a foreign claim stamp is reported and routed to reconcile, never erased"

# --- case 8: no --board is byte-identical local-only behaviour ----------------
# Every pre-existing call site (e.g. /build 3h's `release.sh <n>`) passes no
# --board; it must still make ZERO board calls.
set_marker '#1483 parked item'
set_issue open "fnd:status:ready" "$OWN_STAMP"
run_release 1483
[ "$RC" -eq 0 ] || fail "case8: the release should succeed (got $RC)\n$OUT"
[ "$(gh_calls)" = "0" ] \
  || fail "case8: without --board release.sh must make ZERO gh calls\n$(cat "$FAKE_GH_CALLS")"
echo "PASS: release case 8 without --board the board half is off — zero gh calls (unchanged local-only path)"

# --- case 9: headless (no marker at all) still clears the board stamp ---------
# A /build-style worker runs outside any multiplexer, so claim_marker_peek is
# empty and the marker half exits early with a notice. The DURABLE half must
# still run — which is why the board half is ordered ahead of it.
set_marker ''
set_issue open "fnd:status:ready" "$OWN_STAMP"
run_release 1483 --board 7
[ "$RC" -eq 0 ] || fail "case9: an absent marker must stay a benign exit 0 (got $RC)\n$OUT"
grep -qF "$(printf '1483\t%s' "$OWN_STAMP")" "$FAKE_EDITS_FILE" \
  || fail "case9: the board half must run even with no local marker\n$(cat "$FAKE_EDITS_FILE")\n$OUT"
printf '%s' "$OUT" | grep -q "no claim marker set in this window" \
  || fail "case9: expected the unchanged no-marker notice\n$OUT"
echo "PASS: release case 9 the board half runs headless, with no multiplexer marker present"

# --- case 10: an unresolvable board never fails the release -------------------
# A park must never fail on a release (CLAUDE.md § Claim held until Done).
set_marker '#1483 parked item'
set_issue open "fnd:status:ready" "$OWN_STAMP"
run_release 1483 --board no-such-board
[ "$RC" -eq 0 ] || fail "case10: an unknown board must not fail the release (got $RC)\n$OUT"
[ "$(edits_count)" = "0" ] || fail "case10: nothing may be written for an unresolvable board\n$(cat "$FAKE_EDITS_FILE")"
printf '%s' "$OUT" | grep -q "unknown board 'no-such-board'" \
  || fail "case10: expected the legible skip notice\n$OUT"
printf '%s' "$OUT" | grep -q "Released \[#1483 parked item\]" \
  || fail "case10: the marker half must still run after a board-half skip\n$OUT"
echo "PASS: release case 10 a board-half failure degrades to a notice — the release still succeeds"

# --- case 11: the K#275 refusal still gets the board half --------------------
# A multi-claim window holds only the LATEST claim's marker, so releasing an
# EARLIER one correctly REFUSES (case 1) — but that refusal is about the local
# marker, and the earlier item's own parked stamp is exactly the drift #979 is
# about. The board half runs FIRST for this reason: the stamp is cleared, the
# marker refusal is unchanged (non-zero, marker intact).
set_marker '#502 the latest claim'
set_issue open "fnd:status:ready" "$OWN_STAMP"
run_release 1483 --board 7
[ "$RC" -ne 0 ] || fail "case11: the K#275 non-latest marker refusal must still exit non-zero (got $RC)\n$OUT"
printf '%s' "$OUT" | grep -q "this window holds a claim for #502, not #1483 — refusing." \
  || fail "case11: expected the unchanged K#275 refusal message\n$OUT"
[ "$(cleared_count)" = "0" ] || fail "case11: a refusal must clear NO marker (got $(cleared_count))"
grep -qF "$(printf '1483\t%s' "$OWN_STAMP")" "$FAKE_EDITS_FILE" \
  || fail "case11: the board half must still clear the parked stamp\n$(cat "$FAKE_EDITS_FILE")\n$OUT"
echo "PASS: release case 11 a non-latest marker refusal is unchanged, and no longer suppresses the board half"

echo
echo "PASS: all release.sh claim-marker + board-half contract assertions passed"
