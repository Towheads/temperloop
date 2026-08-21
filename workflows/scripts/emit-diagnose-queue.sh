#!/usr/bin/env bash
#
# emit-diagnose-queue.sh — append one record to the append-only diagnose-queue
# raw-lake stream (temperloop#1192), recording ONE verdict per
# gate.sh `cmd_diagnose_queue` call. Sibling to emit-command-run.sh /
# emit-issue-touch.sh / emit-gh-perf.sh: same structure, arg style, and
# lake-dir resolution.
#
# WHY THIS EXISTS: gate.sh's diagnose-queue subcommand classifies a stalled
# native merge-queue poll into a structured verdict that /build and /fix
# branch their merge decisions on — but that verdict was computed and then
# discarded, with no durable record of which verdicts actually fire in
# practice, at what rate, or how often the queue stalls vs genuinely fails.
# This script is the ONE place a diagnose-queue call becomes a lake record.
#
# WARN, DON'T DROP: this is TELEMETRY, never part of gate.sh's own closed
# exit-code contract. Any failure here (bad args, jq missing, sink
# unwritable) warns to stderr and exits 0 — an emit call must NEVER fail or
# change gate.sh's own exit code, which /build and /fix branch merge
# decisions on. gate.sh's own header: merge CONSENT and outcome computation
# live there; this script only records what already happened, as a
# subprocess call gate.sh's cmd_diagnose_queue makes on every exit path
# (including its own internal die() paths) — never inlined into gate.sh
# itself.
#
# Usage:
#   emit-diagnose-queue.sh --repo <owner/repo> --pr <N> --outcome <OUTCOME> \
#                           [--detail-json <json>]
#
#   OUTCOME one of: QUEUED MERGED MERGE_GROUP_FAILED MERGE_GROUP_INFRA
#                    DEQUEUED QUEUE_STALLED ERROR
#     (the full current cmd_diagnose_queue verdict set — gate.sh's own header
#     "diagnose-queue" section is the source of truth for this list; kept in
#     sync by hand. MERGE_GROUP_INFRA and QUEUE_STALLED landed in epic #1207,
#     after #1192 — the issue this stream implements — was originally filed,
#     so the older issue's verdict list undercounts and must not be trusted.)
#
#   --detail-json is the verdict's own outcome-specific fields (e.g.
#     {"run_id":123} or {"enqueued_secs":900,"merge_group_runs":0} or
#     {"error":"..."}) verbatim as produced by cmd_diagnose_queue — opaque to
#     this script, stored as-is. Defaults to `{}` when omitted or unparseable
#     (WARN-don't-drop extends to a malformed detail payload: better an empty
#     detail than a lost record).
#
# Appends ONE JSONL line to:
#   ${DIAGNOSE_QUEUE_RAW_DIR:-<repo>/meta/data/raw}/diagnose-queue-YYYY-MM.jsonl
# (monthly rotation, matching the claims-/command-runs-/issue-touches-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented there too).
#
# Record shape: {schema_version, ts, repo, pr, outcome, detail, session_id, host}
#   schema_version   "1" (string) — bump on a breaking shape change
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   repo             "owner/repo" the PR lives in, verbatim from --repo
#   pr               integer PR number, verbatim from --pr
#   outcome          one of the closed verdict set above, verbatim from --outcome
#   detail           the verdict's own extra fields, verbatim from --detail-json
#                     (or `{}` when omitted/unparseable)
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED),
#                     null when unset — same join-key convention as
#                     emit-command-run.sh / emit-issue-touch.sh
#   host             $SUBSET_HOST_LABEL if set, else `hostname -s` — same
#                     derivation as the sibling emit scripts
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

repo=""
pr=""
outcome=""
detail_json=""

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
    --repo)        repo="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --pr)          pr="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --outcome)     outcome="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --detail-json) detail_json="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$outcome" ]; then
  printf '%s: WARN --repo, --pr, and --outcome are all required — no record emitted\n' "$self" >&2
  exit 0
fi

case "$pr" in
  ''|*[!0-9]*)
    printf '%s: WARN --pr must be a number, got %s — no record emitted\n' "$self" "$pr" >&2
    exit 0
    ;;
esac

case "$outcome" in
  QUEUED|MERGED|MERGE_GROUP_FAILED|MERGE_GROUP_INFRA|DEQUEUED|QUEUE_STALLED|ERROR) : ;;
  *)
    printf '%s: WARN --outcome must be one of QUEUED|MERGED|MERGE_GROUP_FAILED|MERGE_GROUP_INFRA|DEQUEUED|QUEUE_STALLED|ERROR, got %s — no record emitted\n' "$self" "$outcome" >&2
    exit 0
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (repo=%s pr=%s outcome=%s)\n' "$self" "$repo" "$pr" "$outcome" >&2
  exit 0
fi

# detail-json is opaque and caller-controlled — validate it parses as JSON,
# falling back to {} rather than dropping the whole record on a malformed
# blob (WARN-don't-drop extends to a bad detail payload too).
if [ -z "$detail_json" ] || ! jq -e . >/dev/null 2>&1 <<<"$detail_json"; then
  detail_json='{}'
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"
host="${SUBSET_HOST_LABEL:-$(hostname -s)}"

# Resolve the raw sink dir the same way emit-issue-touch.sh / emit-command-run.sh
# resolve theirs: an explicit override env var first, else the repo this
# script lives in (workflows/scripts/../.. = repo root), so it works from any
# checkout that vendors this file, not just a hardcoded $HOME/dev/foundation path.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${DIAGNOSE_QUEUE_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/diagnose-queue-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

record="$(jq -nc \
  --arg ts "$ts" \
  --arg repo "$repo" \
  --argjson pr "$pr" \
  --arg outcome "$outcome" \
  --argjson detail "$detail_json" \
  --arg session_id "$session_id" \
  --arg host "$host" \
  '{
    schema_version: "1",
    ts: $ts,
    repo: $repo,
    pr: $pr,
    outcome: $outcome,
    detail: $detail,
    session_id: (if $session_id == "" then null else $session_id end),
    host: $host
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (repo=%s pr=%s outcome=%s) — no record emitted\n' "$self" "$repo" "$pr" "$outcome" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (repo=%s pr=%s outcome=%s)\n' "$self" "$raw_file" "$repo" "$pr" "$outcome" >&2
  exit 0
fi

printf '%s\n' "$record"
