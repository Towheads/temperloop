#!/usr/bin/env bash
# SessionEnd hook — writes a transcript stub to <cwd>/.mind/ so Claude can
# import it into the Obsidian vault via MCP at the start of the next session.
#
# Reads JSON on stdin: {session_id, transcript_path, cwd, ...}
# Writes: <cwd>/.mind/<date>-<time>-<project>-<id8>.md
# Also ensures: <cwd>/.mind/.gitignore (contents: "*")
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

DATE=$(date +%Y-%m-%d)
TIME=$(date +%H%M)
PROJECT=$(basename "$CWD")
SHORT_ID=$(printf '%s' "$SESSION_ID" | cut -c1-8)

# Distinct model ids across this session's assistant turns. Usually one; a
# /model switch, /fast toggle, or a compaction summary can yield several, so
# record the comma-joined set. This `model:` field is the carrier of the
# SUBJECT model into a /drain-mind that may run days later under a different
# model: drain stamps it as `source_model` (the model whose behavior the note
# is about), distinct from the drain-runner's own `extracted_by_model`.
# See ~/dev/mind/Decisions/foundation - Vault provenance schema (note-level).md.
MODELS=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$TRANSCRIPT" 2>/dev/null \
  | sort -u | paste -sd, - | sed 's/,$//')

OUTDIR="$CWD/.mind"
OUTFILE="$OUTDIR/${DATE}-${TIME}-${PROJECT}-${SHORT_ID}.md"

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

if [ "${USER_TURNS:-0}" -lt 1 ]; then
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
