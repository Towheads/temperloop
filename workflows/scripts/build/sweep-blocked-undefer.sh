#!/usr/bin/env bash
#
# sweep-blocked-undefer.sh — the deterministic half of /sweep's un-defer
# predicate for a native `blocked_by` edge (temperloop#1835, epic #1847
# "epic-as-metadata for operational work" Produces #2:
# "`blocked_by`-aware chunk formation").
#
# `/sweep` Step 1's pool build (and Step 3's per-chunk-boundary re-check)
# must decide whether an open `blocked_by` edge on a pooled item (member or
# singleton) still holds it back, or whether the blocker has genuinely
# landed and the dependent may now be driven. That decision needs THREE live
# reads this script does NOT make itself (no `gh`, no `git`, no board — the
# same "mechanical piece only" split sweep-answered-exclusion.sh already
# established):
#
#   1. the blocker issue's `state` (gh issue view --json state)
#   2. the blocker's linked MERGED PRs, if any
#      (gh pr list --search "Closes #<n>" --state merged --json number,mergeCommitOid)
#   3. whether that PR's merge commit is an ancestor of origin/<default>
#      (workflows/scripts/build/worktree.sh deps-merged <repo> <sha,...>)
#
# The caller (sweep.md Step 1 / Step 3, or a test fixture standing in for
# them) runs those three reads and hands this script their RESULTS; this
# script is the pure combinator that turns them into the un-defer verdict —
# independently testable with synthetic fixtures, no live network. See
# workflows/scripts/build/tests/test_sweep_blocked_undefer.sh.
#
# THE PREDICATE (temperloop#1847 Produces #2, verbatim):
#   blocker issue CLOSED AND its landing commit is an ancestor of
#   origin/<default> — resolved issue->SHA via the blocker's linked merged
#   PR, then `worktree.sh deps-merged`.
#
# Three explicit dispositions this script fixes so the predicate never has
# to be re-derived per caller:
#   - AMBIGUITY CASE: a blocker closed with NO linked merged PR (e.g.
#     closed-as-not-planned, closed by hand with no PR) releases its
#     dependents — there is no merge commit to wait on, and holding a
#     dependent hostage to a PR that will never exist would stall it
#     forever. un_defer=true, reason=closed-no-linked-merged-pr.
#   - PARKED NEVER RELEASES: a blocker whose OWN sweep disposition (in the
#     SAME run, when the blocker is itself a pool member being driven
#     concurrently) is `parked` never releases its dependents, regardless of
#     the issue's open/closed state read — parked is terminal-by-disposition
#     with the blocker's work UNLANDED, so honoring a stale/incidental
#     closed read here would drive a dependent against work that never
#     shipped. This check is deliberately evaluated FIRST, ahead of the
#     state read.
#   - PENDING ANCESTRY CHECK: a linked merged PR exists but the caller has
#     not yet run (or has not supplied the result of) `deps-merged` — this
#     conservatively still defers (un_defer=false) rather than guessing.
#
# Usage:
#   sweep-blocked-undefer.sh <blocker-json-file>
#   cat blocker.json | sweep-blocked-undefer.sh -
#
# Input JSON shape:
#   {
#     "blocker_number": 1234,
#     "state": "OPEN" | "CLOSED",
#     "linked_merged_prs": [{"number": 5678, "mergeCommitOid": "<sha>"}, ...],
#     "deps_merged": "DEPS_MERGED" | "DEPS_UNMERGED" | null,
#       # the `worktree.sh deps-merged` outcome for the comma-joined
#       # mergeCommitOid list above; null/omitted when linked_merged_prs is
#       # empty (nothing to check) or the caller hasn't run it yet.
#     "sweep_disposition": "merged" | "resolved (verdict)" | "parked" | null
#       # this SAME run's terminal disposition for the blocker, ONLY when
#       # the blocker is itself a pool member being driven this run; null
#       # for the ordinary cross-run case (ignore this field).
#   }
#
# Output JSON on stdout:
#   {
#     "un_defer": bool,
#     "reason": "parked-blocker-never-releases" | "blocker-open" |
#               "closed-no-linked-merged-pr" | "merge-commit-is-ancestor" |
#               "merge-commit-not-yet-ancestor" | "deps-merged-check-pending"
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-blocked-undefer.sh <blocker-json-file>
       cat blocker.json | sweep-blocked-undefer.sh -

Evaluates /sweep's blocked_by un-defer predicate for a single blocker,
given its state, linked-merged-PR set, deps-merged outcome, and (when the
blocker is itself a same-run pool member) its own sweep disposition. Prints
a verdict JSON object to stdout. See this script's own header for the
input/output shape and the predicate it implements.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

INPUT="$1"
if [ "$INPUT" = "-" ]; then
  BLOCKER_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "sweep-blocked-undefer.sh: no such file: $INPUT" >&2; exit 1; }
  BLOCKER_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-blocked-undefer.sh: jq required" >&2; exit 1; }

printf '%s' "$BLOCKER_JSON" | jq -c '
  (.state // "OPEN") as $state
  | (.linked_merged_prs // []) as $prs
  | (.deps_merged // null) as $deps_merged
  | (.sweep_disposition // null) as $disposition
  | if $disposition == "parked" then
      {un_defer: false, reason: "parked-blocker-never-releases"}
    elif $state != "CLOSED" then
      {un_defer: false, reason: "blocker-open"}
    elif ($prs | length) == 0 then
      {un_defer: true, reason: "closed-no-linked-merged-pr"}
    elif $deps_merged == "DEPS_MERGED" then
      {un_defer: true, reason: "merge-commit-is-ancestor"}
    elif $deps_merged == "DEPS_UNMERGED" then
      {un_defer: false, reason: "merge-commit-not-yet-ancestor"}
    else
      {un_defer: false, reason: "deps-merged-check-pending"}
    end
'
