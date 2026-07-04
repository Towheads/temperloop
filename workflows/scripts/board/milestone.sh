#!/usr/bin/env bash
#
# Milestone activation: mark a release phase "active" so that every Backlog item
# deferred to that phase re-enters /triage's next sweep at once — and unmark it
# when the phase is done (foundation #97, #206).
#
# THE MODEL (one machine-owned bit per milestone, no per-item state):
#   A milestone is "active" iff its GitHub DESCRIPTION contains the literal
#   HTML-comment marker `<!-- triage:active -->`. Default = inactive (no marker).
#   The marker is MACHINE-OWNED — written ONLY by the verbs below, never by hand.
#
#   /triage gates intake on the active set: a Backlog item carrying an INACTIVE
#   phase's milestone is skipped until that phase is activated; flipping the one
#   milestone-level bit lights up the whole deferred batch in a single move. No
#   `Parked` Status, no per-item bulk flip, no sequential-phase assumption —
#   multiple phases can be active at once, each an independent marker.
#
#   - The release-phase axis itself rides GitHub's built-in `Milestone` field (a
#     native repo milestone — free due-dates + burndown). Assign it with
#     `gh issue edit <#> --milestone "<phase>"` (or board_set_milestone). This
#     file owns only the ACTIVE/INACTIVE marker, not phase assignment.
#   - (the subsystem axis is `Component`, a separate board single-select.)
#
#   milestone activate "<phase>"   [--board N]   # ADD the triage:active marker
#   milestone deactivate "<phase>" [--board N]   # REMOVE the triage:active marker
#   milestone list                 [--board N]   # list open milestones, active first
#
# Both write verbs are idempotent (re-running is a no-op). --board selects the
# Projects-v2 board (default 3 = stageFind; 4 = foundation). The milestone must
# already exist in the repo (create once with
# `gh api repos/<owner>/<repo>/milestones -f title=...`).
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-milestone}"

# Resolve symlinks so the script finds its real lib/ even when invoked through a
# symlink (on PATH or from a consuming repo's scripts/ dir) — BASH_SOURCE points
# at the symlink, not the real file. Portable (no GNU readlink -f).
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
source "$SCRIPT_DIR/lib/board.sh"

# The machine-owned active marker. A milestone is active iff its description
# contains this literal substring (matches board_active_milestones in board.sh).
MILESTONE_ACTIVE_MARKER='<!-- triage:active -->'

milestone_usage() {
  cat >&2 <<'EOF'
usage:
  milestone activate "<phase>"   [--board 3|4]   # mark a release phase active (re-enters /triage)
  milestone deactivate "<phase>" [--board 3|4]   # mark a release phase inactive
  milestone list                 [--board 3|4]   # list open milestones, active ones flagged
EOF
  return 2
}

# Read an open milestone's current GitHub description by title (empty if the
# milestone has none). Routes through the `_board_gh` seam so tests can replay it.
#   _milestone_description <board#> <phase>  ->  current description text
_milestone_description() {
  local board="$1" phase="$2" repo
  repo="$(board_repo "$board")" || return 1
  _board_gh api "repos/$repo/milestones?state=all" 2>/dev/null |
    _board_sanitize_control_chars |
    jq -r --arg t "$phase" 'map(select(.title == $t)) | .[0].description // ""'
}

# Mark a release phase active: ADD the triage:active marker to its description.
# Idempotent — if the marker is already present, board_set_milestone_description
# sees an unchanged description and no-ops. Flipping this one milestone-level bit
# lets every Backlog item in the phase re-enter /triage's next sweep.
#   milestone_activate <board#> <phase>
milestone_activate() {
  local board="$1" phase="$2" desc
  desc="$(_milestone_description "$board" "$phase")" \
    || { echo "milestone: could not read milestone '$phase' — does it exist in $(board_repo "$board")?" >&2; return 1; }
  case "$desc" in
    *"$MILESTONE_ACTIVE_MARKER"*) ;;            # already active — leave description as-is
    "")   desc="$MILESTONE_ACTIVE_MARKER" ;;    # empty description -> just the marker
    *)    desc="$desc"$'\n'"$MILESTONE_ACTIVE_MARKER" ;;
  esac
  board_set_milestone_description "$board" "$phase" "$desc" \
    || { echo "milestone: could not mark '$phase' active on board $board" >&2; return 1; }
  echo "Activated milestone '$phase' on board $board — its Backlog items re-enter /triage."
}

# Mark a release phase inactive: REMOVE the triage:active marker from its
# description (and tidy any blank line the marker left behind). Idempotent — if
# the marker is absent the description is unchanged and the write no-ops.
#   milestone_deactivate <board#> <phase>
milestone_deactivate() {
  local board="$1" phase="$2" desc
  desc="$(_milestone_description "$board" "$phase")" \
    || { echo "milestone: could not read milestone '$phase' — does it exist in $(board_repo "$board")?" >&2; return 1; }
  # Drop the marker line, then trim trailing blank lines it may have left behind.
  # awk keeps this portable across BSD (macOS) and GNU sed (no multi-line sed).
  desc="$(printf '%s\n' "$desc" \
            | awk -v m="$MILESTONE_ACTIVE_MARKER" '
                index($0, m) { sub(m, ""); }
                { line[NR] = $0 }
                END {
                  last = NR
                  while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
                  for (i = 1; i <= last; i++) print line[i]
                }')"
  board_set_milestone_description "$board" "$phase" "$desc" \
    || { echo "milestone: could not mark '$phase' inactive on board $board" >&2; return 1; }
  echo "Deactivated milestone '$phase' on board $board."
}

# List the repo's OPEN milestones, flagging which are active (carry the
# triage:active marker). Active milestones are listed first and marked; inactive
# ones follow. Reads the active set via board_active_milestones and the full open
# set over the same REST endpoint (both through the `_board_gh` seam).
#   milestone_list <board#>
milestone_list() {
  local board="$1" repo active all n
  repo="$(board_repo "$board")" || return 1
  active="$(board_active_milestones "$board")"
  all="$(_board_gh api "repos/$repo/milestones?state=open" 2>/dev/null | _board_sanitize_control_chars | jq -r '.[].title')"
  if [ -z "$all" ]; then
    echo "No open milestones on board $board ($repo)."
    return 0
  fi
  # bash 3.2 (macOS) has no readarray; collect into arrays with a while loop.
  local active_titles=()
  while IFS= read -r n; do [ -n "$n" ] && active_titles+=("$n"); done <<<"$active"
  local active_out="" inactive_out=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if _milestone_is_in "$n" "${active_titles[@]+"${active_titles[@]}"}"; then
      active_out+="  ● $n  (active)"$'\n'
    else
      inactive_out+="  ○ $n"$'\n'
    fi
  done <<<"$all"
  [ -n "$active_out" ]   && printf '── active ──\n%s' "$active_out"
  [ -n "$inactive_out" ] && printf '── inactive ──\n%s' "$inactive_out"
}

# True if $1 is an exact match for any of the remaining args.
_milestone_is_in() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
  return 1
}

# Parse argv (pulling --board out, leaving positionals) and dispatch a subcommand.
milestone_main() {
  [ $# -ge 1 ] || { milestone_usage; return 2; }
  local sub="$1"; shift
  local board=3
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) board="${2:?--board needs a value}"; shift 2 ;;
      -*) echo "unknown flag: $1" >&2; milestone_usage; return 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  set -- "${positional[@]+"${positional[@]}"}"
  board_repo "$board" >/dev/null \
    || { echo "--board must be 3 (stageFind) or 4 (foundation), got: $board" >&2; return 2; }

  case "$sub" in
    activate)
      [ -n "${1:-}" ] || { milestone_usage; return 2; }
      milestone_activate "$board" "$1" ;;
    deactivate)
      [ -n "${1:-}" ] || { milestone_usage; return 2; }
      milestone_deactivate "$board" "$1" ;;
    list)
      milestone_list "$board" ;;
    *) milestone_usage; return 2 ;;
  esac
}

# Execute-guard: run only when this file is RUN, not when SOURCED. A sourcing test
# defines its _board_gh override after board.sh is sourced and calls the functions
# directly (mirrors reconcile.sh / its test).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  milestone_main "$@"
fi
