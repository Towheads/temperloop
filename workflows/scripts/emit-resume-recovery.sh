#!/usr/bin/env bash
#
# emit-resume-recovery.sh — append one record to the append-only
# resume-recovery raw-lake stream (temperloop#1908), recording ONE `/build`
# Step 0.5 resume that recovered (or flagged) at least one divergence.
# Sibling to emit-issue-touch.sh: same structure, arg style, warn-don't-drop
# contract, and lake-dir resolution.
#
# WHY THIS EXISTS: `/build` Step 0.5 reconciles four state stores (plan-note
# sentinels, git/remote, the board, the workflow journal) on every resume —
# but until this stream existed, nothing durable recorded how often a resume
# actually finds drift, of what kind, or how often the crash-recovery paths
# (the speculative-worker sentinel, the journal `pr:`/`pushed_sha:` recovery,
# the self-claim reclaim) fire in practice. This is a BASELINE instrument for
# the graph-of-record work: a concrete, invocable emit, backed by a
# presence-lint (workflows/scripts/validate-resume-recovery-emit.sh, wired
# into scripts/quality-gates.sh) that fails CI if this script disappears OR
# its call is removed from claude/commands/build.md's Step 0.5 item 5.
#
# THIS IS A NEW STREAM, NOT A command-runs FIELD. `/build` never writes a
# command-run record (its plan note IS the run record — see
# meta/data/raw/README.md's `command-run` section, "these commands have no
# plan-note footer of their own (unlike /build)"), and a resume is not a
# drive, so folding this into command-runs would break that stream's
# disposition-partition invariant (merged+resolved+parked+reported_no_op ==
# items_processed has no slot for "a resume found drift").
#
# Usage:
#   emit-resume-recovery.sh --plan <note-stem> --recovered-count <N> \
#     [--recovered <kind>:<ref>]... [--print-only]
#
#   Each --recovered is one Step 0.5 finding, repeatable — one flag per
#   element of the `recovered` array. <kind> is one of the five closed
#   values below (the five Step 0.5 checks, claude/commands/build.md); <ref>
#   is an opaque caller-supplied pointer (a worktree path, a PR number, an
#   issue/item slug) identifying what was recovered or flagged, verbatim.
#
#   KIND one of: worktree pr claim sentinel-journal board-drift
#     worktree          Step 0.5 item 1 — an orphaned/unmapped worktree
#     pr                Step 0.5 item 2 — a PR/sentinel mismatch
#     claim             Step 0.5 item 3 — a self-claim reclaim (dead-session
#                        claim under this host, re-claimed rather than
#                        treated as a foreign conflict)
#     sentinel-journal   Step 0.5 item 4 — a pr:/pushed_sha: pointer recovered
#                        from the workflow journal
#     board-drift        Step 0.5 item 3 — a board/sentinel status mismatch
#                        (In-Progress-should-be-Done, epic drift, etc.)
#
# --print-only computes and prints the record WITHOUT appending — the
# on-demand-reading convention shared with emit-item-efficiency.sh /
# emit-session-context.sh's own --print-only.
#
# Appends ONE JSONL line to:
#   ${RESUME_RECOVERY_RAW_DIR:-<repo>/meta/data/raw}/resume-recovery-YYYY-MM.jsonl
# (monthly rotation, matching the issue-touches-/command-runs-YYYY-MM
# convention already used in meta/data/raw/).
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented below).
#
# Record shape: {ts, session_id, command, plan, recovered, recovered_count}
#   ts               ISO-8601 UTC, `Z` suffix (matches the raw/ stream convention)
#   session_id       the RAW $CLAUDE_CODE_SESSION_ID (full value, UNTRUNCATED),
#                     null when unset — same join-key convention as
#                     emit-command-run.sh / emit-issue-touch.sh
#   command          "build" (this stream has exactly one caller today)
#   plan             the plan note's stem (its filename without the leading
#                     `Plans/` path and the trailing `.md`), verbatim from
#                     --plan
#   recovered        array of {kind, ref} — one element per --recovered flag,
#                     in the order given, caller's values verbatim
#   recovered_count  integer, verbatim from --recovered-count — MUST equal
#                     recovered's length (see THE ONE LOUD FAILURE below)
#
# WARN, DON'T DROP: any INFRASTRUCTURE failure here (missing required flag,
# jq missing, sink unwritable, disk full) warns to stderr and exits 0 with NO
# record appended. A telemetry emit must never fail or block the calling
# resume — see the `|| true`-safe contract in the epic #724 Contract (the
# same contract emit-command-run.sh / emit-issue-touch.sh follow).
#
# THE ONE LOUD FAILURE — an accounting/enum mismatch, mirroring
# emit-command-run.sh's disposition-partition convention. This is NOT an
# infrastructure hiccup, so it must not be swallowed:
#
#   * the record IS still appended, with the caller's values verbatim — an
#     inconsistent record is strictly more informative than no record, and
#   * the script then prints one FAIL line per problem and exits **2**:
#       - any --recovered <kind> outside the closed enum above, and/or
#       - recovered_count disagreeing with the number of --recovered flags
#         actually given.
#
# Exit codes: 0 = emitted, or warned-and-skipped for an infrastructure reason
#             2 = record emitted BUT an enum value or the count is wrong
#                 (the FAIL lines name which)
# A caller that must never see a non-zero (a `|| true` site) keeps working; a
# caller or CI reading the exit code sees the mismatch loudly.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays — a plain
# indexed array accumulates the repeatable --recovered flag) to match the
# rest of workflows/scripts/ (macOS dev shell + Linux CI).

set -uo pipefail

self="$(basename "$0")"

plan=""
recovered_count=""
print_only=0
recovered_items=()

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
    --plan) plan="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --recovered-count) recovered_count="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
    --recovered) recovered_items+=("${2:-}"); shift; if [ $# -gt 0 ]; then shift; fi ;;
    --print-only) print_only=1; shift ;;
    -h|--help) sed -n '2,90p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if [ -z "$plan" ] || [ -z "$recovered_count" ]; then
  printf '%s: WARN --plan and --recovered-count are both required — no record emitted\n' "$self" >&2
  exit 0
fi

case "$recovered_count" in
  ''|*[!0-9]*)
    printf '%s: WARN --recovered-count must be a non-negative integer, got "%s" — no record emitted\n' "$self" "$recovered_count" >&2
    exit 0
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted (plan=%s)\n' "$self" "$plan" >&2
  exit 0
fi

# Normalise to base-10 so a zero-padded count ("08") is neither read as octal
# by $(( )) nor emitted as invalid JSON by jq --argjson.
recovered_count=$((10#$recovered_count))

# ---------------------------------------------------------------------------
# Build the `recovered` array — each --recovered was "<kind>:<ref>". Split on
# the FIRST colon only, so a ref containing further colons (unlikely, but
# never assumed) survives intact. A malformed item with no colon at all
# becomes {kind: <item>, ref: ""} — still recorded verbatim (WARN-don't-drop
# extends to a malformed --recovered value), and an unrecognised kind is
# caught by the enum check below rather than dropped here.
# ---------------------------------------------------------------------------
valid_kinds=" worktree pr claim sentinel-journal board-drift "
bad_kinds=""
recovered_objs=()
for item in "${recovered_items[@]+"${recovered_items[@]}"}"; do
  case "$item" in
    *:*) kind="${item%%:*}"; ref="${item#*:}" ;;
    *)   kind="$item"; ref="" ;;
  esac
  case " $valid_kinds " in
    *" $kind "*) : ;;
    *) bad_kinds="${bad_kinds}${bad_kinds:+, }$kind" ;;
  esac
  obj="$(jq -nc --arg kind "$kind" --arg ref "$ref" '{kind: $kind, ref: $ref}' 2>/dev/null)"
  [ -n "$obj" ] && recovered_objs+=("$obj")
done

if [ "${#recovered_objs[@]}" -gt 0 ]; then
  recovered_json="$(printf '%s\n' "${recovered_objs[@]}" | jq -sc '.' 2>/dev/null)"
  [ -n "$recovered_json" ] || recovered_json="[]"
else
  recovered_json="[]"
fi

actual_count="${#recovered_items[@]}"
count_reconciles=1
[ "$actual_count" -eq "$recovered_count" ] || count_reconciles=0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"
session_id="${CLAUDE_CODE_SESSION_ID:-}"

record="$(jq -nc \
  --arg ts "$ts" \
  --arg session_id "$session_id" \
  --arg plan "$plan" \
  --argjson recovered "$recovered_json" \
  --argjson recovered_count "$recovered_count" \
  '{
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    command: "build",
    plan: $plan,
    recovered: $recovered,
    recovered_count: $recovered_count
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record (plan=%s) — no record emitted\n' "$self" "$plan" >&2
  exit 0
fi

if [ "$print_only" -eq 1 ]; then
  printf '%s\n' "$record"
  exit 0
fi

# Resolve the raw sink dir the same way emit-issue-touch.sh resolves
# ISSUE_TOUCHES_RAW_DIR: an explicit override env var first, else the repo
# this script lives in (workflows/scripts/../.. = repo root), so it works
# from any checkout that vendors this file, not just a hardcoded
# $HOME/dev/foundation path.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd || echo "$HOME/dev/foundation")"
raw_dir="${RESUME_RECOVERY_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/resume-recovery-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s (plan=%s)\n' "$self" "$raw_file" "$plan" >&2
  exit 0
fi

printf '%s\n' "$record"

# The record is safely on disk; NOW fail loudly if a kind was invalid or the
# count doesn't match (see the header's "THE ONE LOUD FAILURE" note).
loud_fail=0

if [ -n "$bad_kinds" ]; then
  loud_fail=1
  printf '%s: FAIL --recovered carried a kind outside the closed enum {worktree,pr,claim,sentinel-journal,board-drift}: %s (plan=%s)\n' \
    "$self" "$bad_kinds" "$plan" >&2
fi

if [ "$count_reconciles" -ne 1 ]; then
  loud_fail=1
  printf '%s: FAIL --recovered-count (%s) does not match the number of --recovered flags given (%s) (plan=%s)\n' \
    "$self" "$recovered_count" "$actual_count" "$plan" >&2
fi

if [ "$loud_fail" -eq 1 ]; then
  printf '%s: the record above WAS appended to %s (the mismatch is preserved in the stream, not swallowed).\n' \
    "$self" "$raw_file" >&2
  exit 2
fi
