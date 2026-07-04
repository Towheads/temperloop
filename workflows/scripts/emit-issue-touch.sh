#!/usr/bin/env bash
#
# emit-issue-touch.sh — append one record to the append-only issue-touches
# raw-lake stream, recording a `pr-open` or `merge` work-touch on an issue
# (foundation #916/#919, epic #916 "issue-touch-stream"). Sibling to
# emit-command-run.sh: same structure, arg style, and lake-dir resolution.
#
# WHY THIS EXISTS: build.md's Step 3f (PR opened) and Step 4d (PR confirmed
# MERGED) are the only places those two touches happen for a plan item — but,
# like /sweep and /triage before emit-command-run.sh existed, a prose
# orchestrator step can silently rot (an LLM-executed markdown instruction
# gets skipped or paraphrased away and nobody notices, because the failure
# mode is an ABSENT record, not an error). This script is the mechanical fix:
# a concrete, invocable emit, backed by a presence-lint
# (workflows/scripts/validate-issue-touch-emit.sh, wired into
# scripts/quality-gates.sh) that fails CI if this script disappears OR its
# calls are removed from claude/commands/build.md's 3f/4d steps.
#
# Claim touches are DELIBERATELY NOT emitted by this script — the existing
# claims-<YYYY-MM>.jsonl stream (scripts/board/claim.sh's claim_log_emit)
# already covers them and is unioned at read time with this stream. Capture
# touches are likewise emitted separately, by scripts/board/capture.sh's own
# issue_touch_log_emit (same record shape, `kind:"capture"`), not by this
# script — this script only ever emits `kind` in {pr-open, merge}.
#
# Usage:
#   emit-issue-touch.sh --repo <owner/repo> --issue <N> --kind pr-open|merge
#
# Appends ONE JSONL line to:
#   ${ISSUE_TOUCHES_RAW_DIR:-<repo>/meta/data/raw}/issue-touches-YYYY-MM.jsonl
# (monthly rotation, matching the claims-YYYY-MM.jsonl / command-runs-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {schema_version, ts, repo, issue, session_id, host, kind}
#   schema_version   "1" (string) — bump on a breaking shape change
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   repo             "owner/repo" the issue lives in, verbatim from --repo
#   issue            integer issue number, verbatim from --issue
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED),
#                     null when unset — same join-key convention as
#                     emit-command-run.sh and claim.sh's claim_log_emit
#                     (deliberately NOT the truncated host:sess8 board stamp)
#   host             $SUBSET_HOST_LABEL if set, else `hostname -s` — same
#                     derivation as scripts/board/claim.sh's claim_main
#   kind             "pr-open" | "merge" (verbatim from --kind; a `capture`
#                     record is emitted by capture.sh itself, never here)
#
# WARN, DON'T DROP: any failure here (bad args, jq missing, sink unwritable,
# disk full) warns to stderr and exits 0. A telemetry emit must never fail or
# block the calling orchestrator step (build.md 3f/4d) — see the `|| true`-safe
# contract in the epic #724 Contract (the same contract emit-command-run.sh
# follows).
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

repo=""
issue=""
kind=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --issue) issue="${2:-}"; shift 2 ;;
    --kind) kind="${2:-}"; shift 2 ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$repo" ] || [ -z "$issue" ] || [ -z "$kind" ]; then
  printf '%s: WARN --repo, --issue, and --kind are all required — no record emitted\n' "$self" >&2
  exit 0
fi

case "$issue" in
  ''|*[!0-9]*)
    printf '%s: WARN --issue must be a number, got %s — no record emitted\n' "$self" "$issue" >&2
    exit 0
    ;;
esac

case "$kind" in
  pr-open|merge) : ;;
  *)
    printf '%s: WARN --kind must be pr-open or merge, got %s — no record emitted\n' "$self" "$kind" >&2
    exit 0
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (repo=%s issue=%s kind=%s)\n' "$self" "$repo" "$issue" "$kind" >&2
  exit 0
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"
host="${SUBSET_HOST_LABEL:-$(hostname -s)}"

# Resolve the raw sink dir the same way emit-command-run.sh resolves
# CMD_RUN_RAW_DIR: an explicit override env var first, else the repo this
# script lives in (workflows/scripts/../../meta/data/raw), so it works from
# any checkout that vendors this file, not just a hardcoded $HOME/dev/foundation
# path.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${ISSUE_TOUCHES_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/issue-touches-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

record="$(jq -nc \
  --arg ts "$ts" \
  --arg repo "$repo" \
  --argjson issue "$issue" \
  --arg session_id "$session_id" \
  --arg host "$host" \
  --arg kind "$kind" \
  '{
    schema_version: "1",
    ts: $ts,
    repo: $repo,
    issue: $issue,
    session_id: (if $session_id == "" then null else $session_id end),
    host: $host,
    kind: $kind
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (repo=%s issue=%s kind=%s) — no record emitted\n' "$self" "$repo" "$issue" "$kind" >&2
  exit 0
fi

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (repo=%s issue=%s kind=%s)\n' "$self" "$raw_file" "$repo" "$issue" "$kind" >&2
  exit 0
fi

printf '%s\n' "$record"
