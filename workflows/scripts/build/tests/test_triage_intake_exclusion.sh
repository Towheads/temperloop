#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/triage-intake-exclusion.sh — the
# deterministic half of /triage Step 1 Adapter A's THIRD naturally-excluded
# intake bucket, the process-record label filter (temperloop#1614, item
# retro-tracker-intake-exclusion).
#
# Entirely OFFLINE: synthetic board item-list JSON on disk, zero `gh` calls,
# zero board reads (same convention as test_sweep_answered_exclusion.sh, whose
# extracted-classifier shape this mirrors).
#
# Covers:
#   1. a Backlog item carrying `retro-pending` is EXCLUDED from intake — the
#      item's headline acceptance, and the one the six live trackers hit.
#   2. `retro-info` (what a BARE KERNEL checkout with no /retro judge mints)
#      is excluded by the same default — the stranger-test arm.
#   3. an ordinary Backlog item with no excluded label is INTOOK.
#   4. a NON-Backlog (Ready) item carrying `retro-pending` appears in NEITHER
#      list — the exclusion never reaches outside Adapter A's Backlog slice,
#      so it composes with, rather than duplicates, the slice itself.
#   5. intake + excluded PARTITION the Backlog total (no item lost, none
#      double-counted).
#   6. the exclusion is REPORTED on its own summary line, naming the count,
#      the per-label tally and the issue numbers — a silent skip is the
#      failure this bucket must not reproduce (#164).
#   7. the ZERO case still prints a summary line (mandatory-every-run, not
#      "only when non-empty").
#   8. an EMPTY label set excludes nothing AND says so on the line — a
#      disabled filter is reported, never silent.
#   9. one item carrying TWO excluded labels counts ONCE toward N and appears
#      under BOTH labels in the tally.
#  10. the label set is a generic SEAM: an arbitrary operator-supplied label
#      excludes, and `retro-pending` does NOT when it is not in the set —
#      proving nothing is hardcoded to the retro vocabulary.
#  11. an item with a `retro-pending`-ish label that is not an exact match
#      (`retro-pending-followup`) is NOT excluded — substring, not equality,
#      would over-exclude.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../triage-intake-exclusion.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: triage-intake-exclusion.sh not found/executable at $CLI" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Deliberately UNSET in this harness so every case drives the script's own
# documented fallback default (or an explicit --labels), never whatever a
# calling shell happened to export.
unset TRIAGE_INTAKE_EXCLUDE_LABELS

# The shared fixture: a resolved board item-list in BOARD_ITEMS_JSON's exact
# shape (board.sh's issue_item reshape — `.content.number`, `.labels`,
# `.status`), mixing the populations Adapter A actually sees.
BOARD="$TMP/board.json"
cat >"$BOARD" <<'JSON'
{ "items": [
  { "id": "ISSUE_851",  "content": { "number": 851,  "title": "Process retro (mint) for epic #700" },
    "labels": ["Operational", "fnd:status:backlog", "retro-pending"], "status": "Backlog" },
  { "id": "ISSUE_1576", "content": { "number": 1576, "title": "Process retro (mint) for epic #1500" },
    "labels": ["Operational", "fnd:status:backlog", "retro-pending", "retro-urgent"], "status": "Backlog" },
  { "id": "ISSUE_1601", "content": { "number": 1601, "title": "Process retro (mint), no judge installed" },
    "labels": ["Operational", "fnd:status:backlog", "retro-info"], "status": "Backlog" },
  { "id": "ISSUE_1614", "content": { "number": 1614, "title": "Real build work" },
    "labels": ["Operational", "fnd:status:backlog"], "status": "Backlog" },
  { "id": "ISSUE_1615", "content": { "number": 1615, "title": "More real build work" },
    "labels": ["Foundational", "fnd:status:backlog"], "status": "Backlog" },
  { "id": "ISSUE_1700", "content": { "number": 1700, "title": "Tracker already triaged into Ready" },
    "labels": ["Operational", "fnd:status:ready", "retro-pending"], "status": "Ready" }
] }
JSON

run() { # <fixture> [extra args...]
  local f="$1"; shift
  bash "$CLI" "$f" "$@"
}

OUT="$(run "$BOARD")"

field() { jq -r "$1" <<<"$OUT"; }

# --- 1/2/3: the three membership verdicts under the DEFAULT label set -------
if [ "$(field '[.excluded[].issue] | index(851) != null')" = "true" ] &&
   [ "$(field '[.intake[]]   | index(851) == null')" = "true" ]; then
  ok "retro-pending Backlog item is excluded from intake (#851)"
else
  bad "retro-pending Backlog item is excluded from intake (#851)" "out=$OUT"
fi

if [ "$(field '[.excluded[].issue] | index(1601) != null')" = "true" ]; then
  ok "retro-info Backlog item is excluded too (bare-kernel, no /retro judge)"
else
  bad "retro-info Backlog item is excluded too" "out=$OUT"
fi

if [ "$(field '[.intake[]] | index(1614) != null and (index(1615) != null)')" = "true" ] &&
   [ "$(field '[.excluded[].issue] | index(1614) == null')" = "true" ]; then
  ok "ordinary Backlog items are intook untouched (#1614, #1615)"
else
  bad "ordinary Backlog items are intook untouched" "out=$OUT"
fi

# --- 4: the exclusion never reaches outside Adapter A's Backlog slice -------
if [ "$(field '[.intake[]] | index(1700) == null')" = "true" ] &&
   [ "$(field '[.excluded[].issue] | index(1700) == null')" = "true" ]; then
  ok "a Ready item carrying retro-pending is in NEITHER list (Backlog slice only)"
else
  bad "a Ready item carrying retro-pending is in NEITHER list" "out=$OUT"
fi

# --- 5: the two lists partition the Backlog total ---------------------------
if [ "$(field '(.intake | length) + (.excluded | length) == .backlog_total')" = "true" ] &&
   [ "$(field '.backlog_total')" = "5" ]; then
  ok "intake + excluded partition backlog_total (5 Backlog items, Ready one out of scope)"
else
  bad "intake + excluded partition backlog_total" "out=$OUT"
fi

# --- 6: reported on its own summary line ------------------------------------
LINE="$(field '.summary_line')"
case "$LINE" in
  "Excluded at intake (Step 1 — process-record label filter): 3 carrying a non-work record label (retro-info ×1, retro-pending ×2): #851 #1576 #1601. Remove the label to include.")
    ok "summary line reports count, per-label tally and issue numbers" ;;
  *)
    bad "summary line reports count, per-label tally and issue numbers" "got [$LINE]" ;;
esac

# --- 7: the zero case still prints a line -----------------------------------
CLEAN="$TMP/clean.json"
cat >"$CLEAN" <<'JSON'
{ "items": [
  { "id": "ISSUE_10", "content": { "number": 10, "title": "Real work" },
    "labels": ["Operational"], "status": "Backlog" }
] }
JSON
ZLINE="$(run "$CLEAN" | jq -r '.summary_line')"
case "$ZLINE" in
  "Excluded at intake (Step 1 — process-record label filter): 0 — no Backlog item carries an excluded label"*)
    ok "zero case still prints the mandatory summary line" ;;
  *)
    bad "zero case still prints the mandatory summary line" "got [$ZLINE]" ;;
esac

# --- 8: an empty label set excludes nothing, and says so --------------------
EOUT="$(run "$BOARD" --labels "")"
ELINE="$(jq -r '.summary_line' <<<"$EOUT")"
if [ "$(jq -r '.excluded | length' <<<"$EOUT")" = "0" ] &&
   [ "$(jq -r '.intake | length' <<<"$EOUT")" = "5" ] &&
   [ "$ELINE" = "Excluded at intake (Step 1 — process-record label filter): 0 — TRIAGE_INTAKE_EXCLUDE_LABELS is empty, no label exclusion configured" ]; then
  ok "empty label set excludes nothing and reports the disabled filter out loud"
else
  bad "empty label set excludes nothing and reports it" "line=[$ELINE] out=$EOUT"
fi

# --- 9: two excluded labels on one item -> counted once, listed under both ---
DOUBLE="$TMP/double.json"
cat >"$DOUBLE" <<'JSON'
{ "items": [
  { "id": "ISSUE_20", "content": { "number": 20, "title": "Tracker wearing both state labels" },
    "labels": ["retro-pending", "retro-info"], "status": "Backlog" }
] }
JSON
DOUT="$(run "$DOUBLE")"
if [ "$(jq -r '.excluded | length' <<<"$DOUT")" = "1" ] &&
   [ "$(jq -r '.excluded[0].labels | join(",")' <<<"$DOUT")" = "retro-info,retro-pending" ] &&
   [ "$(jq -r '.summary_line | test("retro-info ×1, retro-pending ×1")' <<<"$DOUT")" = "true" ]; then
  ok "an item carrying two excluded labels counts once and lists both"
else
  bad "an item carrying two excluded labels counts once and lists both" "out=$DOUT"
fi

# --- 10: generic seam, not a retro-vocabulary hardcode ----------------------
SOUT="$(run "$BOARD" --labels "Foundational")"
if [ "$(jq -r '[.excluded[].issue] | join(",")' <<<"$SOUT")" = "1615" ] &&
   [ "$(jq -r '[.intake[]] | index(851) != null' <<<"$SOUT")" = "true" ]; then
  ok "the label set is a generic seam (arbitrary label excludes; retro-pending does not when unset)"
else
  bad "the label set is a generic seam" "out=$SOUT"
fi

# --- 11: exact label match, never substring ---------------------------------
NEAR="$TMP/near.json"
cat >"$NEAR" <<'JSON'
{ "items": [
  { "id": "ISSUE_30", "content": { "number": 30, "title": "Follow-up work named after a tracker" },
    "labels": ["retro-pending-followup"], "status": "Backlog" }
] }
JSON
NOUT="$(run "$NEAR")"
if [ "$(jq -r '.excluded | length' <<<"$NOUT")" = "0" ] &&
   [ "$(jq -r '[.intake[]] | join(",")' <<<"$NOUT")" = "30" ]; then
  ok "a near-miss label (retro-pending-followup) is NOT excluded — equality, not substring"
else
  bad "a near-miss label is NOT excluded" "out=$NOUT"
fi

# --- 12: STATIC GUARD — the spec still invokes this classifier, in order, and
#         still carries the mandatory Step-5 report line ---------------------
# The execution signal for triage.md's "process-record exclusion line is
# mandatory" declaration (claude/CLAUDE.kernel.md § Mandatory-step birth rule;
# registered in workflows/scripts/config/mandatory-step-registry.tsv). /triage
# is AI-executed prose, so no runtime tally inside it can catch the invocation
# quietly disappearing from the spec — a static assertion over the spec text is
# the shape that can. Same guard shape as test_claim_guard.sh case 9, which
# pins /triage Step 4.8a's claim filter the same way.
#
# ANCHOR (mandatory-step-registry.tsv):
#   claude/commands/triage.md Step 1 Adapter A must invoke triage-intake-exclusion.sh before the milestone filter
SPEC="$HERE/../../../../claude/commands/triage.md"
if [ ! -f "$SPEC" ]; then
  bad "static guard: triage.md is readable" "no spec at $SPEC"
else
  spec_txt="$(cat "$SPEC")"
  inv_line="$(grep -n 'triage-intake-exclusion\.sh -' "$SPEC" | head -1 | cut -d: -f1 || true)"
  ms_line="$(grep -n 'Then apply the active-milestone intake filter' "$SPEC" | head -1 | cut -d: -f1 || true)"

  if [ -n "$inv_line" ]; then
    ok "static guard: Adapter A still invokes triage-intake-exclusion.sh"
  else
    bad "static guard: Adapter A still invokes triage-intake-exclusion.sh" "no invocation found in $SPEC"
  fi

  # Ordering is load-bearing, not cosmetic: this filter costs no REST call
  # while the milestone/blocked_by filters cost one PER candidate, and running
  # it first is what puts an excluded tracker on its OWN summary line instead
  # of the inactive-milestone deferred[] line.
  if [ -n "$inv_line" ] && [ -n "$ms_line" ] && [ "$inv_line" -le "$ms_line" ]; then
    ok "static guard: the label exclusion precedes the active-milestone filter"
  else
    bad "static guard: the label exclusion precedes the active-milestone filter" \
        "invocation line=[$inv_line] milestone-filter line=[$ms_line]"
  fi

  case "$spec_txt" in
    *"Excluded at intake (Step 1 — process-record label filter)"*)
      ok "static guard: Step 5 still carries the mandatory exclusion report line" ;;
    *)
      bad "static guard: Step 5 still carries the mandatory exclusion report line" \
          "the summary line is gone from $SPEC" ;;
  esac

  case "$spec_txt" in
    *'$TRIAGE_INTAKE_EXCLUDE_LABELS'*)
      ok "static guard: the spec names the setting symbolically (never a literal label list)" ;;
    *)
      bad "static guard: the spec names the setting symbolically" \
          "no \$TRIAGE_INTAKE_EXCLUDE_LABELS reference in $SPEC" ;;
  esac
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_triage_intake_exclusion: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_triage_intake_exclusion: OK — all %d checks passed\n' "$pass"
