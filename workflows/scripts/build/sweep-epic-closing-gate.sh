#!/usr/bin/env bash
#
# sweep-epic-closing-gate.sh — the deterministic half of /sweep's end-of-run
# epic-closing gate (epic #1847 "epic-as-metadata for operational work",
# temperloop item "epic-closing-gate").
#
# `/sweep` Step 3.6 must decide, for each Operational epic Step 1 item 6
# admitted this run, whether its parent is OFFERED FOR CLOSE (every member
# reached a terminal — merged or verdict-resolved — state), REPORTED AS
# PROGRESS (some but not all members terminal), or REPORTED ONLY (the epic
# carries `keep-open`, or a live read failed and drain state cannot be
# established). That decision depends on live reads this script does NOT make
# itself (no `gh`, no board, no filesystem — the same "mechanical piece only"
# split sweep-epic-admission.sh and sweep-blocked-undefer.sh already
# established):
#
#   1. whether every member's state read, and the epic's own label read,
#      succeeded this run (two independent call-failure signals)
#   2. whether the `keep-open` label is present on the epic
#   3. whether this run is attended or unattended (the offer-close vs
#      left-open-unattended branch)
#   4. each member's current state: "CLOSED" (merged or verdict-resolved —
#      a parked member NEVER reaches "CLOSED", by construction: the park
#      path moves the issue back to Ready and never closes it) or "OPEN"
#      (still outstanding, whatever the reason). UPPERCASE — this is the
#      native `gh issue view --json state` casing, matched here VERBATIM
#      (no normalization), the same convention sweep-blocked-undefer.sh's
#      own input schema already documents ("state": "OPEN" | "CLOSED").
#      The caller MUST hand this script the raw gh casing unmodified —
#      a lowercased "closed"/"open" is never recognized (temperloop#1847
#      round 3: comparing against lowercase silently zeroed every drain
#      count, since `gh` never returns lowercase).
#
# The caller (sweep.md Step 3.6, or a test fixture standing in for it) runs
# those reads and hands this script their RESULTS; this script is the pure
# combinator that turns them into the verdict — independently testable with
# synthetic fixtures, no live network. See
# workflows/scripts/build/tests/test_sweep_epic_closing_gate.sh.
#
# AN ERROR IS NEVER THE PERMISSIVE BRANCH (the same discipline
# sweep-epic-admission.sh and sweep-blocked-undefer.sh already apply). A read
# that ERRORED is NOT equivalent to a genuinely-empty or genuinely-false
# result — collapsing the two would silently offer an epic for close (or
# silently leave one open with no pending-decision record) on nothing but a
# flaky read. The caller MUST signal any such failure via
# `member_reads_available: false` / `labels_read_available: false` (never by
# omitting the field and never by guessing a permissive value in its place);
# this script also defaults both fields, and `keep_open_label_present`, to
# their REFUSING direction (false / false / true respectively — an absent
# `keep_open_label_present` is read as "assume present, never offer close")
# when altogether absent from the input, mirroring
# sweep-epic-admission.sh's own absent-field convention.
#
# THE PRECEDENCE (checked in this order — the first matching branch wins):
#   1. total_members == 0                -> verdict=no-members
#      (nothing to evaluate — an epic with no native sub-issues at all is
#      not a real candidate; the caller should not have reached this script,
#      but the script itself never guesses a favorable answer over an empty
#      set)
#   2. member_reads_available=false      -> verdict=cannot-establish,
#                                            reason=member-reads-unavailable
#   3. labels_read_available=false       -> verdict=cannot-establish,
#                                            reason=labels-unavailable
#      (checked AFTER member reads deliberately — a caller that already knows
#      it cannot establish drain state doesn't need a second reason to also
#      report the same "cannot establish" outcome; ORDER matters only for
#      which single `reason` string is returned, never for the verdict)
#   4. keep_open_label_present=true      -> verdict=keep-open,
#                                            reason=keep-open-label
#      (reported, never offered for close — checked BEFORE the drain check
#      so a fully-drained-but-keep-open epic is never silently routed to
#      offer-close)
#   5. fully_drained (closed_members == total_members, total_members > 0):
#        attended=true                   -> verdict=offer-close,
#                                            reason=fully-drained
#        attended=false (or absent)      -> verdict=left-open-unattended,
#                                            reason=fully-drained-unattended
#   6. closed_members > 0                -> verdict=progress,
#                                            reason=partially-drained
#   7. else (closed_members == 0)        -> verdict=no-progress,
#                                            reason=no-progress-this-run
#
# Usage:
#   sweep-epic-closing-gate.sh <epic-json-file>
#   cat epic.json | sweep-epic-closing-gate.sh -
#
# Input JSON shape:
#   {
#     "epic": <int>,
#     "member_reads_available": bool,
#       # true iff EVERY member's state read succeeded this run. false (or
#       # omitted) means at least one read ERRORED — refuse via
#       # cannot-establish, never fall through to the drain computation
#       # below (an errored read's own state value, if the caller supplied
#       # one anyway, is untrustworthy and must be ignored by this
#       # precedence).
#     "labels_read_available": bool,
#       # true iff the epic's own labels/assignees read succeeded this run.
#       # Same refusing-default convention as member_reads_available.
#     "keep_open_label_present": bool,
#       # true iff the epic currently carries the `keep-open` label. Default
#       # when absent: true — an unread label is never assumed absent, since
#       # that direction risks an unwanted close.
#     "attended": bool,
#       # this run's attended/unattended posture. Default when absent: false
#       # (the more conservative branch — left-open-unattended never closes
#       # anything, offer-close does).
#     "members": [ {"issue": <int>, "state": "OPEN"|"CLOSED"}, ... ]
#       # UPPERCASE, matching `gh issue view --json state` verbatim — see
#       # item 4 above. A lowercase "open"/"closed" is NOT recognized.
#   }
#
# Output JSON on stdout:
#   {
#     "epic": <int>,
#     "total_members": <int>,
#     "closed_members": <int>,
#     "fully_drained": bool,
#     "verdict": "no-members" | "cannot-establish" | "keep-open" |
#                "offer-close" | "left-open-unattended" | "progress" |
#                "no-progress",
#     "reason": "no-members" | "member-reads-unavailable" |
#               "labels-unavailable" | "keep-open-label" |
#               "fully-drained" | "fully-drained-unattended" |
#               "partially-drained" | "no-progress-this-run",
#     "open_members": [<int>, ...]
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-epic-closing-gate.sh <epic-json-file>
       cat epic.json | sweep-epic-closing-gate.sh -

Evaluates /sweep's end-of-run epic-closing gate verdict for a single epic,
given the member/label read-success signals, whether the `keep-open` label is
present, this run's attended/unattended posture, and every member's current
state. Prints a verdict JSON object to stdout. See this script's own header
for the input/output shape and the precedence order it implements.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

INPUT="$1"
if [ "$INPUT" = "-" ]; then
  EPIC_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "sweep-epic-closing-gate.sh: no such file: $INPUT" >&2; exit 1; }
  EPIC_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-epic-closing-gate.sh: jq required" >&2; exit 1; }

printf '%s' "$EPIC_JSON" | jq -c '
  (.epic) as $epic
  | (.member_reads_available // false) as $member_reads_available
  | (.labels_read_available // false) as $labels_read_available
  | (if .keep_open_label_present == null then true else .keep_open_label_present end) as $keep_open
  | (.attended // false) as $attended
  | (.members // []) as $members
  | ($members | length) as $total
  | ([$members[] | select(.state == "CLOSED")] | length) as $closed
  | ([$members[] | select(.state != "CLOSED") | .issue] ) as $open_members
  | ($total > 0 and $closed == $total) as $fully_drained
  | {
      epic: $epic,
      total_members: $total,
      closed_members: $closed,
      fully_drained: $fully_drained,
      open_members: $open_members
    } as $base
  | if $total == 0 then
      $base + {verdict: "no-members", reason: "no-members"}
    elif $member_reads_available != true then
      $base + {verdict: "cannot-establish", reason: "member-reads-unavailable"}
    elif $labels_read_available != true then
      $base + {verdict: "cannot-establish", reason: "labels-unavailable"}
    elif $keep_open == true then
      $base + {verdict: "keep-open", reason: "keep-open-label"}
    elif $fully_drained == true then
      if $attended == true then
        $base + {verdict: "offer-close", reason: "fully-drained"}
      else
        $base + {verdict: "left-open-unattended", reason: "fully-drained-unattended"}
      end
    elif $closed > 0 then
      $base + {verdict: "progress", reason: "partially-drained"}
    else
      $base + {verdict: "no-progress", reason: "no-progress-this-run"}
    end
'
