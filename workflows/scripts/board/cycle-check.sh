#!/usr/bin/env bash
#
# cycle-check.sh — refuse a candidate native `blocked_by` edge that would
# close a cycle in the dependency graph (temperloop#1847, docs/adr/0031).
#
#   cycle-check.sh --board 7 <issue#> <blocker#>
#   cycle-check.sh --board temperloop 42 17
#
# ── What this answers ─────────────────────────────────────────────────────
# `/triage`'s Step-4 materialization sub-step stamps DURABLE, meaning-level
# `blocked_by` order between an Operational epic's members (docs/adr/0031).
# Before each write it must know: does "<issue#> is blocked_by <blocker#>"
# close a loop with edges that ALREADY exist? A loop exists iff <blocker#>
# is already (directly or transitively) blocked_by <issue#> — i.e. the
# graph already says <issue#> must finish before <blocker#>, and the
# candidate edge would additionally say <blocker#> must finish before
# <issue#>.
#
# The walk is a BFS over the LIVE `blocked_by` graph, read exclusively
# through the board adapter's `board_blocked_by_open` (never a raw `gh api`
# call — same "route board reads through the adapter" rule every other
# script here follows), starting from <blocker#> and following its own
# blockers outward. If <issue#> is ever reached, the candidate edge closes
# a cycle.
#
# ── Output grammar (stdout, exactly one line) ────────────────────────────
#   SAFE <issue> <blocker>
#     no path from <blocker> back to <issue> was found — the edge may be
#     written.
#   CYCLE <issue> <blocker> path=<blocker>-> ... -><issue>
#     writing the edge would close a loop; `path=` names the existing chain
#     of blocked_by edges that already runs from <blocker> to <issue>.
#   UNREADABLE <issue> <blocker> reason=<why>
#     the walk could not be completed (a `board_blocked_by_open` read
#     failed, or the walk exceeded CYCLE_CHECK_MAX_NODES). Treat exactly
#     like CYCLE — refuse the write. A caller must never read "not CYCLE"
#     as "safe"; only an explicit SAFE line authorizes the write.
#
# Exit status is ALWAYS 0 once a verdict line was printed — a non-zero exit
# here would abort a `set -e` caller mid-sweep over what is, by design, an
# ordinary refusal outcome (see claim-guard.sh, which states the identical
# reasoning for its own always-0 contract). Exit 2 is reserved for a usage
# error (bad args), which prints no verdict line at all.
#
# ── Fail SAFE, not open ───────────────────────────────────────────────────
# Any read failure along the walk (an unreadable issue, a board that will
# not resolve, a graph too large to finish walking) reports UNREADABLE and
# refuses — it never reports SAFE on an incomplete walk. A deferred edge
# costs nothing; a wrongly-written cyclic edge corrupts the dependency
# graph for every downstream reader (`/next`, `/fix`, `/sweep`).
#
# Needs only the DEFAULT `repo` gh scope: blocked_by is a plain per-issue
# REST dependencies read (workflows/scripts/board/ISSUES-ONLY-BACKEND.md).
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this
# command makes, preserving an already-set outer value so a caller's own
# context wins over this nested command's.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-cycle-check}"

# Resolve symlinks so the script finds its real lib/ even invoked through a
# symlink (PATH, or a consuming repo's scripts/ dir) — BASH_SOURCE points at
# the symlink, not the real file. Portable (no GNU readlink -f). Mirrors
# claim-guard.sh / claim.sh.
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$src")" && pwd)"
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/board.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing
# test before it calls cycle_check_main. Mirrors claim-guard.sh's shape.
PROJECT_NUMBER=3
CYCLE_CHECK_ISSUE=""
CYCLE_CHECK_BLOCKER=""
# A generous but finite cap on nodes walked, so a malformed or enormous
# graph fails LOUD (UNREADABLE) instead of hanging. Not expected to bind in
# practice — a triage-stamped dependency graph is epic-sized, not board-wide.
CYCLE_CHECK_MAX_NODES="${CYCLE_CHECK_MAX_NODES:-500}"

# cycle_check_main -> prints exactly ONE verdict line (see grammar above).
# Deliberately NO associative arrays and NO array-slice expansions
# (`${a[@]:off}`) — this file must run under bash 3.2 (macOS's shipped
# /bin/bash; see test_claim_guard.sh's own note on the same constraint), so
# the BFS frontier is two plain, index-walked arrays (queue + qpath) rather
# than a parent map.
cycle_check_main() {
  local issue="$CYCLE_CHECK_ISSUE" blocker="$CYCLE_CHECK_BLOCKER"

  # A self-referential edge is a degenerate 1-node cycle — refuse it without
  # spending a single read.
  if [ "$issue" = "$blocker" ]; then
    printf 'CYCLE %s %s path=%s->%s (self-blocker)\n' "$issue" "$blocker" "$blocker" "$issue"
    return 0
  fi

  local -a queue qpath
  queue=("$blocker")
  qpath=("$blocker")
  local visited=" $blocker "
  local nodes=0 head=0 n path open m

  while [ "$head" -lt "${#queue[@]}" ]; do
    n="${queue[$head]}"
    path="${qpath[$head]}"
    head=$((head + 1))
    nodes=$((nodes + 1))
    if [ "$nodes" -gt "$CYCLE_CHECK_MAX_NODES" ]; then
      printf 'UNREADABLE %s %s reason=graph-too-large(>%s nodes walked)\n' "$issue" "$blocker" "$CYCLE_CHECK_MAX_NODES"
      return 0
    fi
    # A read failure anywhere in the walk means the graph could not be
    # fully seen — never conclude SAFE from a partial walk.
    if ! open="$(board_blocked_by_open "$PROJECT_NUMBER" "$n")"; then
      printf 'UNREADABLE %s %s reason=blocked_by-read-failed(#%s)\n' "$issue" "$blocker" "$n"
      return 0
    fi
    [ -n "$open" ] || continue
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      if [ "$m" = "$issue" ]; then
        printf 'CYCLE %s %s path=%s->%s\n' "$issue" "$blocker" "$path" "$m"
        return 0
      fi
      case "$visited" in
        *" $m "*) ;;  # already queued/visited this run — skip, keeps the walk finite on a diamond graph
        *)
          visited="$visited$m "
          queue+=("$m")
          qpath+=("$path->$m")
          ;;
      esac
    done <<<"$open"
  done

  printf 'SAFE %s %s\n' "$issue" "$blocker"
  return 0
}

# Execute-guard: run only when this file is RUN, not when SOURCED (a test
# sets $PROJECT_NUMBER / $CYCLE_CHECK_ISSUE / $CYCLE_CHECK_BLOCKER, defines
# its own board_blocked_by_open/_board_gh override, and calls
# cycle_check_main directly). Mirrors claim-guard.sh's guard shape.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --board)
        [ $# -ge 2 ] || { echo "usage: cycle-check.sh [--board 3|4|5|6|7|<name>] <issue-number> <blocker-number>" >&2; exit 2; }
        PROJECT_NUMBER="$(board_resolve_name "$2")" || exit 2
        shift 2
        ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if [ "$#" -ne 2 ]; then
    echo "usage: cycle-check.sh [--board 3|4|5|6|7|<name>] <issue-number> <blocker-number>" >&2
    exit 2
  fi
  CYCLE_CHECK_ISSUE="${1#\#}"
  CYCLE_CHECK_BLOCKER="${2#\#}"
  case "$CYCLE_CHECK_ISSUE" in '' | *[!0-9]*) echo "issue must be a number, got: $1" >&2; exit 2 ;; esac
  case "$CYCLE_CHECK_BLOCKER" in '' | *[!0-9]*) echo "blocker must be a number, got: $2" >&2; exit 2 ;; esac
  cycle_check_main
fi
