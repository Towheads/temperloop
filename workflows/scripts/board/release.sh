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
# Scope: LOCAL ONLY. It clears the terminal marker; it does NOT move the board
# item out of In Progress. Park/close the board item deliberately (board UI or
# `gh project item-edit`), per the "Park, don't abandon" rule in CLAUDE.md.
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
# MUST NOT depend on this script to release a non-latest claim.
#
#   scripts/release.sh        # clear THIS window's claim marker
#   scripts/release.sh <issue#>   # same, but REFUSE unless this window holds #<issue>
#
# The optional <issue#> is a SAFETY CHECK, not a target selector (foundation
# #559). release is per-window by design (GH #297): it clears whatever the
# running pane holds. Before this guard, a caller who passed the wrong number —
# e.g. `release.sh 495` from a window claiming #528 — silently released #528, a
# cross-session-lock correctness bug. With the arg, release verifies it matches
# THIS window's marker and refuses (non-zero, nothing cleared) on a mismatch,
# rather than releasing a different item. `--board N` is accepted and ignored
# (release is local-only / board-agnostic — kept for call-site symmetry with
# claim.sh so `release.sh <n> --board N` doesn't error).
#
set -euo pipefail

# --- CLI: optional <issue#> safety arg + tolerated --board ---------------------
want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --board) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;  # accepted + ignored (local-only)
    --) shift; break ;;
    -*) echo "unknown arg: $1" >&2; exit 2 ;;
    *) if [ -z "$want" ]; then want="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
  esac
done
want="${want#\#}"
if [ -n "$want" ] && ! [[ "$want" =~ ^[0-9]+$ ]]; then
  echo "issue must be a number, got: $want" >&2; exit 2
fi

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
source "$SCRIPT_DIR/lib/claim_marker.sh"

# Safety check (foundation #559): when an <issue#> was given, verify it matches
# THIS window's claim before clearing. On a mismatch, REFUSE (clear nothing) so a
# wrong number never releases a different item. `#297 short title` → leading
# `#297` → `297`. No arg = release whatever this window holds (unchanged).
if [ -n "$want" ]; then
  cur="$(claim_marker_peek)"
  if [ -z "$cur" ]; then
    echo "release.sh: no claim marker set in this window — nothing to release for #$want" >&2
    exit 0
  fi
  cur_issue="${cur%% *}"        # first token, e.g. "#297"
  cur_issue="${cur_issue#\#}"   # strip the leading '#'  → "297"
  if [ "$cur_issue" != "$want" ]; then
    echo "release.sh: this window holds a claim for #$cur_issue, not #$want — refusing." >&2
    echo "  Release from #$want's own window, or run 'release.sh' with no argument to release #$cur_issue here." >&2
    exit 1
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
