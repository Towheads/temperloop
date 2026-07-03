#!/usr/bin/env bash
#
# emit-command-run.sh — append one per-run telemetry record for a /sweep or
# /triage command run to the append-only raw sink (foundation #729).
#
# WHY THIS EXISTS: /sweep and /triage have no plan-note footer (unlike /build,
# whose plan note IS the run record), so a whole run could complete — or
# silently stop emitting — with no telemetry signal at all. That is the June
# silent-failure class: a stream nobody writes to produces no staleness alarm,
# so its absence looks identical to "nothing to do" rather than "broken." This
# script is the mechanical fix: a concrete, invocable emit, backed by a
# presence-lint (workflows/scripts/validate-command-run-emit.sh, wired into
# `scripts/quality-gates.sh`) that fails CI if this script disappears OR its
# call is removed from claude/commands/sweep.md / claude/commands/triage.md.
#
# Usage:
#   emit-command-run.sh --command sweep|triage --board <N> \
#     --items-processed <N> --merged <N> --parked <N>
#
# Appends ONE JSONL line to:
#   ${CMD_RUN_RAW_DIR:-<repo>/meta/data/raw}/command-runs-YYYY-MM.jsonl
# (monthly rotation, matching the funnel-<YYYY-MM>.jsonl / session-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {ts, session_id, command, board, items_processed, merged, parked}
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED) —
#                     the join key every other raw/ stream keys on
#                     (askuserquestion-events.jsonl, workflow-eval-results.jsonl);
#                     deliberately NOT the 8-char truncated form claim.sh stamps
#                     onto the board's Host/Session field for human display —
#                     that truncation is a UI convenience, not a join key, and
#                     truncating here would break the join to Layer-2 session
#                     telemetry this record exists to support. null when the
#                     env var is unset (e.g. a manual/non-Claude-Code run).
#   command          "sweep" | "triage" (whatever --command was passed, verbatim)
#   board            the logical board number (--board), or null
#   items_processed  integer — how many items the run drove/considered
#   merged           integer — how many reached a successful terminal outcome
#   parked           integer — how many were parked/deferred/escalated
#
# WARN, DON'T DROP: any failure here (jq missing, sink unwritable, disk full)
# warns to stderr and exits 0. A telemetry emit must never fail or block the
# calling command — see the `|| true`-safe contract in the epic #724 Contract.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

command=""
board=""
items_processed=""
merged=""
parked=""

while [ $# -gt 0 ]; do
  case "$1" in
    --command) command="${2:-}"; shift 2 ;;
    --board) board="${2:-}"; shift 2 ;;
    --items-processed) items_processed="${2:-}"; shift 2 ;;
    --merged) merged="${2:-}"; shift 2 ;;
    --parked) parked="${2:-}"; shift 2 ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$command" ]; then
  printf '%s: WARN --command is required — no record emitted\n' "$self" >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (command=%s)\n' "$self" "$command" >&2
  exit 0
fi

# Default remaining counters to 0 (numeric) rather than failing — a caller
# that only knows command/board can still get a record with 0 counts, which
# is more useful for staleness detection than no record at all.
items_processed="${items_processed:-0}"
merged="${merged:-0}"
parked="${parked:-0}"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"

# Resolve the raw sink dir the same way funnel-cron.sh resolves FUNNEL_RAW_DIR:
# an explicit override env var first, else the repo this script lives in
# (workflows/scripts/../../meta/data/raw), so it works from any checkout that
# vendors this file, not just a hardcoded $HOME/dev/foundation path.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${CMD_RUN_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/command-runs-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

record="$(jq -nc \
  --arg ts "$ts" \
  --arg session_id "$session_id" \
  --arg command "$command" \
  --arg board "$board" \
  --argjson items_processed "$items_processed" \
  --argjson merged "$merged" \
  --argjson parked "$parked" \
  '{
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    command: $command,
    board: (if $board == "" then null else ($board | tonumber? // $board) end),
    items_processed: $items_processed,
    merged: $merged,
    parked: $parked
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (command=%s) — no record emitted\n' "$self" "$command" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (command=%s)\n' "$self" "$raw_file" "$command" >&2
  exit 0
fi

printf '%s\n' "$record"
