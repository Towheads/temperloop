#!/usr/bin/env bash
#
# sweep-epic-review-population.sh — the deterministic half of /sweep's
# end-of-run epic-closing gate REVIEW-POPULATION membership predicate (epic
# #1847 "epic-as-metadata for operational work", temperloop item
# "epic-closing-gate", escalation round 5 HIGH finding).
#
# WHY THIS SCRIPT EXISTS (round 5 fix). Before this script, Step 3.6A's
# review population was defined as "every Operational epic Step 1 item 6
# admitted this run" — but a fully-drained epic has ZERO Ready legs left (all
# of them already merged/resolved), so item 6 can never admit it again once
# it's fully drained, and it can therefore never be re-admitted into a future
# run's population. Every "re-offered next run" / "re-checked next run" /
# "declined offer" promise in sweep.md's Step 4 report language was
# structurally dead on that one-shot population, and the pending-decisions
# dedup-across-history check (§ left-open-unattended) was unreachable dead
# code — an epic that enters the unattended branch once can never be
# re-detected on a later run to exercise the dedup at all.
#
# THE FIX: the review population each run is the UNION of two sets —
#   (a) this run's item-6 admissions (unchanged, still fed in as
#       `admitted_this_run`) — an epic whose leg(s) item 6 already vetted and
#       admitted this run is ALWAYS in the population, no further reads
#       needed; and
#   (b) the "admission-eligible set" — every still-OPEN Operational-epic
#       parent carrying the edges-considered marker, queried ONCE against the
#       board independent of whether any of its legs was Ready this run (so
#       a fully-drained epic with zero Ready legs still qualifies via this
#       arm).
#
# This script is the pure per-candidate combinator for that union — given one
# candidate epic's admission-this-run flag plus the population-query read
# results, it decides whether the epic belongs in this run's review
# population. It does NOT itself query the board (no `gh`, no board, no
# filesystem — the same "mechanical piece only" split every sibling
# sweep-*.sh combinator already establishes); the caller (sweep.md Step 3.6A,
# or a test fixture standing in for it) runs the reads and hands this script
# their results. See workflows/scripts/build/tests/test_sweep_epic_review_population.sh.
#
# AN ERROR IS NEVER THE PERMISSIVE BRANCH (the same discipline every sibling
# sweep-*.sh combinator applies). A population-query read that ERRORED for a
# candidate epic (its open/label/parentage/marker state could not be
# established) is NOT equivalent to a genuinely-false result — collapsing the
# two would silently drop a real epic out of review on nothing but a flaky
# read, OR silently admit an unread candidate into review. The caller MUST
# signal any such failure via `reads_available: false` (never by omitting the
# field and never by guessing a permissive value in its place); this script
# also defaults `admitted_this_run` and `reads_available` to their REFUSING
# direction (false / false) when altogether absent from the input, mirroring
# every sibling combinator's own absent-field convention. Note the asymmetry
# this produces on purpose: `admitted_this_run: true` NEVER needs
# `reads_available` to be true — item 6's own admission reads already
# succeeded to produce that admission (§ THE PRECEDENCE item 1 below), so a
# population-query read failure for an ALREADY-admitted epic can never
# un-admit it.
#
# THE PRECEDENCE (checked in this order — the first matching branch wins):
#   1. admitted_this_run=true          -> in_review_population=true,
#                                          reason=admitted-this-run
#      (the union's (a) arm — unconditional; no other field is consulted,
#      not even reads_available=false, since item 6's own reads already
#      vetted this epic this run)
#   2. reads_available=false           -> in_review_population=false,
#                                          reason=population-reads-unavailable
#      (the union's (b) arm cannot be evaluated on an errored read — refuse,
#      never guess; the epic simply isn't in this run's population, exactly
#      as if the query never found it)
#   3. epic_open=false                 -> false, reason=not-open
#      (a closed epic parent is not a review candidate — either it was
#      already closed by a prior run's offer-close, or it was closed by
#      hand; either way there is nothing left for this gate to offer)
#   4. has_sub_issues=false            -> false, reason=not-a-parent
#      (an "epic" with no native sub-issues at all is not a real epic parent
#      for closing-gate purposes — mirrors sweep-epic-closing-gate.sh's own
#      total_members==0 -> no-members branch, checked here one layer
#      earlier so a non-parent issue never even enters the population)
#   5. epic_label_operational=false    -> false, reason=not-operational
#      (Foundational-labeled epics stay on the ceremony path; this gate only
#      ever reviews Operational epics, same scope as item 6's own admission
#      predicate)
#   6. edges_considered_marker=false   -> false, reason=marker-missing
#      (the same stale-writer guard sweep-epic-admission.sh's own precedence
#      applies — an Operational epic triage never finished recording order
#      for is refused, never admitted into review on an unconsidered read)
#   7. else                            -> true, reason=admission-eligible
#      (the union's (b) arm: open, a real parent, Operational, marker
#      present — independent of whether any leg was Ready this run)
#
# Usage:
#   sweep-epic-review-population.sh <epic-json-file>
#   cat epic.json | sweep-epic-review-population.sh -
#
# Input JSON shape:
#   {
#     "epic": <int>,
#     "admitted_this_run": bool,
#       # true iff Step 1 item 6 admitted at least one of this epic's Ready
#       # legs this run. Default when absent: false.
#     "reads_available": bool,
#       # true iff the population-query reads below (open state, sub-issue
#       # presence, Operational label, edges-considered marker) ALL
#       # succeeded this run for this candidate epic. false (or omitted)
#       # means at least one ERRORED — refuse via population-reads-
#       # unavailable, never fall through to the fields below (their values,
#       # if supplied anyway, are untrustworthy and must be ignored by this
#       # precedence). Irrelevant when admitted_this_run=true (see item 1).
#     "epic_open": bool,
#       # true iff the candidate issue's own state is still open.
#     "has_sub_issues": bool,
#       # true iff the candidate issue has at least one native sub-issue
#       # (i.e. is genuinely an epic parent, not a bare issue).
#     "epic_label_operational": bool,
#       # true iff the candidate issue carries the `Operational` label.
#     "edges_considered_marker": bool
#       # true iff the candidate issue carries triage's
#       # `<!-- triage:edges-considered -->` marker comment.
#   }
#
# Output JSON on stdout:
#   {
#     "epic": <int>,
#     "in_review_population": bool,
#     "reason": "admitted-this-run" | "population-reads-unavailable" |
#               "not-open" | "not-a-parent" | "not-operational" |
#               "marker-missing" | "admission-eligible"
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-epic-review-population.sh <epic-json-file>
       cat epic.json | sweep-epic-review-population.sh -

Evaluates /sweep's end-of-run epic-closing gate REVIEW-POPULATION membership
for a single candidate epic: the union of (a) this run's item-6 admission and
(b) the admission-eligible set (an open Operational-epic parent carrying the
edges-considered marker, independent of whether any leg was Ready this run).
Prints a verdict JSON object to stdout. See this script's own header for the
input/output shape and the precedence order it implements.
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
  [ -f "$INPUT" ] || { echo "sweep-epic-review-population.sh: no such file: $INPUT" >&2; exit 1; }
  EPIC_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-epic-review-population.sh: jq required" >&2; exit 1; }

printf '%s' "$EPIC_JSON" | jq -c '
  (.epic) as $epic
  | (.admitted_this_run // false) as $admitted
  | (.reads_available // false) as $reads_available
  | (.epic_open // false) as $epic_open
  | (.has_sub_issues // false) as $has_sub_issues
  | (.epic_label_operational // false) as $operational
  | (.edges_considered_marker // false) as $marker
  | if $admitted == true then
      {epic: $epic, in_review_population: true, reason: "admitted-this-run"}
    elif $reads_available != true then
      {epic: $epic, in_review_population: false, reason: "population-reads-unavailable"}
    elif $epic_open != true then
      {epic: $epic, in_review_population: false, reason: "not-open"}
    elif $has_sub_issues != true then
      {epic: $epic, in_review_population: false, reason: "not-a-parent"}
    elif $operational != true then
      {epic: $epic, in_review_population: false, reason: "not-operational"}
    elif $marker != true then
      {epic: $epic, in_review_population: false, reason: "marker-missing"}
    else
      {epic: $epic, in_review_population: true, reason: "admission-eligible"}
    end
'
