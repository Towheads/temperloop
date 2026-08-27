#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-epic-closing-gate.sh — the
# deterministic /sweep end-of-run epic-closing gate verdict combinator
# (epic #1847, item "epic-closing-gate").
#
# Entirely OFFLINE: synthetic epic JSON fixtures on disk, zero `gh` calls,
# zero board reads (mirrors test_sweep_epic_admission.sh's convention).
#
# Covers every branch of the precedence independently, plus the precedence
# order between them:
#   1. total_members == 0 -> no-members, regardless of every other field.
#   2. member_reads_available=false -> cannot-establish (member-reads-
#      unavailable), even with a fully-drained member set and every other
#      field favorable — an error is never the permissive branch.
#   2b. member_reads_available OMITTED -> cannot-establish, same as above —
#      the field's own default is refusing, never a permissive guess.
#   3. labels_read_available=false -> cannot-establish (labels-unavailable),
#      checked only once member reads are available.
#   4. keep_open_label_present=true -> keep-open, even on a fully-drained
#      member set (checked BEFORE the drain computation, never silently
#      routed to offer-close).
#   4b. keep_open_label_present OMITTED -> keep-open (default is "assume
#      present", never a permissive guess toward closing).
#   5. fully drained + attended=true -> offer-close.
#   5b. fully drained + attended=false -> left-open-unattended.
#   5c. fully drained + attended OMITTED -> left-open-unattended (the more
#      conservative default).
#   6. partially drained (some but not all members closed) -> progress,
#      with open_members naming exactly the still-open issues.
#   7. zero members closed -> no-progress.
#   8. precedence proof: cannot-establish wins over keep-open and over a
#      fully-drained member set simultaneously.
#   9. --help / -h / no-args activation proof.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-epic-closing-gate.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-epic-closing-gate.sh not found/executable at $CLI" >&2; exit 1; }

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

check_field_compact() { # <desc> <fixture-json> <jq-field> <want> — for array/object fields
  local desc="$1" file="$2" field="$3" want="$4"
  local out got
  out="$(bash "$CLI" "$file")"
  got="$(jq -c "$field" <<<"$out")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "want [$want], got [$got] (full: $out)"
  fi
}

FULLY_DRAINED_MEMBERS='[{"issue":101,"state":"closed"},{"issue":102,"state":"closed"}]'
PARTIAL_MEMBERS='[{"issue":101,"state":"closed"},{"issue":102,"state":"open"},{"issue":103,"state":"open"}]'
NONE_CLOSED_MEMBERS='[{"issue":101,"state":"open"},{"issue":102,"state":"open"}]'

# The fully favorable-to-offer-close baseline every other case flips exactly
# one field away from.
BASE_OFFER='{"epic":900,"member_reads_available":true,"labels_read_available":true,"keep_open_label_present":false,"attended":true,"members":'"$FULLY_DRAINED_MEMBERS"'}'

# ── 1: no members ─────────────────────────────────────────────────────────
echo "--- 1: total_members=0 -> no-members regardless of every other field ---"
NOMEMBERS="$TMP/no-members.json"
jq -n --argjson base "$BASE_OFFER" '$base + {members: []}' > "$NOMEMBERS"
check_field "empty member set -> verdict=no-members" "$NOMEMBERS" '.verdict' "no-members"
check_field "...reason=no-members" "$NOMEMBERS" '.reason' "no-members"
check_field "...total_members=0" "$NOMEMBERS" '.total_members' "0"

# ── 2: member reads unavailable — an error is never the permissive branch ──
echo "--- 2: member_reads_available=false -> cannot-establish (member-reads-unavailable), even on a fully-drained set ---"
NOMEMBERREAD="$TMP/no-member-read.json"
jq -n --argjson base "$BASE_OFFER" '$base + {member_reads_available: false}' > "$NOMEMBERREAD"
check_field "member reads unavailable -> verdict=cannot-establish" "$NOMEMBERREAD" '.verdict' "cannot-establish"
check_field "...reason=member-reads-unavailable" "$NOMEMBERREAD" '.reason' "member-reads-unavailable"

echo "--- 2b: member_reads_available OMITTED -> cannot-establish (default is refusing) ---"
NOMEMBERREADFIELD="$TMP/no-member-read-field.json"
jq -n --argjson base "$BASE_OFFER" '$base | del(.member_reads_available)' > "$NOMEMBERREADFIELD"
check_field "member_reads_available omitted -> verdict=cannot-establish" "$NOMEMBERREADFIELD" '.verdict' "cannot-establish"
check_field "...reason=member-reads-unavailable" "$NOMEMBERREADFIELD" '.reason' "member-reads-unavailable"

# ── 3: labels unavailable ────────────────────────────────────────────────
echo "--- 3: labels_read_available=false -> cannot-establish (labels-unavailable), member reads ARE available ---"
NOLABELREAD="$TMP/no-label-read.json"
jq -n --argjson base "$BASE_OFFER" '$base + {labels_read_available: false}' > "$NOLABELREAD"
check_field "labels unavailable -> verdict=cannot-establish" "$NOLABELREAD" '.verdict' "cannot-establish"
check_field "...reason=labels-unavailable" "$NOLABELREAD" '.reason' "labels-unavailable"

# ── 4: keep-open label wins over a fully-drained member set ─────────────
echo "--- 4: keep_open_label_present=true -> keep-open, even fully drained ---"
KEEPOPEN="$TMP/keep-open.json"
jq -n --argjson base "$BASE_OFFER" '$base + {keep_open_label_present: true}' > "$KEEPOPEN"
check_field "keep-open label present -> verdict=keep-open" "$KEEPOPEN" '.verdict' "keep-open"
check_field "...reason=keep-open-label" "$KEEPOPEN" '.reason' "keep-open-label"
check_field "...fully_drained still reported true (informational)" "$KEEPOPEN" '.fully_drained' "true"

echo "--- 4b: keep_open_label_present OMITTED -> keep-open (default is 'assume present', never a permissive guess) ---"
NOKEEPOPENFIELD="$TMP/no-keep-open-field.json"
jq -n --argjson base "$BASE_OFFER" '$base | del(.keep_open_label_present)' > "$NOKEEPOPENFIELD"
check_field "keep_open_label_present omitted -> verdict=keep-open" "$NOKEEPOPENFIELD" '.verdict' "keep-open"

# ── 5: fully drained, attended vs unattended ─────────────────────────────
echo "--- 5a: fully drained + attended=true -> offer-close ---"
OFFERCLOSE="$TMP/offer-close.json"
printf '%s' "$BASE_OFFER" > "$OFFERCLOSE"
check_field "fully drained, attended -> verdict=offer-close" "$OFFERCLOSE" '.verdict' "offer-close"
check_field "...reason=fully-drained" "$OFFERCLOSE" '.reason' "fully-drained"
check_field "...fully_drained=true" "$OFFERCLOSE" '.fully_drained' "true"

echo "--- 5b: fully drained + attended=false -> left-open-unattended ---"
LEFTOPEN="$TMP/left-open.json"
jq -n --argjson base "$BASE_OFFER" '$base + {attended: false}' > "$LEFTOPEN"
check_field "fully drained, unattended -> verdict=left-open-unattended" "$LEFTOPEN" '.verdict' "left-open-unattended"
check_field "...reason=fully-drained-unattended" "$LEFTOPEN" '.reason' "fully-drained-unattended"

echo "--- 5c: attended OMITTED -> left-open-unattended (the more conservative default) ---"
NOATTENDEDFIELD="$TMP/no-attended-field.json"
jq -n --argjson base "$BASE_OFFER" '$base | del(.attended)' > "$NOATTENDEDFIELD"
check_field "attended omitted -> verdict=left-open-unattended" "$NOATTENDEDFIELD" '.verdict' "left-open-unattended"

# ── 6: partially drained ─────────────────────────────────────────────────
echo "--- 6: some but not all members closed -> progress, open_members names the rest ---"
PARTIAL="$TMP/partial.json"
jq -n --argjson base "$BASE_OFFER" '$base + {members: '"$PARTIAL_MEMBERS"'}' > "$PARTIAL"
check_field "partial drain -> verdict=progress" "$PARTIAL" '.verdict' "progress"
check_field "...reason=partially-drained" "$PARTIAL" '.reason' "partially-drained"
check_field "...closed_members=1" "$PARTIAL" '.closed_members' "1"
check_field "...total_members=3" "$PARTIAL" '.total_members' "3"
check_field_compact "...open_members=[102,103]" "$PARTIAL" '.open_members' "[102,103]"

# ── 7: nothing closed ────────────────────────────────────────────────────
echo "--- 7: zero members closed -> no-progress ---"
NOPROGRESS="$TMP/no-progress.json"
jq -n --argjson base "$BASE_OFFER" '$base + {members: '"$NONE_CLOSED_MEMBERS"'}' > "$NOPROGRESS"
check_field "zero closed -> verdict=no-progress" "$NOPROGRESS" '.verdict' "no-progress"
check_field "...reason=no-progress-this-run" "$NOPROGRESS" '.reason' "no-progress-this-run"

# ── 8: precedence proof ──────────────────────────────────────────────────
echo "--- 8: cannot-establish (member-reads-unavailable) wins over keep-open AND a fully-drained set, simultaneously ---"
ALLBAD="$TMP/all-bad.json"
jq -n '{epic:901, member_reads_available:false, labels_read_available:false, keep_open_label_present:true, attended:true, members:'"$FULLY_DRAINED_MEMBERS"'}' > "$ALLBAD"
check_field "everything else favorable to a different branch -> reason=member-reads-unavailable (checked first)" "$ALLBAD" '.reason' "member-reads-unavailable"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_epic_closing_gate: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_epic_closing_gate: OK — all %d checks passed\n' "$pass"
