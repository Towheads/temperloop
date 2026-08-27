#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-epic-review-population.sh — the
# deterministic /sweep end-of-run epic-closing gate REVIEW-POPULATION
# membership combinator (epic #1847, item "epic-closing-gate", escalation
# round 5 HIGH finding).
#
# Entirely OFFLINE: synthetic epic JSON fixtures on disk, zero `gh` calls,
# zero board reads (mirrors test_sweep_epic_admission.sh's and
# test_sweep_epic_closing_gate.sh's own convention).
#
# Covers every branch of the precedence independently, plus the precedence
# order between them, with the load-bearing round-5 case (2) proving the
# actual regression this script fixes: a fully-drained epic with ZERO Ready
# legs this run (so item 6 never admitted it) still enters the review
# population via the admission-eligible query arm.
#
#   1. admitted_this_run=true -> in_review_population=true (admitted-this-run),
#      regardless of every other field — the union's (a) arm.
#   2. admitted_this_run=false, but epic_open/has_sub_issues/
#      epic_label_operational/edges_considered_marker all true ->
#      in_review_population=true (admission-eligible) — THE ROUND-5 CASE: a
#      drained epic with zero Ready legs this run still enters review.
#   3. reads_available=false (or omitted) -> in_review_population=false
#      (population-reads-unavailable), never a permissive guess.
#   4. epic_open=false -> not-open.
#   5. has_sub_issues=false -> not-a-parent.
#   6. epic_label_operational=false -> not-operational.
#   7. edges_considered_marker=false -> marker-missing.
#   8. precedence proof: admitted_this_run=true wins even when
#      reads_available=false AND every other field is unfavorable
#      simultaneously — the admission union arm never needs the query reads.
#   9. --help / -h / no-args activation proof.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-epic-review-population.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-epic-review-population.sh not found/executable at $CLI" >&2; exit 1; }

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

# The fully favorable-to-admission-eligible baseline every other case flips
# exactly one field away from.
BASE_ELIGIBLE='{"epic":700,"admitted_this_run":false,"reads_available":true,"epic_open":true,"has_sub_issues":true,"epic_label_operational":true,"edges_considered_marker":true}'

# ── 1: admitted_this_run wins unconditionally ────────────────────────────
echo "--- 1: admitted_this_run=true -> in_review_population=true (admitted-this-run), regardless of every other field ---"
ADMITTED="$TMP/admitted.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {admitted_this_run: true}' > "$ADMITTED"
check_field "admitted this run -> in_review_population=true" "$ADMITTED" '.in_review_population' "true"
check_field "...reason=admitted-this-run" "$ADMITTED" '.reason' "admitted-this-run"

# ── 2: THE ROUND-5 CASE — zero Ready legs this run, still admission-eligible
echo "--- 2: admitted_this_run=false but epic is an open, Operational, marker-bearing parent -> admission-eligible (the round-5 fix) ---"
ELIGIBLE="$TMP/eligible.json"
printf '%s' "$BASE_ELIGIBLE" > "$ELIGIBLE"
check_field "not admitted this run, but query-eligible -> in_review_population=true" "$ELIGIBLE" '.in_review_population' "true"
check_field "...reason=admission-eligible" "$ELIGIBLE" '.reason' "admission-eligible"

# ── 3: population-query reads unavailable ─────────────────────────────────
echo "--- 3: reads_available=false -> in_review_population=false (population-reads-unavailable), never a permissive guess ---"
NOREADS="$TMP/no-reads.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {reads_available: false}' > "$NOREADS"
check_field "reads unavailable -> in_review_population=false" "$NOREADS" '.in_review_population' "false"
check_field "...reason=population-reads-unavailable" "$NOREADS" '.reason' "population-reads-unavailable"

echo "--- 3b: reads_available OMITTED -> population-reads-unavailable (default is refusing) ---"
NOREADSFIELD="$TMP/no-reads-field.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base | del(.reads_available)' > "$NOREADSFIELD"
check_field "reads_available omitted -> in_review_population=false" "$NOREADSFIELD" '.in_review_population' "false"
check_field "...reason=population-reads-unavailable" "$NOREADSFIELD" '.reason' "population-reads-unavailable"

# ── 4: not open ────────────────────────────────────────────────────────────
echo "--- 4: epic_open=false -> not-open ---"
NOTOPEN="$TMP/not-open.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {epic_open: false}' > "$NOTOPEN"
check_field "closed epic -> in_review_population=false" "$NOTOPEN" '.in_review_population' "false"
check_field "...reason=not-open" "$NOTOPEN" '.reason' "not-open"

# ── 5: not a parent ────────────────────────────────────────────────────────
echo "--- 5: has_sub_issues=false -> not-a-parent ---"
NOTPARENT="$TMP/not-parent.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {has_sub_issues: false}' > "$NOTPARENT"
check_field "no native sub-issues -> in_review_population=false" "$NOTPARENT" '.in_review_population' "false"
check_field "...reason=not-a-parent" "$NOTPARENT" '.reason' "not-a-parent"

# ── 6: not operational ─────────────────────────────────────────────────────
echo "--- 6: epic_label_operational=false -> not-operational ---"
NOTOPERATIONAL="$TMP/not-operational.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {epic_label_operational: false}' > "$NOTOPERATIONAL"
check_field "not Operational-labeled -> in_review_population=false" "$NOTOPERATIONAL" '.in_review_population' "false"
check_field "...reason=not-operational" "$NOTOPERATIONAL" '.reason' "not-operational"

# ── 7: marker missing ──────────────────────────────────────────────────────
echo "--- 7: edges_considered_marker=false -> marker-missing ---"
NOMARKER="$TMP/no-marker.json"
jq -n --argjson base "$BASE_ELIGIBLE" '$base + {edges_considered_marker: false}' > "$NOMARKER"
check_field "no edges-considered marker -> in_review_population=false" "$NOMARKER" '.in_review_population' "false"
check_field "...reason=marker-missing" "$NOMARKER" '.reason' "marker-missing"

# ── 8: precedence proof ────────────────────────────────────────────────────
echo "--- 8: admitted_this_run=true wins over reads_available=false AND every other field unfavorable, simultaneously ---"
ALLBAD="$TMP/all-bad.json"
jq -n '{epic:701, admitted_this_run:true, reads_available:false, epic_open:false, has_sub_issues:false, epic_label_operational:false, edges_considered_marker:false}' > "$ALLBAD"
check_field "everything else unfavorable -> reason=admitted-this-run (checked first)" "$ALLBAD" '.reason' "admitted-this-run"
check_field "...in_review_population=true regardless" "$ALLBAD" '.in_review_population' "true"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_epic_review_population: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_epic_review_population: OK — all %d checks passed\n' "$pass"
