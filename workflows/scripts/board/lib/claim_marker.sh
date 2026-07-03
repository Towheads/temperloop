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
    prev="$(_claim_marker_tmux show-options -t "$TMUX_PANE" -wqv @claimed_issue 2>/dev/null || true)"
  fi
  # cmux fallback (only if tmux had no value), parsing our own set-status format.
  if _claim_marker_cmux_targetable && [ -z "$prev" ]; then
    prev="$(_claim_marker_cmux list-status 2>/dev/null | sed -n 's/^claim=\(.*\) icon=.*/\1/p')"
  fi
  printf '%s' "$prev"
}

# Clear the claim marker on every terminal surface present. Echoes the prior
# display value to stdout (so callers can report what was released), then clears.
# No-op (fail safe, echoes nothing) outside all multiplexers.
claim_marker_clear() {
  local prev=""
  # tmux: read prior @claimed_issue (for the release message), then unset it.
  if _claim_marker_targetable; then
    prev="$(_claim_marker_tmux show-options -t "$TMUX_PANE" -wqv @claimed_issue 2>/dev/null || true)"
    _claim_marker_tmux set-option -t "$TMUX_PANE" -wu @claimed_issue 2>/dev/null || true
  fi
  # cmux: clear the chip. If tmux had no prior value, recover the chip's value
  # from list-status so the release message still reports it. The sed parses our
  # OWN set-status format (value, then ` icon=… color=…`); a missing chip yields "".
  if _claim_marker_cmux_targetable; then
    if [ -z "$prev" ]; then
      prev="$(_claim_marker_cmux list-status 2>/dev/null | sed -n 's/^claim=\(.*\) icon=.*/\1/p')"
    fi
    _claim_marker_cmux clear-status claim >/dev/null 2>&1 || true
  fi
  printf '%s' "$prev"
}
