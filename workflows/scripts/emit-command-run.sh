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
#   emit-command-run.sh --command sweep|triage|fix --board <N> \
#     --items-processed <N> --merged <N> --resolved <N> --parked <N> \
#     --reported-no-op <N> [--epic <N>]
#
# Appends ONE JSONL line to:
#   ${CMD_RUN_RAW_DIR:-<repo>/meta/data/raw}/command-runs-YYYY-MM.jsonl
# (monthly rotation, matching the pipeline-<YYYY-MM>.jsonl / session-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {ts, session_id, command, board, items_processed, merged, resolved, parked, reported_no_op, epic?}
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
#   command          "sweep" | "triage" | "fix" (whatever --command was passed,
#                     verbatim)
#   board            the board id (--board), or null
#   items_processed  integer — how many items the run drove/considered
#   merged           integer — how many landed a merged PR
#   resolved         integer — how many reached a terminal outcome that is
#                     NOT a merge: a `kind: spike` closed on its verdict, a
#                     culled issue, a decision routed off-board. Added by
#                     temperloop#1084 — before it, /sweep folded these into
#                     `merged` (or, worse, into nothing at all, so the counts
#                     did not reconcile against items_processed).
#                     ⚠ ABSENT on a record written before #1084 — and absent
#                     means UNKNOWN, never 0. This stream is append-only and is
#                     NEVER backfilled, so a consumer must distinguish `has no
#                     resolved field` (a pre-#1084 record: some of its `merged`
#                     count may in fact be verdict-resolved) from
#                     `"resolved": 0` (a post-#1084 run that genuinely resolved
#                     nothing). Every record this script writes from #1084 on
#                     carries the field explicitly, so its absence is a
#                     reliable pre-#1084 marker. Purely additive, so no
#                     schema_version bump (meta/data/raw/README.md convention).
#   parked           integer — how many were parked/deferred/escalated
#   reported_no_op   integer — how many were a terminal "nothing to do" outcome
#                     that is not a merge, a verdict-resolve, or a park: an
#                     already-done target, a claim already held by another
#                     session, or an epic-refused redirect (`/fix` 4d/4e/Step
#                     3). Added by temperloop#1103 — before it, `/fix`'s two
#                     reported-no-op routes (4d/4e) never called this emitter
#                     at all, so a no-op /fix run had no way to reconcile:
#                     items_processed=1 with merged=resolved=parked=0 would
#                     have tripped the loud failure below on every single
#                     no-op run, so fix.md instead skipped the emit entirely —
#                     which meant a no-op /fix run left NO telemetry record,
#                     the exact absent-signal failure this whole script exists
#                     to close.
#                     ⚠ ABSENT on a record written before #1103 — and absent
#                     means UNKNOWN, never 0, same convention as `resolved`
#                     above: this stream is append-only and is NEVER
#                     backfilled, so a pre-#1103 record's true disposition
#                     mix (e.g. a /fix no-op that got folded into no count at
#                     all, or simply never emitted) cannot be recovered.
#                     Every record this script writes from #1103 on carries
#                     the field explicitly, so its absence is a reliable
#                     pre-#1103 marker. Purely additive, so no schema_version
#                     bump (meta/data/raw/README.md convention).
#   epic             OPTIONAL — the epic issue number the run drove against
#                     (e.g. `/assess --epic N`, or `/build` on a plan note with
#                     an `epic:` frontmatter field). ABSENT (not null/empty)
#                     from the record entirely when the caller doesn't pass
#                     `--epic` — most command-run callers (sweep/triage) never
#                     run against a single epic, so this keeps their records
#                     shaped exactly as before (purely additive; no
#                     schema_version bump per the convention in
#                     meta/data/raw/README.md).
#
# WARN, DON'T DROP: any INFRASTRUCTURE failure here (jq missing, sink
# unwritable, disk full, a malformed count) warns to stderr and exits 0. A
# telemetry emit must never fail or block the calling command — see the
# `|| true`-safe contract in the epic #724 Contract.
#
# THE ONE LOUD FAILURE — a disposition-accounting mismatch (temperloop#1084,
# extended to a four-way partition by temperloop#1103).
# `merged + resolved + parked + reported_no_op` MUST equal `items_processed`:
# every item a run drove reaches exactly one terminal disposition, so the four
# counts partition the total. If they don't, the run produced an outcome this
# schema cannot express — precisely the silent under-report #1084 was filed
# for (a 30-item sweep emitting merged=27, parked=1 and no way to say the
# other 2 were resolved by verdict), and the same class of bug #1103 was filed
# for (a /fix no-op run emitting items_processed=1 with nothing else set,
# because the schema had no fourth field to say "nothing happened, on
# purpose"). That is an ACCOUNTING bug in the caller or a MISSING FIELD in
# this schema, not an infrastructure hiccup, so it must not be swallowed:
#
#   * the record IS still appended, with the caller's counts verbatim — the
#     mismatch is preserved in the stream rather than dropped, because an
#     inconsistent record is strictly more informative than no record (the
#     absent-stream ambiguity this whole script exists to close), and
#   * the script then prints a FAIL line naming the arithmetic and exits **2**.
#
# Exit codes: 0 = emitted, or warned-and-skipped for an infrastructure reason
#             2 = record emitted BUT the disposition counts do not reconcile
# A caller that must never see a non-zero (a `|| true` site) keeps working; a
# caller or CI reading the exit code sees the accounting break loudly.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

command=""
board=""
items_processed=""
merged=""
resolved=""
parked=""
reported_no_op=""
epic=""

# ARG LOOP — the shift is deliberately TWO steps (temperloop#1342). Bash's
# `shift 2` FAILS (count out of range) when the flag is the LAST argument, and
# a FAILED shift does not shift: `$#` never decreases, the same arm re-matches,
# and this loop spins at 100% CPU forever. `${2:-}` is what makes that a HANG
# rather than a `set -u` crash. A hang here is strictly worse than the failure
# this file's never-fail-or-block-the-spawn-site contract exists to prevent —
# the conventional `emit-… || true` call shape cannot save a caller from it.
# So: shift the FLAG, then the value only if one is actually there.
# scripts/lint-argloop-shift2.sh is the mechanical guard for the class.
while [ $# -gt 0 ]; do
  case "$1" in
    --command) command="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --board) board="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --items-processed) items_processed="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --merged) merged="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --resolved) resolved="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --parked) parked="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --reported-no-op) reported_no_op="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --epic) epic="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
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
# is more useful for staleness detection than no record at all. (0/0/0/0 still
# reconciles, so the no-counter caller never trips the accounting check below.)
items_processed="${items_processed:-0}"
merged="${merged:-0}"
resolved="${resolved:-0}"
parked="${parked:-0}"
reported_no_op="${reported_no_op:-0}"

# A count that isn't a non-negative integer is an infrastructure-class caller
# error, not an accounting one: warn and emit nothing (exit 0). Previously jq
# would fail on the --argjson and produce the generic "failed to build JSON
# record" warning; naming the offending flag is strictly more useful.
check_count() {  # $1=flag $2=value → 0 ok, 1 malformed (already warned)
  case "$2" in
    ''|*[!0-9]*)
      printf '%s: WARN %s must be a non-negative integer, got "%s" — no record emitted (command=%s)\n' \
        "$self" "$1" "$2" "$command" >&2
      return 1 ;;
  esac
  return 0
}

check_count --items-processed "$items_processed" || exit 0
check_count --merged          "$merged"          || exit 0
check_count --resolved        "$resolved"        || exit 0
check_count --parked          "$parked"          || exit 0
check_count --reported-no-op  "$reported_no_op"  || exit 0

# Normalise to base-10 so a zero-padded count ("08") is neither read as octal
# by $(( )) nor emitted as invalid JSON by jq --argjson.
items_processed=$((10#$items_processed))
merged=$((10#$merged))
resolved=$((10#$resolved))
parked=$((10#$parked))
reported_no_op=$((10#$reported_no_op))

# THE ACCOUNTING CHECK (temperloop#1084, extended #1103) — see the header.
# Computed BEFORE the emit so the failure message is ready, but acted on
# AFTER it so the record is never dropped over it.
disposition_total=$((merged + resolved + parked + reported_no_op))
reconciles=1
[ "$disposition_total" -eq "$items_processed" ] || reconciles=0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"

# Resolve the raw sink dir the same way pipeline-cron.sh resolves PIPELINE_RAW_DIR:
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
  --argjson resolved "$resolved" \
  --argjson parked "$parked" \
  --argjson reported_no_op "$reported_no_op" \
  --arg epic "$epic" \
  '{
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    command: $command,
    board: (if $board == "" then null else ($board | tonumber? // $board) end),
    items_processed: $items_processed,
    merged: $merged,
    resolved: $resolved,
    parked: $parked,
    reported_no_op: $reported_no_op
  }
  + (if $epic == "" then {} else {epic: ($epic | tonumber? // $epic)} end)' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (command=%s) — no record emitted\n' "$self" "$command" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (command=%s)\n' "$self" "$raw_file" "$command" >&2
  exit 0
fi

printf '%s\n' "$record"

# The record is safely on disk; NOW fail loudly if the dispositions don't add up.
if [ "$reconciles" -ne 1 ]; then
  printf '%s: FAIL disposition counts do not reconcile (command=%s): merged(%s) + resolved(%s) + parked(%s) + reported_no_op(%s) = %s, but --items-processed is %s.\n' \
    "$self" "$command" "$merged" "$resolved" "$parked" "$reported_no_op" "$disposition_total" "$items_processed" >&2
  printf '%s: every item a run drives must reach exactly one terminal disposition, so the four counts must partition the total. Either the caller miscounted, or the run produced an outcome this schema cannot express — in which case the fix is a new disposition field here, NOT a fudged total. Canonical shape: meta/data/raw/README.md (command-run stream).\n' \
    "$self" >&2
  printf '%s: the record above WAS appended to %s (the mismatch is preserved in the stream, not swallowed).\n' \
    "$self" "$raw_file" >&2
  exit 2
fi
