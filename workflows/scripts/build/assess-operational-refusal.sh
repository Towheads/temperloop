#!/usr/bin/env bash
#
# assess-operational-refusal.sh — the deterministic half of `/assess`'s
# Step 1 mutual-exclusion guard (epic #1847 "epic-as-metadata for
# operational work" Produces #5, item assess-refusal-guard,
# temperloop#1854).
#
# `/assess --epic <N>` must refuse to decompose an epic that
# `/sweep`'s own pool-admission predicate
# (workflows/scripts/build/sweep-epic-admission.sh) would instead drain —
# an Operational epic, with no Foundational label anywhere in the group,
# while the checkout-wide SWEEP_ADMIT_OPERATIONAL_EPICS setting is on —
# UNLESS this run IS the un-rewired autonomous router's own
# `route-foundational` hand-off (pipeline-drive.md), which predates the
# sweep cutover (deferred: #1848) and would otherwise loop refusing
# itself forever, or the operator explicitly overrides.
#
# This script does NOT call `gh`, read the board, or read the vault — it is
# the pure combinator, fed the caller's (`/assess` Step 1, or a test
# fixture standing in for it) already-resolved reads. Mirrors the "mechanical
# piece only" split sweep-epic-admission.sh established: independently
# testable with synthetic fixtures, no live network. See
# workflows/scripts/build/tests/test_assess_operational_refusal.sh.
#
# THE PREDICATE (verbatim from epic #1847 Produces #5): `/assess` refuses an
# Operational epic when (admission setting on) AND (not a
# pipeline-drive-invoked run) AND (no Foundational label anywhere in the
# group) — UNLESS the operator explicitly overrides.
#
# PRECEDENCE (checked in this order — the first matching branch wins):
#   1. pipeline_drive_invoked=true  -> proceed, reason=pipeline-drive-carve-out
#      (the carve-out: pipeline-drive.md's route-foundational action calls
#      `/assess --epic <issue> --board <board> --no-poll` operator-absent —
#      this is the ONLY unattended caller of `/assess --epic` anywhere in
#      the pipeline, so this branch wins BEFORE the setting/class checks
#      below regardless of their values — never let the un-rewired router
#      refuse itself in a loop.)
#   2. setting_enabled=false        -> proceed, reason=setting-off
#      (rollback identity: with the setting off, `/assess` behavior is
#      unchanged from before this guard existed.)
#   3. epic_work_class != "Operational" -> proceed, reason=not-operational-epic
#      (the normal Foundational routing; default "" on an absent field
#      refuses THIS branch — i.e. does not treat an unread class as
#      Operational's proceed-favorable opposite; see epic_work_class note
#      below.)
#   4. any_foundational_in_group=true   -> proceed, reason=foundational-wins
#      (Foundational always wins — the same per-group precedence
#      sweep-epic-admission.sh applies on the admission side.)
#   5. override=true                -> proceed, reason=override, override_logged=true
#      (the explicit operator override — ONLY reachable once branches 1-4
#      have already fallen through, i.e. only when the guard would
#      otherwise refuse. An override passed on a pipeline-drive-invoked or
#      already-proceeding run is inert: override_logged stays false because
#      there was nothing to override.)
#   6. else                         -> refuse, reason=operational-admitted-elsewhere
#
# NOTE on defaults: unlike sweep-epic-admission.sh's admit/refuse verdict
# (where "refuse" is always the safe default on a missing/failed read),
# this predicate's safe default is "proceed" (`/assess`'s own pre-#1854
# behavior) — refusing is the NEW, narrower behavior this guard adds, so an
# absent/unresolvable field falls back to the old default rather than
# manufacturing a NEW refusal out of missing data. A genuinely FAILED read
# (e.g. `gh issue view --json labels` erroring) is handled procedurally by
# the caller BEFORE this script is invoked — `/assess` Step 1 stops the
# whole command on that read failure exactly as every other Step-0/Step-1
# `gh` read failure already does, rather than encoding a third
# read-availability field here.
#
# Usage:
#   assess-operational-refusal.sh <input-json-file>
#   cat input.json | assess-operational-refusal.sh -
#
# Input JSON shape:
#   {
#     "pipeline_drive_invoked": bool,   # PIPELINE_OPERATOR_ABSENT=1 detected
#     "setting_enabled": bool,          # ${SWEEP_ADMIT_OPERATIONAL_EPICS:-0} = 1
#     "epic_work_class": "Operational" | "Foundational" | "",
#     "any_foundational_in_group": bool,
#     "override": bool                  # operator explicitly overrode the refusal
#   }
#
# Output JSON on stdout:
#   {
#     "refuse": bool,
#     "reason": "pipeline-drive-carve-out" | "setting-off" |
#               "not-operational-epic" | "foundational-wins" |
#               "override" | "operational-admitted-elsewhere",
#     "override_logged": bool
#   }

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: assess-operational-refusal.sh <input-json-file>
       cat input.json | assess-operational-refusal.sh -

Evaluates /assess's Step 1 mutual-exclusion guard for a single epic, given
the pipeline-drive-invoked detection, the sweep-admission setting, the
epic's work-class reads, and any explicit operator override. Prints a
verdict JSON object to stdout. See this script's own header for the
input/output shape and the predicate it implements.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

INPUT="$1"
if [ "$INPUT" = "-" ]; then
  IN_JSON="$(cat)"
else
  [ -f "$INPUT" ] || { echo "assess-operational-refusal.sh: no such file: $INPUT" >&2; exit 1; }
  IN_JSON="$(cat "$INPUT")"
fi

command -v jq >/dev/null 2>&1 || { echo "assess-operational-refusal.sh: jq required" >&2; exit 1; }

printf '%s' "$IN_JSON" | jq -c '
  (.pipeline_drive_invoked // false) as $pipeline_drive
  | (.setting_enabled // false) as $setting_enabled
  | (.epic_work_class // "") as $work_class
  | (.any_foundational_in_group // false) as $any_foundational
  | (.override // false) as $override
  | if $pipeline_drive == true then
      {refuse: false, reason: "pipeline-drive-carve-out", override_logged: false}
    elif $setting_enabled != true then
      {refuse: false, reason: "setting-off", override_logged: false}
    elif $work_class != "Operational" then
      {refuse: false, reason: "not-operational-epic", override_logged: false}
    elif $any_foundational == true then
      {refuse: false, reason: "foundational-wins", override_logged: false}
    elif $override == true then
      {refuse: false, reason: "override", override_logged: true}
    else
      {refuse: true, reason: "operational-admitted-elsewhere", override_logged: false}
    end
'
