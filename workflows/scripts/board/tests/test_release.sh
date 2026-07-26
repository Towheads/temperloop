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
echo "PASS: all release.sh claim-marker contract assertions passed"
