#!/usr/bin/env bash
#
# Release this session's claimed-item terminal marker so the status surface
# falls back to "No Issue Claimed". Run this when work on the item shown in
# this window/tab stops — i.e. when you park it or it gets closed/merged.
#
# This is the symmetric counterpart to scripts/claim.sh step 3. It clears the
# claim marker on whatever multiplexer is present — the per-window @claimed_issue
# tmux option that `status-right` reads (GH #251) and/or the cmux per-workspace
# status chip (GH #348) — by deferring to claim_marker_clear, which no-ops safely
# per surface.
#
# Scope: the LOCAL marker, plus ONE narrow board-side clear (below). It never
# moves the board item out of In Progress. Park/close the board item
# deliberately (`unclaim.sh`, `board_set_status` via lib/board.sh, or editing
# the issue's `fnd:status:*` label by hand on GitHub), per the
# "Park, don't abandon" rule in CLAUDE.md.
#
# ── The board-side half: a PARKED claim stamp (temperloop#979) ────────────────
# Historically this script was LOCAL-ONLY, on the reasoning that the board half
# of a claim is cleared later — by the Done write, or by `reconcile.sh`. On the
# ISSUES-ONLY backend that reasoning has a hole, and it is exactly the park
# path: a claim's owner lives in a `fnd:host/session:<host>:<sess8>` LABEL, an
# item parked back to Ready never reaches Done, and `reconcile.sh --labels`
# swept only CLOSED issues. So the stamp sat on an open, Ready issue reading as
# a live claim by a session that is gone — the cross-session-lock confusion the
# stamp exists to prevent (temperloop#979 reproduced it on foundation#1483).
#
# So, when BOTH an <issue#> and `--board <N>` are given AND that board is the
# issues-only backend, this script now also clears that issue's claim stamp —
# through `board_stamp <item> Host/Session ""`, the SAME one clearing
# implementation the adapter already owns, never a second label-strip path.
# Four guards make that safe, and each is a deliberate refusal, not an omission:
#
#   1. NOT In Progress. A stamp on an In-Progress item is a LIVE claim held
#      until Done (K#275) — the sanctioned flow, not drift. The stamp is left
#      in place with a notice; only a Ready/Backlog/closed item is cleared. This
#      is what keeps the normal claim → work → Done path byte-identical.
#   2. THIS SESSION'S stamp only. A foreign stamp (another host, or another
#      session on this host) is REPORTED and left alone, so a peer's in-flight
#      claim — claim.sh stamps the owner BEFORE it flips the status, so there is
#      a real window where a live claim reads Ready+stamped — can never be
#      erased from here. The foreign/stale case is `reconcile.sh --labels`'s
#      job; it is the robust half by construction (it catches the drift whether
#      or not anyone remembered to run this script).
#   3. OPT-IN by argument. Without `--board`, or without an <issue#>, nothing
#      board-side happens at all — every pre-existing call site (e.g. /build 3h,
#      which calls `release.sh <n>` with no --board) keeps its exact prior
#      behavior.
#   4. NEVER changes this script's exit status. Every board-side failure —
#      an unknown board, an unreadable issue, a failed label write — degrades to
#      a stderr notice and continues to the marker half. A park must never fail
#      on a release (CLAUDE.md § Claim held until Done), and that includes this.
#
# Claim held until Done (K#275). This script is NOT required by the normal
# /build flow: a claim is legitimately HELD until its item reaches Done (the
# board half leaves In Progress via the close->Done cascade on merge, or a
# deliberate skip — see CLAUDE.md "Claim held until Done"). Clearing the local
# marker at park is an optional convenience. Because the marker is one-per-
# window (below), in a MULTI-CLAIM WINDOW — one session claiming several items
# in a parallel level — the marker holds only the LATEST claim, so releasing a
# NON-LATEST issue here correctly REFUSES. That refusal is expected and non-
# fatal: leave the earlier claim held; reconcile.sh / the cascade clear it on
# merge. Callers (e.g. /build 3h) MUST NOT fail a park on this refusal, and
# MUST NOT depend on this script to release a non-latest claim. Note the
# ORDER below: the board-side clear runs BEFORE the marker safety check, so a
# multi-claim window's expected non-latest REFUSAL never suppresses it (and so
# a headless caller, which has no multiplexer marker at all, still gets it).
#
#   scripts/release.sh            # clear THIS window's claim marker
#   scripts/release.sh <issue#>   # same, but REFUSE unless this window holds #<issue>
#   scripts/release.sh <issue#> --board <N>   # + clear #<issue>'s parked claim
#                                             #   stamp on an issues-only board
#
# The optional <issue#> is a SAFETY CHECK for the marker half, not a target
# selector (foundation #559). release is per-window by design (GH #297): it
# clears whatever the running pane holds. Before this guard, a caller who passed
# the wrong number — e.g. `release.sh 495` from a window claiming #528 —
# silently released #528, a cross-session-lock correctness bug. With the arg,
# release verifies it matches THIS window's marker and refuses (non-zero,
# nothing cleared) on a mismatch, rather than releasing a different item. For
# the BOARD half the same <issue#> IS the target — but guard 2 above makes a
# wrong number inert there too: a stamp this session did not write is never
# touched.
#
# Test seam: board reads/writes route through lib/board.sh's `_board_gh`, and
# the tmux marker through lib/claim_marker.sh's `_claim_marker_tmux` — a test
# fakes both (see tests/test_release.sh) for a fully offline run.
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this
# command makes with its outermost context, preserving an already-set outer
# value so an autonomous driver's context wins over this nested command.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-release}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/claim_marker.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/claim_marker.sh"
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing
# test before it calls release_main. Empty BOARD_ARG = the board half is OFF
# (the historical local-only behavior), which is what every call site that
# passes no --board keeps.
want=""
BOARD_ARG=""

# THIS session's own claim stamp comes from board.sh's board_own_stamp — the
# single owner of the `<host>:<sess8>`/`<host>:manual` format (temperloop#1220/
# #1823), the exact derivation claim.sh writes, so guard 2 below always matches
# its own stamp. Never re-derive it here.

# The board-side half (temperloop#979) — see the header's four guards. ALWAYS
# returns 0: this must never change release.sh's exit status.
release_board_half() {
  [ -n "$want" ] || return 0
  [ -n "$BOARD_ARG" ] || return 0

  local board item_id status stamp mine
  board="$(board_resolve_name "$BOARD_ARG" 2>/dev/null)" || {
    echo "release.sh: unknown board '$BOARD_ARG' — skipping the board-side claim-stamp clear (the marker release below is unaffected)" >&2
    return 0
  }
  # Every registered board runs the issues-only backend (temperloop#524's
  # 2026-08-04 addendum), so the clear below always applies.

  if ! board_resolve_item "$board" "$want" >/dev/null 2>&1; then
    echo "release.sh: could not read #$want on board $board — skipping the board-side claim-stamp clear" >&2
    return 0
  fi
  item_id="$(board_item_id "$want")"
  if [ -z "$item_id" ]; then
    echo "release.sh: #$want is not on board $board — skipping the board-side claim-stamp clear" >&2
    return 0
  fi

  # Both reads are pure jq against the item board_resolve_item just fetched —
  # no second gh call.
  stamp="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$want" '.items[] | select(.content.number==$n) | .["host/Session"] // ""')"
  # Nothing stamped: the common, already-clean case. Silent — a no-op notice on
  # every park would be pure noise.
  [ -n "$stamp" ] || return 0

  status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$want" '.items[] | select(.content.number==$n) | .status // ""')"

  # Guard 1 — a live claim held until Done is NOT drift.
  if [ "$status" = "$BOARD_OPT_INPROGRESS" ]; then
    echo "release.sh: #$want is still In Progress — the claim is held until Done (K#275); leaving its stamp [$stamp] in place." >&2
    return 0
  fi

  # Guard 2 — never erase a stamp this session did not write.
  mine="$(board_own_stamp)"
  if [ "$stamp" != "$mine" ]; then
    echo "release.sh: #$want carries another session's claim stamp [$stamp] (this session is [$mine]) — leaving it; sweep it with 'reconcile.sh --board $board --labels'." >&2
    return 0
  fi

  # The clear itself: the adapter's own single implementation (an empty text
  # CLEARS the field / strips the label on both backends).
  if board_stamp "$item_id" "$BOARD_FIELD_HOSTSESSION" ""; then
    echo "Cleared #$want's claim stamp [$stamp] (status: ${status:-unknown}) — the board no longer reads it as claimed"
  else
    echo "release.sh: could not clear #$want's claim stamp [$stamp] — 'reconcile.sh --board $board --labels --apply' will sweep it" >&2
  fi
  return 0
}

# The whole release, wrapped so a test can source this file (the execute-guard
# at the bottom suppresses the auto-run when sourced), set $want / $BOARD_ARG,
# override the `_board_gh` / `_claim_marker_tmux` seams, and drive it offline.
release_main() {
  local cur cur_issue prev

  # Board half FIRST — deliberately ahead of the marker safety check below, so
  # neither the expected non-latest REFUSAL (K#275, a multi-claim window) nor an
  # absent marker (a headless run outside any multiplexer) can suppress the
  # durable, cross-session half of the release. Never affects the exit status.
  release_board_half || true

  # Safety check (foundation #559): when an <issue#> was given, verify it matches
  # THIS window's claim before clearing. On a mismatch, REFUSE (clear nothing) so a
  # wrong number never releases a different item. `#297 short title` → leading
  # `#297` → `297`. No arg = release whatever this window holds (unchanged).
  if [ -n "$want" ]; then
    cur="$(claim_marker_peek)"
    if [ -z "$cur" ]; then
      echo "release.sh: no claim marker set in this window — nothing to release for #$want" >&2
      return 0
    fi
    cur_issue="${cur%% *}"        # first token, e.g. "#297"
    cur_issue="${cur_issue#\#}"   # strip the leading '#'  → "297"
    if [ "$cur_issue" != "$want" ]; then
      echo "release.sh: this window holds a claim for #$cur_issue, not #$want — refusing." >&2
      echo "  Release from #$want's own window, or run 'release.sh' with no argument to release #$cur_issue here." >&2
      return 1
    fi
  fi

  # Clears the claim marker on whatever multiplexer is present: @claimed_issue on
  # THIS session's own tmux window (the pane this runs in, not the server's
  # "current" window — GH #297) and/or the cmux per-workspace chip (GH #348).
  # A no-op (echoes nothing) outside every multiplexer.
  prev="$(claim_marker_clear)"

  if [ -n "$prev" ]; then
    echo "Released [$prev] → status now shows 'No Issue Claimed'"
  else
    echo "No claim marker was set; status shows 'No Issue Claimed'"
  fi
  return 0
}

# Execute-guard: run the release only when this file is RUN, not when SOURCED.
# When sourced (BASH_SOURCE[0] != $0), a test sets $want / $BOARD_ARG, defines
# its seam overrides, and calls release_main itself — keeping the CLI parsing
# and the module-var defaults untouched. Mirrors claim.sh / unclaim.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  # --- CLI: optional <issue#> safety arg + --board -----------------------------
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) if [ $# -ge 2 ]; then BOARD_ARG="$2"; shift 2; else shift; fi ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) if [ -z "$want" ]; then want="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
    esac
  done
  want="${want#\#}"
  if [ -n "$want" ] && ! [[ "$want" =~ ^[0-9]+$ ]]; then
    echo "issue must be a number, got: $want" >&2; exit 2
  fi
  release_main
fi
