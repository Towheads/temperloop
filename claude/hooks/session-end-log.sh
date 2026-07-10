#!/usr/bin/env bash
# SessionEnd hook — writes a transcript stub to <cwd>/.mind/ so Claude can
# import it into the Obsidian vault via MCP at the start of the next session.
#
# Reads JSON on stdin: {session_id, transcript_path, cwd, ...}
# Writes: <cwd>/.mind/<date>-<time>-<project>-<id8>.md
# Also ensures: <cwd>/.mind/.gitignore (contents: "*")
#
# Rollover-chain following (foundation#984): a context compaction can roll the
# conversation into a NEW transcript jsonl while SessionEnd is still handed the
# stale original path; this hook follows the chain to the live end so the stub
# covers the whole session, and reuses an existing stub for the same session id
# instead of accumulating near-duplicates.
#
# EVAL_RUN suppression: when EVAL_RUN is set (non-empty), this hook exits
# immediately without writing any stub.  Eval sessions must not produce
# .mind/ files or vault drain targets.
# shellcheck source=eval-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/eval-guard.sh"
eval_guard_exit_if_eval

set -uo pipefail

INPUT=$(cat)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

[ -z "$TRANSCRIPT" ] && exit 0
[ ! -f "$TRANSCRIPT" ] && exit 0
[ -z "$CWD" ] && exit 0
[ ! -d "$CWD" ] && exit 0

# --- Rollover-chain following (foundation#984) --------------------------------
# A compact rollover copies the prior history into the new jsonl with the
# ORIGINAL record timestamps, so chain members share the same first top-level
# .timestamp (head-of-file preamble records — last-prompt, custom-title, mode —
# are mutable and carry none; nested timestamps like file-history-snapshot's
# don't count). Among sibling jsonls with a matching first timestamp, dump the
# largest: each rollover carries a full copy plus the new tail, so the live end
# is strictly the biggest. No match -> current behavior, unchanged.
first_ts() {
  jq -r 'select(.timestamp != null) | .timestamp' "$1" 2>/dev/null | head -n 1
}
GIVEN_TRANSCRIPT="$TRANSCRIPT"
OWN_TS=$(first_ts "$TRANSCRIPT")
if [ -n "$OWN_TS" ]; then
  BEST_SIZE=$(wc -c < "$TRANSCRIPT")
  for SIB in "$(dirname "$TRANSCRIPT")"/*.jsonl; do
    [ -f "$SIB" ] || continue
    [ "$SIB" = "$TRANSCRIPT" ] && continue
    SIB_SIZE=$(wc -c < "$SIB")
    [ "$SIB_SIZE" -gt "$BEST_SIZE" ] || continue
    [ "$(first_ts "$SIB")" = "$OWN_TS" ] || continue
    TRANSCRIPT="$SIB"
    BEST_SIZE="$SIB_SIZE"
  done
fi

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H%M)
PROJECT=$(basename "$CWD")
SHORT_ID=$(printf '%s' "$SESSION_ID" | cut -c1-8)

# Distinct model ids across this session's assistant turns. Usually one; a
# /model switch, /fast toggle, or a compaction summary can yield several, so
# record the comma-joined set. This `model:` field is the carrier of the
# SUBJECT model into a /tidy that may run days later under a different
# model: drain stamps it as `source_model` (the model whose behavior the note
# is about), distinct from the drain-runner's own `extracted_by_model`.
# See "Decisions/foundation - Vault provenance schema (note-level).md" in the
# operator's knowledge store (workflows/scripts/lib/knowledge_store.contract.md).
MODELS=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$TRANSCRIPT" 2>/dev/null \
  | sort -u | paste -sd, - | sed 's/,$//')

OUTDIR="$CWD/.mind"
OUTFILE="$OUTDIR/${DATE}-${TIME}-${PROJECT}-${SHORT_ID}.md"

# Reuse an existing stub for this session id if one is already on disk (an
# exit/re-enter minutes apart, or a fuller post-rollover re-dump), so repeat
# fires overwrite in place instead of accumulating near-duplicates
# (foundation#984). The transcript only grows, so a re-dump is a superset.
for EXISTING in "$OUTDIR"/*-"${PROJECT}-${SHORT_ID}.md"; do
  if [ -f "$EXISTING" ]; then
    OUTFILE="$EXISTING"
    break
  fi
done

mkdir -p "$OUTDIR"
# Belt-and-suspenders: never let .mind/ get committed.
if [ ! -f "$OUTDIR/.gitignore" ]; then
  printf '*\n' > "$OUTDIR/.gitignore"
fi

# Skip empty/no-op sessions: require at least one user prompt with text.
USER_TURNS=$(jq -r '
  select(.type == "user" and (.message.role // "") == "user")
  | .message.content
  | if type == "string" then .
    else (map(select(.type == "text") | .text) | join(""))
    end
  | select(length > 0)
' "$TRANSCRIPT" 2>/dev/null | grep -c . || true)

if [ "${USER_TURNS:-0}" -lt 1 ]; then  # knob:exempt — USER_TURNS is a computed jq-derived count, not an operator default
  exit 0
fi

{
  printf -- "---\n"
  printf "date: %s\n" "$DATE"
  printf "time: \"%s\"\n" "$TIME"
  printf "project: %s\n" "$PROJECT"
  printf "cwd: %s\n" "$CWD"
  printf "session_id: %s\n" "$SESSION_ID"
  [ -n "$MODELS" ] && printf "model: %s\n" "$MODELS"
  printf "transcript: %s\n" "$TRANSCRIPT"
  [ "$TRANSCRIPT" != "$GIVEN_TRANSCRIPT" ] && printf "transcript_given: %s\n" "$GIVEN_TRANSCRIPT"
  printf "tags:\n  - session\n  - project/%s\n" "$PROJECT"
  printf -- "---\n\n"
  printf "# Session — %s (%s %s)\n\n" "$PROJECT" "$DATE" "$TIME"
  printf "_Auto-saved by SessionEnd hook. Curated notes go above the transcript dump._\n\n"
  printf "## Transcript\n\n"

  jq -r '
    select(.type == "user" or .type == "assistant")
    | (.message.role // "") as $role
    | (.message.content) as $c
    | (if ($c | type) == "string" then $c
       else ($c | map(select(.type == "text") | .text) | join("\n\n"))
       end) as $text
    | select(($text // "") | length > 0)
    | "### " + ($role[0:1] | ascii_upcase) + ($role[1:]) + "\n\n" + $text + "\n"
  ' "$TRANSCRIPT"
} > "$OUTFILE"

exit 0
