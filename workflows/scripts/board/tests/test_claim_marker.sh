#!/usr/bin/env bash
#
# Regression test for GH #297: claim_marker_set / claim_marker_clear must brand
# only the CALLER'S OWN window (the one containing $TMUX_PANE), never the tmux
# server's "current"/active window. The pre-fix untargeted code branded the
# active window, so a claim from one session leaked onto a concurrent session's
# window.
#
# Runs against an ISOLATED tmux socket (and overrides the lib's tmux seam to
# pin to it), so it never touches the user's real tmux server. Skips cleanly
# where tmux is not installed.
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP: tmux not installed"
  exit 0
fi

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=scripts/lib/claim_marker.sh
source "$LIB_DIR/claim_marker.sh"

SOCK="$(mktemp -u "${TMPDIR:-/tmp}/test-claim-marker-XXXXXX.sock")"

# Pin every lib tmux call to the isolated server — no chance of hitting the
# user's default server.
_claim_marker_tmux() { command tmux -S "$SOCK" "$@"; }

T() { command tmux -S "$SOCK" "$@"; }   # the test's own assertions

cleanup() { T kill-server 2>/dev/null || true; rm -f "$SOCK"; }
trap cleanup EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

# Two windows in one session; make win1 the ACTIVE window — the wrong target the
# untargeted code would brand. Capture STABLE window ids (@N) up front: the set
# call renames win0, so name-based (`s:win0`) lookups would silently resolve to
# the active window afterward.
T new-session -d -s s -n win0
T new-window -t s: -n win1
PANE0="$(T list-panes -t s:win0 -F '#{pane_id}')"
WIN0="$(T display-message -p -t s:win0 '#{window_id}')"
WIN1="$(T display-message -p -t s:win1 '#{window_id}')"
if [ -z "$PANE0" ] || [ -z "$WIN0" ] || [ -z "$WIN1" ]; then fail "could not resolve ids"; fi
T select-window -t "$WIN1"

# Act as a session whose pane lives in win0 (NOT the active window).
# SC2030/SC2031: the TMUX/TMUX_PANE exports are deliberately scoped to this
# subshell — they feed claim_marker_set running in the same subshell, and the
# test asserts the effect via the isolated socket. Hoisting them out would
# change behavior. The same applies to the claim_marker_clear subshell below.
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; claim_marker_set "#297 test" )

got0="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
got1="$(T show-options -t "$WIN1" -wqv @claimed_issue || true)"
name0="$(T display-message -p -t "$WIN0" '#{window_name}')"

[ "$got0" = "#297 test" ] || fail "win0 @claimed_issue not set (got: '$got0')"
[ "$name0" = "#297 test" ] || fail "win0 not renamed (got: '$name0')"
[ -z "$got1" ] || fail "win1 (active window) was branded — targeting leaked (got: '$got1')"

# Release from win0: clears win0 only; win1 already empty.
# shellcheck disable=SC2030,SC2031
prev="$( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; claim_marker_clear )"
[ "$prev" = "#297 test" ] || fail "release did not echo prior marker (got: '$prev')"
got0b="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
[ -z "$got0b" ] || fail "win0 @claimed_issue not cleared (got: '$got0b')"

# --- GH #297 hardening: $TMUX_PANE unset must FAIL SAFE (no-op) ----------------
# In tmux but with no pane id in the environment, the helpers cannot identify
# the caller's own window. The pre-hardening code fell back to the UNTARGETED
# tmux form, which brands the server's CURRENT window — here win1, which is
# selected as active below. The hardened code must NO-OP instead, branding
# nothing. win1 is the active window, so it's the one the untargeted form would
# wrongly stamp.
T select-window -t "$WIN1"
ACTIVE="$(T display-message -p '#{window_id}')"
[ "$ACTIVE" = "$WIN1" ] || fail "test setup: win1 is not the active window (got: '$ACTIVE')"

# Act as a session that is in tmux (TMUX set) but has NO TMUX_PANE exported.
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0"; unset TMUX_PANE; claim_marker_set "#leak should not happen" )

active_after_set="$(T show-options -t "$WIN1" -wqv @claimed_issue || true)"
name1_after_set="$(T display-message -p -t "$WIN1" '#{window_name}')"
[ -z "$active_after_set" ] || fail "TMUX_PANE-unset set() branded the active window (got: '$active_after_set')"
[ "$name1_after_set" != "#leak should not happen" ] || fail "TMUX_PANE-unset set() renamed the active window"

# Seed a marker on win1 directly, then confirm clear() with TMUX_PANE unset
# leaves it untouched (no-op) and echoes nothing.
T set-option -t "$WIN1" -w @claimed_issue "#seeded" >/dev/null
# shellcheck disable=SC2030,SC2031
prev_noop="$( export TMUX="$SOCK,$$,0"; unset TMUX_PANE; claim_marker_clear )"
[ -z "$prev_noop" ] || fail "TMUX_PANE-unset clear() echoed a value (got: '$prev_noop')"
seeded_after="$(T show-options -t "$WIN1" -wqv @claimed_issue || true)"
[ "$seeded_after" = "#seeded" ] || fail "TMUX_PANE-unset clear() mutated the active window (got: '$seeded_after')"
T set-option -t "$WIN1" -wu @claimed_issue >/dev/null

# --- GH #348: cmux surface — per-workspace status chip via the cmux CLI seam ----
# cmux is installed only on the macbook, so the test must NOT shell out to real
# cmux. Override the _claim_marker_cmux seam with a stub that records set/clear
# calls to a log and emulates `list-status` for the clear-path value recovery.
# (Mirrors the _claim_marker_tmux isolation above; runs on any host.)
CMUX_LOG="$(mktemp "${TMPDIR:-/tmp}/test-claim-marker-cmux-XXXXXX")"
trap 'cleanup; rm -f "$CMUX_LOG"' EXIT

# Stub: list-status emits a canned chip (our own set-status format); set/clear
# append their args to the log. No real cmux is ever invoked.
_claim_marker_cmux() {
  case "$1" in
    list-status)
      printf 'claim=#348 cmux chip icon=lock color=#d29922\n'
      printf 'claude_code=Running icon=bolt.fill color=#4C8DFF\n' ;;
    *) printf '%s\n' "$*" >>"$CMUX_LOG" ;;
  esac
}

# set() from a cmux workspace (no tmux): records the set-status call verbatim.
# shellcheck disable=SC2030,SC2031
( export CMUX_WORKSPACE_ID="WS-TEST"; unset TMUX TMUX_PANE; claim_marker_set "#348 cmux chip" )
grep -qxF 'set-status claim #348 cmux chip --icon lock --color #d29922' "$CMUX_LOG" \
  || fail "cmux set() did not issue the expected set-status call (got: '$(cat "$CMUX_LOG")')"

# clear() from a cmux workspace: echoes the chip value (recovered via list-status)
# and records the clear-status call.
: >"$CMUX_LOG"
# shellcheck disable=SC2030,SC2031
prev_cmux="$( export CMUX_WORKSPACE_ID="WS-TEST"; unset TMUX TMUX_PANE; claim_marker_clear )"
[ "$prev_cmux" = "#348 cmux chip" ] || fail "cmux clear() did not echo the chip value (got: '$prev_cmux')"
grep -qxF 'clear-status claim' "$CMUX_LOG" \
  || fail "cmux clear() did not issue clear-status (got: '$(cat "$CMUX_LOG")')"

# Outside cmux (CMUX_WORKSPACE_ID unset) the cmux surface must NO-OP.
: >"$CMUX_LOG"
# shellcheck disable=SC2030,SC2031
( unset TMUX TMUX_PANE CMUX_WORKSPACE_ID; claim_marker_set "#leak" )
[ ! -s "$CMUX_LOG" ] || fail "cmux set() fired with CMUX_WORKSPACE_ID unset (got: '$(cat "$CMUX_LOG")')"

# --- foundation #559: release.sh <issue#> is a SAFETY CHECK, not a target ------
# release is per-window (GH #297); a passed <issue#> must MATCH this window's
# claim or release must REFUSE — never silently release a different item (the bug).
RELEASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/release.sh"

# claim_marker_peek reads the marker WITHOUT clearing (the read-only lib helper).
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; claim_marker_set "#559 peek test" )
# shellcheck disable=SC2030,SC2031
peeked="$( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; unset CMUX_WORKSPACE_ID; claim_marker_peek )"
[ "$peeked" = "#559 peek test" ] || fail "claim_marker_peek did not read the marker (got: '$peeked')"
still="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
[ "$still" = "#559 peek test" ] || fail "claim_marker_peek must NOT clear (got: '$still')"

# Mismatched issue# → REFUSE (non-zero) and leave the marker INTACT (the #559 bug).
set +e
# shellcheck disable=SC2030,SC2031
mm_out="$( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; unset CMUX_WORKSPACE_ID; bash "$RELEASE" 999 2>&1 )"
mm_rc=$?
set -e
[ "$mm_rc" -ne 0 ] || fail "release.sh <mismatch> must exit non-zero (rc=$mm_rc, out: '$mm_out')"
intact="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
[ "$intact" = "#559 peek test" ] || fail "release.sh <mismatch> must NOT clear the marker (got: '$intact')"

# Matching issue# (with a tolerated --board) → clears.
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; unset CMUX_WORKSPACE_ID; bash "$RELEASE" 559 --board 4 ) >/dev/null
cleared="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
[ -z "$cleared" ] || fail "release.sh <match> --board should clear (got: '$cleared')"

# No-arg release still clears whatever the window holds (backward compatible).
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; claim_marker_set "#559 noarg" )
# shellcheck disable=SC2030,SC2031
( export TMUX="$SOCK,$$,0" TMUX_PANE="$PANE0"; unset CMUX_WORKSPACE_ID; bash "$RELEASE" ) >/dev/null
cleared2="$(T show-options -t "$WIN0" -wqv @claimed_issue || true)"
[ -z "$cleared2" ] || fail "release.sh (no arg) should clear (got: '$cleared2')"

echo "PASS: claim_marker_{set,clear} target only the caller's own window (GH #297)"
echo "PASS: claim_marker_{set,clear} fail safe (no-op) when \$TMUX_PANE is unset (GH #297)"
echo "PASS: claim_marker_{set,clear} drive the cmux per-workspace status chip (GH #348)"
echo "PASS: release.sh <issue#> refuses on mismatch, clears on match/no-arg; claim_marker_peek is read-only (#559)"
