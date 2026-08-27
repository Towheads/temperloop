#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-epic-admission.sh — the
# deterministic Operational-epic member admission predicate combinator for
# /sweep's Step 1 pool build (epic #1847 Produces #1/#4/#6, item
# pool-admission-setting).
#
# Entirely OFFLINE: synthetic epic JSON fixtures on disk, zero `gh` calls,
# zero board reads (mirrors test_sweep_blocked_undefer.sh's convention).
#
# Covers every conjunct of the predicate independently, plus the precedence
# order between them:
#   1. setting_enabled=false -> ALWAYS refused (setting-off), regardless of
#      every other field being maximally admit-favorable — the rollback-
#      identity proof: with the setting off, this is the only reachable
#      branch.
#   2. reader_helpers_available=false -> refused (readers-unavailable),
#      even with the setting on and every other field admit-favorable.
#   2b. epic_reads_available=false -> refused (readers-unavailable), the
#      per-epic call-failure branch (escalation round 2, HIGH finding): an
#      errored per-epic read is never the permissive branch, even with
#      epic_work_class="Operational" and any_foundational_in_group=false
#      explicitly present and admit-favorable (proving the failure signal
#      overrides them, not merely that they happen to also be absent).
#   2c. epic_reads_available OMITTED -> refused (readers-unavailable), same
#      as 2b — the field's own default is refusing, never a permissive
#      guess when the caller forgets to pass it.
#   3. epic_work_class != Operational -> refused (not-operational-epic); an
#      ABSENT epic_work_class field refuses the same way (default "",
#      never "Operational" — an unread field is never admit-favorable).
#   4. any_foundational_in_group=true -> refused (foundational-wins); with
#      mixed_class_group=true, surface_required=true (the anomaly needing
#      operator surfacing); with mixed_class_group=false (a uniformly
#      Foundational epic — not an anomaly), surface_required=false. An
#      ABSENT any_foundational_in_group field refuses the same way
#      (default true, mirroring edges_considered_marker's existing false
#      default — an unread group is never assumed foundational-free).
#   5. live_plan_note=true -> refused (live-plan-note), the /assess race
#      guard.
#   6. edges_considered_marker=false -> refused (marker-missing), the
#      stale-writer guard.
#   7. every conjunct satisfied -> admit=true, reason=admitted.
#   8. precedence proof: setting-off wins over every other refusing
#      condition; readers-unavailable wins over every condition below it.
#   9. --help / -h / no-args activation proof.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-epic-admission.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-epic-admission.sh not found/executable at $CLI" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_field() { # <desc> <fixture-json> <jq-field> <want>
  local desc="$1" file="$2" field="$3" want="$4"
  local out got
  out="$(bash "$CLI" "$file")"
  got="$(jq -r "$field" <<<"$out")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "want [$want], got [$got] (full: $out)"
  fi
}

# The fully admit-favorable baseline every negative case starts from and
# flips exactly one field away from.
ADMIT_ALL='{"setting_enabled":true,"reader_helpers_available":true,"epic_reads_available":true,"epic_work_class":"Operational","any_foundational_in_group":false,"mixed_class_group":false,"live_plan_note":false,"edges_considered_marker":true}'

# ── 1: setting off — rollback identity ──────────────────────────────────
echo "--- 1: setting_enabled=false always refuses (setting-off), even fully admit-favorable otherwise ---"
OFF="$TMP/setting-off.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {setting_enabled: false}' > "$OFF"
check_field "setting off -> admit=false" "$OFF" '.admit' "false"
check_field "...reason=setting-off" "$OFF" '.reason' "setting-off"

# ── 2: readers unavailable ───────────────────────────────────────────────
echo "--- 2: reader_helpers_available=false refuses (readers-unavailable) even with everything else admit-favorable ---"
NOREAD="$TMP/no-readers.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {reader_helpers_available: false}' > "$NOREAD"
check_field "readers unavailable -> admit=false" "$NOREAD" '.admit' "false"
check_field "...reason=readers-unavailable" "$NOREAD" '.reason' "readers-unavailable"

# ── 2b: per-epic read failure — an error is never the permissive branch ──
echo "--- 2b: epic_reads_available=false refuses (readers-unavailable) even with everything else admit-favorable (escalation round 2, HIGH) ---"
EPICREADFAIL="$TMP/epic-read-fail.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {epic_reads_available: false}' > "$EPICREADFAIL"
check_field "epic read failure -> admit=false" "$EPICREADFAIL" '.admit' "false"
check_field "...reason=readers-unavailable" "$EPICREADFAIL" '.reason' "readers-unavailable"

echo "--- 2c: epic_reads_available OMITTED refuses the same way (default is refusing, never a permissive guess) ---"
EPICREADABSENT="$TMP/epic-read-absent.json"
jq -n '{setting_enabled:true, reader_helpers_available:true, epic_work_class:"Operational", any_foundational_in_group:false, mixed_class_group:false, live_plan_note:false, edges_considered_marker:true}' > "$EPICREADABSENT"
check_field "epic_reads_available omitted -> admit=false" "$EPICREADABSENT" '.admit' "false"
check_field "...reason=readers-unavailable" "$EPICREADABSENT" '.reason' "readers-unavailable"

# ── 3: not an Operational epic ───────────────────────────────────────────
echo "--- 3: epic_work_class=Foundational refuses (not-operational-epic) ---"
NOTOP="$TMP/not-operational.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {epic_work_class: "Foundational"}' > "$NOTOP"
check_field "Foundational epic -> admit=false" "$NOTOP" '.admit' "false"
check_field "...reason=not-operational-epic" "$NOTOP" '.reason' "not-operational-epic"

echo "--- 3b: epic_work_class OMITTED refuses (not-operational-epic) — absent field defaults refusing, never 'Operational' ---"
NOWORKCLASS="$TMP/no-work-class.json"
jq -n --argjson base "$ADMIT_ALL" '$base | del(.epic_work_class)' > "$NOWORKCLASS"
check_field "epic_work_class omitted -> admit=false" "$NOWORKCLASS" '.admit' "false"
check_field "...reason=not-operational-epic" "$NOWORKCLASS" '.reason' "not-operational-epic"

# ── 4c: any_foundational_in_group omitted -> refuses the same as true ────
echo "--- 4c: any_foundational_in_group OMITTED refuses (foundational-wins) — absent field defaults refusing, never false ---"
NOFOUNDFIELD="$TMP/no-foundational-field.json"
jq -n --argjson base "$ADMIT_ALL" '$base | del(.any_foundational_in_group)' > "$NOFOUNDFIELD"
check_field "any_foundational_in_group omitted -> admit=false" "$NOFOUNDFIELD" '.admit' "false"
check_field "...reason=foundational-wins" "$NOFOUNDFIELD" '.reason' "foundational-wins"

# ── 4: Foundational-wins, mixed group -> surfaced ────────────────────────
echo "--- 4a: any_foundational_in_group=true + mixed_class_group=true -> refused AND surface_required=true ---"
MIXED="$TMP/mixed.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {any_foundational_in_group: true, mixed_class_group: true}' > "$MIXED"
check_field "mixed group -> admit=false" "$MIXED" '.admit' "false"
check_field "...reason=foundational-wins" "$MIXED" '.reason' "foundational-wins"
check_field "...surface_required=true (the anomaly, mixed group)" "$MIXED" '.surface_required' "true"

echo "--- 4b: any_foundational_in_group=true + mixed_class_group=false -> refused, NOT surfaced (uniformly Foundational, not an anomaly) ---"
UNIFORM_F="$TMP/uniform-foundational.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {any_foundational_in_group: true, mixed_class_group: false}' > "$UNIFORM_F"
check_field "uniformly-Foundational group -> admit=false" "$UNIFORM_F" '.admit' "false"
check_field "...reason=foundational-wins" "$UNIFORM_F" '.reason' "foundational-wins"
check_field "...surface_required=false (not an anomaly)" "$UNIFORM_F" '.surface_required' "false"

# ── 5: live plan note — the /assess race guard ───────────────────────────
echo "--- 5: live_plan_note=true refuses (live-plan-note) ---"
LIVEPLAN="$TMP/live-plan.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {live_plan_note: true}' > "$LIVEPLAN"
check_field "live plan note -> admit=false" "$LIVEPLAN" '.admit' "false"
check_field "...reason=live-plan-note" "$LIVEPLAN" '.reason' "live-plan-note"

# ── 6: marker missing — the stale-writer guard ───────────────────────────
echo "--- 6: edges_considered_marker=false refuses (marker-missing) ---"
NOMARKER="$TMP/no-marker.json"
jq -n --argjson base "$ADMIT_ALL" '$base + {edges_considered_marker: false}' > "$NOMARKER"
check_field "no edges-considered marker -> admit=false" "$NOMARKER" '.admit' "false"
check_field "...reason=marker-missing" "$NOMARKER" '.reason' "marker-missing"

# ── 7: every conjunct satisfied -> admitted ──────────────────────────────
echo "--- 7: every conjunct satisfied -> admit=true, reason=admitted ---"
ADMITTED="$TMP/admitted.json"
printf '%s' "$ADMIT_ALL" > "$ADMITTED"
check_field "all conjuncts satisfied -> admit=true" "$ADMITTED" '.admit' "true"
check_field "...reason=admitted" "$ADMITTED" '.reason' "admitted"
check_field "...surface_required=false" "$ADMITTED" '.surface_required' "false"

# ── 8: precedence proof ──────────────────────────────────────────────────
echo "--- 8a: setting-off wins over every other simultaneously-failing condition ---"
ALL_BAD="$TMP/all-bad.json"
jq -n '{setting_enabled:false, reader_helpers_available:false, epic_work_class:"Foundational", any_foundational_in_group:true, mixed_class_group:true, live_plan_note:true, edges_considered_marker:false}' > "$ALL_BAD"
check_field "everything failing at once -> reason=setting-off (checked first)" "$ALL_BAD" '.reason' "setting-off"

echo "--- 8b: readers-unavailable wins over every condition below it (setting is on) ---"
READERS_AND_REST_BAD="$TMP/readers-and-rest-bad.json"
jq -n '{setting_enabled:true, reader_helpers_available:false, epic_work_class:"Foundational", any_foundational_in_group:true, mixed_class_group:true, live_plan_note:true, edges_considered_marker:false}' > "$READERS_AND_REST_BAD"
check_field "setting on, readers unavailable, everything else also bad -> reason=readers-unavailable" "$READERS_AND_REST_BAD" '.reason' "readers-unavailable"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_epic_admission: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_epic_admission: OK — all %d checks passed\n' "$pass"
