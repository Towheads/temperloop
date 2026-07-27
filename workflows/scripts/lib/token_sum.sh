#!/usr/bin/env bash
#
# token_sum.sh — SOURCED shared helper: the ONE jq expression that sums a
# transcript's cumulative token usage across every recorded message
# (temperloop#828, epic #810 "realized-session-context probe").
#
# WHY THIS EXISTS: claude/status-line.sh's "Tokens: NNk" display and the
# SessionEnd realized-context-probe emit (workflows/scripts/emit-session-context.sh)
# both need EXACTLY the same number — a displayed figure and a recorded
# figure that could silently drift apart (one edited, the other forgotten) is
# worse than no number at all, since a reader trusts them to agree.
# Extracting the expression here (lifted byte-for-byte from status-line.sh's
# prior inline `build_tokens_part()`) makes drift structurally impossible:
# there is exactly one place this sum is computed, ever.
#
# STRUCTURAL PRIVACY GUARANTEE (engineering-principles.md Principle 5 —
# counter AI failure modes structurally, not by convention/testing alone):
# the ONLY jq selector this file's function ever touches is
# `.message.usage.*` — never `.message.content`, `.message.role`, or any
# other transcript field. A transcript's prose is therefore categorically
# out of reach of this code path; there is no branch that could leak it, so
# no reviewer discipline is required to keep it that way. See
# workflows/scripts/lib/tests/test_token_sum.sh's synthetic-recognizable-
# content fixture for the regression PROOF of this guarantee — the test is
# evidence the guard holds, never a substitute for the structural guarantee
# itself.
#
# Usage (sourced, never executed directly — this file has no CLI of its own):
#   . workflows/scripts/lib/token_sum.sh
#   total=$(token_sum_transcript "$TRANSCRIPT_PATH")   # prints an integer, "0" on any failure
#
# Kept bash-3.2-portable (no associative arrays / mapfile), matching the rest
# of workflows/scripts/lib/.

# token_sum_transcript <transcript-jsonl-path>
# Prints the cumulative token total — (input + cache_creation_input +
# cache_read_input + output) tokens — summed across every `.message.usage`
# object found in the given JSONL transcript, one line at a time via `jq -s`.
# This is the WHOLE-SESSION sum (every message in the file), deliberately NOT
# scoped to any prefix — the point of the realized-context probe is measuring
# the whole session, not just its opening turns.
#
# Prints "0" (exit 0) for a missing/empty/unreadable file or any jq failure —
# this is a display/telemetry aid, never a hard dependency for its callers.
token_sum_transcript() {
  local transcript="${1:-}"
  local total

  if [ -z "$transcript" ] || [ ! -f "$transcript" ]; then
    printf '0\n'
    return 0
  fi

  total=$(jq -s '
    map(
      .message.usage // {}
      | (.input_tokens // 0)
        + (.cache_creation_input_tokens // 0)
        + (.cache_read_input_tokens // 0)
        + (.output_tokens // 0)
    )
    | add // 0
  ' "$transcript" 2>/dev/null)

  if [ -z "$total" ] || [ "$total" = "null" ]; then
    total=0
  fi

  printf '%s\n' "$total"
}
