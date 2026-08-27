#!/usr/bin/env bash
#
# sweep-epic-admission.sh — the deterministic half of /sweep's Operational-epic
# member admission predicate (epic #1847 "epic-as-metadata for operational
# work", Produces #1 + #4 + #6, item pool-admission-setting).
#
# `/sweep` Step 1's pool build must decide, for each Ready sub-issue whose
# parent is a board epic, whether that member is ADMITTED into the fix pool
# (drained via sweep, no /assess) or left to the ceremony path
# (assess -> plan -> build). That decision depends on FIVE live reads this
# script does NOT make itself (no `gh`, no board, no filesystem — the same
# "mechanical piece only" split sweep-blocked-undefer.sh established):
#
#   1. the SWEEP_ADMIT_OPERATIONAL_EPICS setting (build.config.sh)
#   2. whether the pooled adapter helper the admission read depends on
#      (board_blocked_by_open) is even present in this checkout's vendored
#      board.sh (a stale-adapter probe, `declare -F`)
#   3. the epic parent's work-class label (gh issue view --json labels)
#   4. whether ANY Foundational label exists anywhere in the group — parent
#      or any member (gh issue view --json labels, per member)
#   5. whether a LIVE (draft/approved, non-superseded) Plans/ note exists
#      for this epic (a vault read — the /assess race guard)
#   6. whether the parent carries triage's `<!-- triage:edges-considered -->`
#      marker (gh issue view --json comments)
#
# The caller (sweep.md Step 1, or a test fixture standing in for it) runs
# those reads and hands this script their RESULTS; this script is the pure
# combinator that turns them into the admit/refuse verdict — independently
# testable with synthetic fixtures, no live network. See
# workflows/scripts/build/tests/test_sweep_epic_admission.sh.
#
# THE PREDICATE (epic #1847 Produces #1, verbatim): setting ON AND parent
# epic Operational AND no Foundational label anywhere in the group (parent
# or member — Foundational-wins, re-evaluated live every pool build) AND no
# live (draft/approved, non-superseded) plan note for the epic (race guard)
# AND the edges-considered marker present (stale-writer guard).
#
# PRECEDENCE (checked in this order — the first matching branch wins):
#   1. setting_enabled=false            -> refuse, reason=setting-off
#      (rollback identity: with the setting off, this is the ONLY branch
#      that can ever fire, so pool selection is behavior-identical to
#      legacy — test_sweep_epic_admission.sh Case 1.)
#   2. reader_helpers_available=false   -> refuse, reason=readers-unavailable
#      (a stale vendored board.sh lacking board_blocked_by_open cannot
#      safely admit ANY epic member this run — falls back to a
#      singleton-only pool, never a per-item guess.)
#   3. epic_work_class != "Operational" -> refuse, reason=not-operational-epic
#      (the normal Foundational routing; not an anomaly, no surfacing.)
#   4. any_foundational_in_group=true   -> refuse, reason=foundational-wins
#      (Foundational always wins. surface_required is set true in the
#      output IFF mixed_class_group=true — a group that is genuinely mixed
#      (some Operational, some Foundational) is an anomaly the operator must
#      see, distinct from an epic that was always uniformly Foundational.)
#   5. live_plan_note=true              -> refuse, reason=live-plan-note
#      (the /assess race guard — a plan note already in flight for this
#      epic owns it; sweep must not double-drive it.)
#   6. edges_considered_marker=false    -> refuse, reason=marker-missing
#      (the stale-writer guard: an empty edge read alone never proves
#      order-freedom, docs/adr/0031 — a marker-less Operational epic is
#      refused rather than silently admitted on an unconsidered read.)
#   7. else                             -> admit=true, reason=admitted
#
# Usage:
#   sweep-epic-admission.sh <epic-json-file>
#   cat epic.json | sweep-epic-admission.sh -
#
# Input JSON shape:
#   {
#     "setting_enabled": bool,
#     "reader_helpers_available": bool,
#     "epic_work_class": "Operational" | "Foundational",
#     "any_foundational_in_group": bool,
#     "mixed_class_group": bool,
#       # true iff the group (parent + members) carries BOTH Operational and
#       # Foundational classifications — the anomaly requiring surfacing.
#       # Only consulted when any_foundational_in_group=true; ignored
#       # otherwise (a uniformly-Operational group is never "mixed").
#     "live_plan_note": bool,
#     "edges_considered_marker": bool
#   }
#
# Output JSON on stdout:
#   {
#     "admit": bool,
#     "reason": "setting-off" | "readers-unavailable" |
#               "not-operational-epic" | "foundational-wins" |
#               "live-plan-note" | "marker-missing" | "admitted",
#     "surface_required": bool
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sweep-epic-admission.sh <epic-json-file>
       cat epic.json | sweep-epic-admission.sh -

Evaluates /sweep's Operational-epic member admission predicate for a single
epic, given the admission setting, the reader-helper availability probe,
the group's work-class reads, the live-plan-note race-guard read, and the
edges-considered marker read. Prints a verdict JSON object to stdout. See
this script's own header for the input/output shape and the predicate it
implements.
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
  [ -f "$INPUT" ] || { echo "sweep-epic-admission.sh: no such file: $INPUT" >&2; exit 1; }
  EPIC_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "sweep-epic-admission.sh: jq required" >&2; exit 1; }

printf '%s' "$EPIC_JSON" | jq -c '
  (.setting_enabled // false) as $setting_enabled
  | (.reader_helpers_available // false) as $readers_available
  | (.epic_work_class // "Operational") as $work_class
  | (.any_foundational_in_group // false) as $any_foundational
  | (.mixed_class_group // false) as $mixed
  | (.live_plan_note // false) as $live_plan_note
  | (.edges_considered_marker // false) as $marker
  | if $setting_enabled != true then
      {admit: false, reason: "setting-off", surface_required: false}
    elif $readers_available != true then
      {admit: false, reason: "readers-unavailable", surface_required: false}
    elif $work_class != "Operational" then
      {admit: false, reason: "not-operational-epic", surface_required: false}
    elif $any_foundational == true then
      {admit: false, reason: "foundational-wins", surface_required: $mixed}
    elif $live_plan_note == true then
      {admit: false, reason: "live-plan-note", surface_required: false}
    elif $marker != true then
      {admit: false, reason: "marker-missing", surface_required: false}
    else
      {admit: true, reason: "admitted", surface_required: false}
    end
'
