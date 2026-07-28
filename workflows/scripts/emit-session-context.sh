#!/usr/bin/env bash
#
# emit-session-context.sh — realized-session-context probe (temperloop#828,
# epic #810 "session-start context growth"). Appends one JSONL record per
# session summarizing the WHOLE session's realized context — not only its
# opening (session-start) prefix — so a prose relocation's real value
# becomes measurable rather than assumed. A prior scope measured t0 (context
# BEFORE the agent reads anything); relocating content out of an
# always-loaded document improves t0 by construction whether or not the
# agent ever reads the relocated content later in the session. This probe
# measures the realized whole-session figure instead.
#
# CALL-SITE CONTRACT — this script does NOT resolve its own transcript path
# or its own context-window snapshot. It is designed to sit at the SessionEnd
# hook seam (claude/hooks/session-end-log.sh), where:
#   - the transcript path has ALREADY been resolved through the compaction-
#     rollover chain (a compaction rolls the conversation into a NEW .jsonl;
#     hunting for the wrong transcript here would silently undercount
#     exactly the long sessions this probe exists to measure — the bug
#     session-end-log.sh's own rollover-chain-following already fixed once);
#   - `.context_window.*` has already been handed to the hook on stdin.
# The caller passes both in via --transcript / --context-window-*; this
# script only assembles and appends the record.
#
# ONE-OFF READING (temperloop#825's cross-epic consumer contract: a design
# that relocates prose out of the always-loaded document gates its own
# acceptance on this probe being able to produce a SINGLE on-demand reading,
# not only fire passively at SessionEnd) — pass --print-only:
#   emit-session-context.sh --transcript <path> --print-only
# prints the computed record JSON to stdout and returns WITHOUT appending to
# the raw lake and WITHOUT checking the passive opt-in gate below (a direct,
# explicit invocation IS the consent for that one call — the opt-in below
# gates only the passive per-SessionEnd sink write).
#
# Usage (SessionEnd hook call, the primary/passive caller):
#   emit-session-context.sh --transcript <path> [--session-id <id>] \
#     [--project <name>] [--cwd <path>] \
#     [--context-window-size <N>] [--context-window-remaining-pct <P>]
#
# canonical sink spec: meta/data/raw/README.md (lake path + schema-version
# convention; this stream's own record shape is documented there and below).
#
# Record shape: {schema_version, ts, session_id, host, project, cwd,
#                transcript_tokens_total, context_window_size,
#                context_window_remaining_pct}
#   schema_version              "1"
#   ts                           ISO-8601 UTC, `Z` suffix
#   session_id                   raw, untruncated $CLAUDE_CODE_SESSION_ID-shaped
#                                 value the caller passed; null if omitted
#   host                         $SUBSET_HOST_LABEL if set, else `hostname -s`
#   project                      the caller's --project value, or null
#   cwd                          the caller's --cwd value, or null
#   transcript_tokens_total       cumulative token sum across the WHOLE
#                                 transcript (see STRUCTURAL PRIVACY below) —
#                                 null if --transcript was never passed, and
#                                 null (never 0) if the token_sum.sh helper
#                                 could not be resolved, so an unknown is
#                                 never recorded as a real zero
#   context_window_size          the harness's `.context_window.context_window_size`
#                                 at SessionEnd, passed through verbatim; null if absent
#   context_window_remaining_pct  the harness's `.context_window.remaining_percentage`
#                                 at SessionEnd, passed through verbatim; null if absent
#
# STRUCTURAL PRIVACY (engineering-principles.md Principle 5 — counter AI
# failure modes structurally, not by convention): token counting is
# delegated ENTIRELY to workflows/scripts/lib/token_sum.sh's
# token_sum_transcript(), whose only jq selector is `.message.usage.*` — this
# script never itself reads `.message.content` (or any other transcript
# field) either. Message content is therefore never in scope of this parser.
# See that helper's header + workflows/scripts/lib/tests/test_token_sum.sh's
# synthetic-recognizable-content fixture for the regression proof.
#
# Follows the raw-lake convention verbatim (meta/data/raw/README.md):
# per-stream SESSION_CONTEXT_RAW_DIR override, the same BASH_SOURCE-relative
# fallback ladder as emit-command-run.sh, and WARN-DON'T-DROP + always exit 0
# — a telemetry emit must never fail or block its caller.
#
# The passive per-SessionEnd sink write is gated by an EXPLICIT, default-off
# setting-registry.tsv row (SESSION_CONTEXT_RAW_ENABLED) checked by the
# CALLER (claude/hooks/session-end-log.sh) before this script is even
# invoked — never sink-presence (a writable SESSION_CONTEXT_RAW_DIR) used as
# an implicit switch. This script itself has no opinion on that gate; a
# direct invocation (one-off reading, or a future explicit caller) always
# runs.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays), matching the
# rest of workflows/scripts/.

set -uo pipefail

self="$(basename "$0")"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

transcript=""
session_id=""
project=""
cwd=""
cw_size=""
cw_remaining=""
print_only=0

while [ $# -gt 0 ]; do
  # VALUE GUARD, ahead of the dispatch below — both failure shapes an
  # UNQUOTED empty variable produces at the documented one-off call site
  # (`emit-session-context.sh --transcript $X --print-only` with $X empty):
  #
  #   1. TRAILING position (`... --print-only --transcript`) HUNG. Bash's
  #      `shift n` FAILS and does not shift when n > $#, and this script
  #      deliberately runs without `set -e`, so a bare `shift 2` left $1
  #      unchanged and the same case arm re-matched forever.
  #   2. MID-string (`--transcript --print-only`) silently swallowed the NEXT
  #      FLAG as the value — so `--print-only` was never honored and the
  #      record was appended to the raw lake instead of printed. Quieter than
  #      the hang and worse: it writes where the caller asked it not to.
  #
  # Both are caught here: a value-taking flag needs a next argument that
  # exists AND is not itself flag-shaped. Otherwise warn and drop the flag,
  # matching the unknown-argument WARN-don't-fail posture below. Past this
  # guard every `shift 2` is provably safe ($# >= 2), so "$2" needs no
  # `:-` default. (An explicitly QUOTED empty value — `--transcript ""` — is
  # a real argv token, passes this guard, and still means "no transcript".)
  case "$1" in
    --transcript | --session-id | --project | --cwd | --context-window-size | --context-window-remaining-pct)
      if [ $# -lt 2 ]; then
        printf '%s: WARN %s requires a value (ignored)\n' "$self" "$1" >&2
        shift
        continue
      fi
      case "${2}" in
        --*)
          printf '%s: WARN %s requires a value but was followed by %s (ignored)\n' "$self" "$1" "$2" >&2
          shift
          continue
          ;;
      esac
      ;;
  esac
  case "$1" in
    --transcript) transcript="$2"; shift 2 ;;
    --session-id) session_id="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --context-window-size) cw_size="$2"; shift 2 ;;
    --context-window-remaining-pct) cw_remaining="$2"; shift 2 ;;
    --print-only) print_only=1; shift ;;
    *)
      printf '%s: WARN unknown argument %s (ignored)\n' "$self" "$1" >&2
      shift
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: WARN jq not found — no record emitted\n' "$self" >&2
  exit 0
fi

lib="$here/lib/token_sum.sh"
if [ -f "$lib" ]; then
  # shellcheck source=/dev/null
  . "$lib"
else
  # Helper unreachable: print an EMPTY value, never "0". A literal 0 would be
  # written to the raw lake as a real number, indistinguishable from a
  # genuine zero-token session — polluting the very dataset this probe exists
  # to build. Empty maps to `null` in the record below, the same shape the
  # record already uses for a missing --transcript.
  token_sum_transcript() { printf '\n'; }
fi

tokens_total=""
if [ -n "$transcript" ]; then
  tokens_total="$(token_sum_transcript "$transcript")"
fi

host="${SUBSET_HOST_LABEL:-$(hostname -s)}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
month="$(date -u +%Y-%m)"

record="$(jq -nc \
  --arg ts "$ts" \
  --arg session_id "$session_id" \
  --arg host "$host" \
  --arg project "$project" \
  --arg cwd "$cwd" \
  --arg tokens_total "$tokens_total" \
  --arg cw_size "$cw_size" \
  --arg cw_remaining "$cw_remaining" \
  '{
    schema_version: "1",
    ts: $ts,
    session_id: (if $session_id == "" then null else $session_id end),
    host: $host,
    project: (if $project == "" then null else $project end),
    cwd: (if $cwd == "" then null else $cwd end),
    transcript_tokens_total: (if $tokens_total == "" then null else ($tokens_total | tonumber? // null) end),
    context_window_size: (if $cw_size == "" then null else ($cw_size | tonumber? // null) end),
    context_window_remaining_pct: (if $cw_remaining == "" then null else ($cw_remaining | tonumber? // null) end)
  }' 2>/dev/null)"

if [ -z "$record" ]; then
  printf '%s: WARN failed to build JSON record — no record emitted\n' "$self" >&2
  exit 0
fi

if [ "$print_only" -eq 1 ]; then
  printf '%s\n' "$record"
  exit 0
fi

# Resolve the raw sink dir the same way emit-command-run.sh resolves
# CMD_RUN_RAW_DIR: an explicit override env var first, else the repo this
# script lives in (workflows/scripts/../.. -> meta/data/raw), so it works
# from any checkout that vendors this file, not just a hardcoded path.
#
# NO hardcoded personal-checkout default (temperloop#406: no shipped script
# may fall back to someone's own ~/dev/... path). If neither the override nor
# the BASH_SOURCE-relative climb resolves, WARN and skip the append — the
# same warn-don't-drop posture as every other failure path here, never a
# silent write into a stranger's tree.
# NOTE the presence test below uses `:+`, deliberately, NOT `:-`. Only
# `:=` / `:-` / `=` / `-` are setting-registry SEAMS, and
# setting-registry.tsv records exactly ONE default per setting/owning-script
# pair — a second `${SESSION_CONTEXT_RAW_DIR:-}` here would register as a
# rival seam with an empty default and fail check-setting-registry.sh's
# equality lint. `:+` reads presence without declaring a default, so the
# canonical seam stays the single one on the raw_dir line.
raw_root="$(cd -P "$here/../.." 2>/dev/null && pwd)"
if [ -z "$raw_root" ] && [ -z "${SESSION_CONTEXT_RAW_DIR:+set}" ]; then
  printf '%s: WARN could not resolve the raw-lake root from %s and SESSION_CONTEXT_RAW_DIR is unset — no record appended\n' \
    "$self" "$here" >&2
  exit 0
fi
raw_dir="${SESSION_CONTEXT_RAW_DIR:-$raw_root/meta/data/raw}"
raw_file="$raw_dir/session-context-${month}.jsonl"

mkdir -p "$raw_dir" 2>/dev/null || true

if ! printf '%s\n' "$record" >> "$raw_file" 2>/dev/null; then
  printf '%s: WARN failed to append record to %s\n' "$self" "$raw_file" >&2
  exit 0
fi

printf '%s\n' "$record"
