#!/usr/bin/env bash
#
# sweep-answered-exclusion.sh — the deterministic half of `/sweep` Step 2's
# "answered, not underspecified" comment-anchored exclusion rule
# (temperloop#1193, item sweep-detects-answered-questions).
#
# `/sweep` Phase 1 decides whether a pooled issue has an open question via
# subagent JUDGMENT (reading title/body for meaning) — that part cannot be a
# deterministic script. But the EXCLUSION this rule adds on top —
# "an issue carrying a Clarified (…) comment newer than the most recent
# flagging-type comment is answered, not underspecified" — is pure
# comment-timestamp comparison, mechanical by construction. This script is
# that mechanical piece, extracted so it is independently testable with
# synthetic fixtures (no live `gh`, no live board — see
# workflows/scripts/build/tests/test_sweep_answered_exclusion.sh) and usable
# as ground truth by any caller, human or subagent.
#
# Flagging-type comment anchors (BOTH wordings sweep.md actually posts):
#   - `needs-clarification: <question>`  (Step 2's self-judged-underspecified
#     arm, and triage.md's own flag)
#   - `Parked by sweep — <question>`     (Step 3's escalation-park path)
#
# Answered-type comment anchor:
#   - `Clarified (…): <answer>`          (e.g. "Clarified (sweep): …",
#     "Clarified (triage): …" — any parenthesized source tag)
#
# Usage:
#   sweep-answered-exclusion.sh <issue-json-file>
#   cat issue.json | sweep-answered-exclusion.sh -
#
# Input JSON shape (a trimmed projection of `gh issue view --json
# labels,comments`, plus one field a script cannot derive from body text):
#   {
#     "labels": [{"name": "needs-clarification"}, ...],
#     "comments": [{"createdAt": "<ISO-8601 UTC>", "body": "<comment text>"}],
#     "self_judged_underspecified": true|false   # OPTIONAL, default false —
#       the detection subagent's OWN read of title/body, IGNORING comments;
#       this script cannot read English for ambiguity, so the caller (the
#       Step 2 detection fanout, or a test fixture standing in for it)
#       supplies this. Irrelevant when the issue already carries the
#       needs-clarification label (that arm's "has an open question" input
#       is the label itself, not this field).
#   }
#
# Output JSON on stdout:
#   {
#     "has_open_question": bool,
#     "reason": "answered" | "underspecified" | "clean",
#     "would_post_needs_clarification_comment": bool,
#     "latest_flag_comment_at": "<ISO-8601>" | null,
#     "latest_clarified_comment_at": "<ISO-8601>" | null
#   }
#
# ISO-8601 UTC ("...Z") timestamps sort correctly under plain string/jq `>`
# comparison — no date parsing needed.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-answered-exclusion.sh <issue-json-file>
       cat issue.json | sweep-answered-exclusion.sh -

Classifies a single synthetic/fetched issue (labels + comments) per
/sweep Step 2's "answered, not underspecified" comment-anchored exclusion
rule. Prints a verdict JSON object to stdout. See this script's own header
for the input/output shape.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

INPUT="$1"
if [ "$INPUT" = "-" ]; then
  ISSUE_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "sweep-answered-exclusion.sh: no such file: $INPUT" >&2; exit 1; }
  ISSUE_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-answered-exclusion.sh: jq required" >&2; exit 1; }

printf '%s' "$ISSUE_JSON" | jq -c '
  (.comments // []) as $comments
  # Flagging-type comment anchors: BOTH wordings sweep.md posts.
  | ($comments
      | map(select(
          (.body // "" | test("^needs-clarification:"))
          or (.body // "" | startswith("Parked by sweep — "))
        ) | .createdAt)
      | sort) as $flag_times
  | ($comments
      | map(select(.body // "" | test("^Clarified \\(")) | .createdAt)
      | sort) as $clarified_times
  | (if ($flag_times | length) > 0 then $flag_times[-1] else null end) as $latest_flag
  | (if ($clarified_times | length) > 0 then $clarified_times[-1] else null end) as $latest_clarified
  | ((.labels // []) | any(.name == "needs-clarification")) as $has_label
  | ((.self_judged_underspecified // false) or $has_label) as $raw_open_question
  | (
      ($latest_clarified != null)
      and ($latest_flag == null or $latest_clarified > $latest_flag)
    ) as $answered
  | {
      has_open_question: (if $answered then false else $raw_open_question end),
      reason: (if $answered then "answered"
               elif $raw_open_question then "underspecified"
               else "clean" end),
      would_post_needs_clarification_comment:
        ($raw_open_question and ($has_label | not) and ($answered | not)),
      latest_flag_comment_at: $latest_flag,
      latest_clarified_comment_at: $latest_clarified
    }
'
