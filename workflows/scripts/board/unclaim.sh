#!/usr/bin/env bash
#
# Release a board item's CLAIM by moving its Status from In Progress back to
# Ready — the board-status half of undoing claim.sh. This is the autonomous
# "release-to-Ready" primitive the pipeline was missing: claim.sh flips a
# Ready item to In Progress (+ stamps the owner); unclaim.sh flips an In-Progress
# item back to Ready so it re-enters the drive/worklist pool.
#
#   unclaim.sh 227            # release issue #227 on the default board (3)
#   unclaim.sh '#227'        # leading # is fine
#   unclaim.sh 12 --board 4   # release issue #12 on the foundation board
#
# ── unclaim.sh vs release.sh — the two halves of undoing claim.sh ──────────────
# claim.sh does TWO things: it writes the BOARD status (Ready → In Progress) AND
# sets a LOCAL terminal marker (the tmux/cmux claim chip). The inverse is split
# across two scripts, by design, so each can be run independently:
#   * release.sh — clears the LOCAL marker only (per-window; it deliberately does
#     NOT touch board status — see its header and the "Park, don't abandon" rule).
#   * unclaim.sh — clears the BOARD status only (In Progress → Ready; it does not
#     touch any local marker).
# Together they invert claim.sh. A human parking work interactively usually wants
# release.sh (+ deliberately parking the card); an AUTONOMOUS/headless context
# (cron, the funnel driver) that must un-strand a board card wants unclaim.sh.
#
# ── Releases regardless of owner — deliberate (#1157) ─────────────────────────
# UNLIKE claim.sh, unclaim.sh does NOT consult the Host/Session owner stamp and
# does NOT refuse a foreign-owned claim. Its guard is "is the card In Progress?",
# NOT "is this MY claim?". This is the whole point: the motivating caller is the
# funnel's #1157 abandonment reclaim, where the stranded claim was stamped by a
# now-dead one-shot session — an owner-stamp refusal would refuse the exact case
# this exists for. So unclaim.sh is a more powerful primitive than the local-only
# release.sh: run bare (`unclaim.sh 42 --board 4`) it can Ready-ify ANY In-Progress
# card, including a peer session's LIVE claim. The caller owns that safety — only
# release items you know are abandoned. For interactive parking prefer the board
# UI or release.sh.
#
# ── Idempotent: only In Progress → Ready, else a no-op ────────────────────────
# The flip fires ONLY when the card's current status is In Progress. Any other
# status (already Ready, Done, Backlog, or the issue not on the board) is a no-op
# exit 0. This makes unclaim.sh safe to call speculatively — the current board
# status IS the ground-truth "is it actually claimed?" check, read here (inside
# this adapter-sourcing process) so a headless caller never has to source the
# board adapter itself to make that decision.
#
# Needs the `project` gh scope (gh auth refresh -s project), like claim.sh.
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context, preserving an already-set outer value so an
# autonomous driver's context wins over this nested command.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-unclaim}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f). Mirrors claim.sh.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
source "$SCRIPT_DIR/lib/board.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing test
# before it calls unclaim_main. Defaults match claim.sh's historical CLI (board 3).
PROJECT_NUMBER=3
issue=""

# The whole release, wrapped so a test can source this file (the execute-guard at
# the bottom suppresses the auto-run when sourced), set $issue / $PROJECT_NUMBER,
# override board_resolve_item / the board.sh `_board_gh` seam with canned data, and
# drive unclaim_main with zero network. Reads the two module vars above.
unclaim_main() {
  # Resolve project + fields + THIS issue's item by name (one targeted GraphQL
  # lookup, not the whole-board page) — the same cheap path claim.sh uses.
  board_resolve_item "$PROJECT_NUMBER" "$issue"

  local item_id status
  item_id=$(board_item_id "$issue")
  if [ -z "$item_id" ]; then
    # Not on the board → nothing to release. Idempotent no-op, not an error.
    echo "unclaim: #$issue is not on project $PROJECT_NUMBER — nothing to release"
    return 0
  fi

  # Idempotent ground-truth guard (#1157, architecture review): read the card's
  # CURRENT status from the warm BOARD_ITEMS_JSON board_resolve_item just fetched
  # (a pure jq read, no extra gh/GraphQL — mirrors board_claim_contended) and flip
  # ONLY when it is In Progress. This is the authoritative "is it actually claimed?"
  # check; keeping it here (not in a headless caller) lets that caller stay
  # adapter-free and closes the cross-process TOCTOU a read-then-blind-flip opens.
  status="$(printf '%s' "$BOARD_ITEMS_JSON" |
    jq -r --argjson n "$issue" '.items[] | select(.content.number==$n) | .status // ""')"
  if [ "$status" != "$BOARD_OPT_INPROGRESS" ]; then
    echo "unclaim: #$issue is not In Progress (status: ${status:-unknown}) — no-op"
    return 0
  fi

  # Flip Status → Ready. No owner-stamp check (see header): a stranded claim was
  # stamped by a dead session; refusing on a foreign stamp would refuse the exact
  # case this exists for. The stale Host/Session stamp is left in place — it is
  # inert on a Ready card (board_claim_contended only counts a stamp while In
  # Progress) and the next claim overwrites it.
  board_set_status "$item_id" "$BOARD_OPT_READY"
  echo "Released #$issue → Ready"
}

# Execute-guard: run only when this file is RUN, not when SOURCED (a test sets
# $issue / $PROJECT_NUMBER, defines its seam overrides, and calls unclaim_main
# itself). Mirrors claim.sh's guard and CLI shape exactly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) PROJECT_NUMBER="$(board_resolve_name "${2:?--board needs a value}")" || exit 2; shift 2 ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) if [ -z "$issue" ]; then issue="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
    esac
  done
  [ -n "$issue" ] || { echo "usage: unclaim.sh <issue-number> [--board 3|4]" >&2; exit 2; }
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "issue must be a number, got: $issue" >&2; exit 2; }
  unclaim_main
fi
