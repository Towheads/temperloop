#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-answered-exclusion.sh — the
# deterministic half of /sweep Step 2's "answered, not underspecified"
# comment-anchored exclusion rule (temperloop#1193, item
# sweep-detects-answered-questions).
#
# Entirely OFFLINE: synthetic issue JSON fixtures on disk, zero `gh` calls,
# zero board reads (mirrors test_issue_state_resolve.sh's --dry-run --fixture
# convention, minus the fixture-directory harness since this script takes a
# single JSON file directly).
#
# Covers:
#   1. label-carrier arm, fixture WITH a later Clarified comment ->
#      answered, no open question, no comment would be composed.
#   2. THE SAME FIXTURE with the answer comment removed -> still
#      underspecified (the label-carrier arm's baseline).
#   3. the `Parked by sweep — ` escalation-park wording is also a
#      recognised flagging-type anchor, and a later Clarified comment
#      excludes it too (an issue parked by escalation and later answered
#      must not be re-asked).
#   4. self-judged-underspecified arm (no label), WITH a later Clarified
#      comment -> answered, excluded.
#   5. THE SAME self-judged fixture with the answer comment removed ->
#      still underspecified, and a needs-clarification comment WOULD be
#      composed (the self-judged arm's own posting step).
#   6. recency matters, not mere presence: a Clarified comment OLDER than
#      the most recent flagging comment (re-flagged after being answered)
#      must NOT exclude the issue.
#   7. a clean issue (no label, not self-judged underspecified, no
#      comments) carries no open question and needs no exclusion.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-answered-exclusion.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-answered-exclusion.sh not found/executable at $CLI" >&2; exit 1; }

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

# ── 1+2: label-carrier arm, both directions ─────────────────────────────
echo "--- 1+2: label-carrier arm — with and without the later Clarified answer ---"
WITH="$TMP/carrier-answered.json"
cat > "$WITH" <<'JSON'
{
  "labels": [{"name": "needs-clarification"}],
  "comments": [
    {"createdAt": "2026-07-01T00:00:00Z", "body": "needs-clarification: Should this use approach A or B? The issue body poses an open fork between two designs."},
    {"createdAt": "2026-07-05T09:00:00Z", "body": "Clarified (triage): Use approach A."}
  ]
}
JSON
check_field "carrier arm, later Clarified present -> has_open_question=false" "$WITH" '.has_open_question' "false"
check_field "carrier arm, later Clarified present -> reason=answered" "$WITH" '.reason' "answered"
check_field "carrier arm, later Clarified present -> no comment composed" "$WITH" '.would_post_needs_clarification_comment' "false"

WITHOUT="$TMP/carrier-unanswered.json"
jq 'del(.comments[1])' "$WITH" > "$WITHOUT"
check_field "same fixture, answer comment removed -> has_open_question=true" "$WITHOUT" '.has_open_question' "true"
check_field "same fixture, answer comment removed -> reason=underspecified" "$WITHOUT" '.reason' "underspecified"

# ── 3: the Parked-by-sweep escalation-park wording ──────────────────────
echo "--- 3: the escalation-park 'Parked by sweep — ' anchor is honored too ---"
PARKED="$TMP/parked-answered.json"
cat > "$PARKED" <<'JSON'
{
  "labels": [{"name": "needs-clarification"}],
  "comments": [
    {"createdAt": "2026-07-01T00:00:00Z", "body": "Parked by sweep — Which retry policy should the worker use, exponential or fixed backoff? Where it stands: worker escalated a design fork."},
    {"createdAt": "2026-07-06T00:00:00Z", "body": "Clarified (sweep): Use exponential backoff."}
  ]
}
JSON
check_field "escalation-park + later Clarified -> answered" "$PARKED" '.reason' "answered"
check_field "escalation-park + later Clarified -> no open question" "$PARKED" '.has_open_question' "false"

# ── 4+5: self-judged-underspecified arm, both directions ────────────────
echo "--- 4+5: self-judged-underspecified arm — with and without the later Clarified answer ---"
SELF_WITH="$TMP/self-answered.json"
cat > "$SELF_WITH" <<'JSON'
{
  "labels": [],
  "self_judged_underspecified": true,
  "comments": [
    {"createdAt": "2026-08-01T00:00:00Z", "body": "Clarified (sweep): Ship the synchronous path only; the async variant is out of scope."}
  ]
}
JSON
check_field "self-judged arm, Clarified present, no prior flag -> answered" "$SELF_WITH" '.reason' "answered"
check_field "self-judged arm, Clarified present -> no open question" "$SELF_WITH" '.has_open_question' "false"
check_field "self-judged arm, Clarified present -> no comment composed" "$SELF_WITH" '.would_post_needs_clarification_comment' "false"

SELF_WITHOUT="$TMP/self-unanswered.json"
jq 'del(.comments[0])' "$SELF_WITH" > "$SELF_WITHOUT"
check_field "same self-judged fixture, answer comment removed -> still underspecified" "$SELF_WITHOUT" '.reason' "underspecified"
check_field "...has_open_question=true" "$SELF_WITHOUT" '.has_open_question' "true"
check_field "...and a needs-clarification comment WOULD be composed" "$SELF_WITHOUT" '.would_post_needs_clarification_comment' "true"

# ── 6: recency, not mere presence ────────────────────────────────────────
echo "--- 6: a STALE Clarified comment (older than a later re-flag) does not exclude ---"
STALE="$TMP/stale-answer-reflagged.json"
cat > "$STALE" <<'JSON'
{
  "labels": [{"name": "needs-clarification"}],
  "comments": [
    {"createdAt": "2026-06-01T00:00:00Z", "body": "Clarified (triage): Use approach A."},
    {"createdAt": "2026-06-15T00:00:00Z", "body": "needs-clarification: Approach A regressed a downstream consumer — reconsider the choice?"}
  ]
}
JSON
check_field "Clarified predates the newer flag -> still underspecified" "$STALE" '.reason' "underspecified"
check_field "...has_open_question=true" "$STALE" '.has_open_question' "true"

# ── 7: a clean issue ──────────────────────────────────────────────────────
echo "--- 7: a clean issue (no label, not self-judged, no comments) ---"
CLEAN="$TMP/clean.json"
cat > "$CLEAN" <<'JSON'
{"labels": [], "comments": []}
JSON
check_field "clean issue -> reason=clean" "$CLEAN" '.reason' "clean"
check_field "clean issue -> has_open_question=false" "$CLEAN" '.has_open_question' "false"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_answered_exclusion: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_answered_exclusion: OK — all %d checks passed\n' "$pass"
