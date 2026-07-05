#!/usr/bin/env bash
#
# Claim a board item as the FIRST action when starting work on it: mark it
# In Progress and stamp the Host/Session field so other machines can see which
# session owns it.
#
# Why first: the board (GitHub Projects v2) acts as a distributed
# lock across concurrent Claude Code sessions. A slow claim opens a race window
# where a second session reads the item as still-Ready and double-pulls it.
# Claiming as the first action shrinks that window to zero. `worklist.sh` reads
# the board back for the unified cross-machine view. Needs the `project` gh scope
# (gh auth refresh -s project).
#
# --board selects the Projects-v2 board (default 3 = stageFind; 4 = foundation).
#
#   claim.sh 227               # claim issue #227 on the default board (3)
#   claim.sh '#227'            # leading # is fine
#   claim.sh 12 --board 4      # claim issue #12 on the foundation board
#
set -euo pipefail

# Attribution for the gh call-logger shim (F#988): tag every gh call this command
# makes with its outermost context. `:-` preserves an already-set (outer) value,
# so an autonomous driver's context wins over a nested command. See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-claim}"

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
# shellcheck source=scripts/lib/board.sh
source "$SCRIPT_DIR/lib/board.sh"

# Module-level state, set by the execute-guard (direct run) or by a sourcing test
# before it calls claim_main. Defaults match the historical CLI (board 3).
PROJECT_NUMBER=3
issue=""

# Canonical default sink for the append-only claims log (F#728) — computed ONCE as
# a module constant, never re-literal'd at the call site. claim.sh runs from
# CONSUMING checkouts too (stageFind, worker cwds symlink/copy this script), so the
# sink is pinned to the foundation checkout's own raw lake regardless of cwd — this
# is deliberate: the lake is all-boards by design (stageFind claims flow in here
# alongside foundation's own). CLAIMS_RAW_DIR overrides it (tests only).
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's record shape is documented at claim_log_emit below).
CLAIMS_RAW_DIR_DEFAULT="$HOME/dev/foundation/meta/data/raw"

# Append one JSONL record of this claim to the durable session↔issue join key the
# cost model needs (F#728). The board's Host/Session field is OVERWRITTEN by every
# subsequent claim (transient — no history), so it can't answer "which session
# claimed issue N, and when" after the fact; this log can. Sink: canonical
# `$HOME`-based CLAIMS_RAW_DIR_DEFAULT above (override via CLAIMS_RAW_DIR, tests
# only), file `claims-YYYY-MM.jsonl` (monthly rotation, matching the other raw-lake
# streams). ALL-BOARDS BY DESIGN: this is the one canonical foundation checkout's
# lake, so a claim run from a stageFind (or any consuming) checkout still lands
# here — cost attribution is meant to span every board, not just foundation's.
# COVERAGE CAVEAT: meta/data/raw/ is gitignored and per-host, so today this only
# captures work claimed on ONE host; a claim made on a different machine never reaches this file
# until a future cross-host ingest exists to merge raw lakes.
#
# session_id is the RAW, FULL `$CLAUDE_CODE_SESSION_ID` UUID — NOT the truncated
# `host:sess8` board stamp computed above for `stamp`. The cost rollup joins on
# session_id[:8] against the run-status footer's 8-char id; emitting the
# host-prefixed stamp here would join as `mini:c33` garbage and silently break
# attribution. `$sess` (set above, before the stamp is derived from it) already IS
# that raw id — reuse it verbatim, do not re-derive from `$stamp`.
#
# `|| true`-isolated at the call site from claim.sh's `set -e`: this is telemetry,
# never allowed to affect the lock's stamp-then-flip safety ordering (#103/#135).
# A missing/uncreatable sink dir WARNS to stderr and returns — the claim itself
# (already committed via the two board writes above) is never dropped or aborted.
claim_log_emit() {  # $1=item_id
  local dir file ts rec
  dir="${CLAIMS_RAW_DIR:-$CLAIMS_RAW_DIR_DEFAULT}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file="$dir/claims-${ts%-*}.jsonl"   # ts%-* strips DDThh:mm:ssZ, leaving YYYY-MM
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "claim.sh: WARN claims log dir unavailable: $dir (claim recorded on the board; NOT logged to the raw lake)" >&2
    return 0
  fi
  rec=$(printf '{"ts":"%s","host":"%s","session_id":"%s","board":%s,"issue":%s,"item_id":"%s"}' \
    "$ts" "$host" "$sess" "$PROJECT_NUMBER" "$issue" "$1")
  printf '%s\n' "$rec" >>"$file" 2>/dev/null \
    || echo "claim.sh: WARN failed to append claims log record to $file (claim itself still succeeded)" >&2
}

# The whole claim, wrapped so a test can source this file (the execute-guard at
# the bottom suppresses the auto-run when sourced), set $issue / $PROJECT_NUMBER,
# override the board.sh `_board_gh` seam (or board_resolve_item) with canned data,
# and drive claim_main with zero network. Reads the two module vars above.
claim_main() {
  # Resolve project + fields + THIS issue's item by name (robust to field
  # re-creation). board_resolve_item issues a single project view + field-list +
  # one targeted GraphQL lookup for this issue's project item — skipping the
  # whole-board `item-list --limit 200` page that drained the Projects-v2 budget
  # when claim ran in a burst (GH #53). Same globals/accessors as board_resolve.
  board_resolve_item "$PROJECT_NUMBER" "$issue"

  local status_field_id inprogress_opt hostsession_field_id item_id issue_title host sess stamp
  # On an issues-only board (foundation #800) there is no Projects-v2 field/
  # option schema to resolve — BOARD_FIELDS_JSON is always {"fields":[]} there
  # (see ISSUES-ONLY-BACKEND.md) — so board_field_id/board_option_id would
  # always resolve empty and this pre-check would refuse EVERY claim. The
  # issues-only backend drives status/stamp writes entirely through fnd:
  # labels inside board_set_status/board_stamp themselves; skip the
  # Projects-v2-only field-resolution gate for that backend.
  if ! _board_is_issues_only "$PROJECT_NUMBER"; then
    status_field_id=$(board_field_id "$BOARD_FIELD_STATUS")
    inprogress_opt=$(board_option_id "$BOARD_FIELD_STATUS" "$BOARD_OPT_INPROGRESS")
    hostsession_field_id=$(board_field_id "$BOARD_FIELD_HOSTSESSION")

    if [ -z "$status_field_id" ] || [ -z "$inprogress_opt" ] || [ -z "$hostsession_field_id" ]; then
      echo "could not resolve board fields (Status / Host/Session) on project $PROJECT_NUMBER" >&2
      return 1
    fi
  fi

  # Resolve the project item id (and title, for the tmux window name) for this issue.
  item_id=$(board_item_id "$issue")
  issue_title=$(board_item_title "$issue")
  [ -n "$item_id" ] || { echo "issue #$issue is not on project $PROJECT_NUMBER" >&2; return 1; }

  host="${SUBSET_HOST_LABEL:-$(hostname -s)}"
  sess="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$sess" ]; then stamp="${host}:${sess:0:8}"; else stamp="${host}:manual"; fi

  # Cross-session lock contention pre-check (foundation #800, extended to the
  # Projects-v2 arm): refuses a claim already held by a DIFFERENT host:session
  # stamp, on EITHER backend — the item is already resolved above (via
  # board_resolve_item), so this is one more jq read against the warm
  # BOARD_ITEMS_JSON, no extra `gh`/GraphQL call. See board_claim_contended's
  # own header comment for exactly what does/does not count as contended
  # (self-reclaim and half-claim adoption are both safe).
  local foreign_stamp
  if foreign_stamp="$(board_claim_contended "$PROJECT_NUMBER" "$issue" "$stamp")"; then
    echo "claim refused: #$issue is already In Progress, claimed by [$foreign_stamp] — verify there (or via reconcile.sh) before taking it." >&2
    return 1
  fi

  # The claim is two board writes, and their ORDER is the lock's safety property:
  # stamp the owner FIRST, flip the In-Progress status LAST. The status flip is
  # the lock — the one observable, contended commit; everything else is metadata.
  # Under `set -e` a failed write aborts, so by committing the lock last, any
  # failure (rate-limit, GraphQL blip) leaves the item in a SAFE state:
  #   - stamp fails  → status never flipped → item stays Ready / un-claimed (no
  #                    phantom lock; the exact #103 failure this ordering fixes).
  #   - status fails → item still Ready, merely carrying an owner stamp — harmless
  #                    (worklist.sh shows In-Progress only) and overwritten by the
  #                    next claim.
  # Do NOT reorder these: flipping status before the stamp re-introduces the
  # ownerless In-Progress lock (GH #135). Stamping while still Ready is safe — the
  # Host/Session field is pure metadata until the status flip makes it a claim.

  # 1) Stamp Host/Session (owner metadata) — safe to write while still Ready.
  board_stamp "$item_id" "$BOARD_FIELD_HOSTSESSION" "$stamp"

  # 2) Flip In Progress — the claim-first lock; the atomic commit, done LAST.
  board_set_status "$item_id" "$BOARD_OPT_INPROGRESS"

  echo "Claimed #$issue → In Progress  [$stamp]"

  # 3) Append to the durable claims log (F#728) — AFTER the lock is committed, so
  #    a telemetry failure can never affect the stamp-then-flip ordering above.
  #    See claim_log_emit's header comment for the sink, all-boards intent, and
  #    the single-host coverage caveat.
  claim_log_emit "$item_id" || true

  # 4) Surface the claim in whatever terminal multiplexer is present. The marker
  #    helper is multiplexer-aware and SELF-GUARDS per surface, so we compute the
  #    display string unconditionally and always call it — it is a no-op outside
  #    every multiplexer. The surfaces it drives:
  #    - tmux rename-window: sets the window *name* (#W) — the tmux window-status
  #      list and the tab title under plain tmux. A manual rename also disables
  #      automatic-rename for the window, so the name sticks.
  #    - tmux @claimed_issue: a per-window option read by the status bar
  #      (`status-right`) — the lever for iTerm2 control mode (`tmux -CC`), where
  #      the native tab follows the *pane* title (owned by Claude Code's live
  #      summary), so the window name never reaches the tab. status-right falls
  #      back to "No Issue Claimed" when empty. See GH #251.
  #    - cmux set-status: a per-workspace status chip (GH #348), for sessions
  #      running under cmux instead of tmux.
  #    The tmux surfaces apply to THIS session's own window (the pane Claude runs
  #    in), not the server's "current" window — else a claim from one session
  #    brands a concurrent session's window (GH #297). `scripts/release.sh` clears
  #    the marker when work on the item stops.
  local wname title_max short
  wname="#$issue"
  if [ -n "$issue_title" ]; then
    title_max=22                       # tune: chars of title shown after the number
    short="$issue_title"
    if [ "${#short}" -gt "$title_max" ]; then short="${short:0:$title_max}…"; fi
    wname="#$issue $short"
  fi
  claim_marker_set "$wname"
}

# Execute-guard: run the claim only when this file is RUN, not when SOURCED. When
# sourced (BASH_SOURCE[0] != $0), a test sets $issue / $PROJECT_NUMBER, defines
# its seam overrides, and calls claim_main itself — keeping the CLI parsing and
# the module-var defaults untouched.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --board) PROJECT_NUMBER="${2:?--board needs a value}"; shift 2 ;;
      --) shift; break ;;
      -*) echo "unknown arg: $1" >&2; exit 2 ;;
      *) if [ -z "$issue" ]; then issue="$1"; shift; else echo "unexpected arg: $1" >&2; exit 2; fi ;;
    esac
  done
  [ -n "$issue" ] || { echo "usage: claim.sh <issue-number> [--board 3|4]" >&2; exit 2; }
  issue="${issue#\#}"
  [[ "$issue" =~ ^[0-9]+$ ]] || { echo "issue must be a number, got: $issue" >&2; exit 2; }
  claim_main
fi
