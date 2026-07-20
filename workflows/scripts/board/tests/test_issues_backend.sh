#!/usr/bin/env bash
#
# Fixture-replay tests for board.sh's ISSUES-ONLY tracker backend (foundation
# #799, split 1/3 of the issues-only tracker adapter). See sibling
# workflows/scripts/board/ISSUES-ONLY-BACKEND.md for the full fnd: label
# vocabulary + status-mapping contract this suite pins.
#
# Zero network: we source board.sh, override its `_board_gh` seam to record
# argv (via the shared _fake_gh_log_argv helper) and replay canned JSON, then
# drive the SAME public functions the Projects-v2 suite (test_board_replay.sh)
# exercises — board_resolve / board_resolve_item / board_item_list /
# board_item_id / board_item_title / board_set_status / board_set_component /
# board_create_many / board_capture_item — proving the issues-only backend
# presents an IDENTICAL function-level interface, selected purely by
# boards.conf's `backend` axis.
#
# Coverage:
#   1. board_backend / _board_is_issues_only resolve the new axis.
#   2. Config-selection proof: a board NOT configured for `backend=issues`
#      (board 3, using the SAME fixtures as test_board_replay.sh) still
#      issues the byte-identical Projects-v2 `gh project …` argv — the
#      issues-only seam is additive-only, never a behavior change for an
#      unselected board.
#   3. Issues-only item CRUD + status round-trips through plain labels:
#      board_resolve / board_item_list / board_resolve_item reshape
#      `fnd:status:*` / `fnd:component:*` labels into the SAME item schema
#      the Projects-v2 path produces; board_set_status writes labels +
#      drives open/close for the Done transition (no Projects call ever).
#   4. board_create_many / board_capture_item (item CRUD "create" path) label
#      a freshly-created issue Backlog with no `gh project item-add`.
#   5. Milestone intake (board_active_milestones / board_set_milestone) is
#      unchanged — those functions were already REST-only / backend-agnostic
#      before this split; this suite proves that holds for an issues-only
#      board number too.
#   6. _board_assert_item_id accepts ISSUE_* alongside PVTI_*; board_set_number
#      (Seq — retired by design, ADR 0006) fails loud with a documented stderr
#      message naming the retirement, rather than silently misbehaving.
#      board_stamp (Host/Session) is now implemented by the claim/edges split
#      (foundation #800) — see test_issues_claim_edges.sh for its coverage.
#
# The `_board_gh` overrides are invoked indirectly (the library calls
# _board_gh, which the test redefines), so shellcheck's "never invoked" check
# is a false positive — disabled file-wide, as in test_board_replay.sh.
# shellcheck disable=SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
FIX="$HERE/fixtures"

# shellcheck source=scripts/tests/fixtures/fake_gh.sh
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Isolate the on-disk read cache (irrelevant here — the issues-only path never
# touches it — but keep it out of a real session's /tmp state regardless), and
# disable the pre-flight GraphQL budget guard (test_board_replay.sh does the
# same) so the config-selection proof's call count stays canonical.
export BOARD_CACHE_TTL=0
export BOARD_BUDGET_GUARD_THRESHOLD=0
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/issues-backend-cache-XXXXXX")"
export BOARD_CACHE_DIR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issues-backend-conf-XXXXXX")"
CALLS="$(mktemp "${TMPDIR:-/tmp}/issues-backend-calls-XXXXXX")"
cleanup() { rm -rf "$WORK" "$CALLS" "$BOARD_CACHE_DIR"; }
trap cleanup EXIT

# Board 20 = an issues-only board (generic placeholder org/repo — no personal
# token). Board 3 stays UNCONFIGURED here (no boards.conf entry), so it must
# resolve exactly board.sh's own built-in Projects-v2 fallback (see board_repo
# / board_owner / board_project_number's built-in case maps) — the
# config-selection proof depends on that.
cat > "$WORK/boards.conf" <<'EOF'
board.20.repo=Acme/kernel-test
board.20.backend=issues
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

last_call() { tail -n1 "$CALLS"; }

# --- 1: board_backend / _board_is_issues_only resolve the new axis ---------
[ "$(board_backend 20)" = "issues" ]   || fail "board_backend 20 should be issues"
[ "$(board_backend 3)" = "projects" ]  || fail "board_backend 3 (unconfigured) should default to projects"
_board_is_issues_only 20 || fail "_board_is_issues_only 20 should be true"
if _board_is_issues_only 3; then fail "_board_is_issues_only 3 should be false"; fi
echo "PASS: board_backend resolves the boards.conf backend axis (default: projects)"

# --- 2: config-selection proof — an unconfigured board's Projects-v2 path is
# byte-identical to test_board_replay.sh's pinned argv (same fixtures) -------
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")  cat "$FIX/item_list.json" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# Resolve board 3's built-in owner/project-number DYNAMICALLY (never hardcode
# the org literal here — this file is kernel-classified and must stay free of
# personal/org tokens per workflows/scripts/kernel/personal-token-denylist.tsv;
# board.sh's own built-in case map is the one place that literal is allowed).
B3_OWNER="$(board_owner 3)"; B3_PROJ="$(board_project_number 3)"
: >"$CALLS"
board_resolve 3
[ "$(grep -c '^gh ' "$CALLS")" -eq 3 ] \
  || fail "board_resolve 3 (unselected) should still make exactly 3 Projects-v2 gh calls"
grep -q "gh project view $B3_PROJ --owner $B3_OWNER --format json"                                       "$CALLS" || fail "missing project view call"
grep -q "gh project field-list $B3_PROJ --owner $B3_OWNER --format json"                                 "$CALLS" || fail "missing field-list call"
grep -q "gh project item-list $B3_PROJ --owner $B3_OWNER --limit 500 --query -status:Done --format json" "$CALLS" || fail "missing item-list active-set call"
[ "$BOARD_PROJECT_ID" = "PVT_kwTESTPROJECT123" ] || fail "BOARD_PROJECT_ID wrong: $BOARD_PROJECT_ID"
echo "PASS: an unselected board's gh argv is byte-identical to the pre-#799 Projects-v2 path"

# --- 3: issues-only board_item_list reshapes fnd: labels -------------------
ISSUE_LIST_JSON='[
  {"number":101,"title":"Ready item","labels":[{"name":"fnd:status:ready"},{"name":"spike"}],"milestone":{"title":"Phase 2"}},
  {"number":102,"title":"Unstatused item","labels":[],"milestone":null},
  {"number":103,"title":"In-progress + component","labels":[{"name":"fnd:status:in-progress"},{"name":"fnd:component:ingest"}]}
]'
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "issue list") printf '%s' "$ISSUE_LIST_JSON" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_resolve 20
[ "$(grep -c '^gh ' "$CALLS")" -eq 1 ] || fail "board_resolve 20 (issues-only) should make exactly 1 gh call"
# %q under bash 3.2 (macOS system bash) backslash-escapes the commas in the
# --json value; match loosely on the field LIST rather than pin the escaping.
grep -Eq 'gh issue list -R Acme/kernel-test --state open --limit 500 --json number.?,?title.?,?labels.?,?milestone' "$CALLS" \
  || fail "board_resolve 20 issued the wrong issue-list argv: $(cat "$CALLS")"
grep -q '^gh project' "$CALLS" && fail "board_resolve 20 must NEVER call gh project (no Projects board provisioned)"
[ "$BOARD_PROJECT_ID" = "" ] || fail "BOARD_PROJECT_ID must be empty on the issues-only path, got '$BOARD_PROJECT_ID'"

[ "$(board_item_id 101)" = "ISSUE_101" ]  || fail "item id for #101 wrong: $(board_item_id 101)"
[ "$(board_item_title 101)" = "Ready item" ] || fail "item title for #101 wrong"
STATUS_101="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[] | select(.content.number==101) | .status')"
[ "$STATUS_101" = "Ready" ] || fail "status for #101 wrong: $STATUS_101"
STATUS_102="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[] | select(.content.number==102) | .status // "MISSING"')"
[ "$STATUS_102" = "MISSING" ] || fail "unstatused #102 should carry no .status key, got: $STATUS_102"
STATUS_103="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[] | select(.content.number==103) | .status')"
COMP_103="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[] | select(.content.number==103) | .component')"
[ "$STATUS_103" = "In Progress" ] || fail "status for #103 wrong: $STATUS_103 (fnd:status:in-progress must unslug to 'In Progress')"
[ "$COMP_103" = "Ingest" ] || fail "component for #103 wrong: $COMP_103 (fnd:component:ingest must unslug to 'Ingest')"

# foundation #801 (split 3/3, funnel integration "D3 seam"): the reshape must
# ALSO pass through the raw, UNFILTERED label-name list (fnd:-prefixed ones
# included) — not just the fnd: labels it extracts into status/component. This
# is what lets a caller like funnel-tick.sh see an ordinary work-class label
# (`spike`, `Foundational`, `needs-clarification`, …) on an issues-only board;
# see ISSUES-ONLY-BACKEND.md § Funnel integration and test_board_dual_adapter.sh.
LABELS_101="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -c '.items[] | select(.content.number==101) | .labels')"
[ "$(jq -e 'any(.[]; . == "spike")' <<<"$LABELS_101" >/dev/null 2>&1 && echo yes || echo no)" = "yes" ] \
  || fail "labels for #101 should include the raw 'spike' label, got: $LABELS_101"
[ "$(jq -e 'any(.[]; . == "fnd:status:ready")' <<<"$LABELS_101" >/dev/null 2>&1 && echo yes || echo no)" = "yes" ] \
  || fail "labels for #101 should still include its own fnd:status:ready label (unfiltered passthrough), got: $LABELS_101"
LABELS_102="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -c '.items[] | select(.content.number==102) | .labels')"
[ "$LABELS_102" = "[]" ] || fail "labels for #102 (no labels) should be [], got: $LABELS_102"
echo "PASS: issue_item's reshape passes through the raw, unfiltered label-name list (foundation #801)"

# temperloop#154: the reshape must ALSO carry the release-phase milestone, or
# board_item_milestone returns empty on this backend and /triage's active-milestone
# intake filter silently mis-intakes a Backlog item on an inactive milestone. A
# milestoned issue's title must round-trip; an unmilestoned one reads empty.
[ "$(board_item_milestone 101)" = "Phase 2" ] \
  || fail "board_item_milestone (issues-only) should read #101's milestone 'Phase 2', got: '$(board_item_milestone 101)'"
[ "$(board_item_milestone 102)" = "" ] \
  || fail "board_item_milestone (issues-only) should be empty for unmilestoned #102, got: '$(board_item_milestone 102)'"
MS_102_KEY="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[] | select(.content.number==102) | has("milestone")')"
[ "$MS_102_KEY" = "false" ] || fail "unmilestoned #102 should carry no .milestone key (optional-field style), got has()=$MS_102_KEY"
echo "PASS: issue_item's reshape carries the milestone title; board_item_milestone round-trips it (temperloop#154)"
echo "PASS: board_resolve/board_item_list (issues-only) reshapes fnd: labels into the shared item schema, zero gh project calls"

# --- 4: board_resolve_item (issues-only) is always-live and sees closed=Done ---
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/issues/104")
      echo '{"number":104,"title":"Closed item","state":"closed","labels":[]}' ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_resolve_item 20 104
[ "$(grep -c '^gh ' "$CALLS")" -eq 1 ] || fail "board_resolve_item 20 should make exactly 1 gh call"
grep -q 'gh api repos/Acme/kernel-test/issues/104' "$CALLS" || fail "board_resolve_item 20 wrong argv: $(cat "$CALLS")"
STATUS_104="$(printf '%s' "$BOARD_ITEMS_JSON" | jq -r '.items[0].status')"
[ "$STATUS_104" = "Done" ] || fail "a CLOSED issue must always read status Done regardless of labels, got: $STATUS_104"
echo "PASS: board_resolve_item (issues-only) is always-live; a closed issue reads status Done with no label needed"

# --- 5: _board_assert_item_id accepts ISSUE_* alongside PVTI_* -------------
_board_assert_item_id "ISSUE_104" test || fail "_board_assert_item_id should accept ISSUE_*"
if _board_assert_item_id "104" test 2>/dev/null; then fail "_board_assert_item_id should still reject a bare issue#"; fi
echo "PASS: _board_assert_item_id accepts ISSUE_* (issues-only) alongside PVTI_* (Projects-v2)"

# --- 6: board_set_status (issues-only) write path — status transitions -----
# Stateful fake: tracks one issue's open/closed state + fnd: labels across a
# sequence of board_set_status calls, mirroring what a real repo would do.
FAKE_STATE="open"
FAKE_LABELS="fnd:status:backlog"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/issues/105")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":105,"title":"t","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --remove-label) FAKE_LABELS="$(printf '%s\n' $FAKE_LABELS | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label)    FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "issue close")  FAKE_STATE="closed" ;;
    "issue reopen") FAKE_STATE="open" ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
BOARD_CURRENT=20

: >"$CALLS"
board_set_status "ISSUE_105" "In Progress" || fail "board_set_status In Progress should succeed"
grep -q '^gh project' "$CALLS" && fail "board_set_status (issues-only) must NEVER call gh project"
grep -q -- '--remove-label fnd:status:backlog' "$CALLS" || fail "expected the stale Backlog label removed"
grep -q -- '--add-label fnd:status:in-progress' "$CALLS" || fail "expected the In Progress label added"
[ "$FAKE_LABELS" = " fnd:status:in-progress" ] || fail "label state wrong after In Progress: '$FAKE_LABELS'"
[ "$FAKE_STATE" = "open" ] || fail "issue should stay open on a non-Done status"
echo "PASS: board_set_status (issues-only) swaps the fnd:status:* label, no Projects call"

: >"$CALLS"
board_set_status "ISSUE_105" "Done" || fail "board_set_status Done should succeed"
grep -q -- '--remove-label fnd:status:in-progress' "$CALLS" || fail "Done must strip the residual status label"
grep -q -- '--add-label' "$CALLS" && fail "Done must NOT add any fnd:status:* label (closed IS the Done signal)"
grep -q '^gh issue close 105' "$CALLS" || fail "Done must close the issue"
[ "$FAKE_STATE" = "closed" ] || fail "issue should be closed after Done"
[ "$FAKE_LABELS" = "" ] || fail "no fnd:status:* label should remain after Done, got: '$FAKE_LABELS'"
echo "PASS: board_set_status Done closes the issue and carries no label (contract: Done = closed)"

: >"$CALLS"
board_set_status "ISSUE_105" "Ready" || fail "board_set_status Ready (from Done) should succeed"
grep -q -- '--add-label fnd:status:ready' "$CALLS" || fail "expected the Ready label added"
grep -q '^gh issue reopen 105' "$CALLS" || fail "moving off Done must reopen the issue"
[ "$FAKE_STATE" = "open" ] || fail "issue should be reopened"
[ "$FAKE_LABELS" = " fnd:status:ready" ] || fail "label state wrong after reopen-to-Ready: '$FAKE_LABELS'"
echo "PASS: board_set_status off Done reopens the issue and relabels it"

# Idempotent-ish: setting the SAME status again should not error and should
# not leave a duplicate label (remove-then-add still yields exactly one).
: >"$CALLS"
board_set_status "ISSUE_105" "Ready" || fail "re-setting the same status should still succeed"
[ "$FAKE_LABELS" = " fnd:status:ready" ] || fail "re-setting the same status must not duplicate the label: '$FAKE_LABELS'"
echo "PASS: re-setting the same status is stable (no duplicate label)"

# --- 7: board_set_component (issues-only) — thin wrapper, fnd:component:* --
FAKE_LABELS="fnd:status:ready"
: >"$CALLS"
board_set_component "ISSUE_105" "Ingest" || fail "board_set_component should succeed"
grep -q -- '--add-label fnd:component:ingest' "$CALLS" || fail "expected the Component label added"
grep -q '^gh issue close\|^gh issue reopen' "$CALLS" && fail "Component writes must never touch open/closed state"
echo "PASS: board_set_component (issues-only) writes fnd:component:* without touching issue state"

# --- 8: board_create_many / board_capture_item (issues-only "create") ------
# No Projects board exists, so "landing" a freshly-created issue collapses to
# labeling it Backlog — no item-add, no index-lag retry.
FAKE_STATE="open"
FAKE_LABELS=""
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/issues/106")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":106,"title":"fresh","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --add-label) FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_create_many 20 "https://example.test/issues/106" 106
grep -q '^gh project item-add' "$CALLS" && fail "issues-only board_create_many must never item-add to a Projects board"
grep -q -- '--add-label fnd:status:backlog' "$CALLS" || fail "expected the new issue labeled Backlog"
[ "$FAKE_LABELS" = " fnd:status:backlog" ] || fail "label state wrong after create: '$FAKE_LABELS'"
echo "PASS: board_create_many (issues-only) labels a freshly-created issue Backlog, no Projects item-add"

# board_capture_item reuses board_resolve_item + board_item_id + board_set_status
# unchanged (no issues-only-specific code needed there — same interface holds).
FAKE_STATE="open"
FAKE_LABELS=""
: >"$CALLS"
board_capture_item 20 "https://example.test/issues/106" 106
grep -q -- '--add-label fnd:status:backlog' "$CALLS" || fail "board_capture_item should land a fresh issue in Backlog"
echo "PASS: board_capture_item (issues-only) lands a fresh issue in Backlog via the same public functions"

# --- 9: milestone intake is unchanged (already backend-agnostic pre-#799) ---
MILESTONES_JSON='[{"title":"Phase 1","number":5,"description":"<!-- triage:active -->"},{"title":"Phase 2","number":6,"description":""}]'
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/milestones?state=open") printf '%s' "$MILESTONES_JSON" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
ACTIVE="$(board_active_milestones 20)"
[ "$ACTIVE" = "Phase 1" ] || fail "board_active_milestones (issues-only board) wrong: $ACTIVE"
grep -q '^gh project' "$CALLS" && fail "milestone intake must never touch Projects-v2"
echo "PASS: board_active_milestones works unchanged against an issues-only board (REST-only, always was)"

_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "issue edit") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_set_milestone 20 106 "Phase 2"
grep -q 'gh issue edit 106 -R Acme/kernel-test --milestone Phase' "$CALLS" \
  || fail "board_set_milestone (issues-only board) wrong argv: $(cat "$CALLS")"
echo "PASS: board_set_milestone works unchanged against an issues-only board"

# --- 10: board_set_number fails LOUD with a documented retirement message ---
# Seq is RETIRED BY DESIGN on the issues-only backend (ADR 0006), not emulated:
# an issues-only board has no Projects field schema for it, so it must refuse
# (return 1) with an explicit stderr message naming the retirement and its
# replacement signal (epic dependency levels + milestones) — never silently
# no-op or crash. board_stamp on ISSUE_* is IMPLEMENTED by the claim/edges
# split (foundation #800) — see test_issues_claim_edges.sh for its full
# coverage (write/clear/round-trip); this file just pins that board_set_number
# refuses loudly here.
SET_NUMBER_ERR="$(board_set_number "ISSUE_106" "Seq" 3 2>&1 1>/dev/null)" && \
  fail "board_set_number must fail loud on an issues-only board (Seq retired by design)"
case "$SET_NUMBER_ERR" in
  *"retired by design"*"issues-only"*"dependency levels and milestones"*) : ;;
  *) fail "board_set_number stderr should name the ADR-0004 retirement (dependency levels + milestones), got: $SET_NUMBER_ERR" ;;
esac
echo "PASS: board_set_number fails loud on an issues-only board with a documented 'Seq retired by design' stderr message — board_stamp is now implemented (see test_issues_claim_edges.sh)"

# --- 11: a --remove-label failure is NOT swallowed (temperloop#601) ---------
# Regression: _board_issues_set_field used `--remove-label … || true`, so a
# throttled/transient removal that left the OLD fnd:status:* label behind still
# returned 0 — the item ended up carrying DUAL fnd:status:* labels (e.g.
# backlog + ready) while board_set_status reported a clean flip. The fix retries
# the removal once and, on a persistent failure, returns non-zero so the
# caller's exit code reflects the half-failed flip.

# 11a — a PERSISTENT --remove-label failure surfaces as a non-zero return.
FAKE_STATE="open"
FAKE_LABELS="fnd:status:backlog"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/issues/105")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":105,"title":"t","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --remove-label) return 1 ;;                # every removal fails
          --add-label)    FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
if board_set_status "ISSUE_105" "Ready" 2>/dev/null; then
  fail "board_set_status must return non-zero when a stale fnd:status:* removal persistently fails (temperloop#601 — no swallowed dual-label flip)"
fi
[ "$(grep -c -- '--remove-label fnd:status:backlog' "$CALLS")" -ge 2 ] \
  || fail "expected the failing --remove-label to be retried at least once before surfacing the failure"
echo "PASS: board_set_status surfaces a persistent --remove-label failure (no swallowed dual-label flip)"

# 11b — a SINGLE transient --remove-label failure is absorbed by the retry, so
# the write still succeeds and the item is left with exactly one fnd:status:*.
FAKE_STATE="open"
FAKE_LABELS="fnd:status:backlog"
REMOVE_FAILS_LEFT=1
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Acme/kernel-test/issues/105")
      local ljson='[]'
      if [ -n "$FAKE_LABELS" ]; then
        ljson="$(printf '%s\n' $FAKE_LABELS | jq -R . | jq -s 'map({name:.})')"
      fi
      printf '{"number":105,"title":"t","state":"%s","labels":%s}' "$FAKE_STATE" "$ljson"
      ;;
    "issue edit")
      shift 2
      local prev="" a
      for a in "$@"; do
        case "$prev" in
          --remove-label)
            if [ "$REMOVE_FAILS_LEFT" -gt 0 ]; then
              REMOVE_FAILS_LEFT=$((REMOVE_FAILS_LEFT - 1)); return 1
            fi
            FAKE_LABELS="$(printf '%s\n' $FAKE_LABELS | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label) FAKE_LABELS="$FAKE_LABELS $a" ;;
        esac
        prev="$a"
      done
      ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_set_status "ISSUE_105" "Ready" || fail "a single transient --remove-label failure should be absorbed by the retry and still succeed"
[ "$FAKE_LABELS" = " fnd:status:ready" ] || fail "after a retry-absorbed removal the item must carry exactly one fnd:status:* label, got: '$FAKE_LABELS'"
echo "PASS: board_set_status retries a transient --remove-label failure and yields a single fnd:status:* label"

echo
echo "ALL PASS: test_issues_backend.sh"
