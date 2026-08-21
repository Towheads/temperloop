#!/usr/bin/env bash
#
# Shared terminal claim-marker helpers for claim.sh / release.sh.
#
# These are MULTIPLEXER-AWARE and apply each terminal surface INDEPENDENTLY, so a
# nested tmux-in-cmux session brands both (harmless). Each surface self-guards;
# outside every multiplexer the helpers are a complete no-op (GH #348).
#
# --- tmux surface (GH #251, GH #297) ------------------------------------------
# The tmux branch acts on the CALLER'S OWN tmux window — the window containing
# $TMUX_PANE — never the tmux server's "current" window. The untargeted form
# (plain `tmux rename-window` / `tmux set-option -w`) brands whichever window is
# active in the server, so a claim run from one Claude session would stamp a
# *concurrent* session's window when both share a tmux server (GH #297). Pinning
# every call to `-t "$TMUX_PANE"` makes a session only ever touch its own window.
#
# The tmux branch is a no-op outside tmux. It is ALSO a no-op when $TMUX_PANE is
# unset or empty while inside tmux (in tmux but no pane id in the environment):
# in that state we cannot identify the caller's own window, and the untargeted
# tmux form would brand the server's CURRENT window — which may belong to a
# concurrent session. Failing safe (do nothing) is correct here; branding the
# wrong window is the exact GH #297 regression we are guarding against, so we
# never fall back to the untargeted command. (See _claim_marker_targetable below.)
#
# --- cmux surface (GH #348) ---------------------------------------------------
# The cmux branch sets a per-workspace status chip via the cmux socket CLI
# (`set-status claim …` / `clear-status claim`). cmux auto-targets the caller's
# own workspace ($CMUX_WORKSPACE_ID, set in every cmux terminal), so there is NO
# wrong-window hazard — the GH #297 concern is tmux-specific. We use set-status,
# NOT rename-tab: cmux owns the tab title (the live agent summary) and would
# overwrite a rename — the same lesson as iTerm2 -CC moving to status-right
# (GH #251). The chip coexists with cmux's own claude_code chip.
#
# --- clearing a window you are not in: the TARGETED helpers (temperloop#1037) -
# `claim_marker_clear` is the CALLER'S-OWN-WINDOW clear, and it is the only form
# claim.sh / release.sh ever need. A stale marker in a window the caller is not
# sitting in, though, was unreachable: nothing clears a marker on session death,
# issue close, or merge, so the status bar kept asserting a claim that no longer
# existed (observed live — a marker branded four windows for over a month while
# its issue had been closed since the previous month, temperloop#1037).
# `claim_marker_{peek,clear}_window` take an EXPLICIT tmux window/pane target so a
# sweep (reconcile.sh Lens 1 `--fix`) can reach those windows.
#
# This does NOT weaken GH #297. #297 is about touching a window you cannot prove
# is yours on a "looks stale" basis; the safety of a cross-window clear lives in
# the CALLER'S gate, and reconcile.sh calls these only after proving the marker
# names an issue that reads CLOSED or MERGED on GitHub. A terminal issue's marker
# is dead information in every window, including a concurrent session's. They are
# therefore deliberately NOT wired into claim.sh — a targeted marker WRITE
# (branding someone else's window) still has no provably-safe caller, so no
# `claim_marker_set_window` exists.
#
# --- automatic-rename restore (temperloop#1037) -------------------------------
# `claim_marker_set` brands the window with `rename-window`, and tmux turns the
# window-local `automatic-rename` OFF whenever a window is renamed. Nothing ever
# turned it back on, so a cleared window kept the claim string as its name
# forever. Every clear path therefore also runs `set-option -wu automatic-rename`,
# which REMOVES the window-local override rather than forcing `on` — the window
# then inherits whatever the operator's global setting is, which is the true
# "restore" (forcing `on` would override an operator who deliberately set it off
# globally). Unsetting an option that was never set is a no-op, so this is
# idempotent and safe on a window claim.sh never branded.
#
# --- @claimed_issue → status-right contract (GH #251) -------------------------
# The per-window @claimed_issue tmux option these helpers set is consumed
# VERBATIM by the user's ~/.tmux.conf `status-right` (GH #251): the status bar
# interpolates the stored string directly. That makes the stored value a HIDDEN
# CROSS-FILE CONTRACT — the format here and the format ~/.tmux.conf expects must
# stay in lockstep. Do not reshape, prefix, escape, or wrap the value passed to
# `set-option -w @claimed_issue` without updating the user's status-right to
# match; status-right has no parser, it just prints what it finds. claim.sh
# chooses the display string ("#297 short title"); these helpers store it as-is.
#
# Sourced, not executed:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/claim_marker.sh"

# Indirection seam so tests can point these helpers at an isolated tmux socket
# (override after sourcing: `_claim_marker_tmux() { command tmux -S "$SOCK" "$@"; }`)
# without any risk of mutating the caller's real tmux server. Production always
# uses the default server.
_claim_marker_tmux() { tmux "$@"; }

# Indirection seam for the cmux CLI, mirroring _claim_marker_tmux so tests stub
# it with zero side effects (override after sourcing). Production uses the bundled
# CLI cmux exports as $CMUX_BUNDLED_CLI_PATH in every terminal, falling back to a
# plain `cmux` on PATH.
_claim_marker_cmux() { "${CMUX_BUNDLED_CLI_PATH:-cmux}" "$@"; }

# Predicate: is there a usable per-window target for the CALLER'S OWN window?
# True only when inside tmux AND $TMUX_PANE is set/non-empty. We deliberately
# refuse the untargeted (no -t) form: without a pane id the untargeted command
# would brand the server's current window, which may be a concurrent session's
# (GH #297). Better to do nothing than to brand the wrong window. Callers that
# get a false here must NO-OP. (Kept bash 3.2-safe — no namerefs.)
_claim_marker_targetable() {
  [ -n "${TMUX:-}" ] || return 1
  [ -n "${TMUX_PANE:-}" ] || return 1
  return 0
}

# Predicate: are we inside a cmux workspace? cmux exports $CMUX_WORKSPACE_ID in
# every terminal and its set-status/clear-status auto-target it, so (unlike tmux)
# there is no caller-vs-active ambiguity to guard against. True iff the id is set.
_claim_marker_cmux_targetable() {
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 1
  return 0
}

# Brand the claim in every terminal surface present. Each surface is independent
# (a nested tmux-in-cmux session brands both; harmless). No-op outside all of them.
#   $1 = display string, e.g. "#297 short title"
claim_marker_set() {
  # tmux: rename the caller's own window and set @claimed_issue (GH #297 targeting).
  if _claim_marker_targetable; then
    _claim_marker_tmux rename-window -t "$TMUX_PANE" "$1" 2>/dev/null || true
    _claim_marker_tmux set-option -t "$TMUX_PANE" -w @claimed_issue "$1" 2>/dev/null || true
  fi
  # cmux: a per-workspace status chip, auto-scoped to $CMUX_WORKSPACE_ID (GH #348).
  if _claim_marker_cmux_targetable; then
    _claim_marker_cmux set-status claim "$1" --icon lock --color "#d29922" >/dev/null 2>&1 || true
  fi
}

# Read the current claim marker's display value WITHOUT clearing it — the
# read-only counterpart to claim_marker_clear. Added for release.sh's optional
# <issue#> safety check (foundation #559): release peeks the marker to verify a
# requested issue matches THIS window's claim before clearing, so a mismatched
# arg refuses instead of silently releasing a different item. Echoes the stored
# display string ("#297 short title") or "" if none / outside every multiplexer.
claim_marker_peek() {
  local prev=""
  if _claim_marker_targetable; then
    prev="$(claim_marker_peek_window "$TMUX_PANE")"
  fi
  # cmux fallback (only if tmux had no value), parsing our own set-status format.
  if _claim_marker_cmux_targetable && [ -z "$prev" ]; then
    prev="$(claim_marker_peek_cmux)"
  fi
  printf '%s' "$prev"
}

# Read the @claimed_issue marker of an EXPLICITLY TARGETED tmux window (or any
# tmux target that resolves to one — a `%pane` id, a `@window` id, `sess:win`).
# Unlike claim_marker_peek this needs NO $TMUX/$TMUX_PANE: the target is given,
# so a caller outside tmux (a nightly sweep) can read the running server's
# windows. Echoes the stored display string, or "" when the option is unset, the
# target does not resolve, or no tmux server is reachable at all.
#   claim_marker_peek_window <tmux-target>
claim_marker_peek_window() {
  local target="$1" prev=""
  [ -n "$target" ] || { printf ''; return 0; }
  prev="$(_claim_marker_tmux show-options -t "$target" -wqv @claimed_issue 2>/dev/null || true)"
  printf '%s' "$prev"
}

# Clear the @claimed_issue marker of an EXPLICITLY TARGETED tmux window and
# restore that window's `automatic-rename` (see the header section of the same
# name). Echoes the prior display value, like claim_marker_clear. Needs no
# $TMUX/$TMUX_PANE, for the same reason claim_marker_peek_window does not.
#
# CALLER'S RESPONSIBILITY: this helper applies NO safety gate — the caller must
# have proved the clear is safe (reconcile.sh's `--fix` proves the named issue is
# CLOSED/MERGED before calling). See the temperloop#1037 header section.
#   claim_marker_clear_window <tmux-target>
claim_marker_clear_window() {
  local target="$1" prev=""
  [ -n "$target" ] || { printf ''; return 0; }
  prev="$(claim_marker_peek_window "$target")"
  _claim_marker_tmux set-option -t "$target" -wu @claimed_issue 2>/dev/null || true
  _claim_marker_tmux set-option -t "$target" -wu automatic-rename 2>/dev/null || true
  printf '%s' "$prev"
}

# Read the cmux claim chip's display value without clearing it, parsing our OWN
# set-status format (value, then ` icon=… color=…`). "" when no chip is set or
# the CLI is unreachable. Split out of claim_marker_peek so a sweep can gate on
# the cmux surface separately from the tmux one (temperloop#1037).
claim_marker_peek_cmux() {
  _claim_marker_cmux list-status 2>/dev/null | sed -n 's/^claim=\(.*\) icon=.*/\1/p'
}

# Clear the claim marker on every terminal surface present. Echoes the prior
# display value to stdout (so callers can report what was released), then clears.
# No-op (fail safe, echoes nothing) outside all multiplexers.
claim_marker_clear() {
  local prev=""
  # tmux: read prior @claimed_issue (for the release message), unset it, and
  # restore automatic-rename — all via the targeted helper, pinned to this
  # window, so there is exactly ONE tmux clear implementation (temperloop#1037).
  if _claim_marker_targetable; then
    prev="$(claim_marker_clear_window "$TMUX_PANE")"
  fi
  # cmux: clear the chip. If tmux had no prior value, recover the chip's value
  # from list-status so the release message still reports it; a missing chip
  # yields "".
  if _claim_marker_cmux_targetable; then
    if [ -z "$prev" ]; then
      prev="$(claim_marker_peek_cmux)"
    fi
    claim_marker_clear_cmux
  fi
  printf '%s' "$prev"
}

# Clear the cmux claim chip for the caller's OWN workspace (cmux auto-targets
# $CMUX_WORKSPACE_ID, so there is no cross-workspace form to widen to — the
# GH #297 hazard is tmux-specific). Split out of claim_marker_clear so a sweep
# can dispose the cmux surface separately from the tmux one (temperloop#1037).
claim_marker_clear_cmux() {
  _claim_marker_cmux clear-status claim >/dev/null 2>&1 || true
}
