#!/usr/bin/env bash
#
# Fixture-replay tests for reconcile.sh's Lens 2 (--status) CLOSED-ISSUE TAIL
# (temperloop#1410) — the drift the status lens was structurally blind to on the
# issues-only backend.
#
# The blindness: on that backend the board item IS the issue, and the whole-board
# read (`_board_issues_item_list`) is the OPEN issue set — "Done" is the issue
# being CLOSED, not a label. So an issue that was closed behind the adapter's
# back (a merged PR's bare `Closes #N`) while still wearing `fnd:status:in-progress`
# and a `fnd:host/session:*` claim stamp is ABSENT from `board_item_list`
# entirely. Every Lens 2 class started from a board item, so the lens saw nothing
# and printed "In sync" over real drift. Observed three times in one session
# (foundation #1392, #1393, and the epic #1324 run).
#
# Covered:
#   1) issues-only, drift  — a closed issue carrying BOTH a residual
#      `fnd:status:*` label and a stranded `fnd:host/session:*` stamp is reported
#      under both new sections; "In sync" must NOT print; a clean closed issue
#      (non-fnd: labels only) is not flagged; and even with FIX=1 nothing is
#      written (the repair lives once, in Lens 3 --labels --apply).
#   2) issues-only, clean  — no closed issue carries an fnd: label → "In sync",
#      and neither new section prints (no false positives).
#   3) issues-only, stamp only — a closed issue wearing ONLY the claim stamp is
#      still flagged, and BOTH lenses agree on it: --status's new class (l) and
#      --labels' pre-existing class (j) name the same issue from the same data.
#   4) Projects-v2 UNREGRESSED — the same closed+labeled issue in the issue-state
#      read produces NEITHER new section on a `backend=projects` board, the
#      pre-existing terminal-but-not-Done class still fires, and the issue-state
#      read's `--json` argv is byte-identical to what it was before this change.
#
# Zero network: reconcile.sh is SOURCED (its execute-guard suppresses the
# auto-run) and its `_board_gh` / `_reconcile_session_live` / `_reconcile_now`
# seams are overridden, exactly like test_reconcile.sh and
# test_reconcile_labels.sh do.
#
# FIX / LABELS_APPLY are read by the sourced reconcile.sh, not in this file —
# shellcheck can't see that cross-file use, so silence SC2034 file-wide (the
# directive must precede the first command). CI excludes tests/ anyway.
# shellcheck disable=SC2034

# Pin BOTH boards.conf discovery paths to nonexistent files (same convention as
# test_reconcile_labels.sh / test_boards_conf.sh) so board 7 resolves to the
# built-in "issues" backend and board 3 to the built-in "projects" default,
# regardless of what machine this runs on — a host whose machine-level conf
# flips board 3 to issues must not change what these cases prove.
export BOARDS_CONF_MACHINE="/no-such-machine-conf-$$"
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Deterministic host regardless of the runner's hostname (claim-stamp comparison).
export SUBSET_HOST_LABEL="testhost"

# Isolated cache dir — never the real TMPDIR/BOARD_CACHE_DIR (mirrors the
# isolation rationale in test_reconcile.sh).
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-status-io-test-XXXXXX")"
export BOARD_CACHE_DIR
TEST_TMP_DIRS=("$BOARD_CACHE_DIR")
cleanup() { rm -rf "${TEST_TMP_DIRS[@]}"; }
trap cleanup EXIT

# shellcheck source=scripts/reconcile.sh
source "$SCRIPTS_DIR/reconcile.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# --- fixtures ------------------------------------------------------------
# ALL_ISSUES_JSON is the SINGLE source of truth for issue state in these cases:
# the `issue list --state all` read Lens 2 makes, the `--state open` whole-board
# read board_resolve makes on the issues-only backend, the `--state closed` read
# Lens 3 makes, and the per-issue `api` re-check are ALL derived from it by jq.
# That is deliberate — case 3's cross-lens agreement assertion is only meaningful
# if both lenses are reading the same underlying repo state.
ALL_ISSUES_JSON='[]'
PR_LIST_JSON='[]'
LABEL_LIST_JSON='[]'
OPEN_ATTACHED_LABELS=""
# Projects-v2 fixtures (case 4 only).
ITEM_LIST_JSON='{"items":[]}'
FIELD_LIST_JSON='{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_inprogress","name":"In Progress"},{"id":"opt_ready","name":"Ready"},{"id":"opt_done","name":"Done"}]},{"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"}]}'
# Write/argv logs — files, not shell variables: _board_gh runs inside a
# command-substitution subshell (its stdout is captured), so a variable
# increment would be lost at the subshell boundary.
WRITES="/dev/null"        # every mutating gh call this run made
STATE_READ_JSON="/dev/null"  # the --json field list of each `issue list --state all`

_issues_where() { printf '%s' "$ALL_ISSUES_JSON" | jq -c --arg s "$1" '[ .[] | select(((.state // "open") | ascii_downcase) == $s) ]'; }

_board_gh() {
  case "$1 $2" in
    "project view")       echo '{"id":"PVT_TESTPROJECT"}' ;;
    "project field-list") printf '%s' "$FIELD_LIST_JSON" ;;
    "project item-list")  printf '%s' "$ITEM_LIST_JSON" ;;
    "project item-edit")  printf 'project item-edit %s\n' "$*" >>"$WRITES"; return 0 ;;
    "pr list")            printf '%s' "$PR_LIST_JSON" ;;
    "label list")         printf '%s' "$LABEL_LIST_JSON" ;;
    "label create")       return 0 ;;
    "label delete")       printf 'label delete %s\n' "$3" >>"$WRITES"; return 0 ;;
    "issue edit")         printf 'issue edit %s\n' "$*" >>"$WRITES"; return 0 ;;
    "issue list")
      local a want="" state="" lbl="" jsonfields=""
      for a in "$@"; do
        case "$want" in
          state)  state="$a"; want="" ; continue ;;
          label)  lbl="$a";   want="" ; continue ;;
          json)   jsonfields="$a"; want="" ; continue ;;
        esac
        case "$a" in
          --state) want=state ;;
          --label) want=label ;;
          --json)  want=json ;;
        esac
      done
      if [ -n "$lbl" ]; then
        # Lens 3's per-label orphan probe (`--label X --state open --limit 1`).
        case " $OPEN_ATTACHED_LABELS " in
          *" $lbl "*) echo '[{"number":100}]' ;;
          *)          echo '[]' ;;
        esac
        return 0
      fi
      case "$state" in
        all)
          # Lens 2's issue-state read. Record its --json argv so case 4 can prove
          # the Projects-v2 request shape is byte-identical to pre-#1410.
          printf '%s\n' "$jsonfields" >>"$STATE_READ_JSON"
          printf '%s' "$ALL_ISSUES_JSON" ;;
        closed) _issues_where closed ;;
        *)      _issues_where open ;;
      esac
      ;;
    *)
      case "$1" in
        api)
          local n="${2##*/}"
          printf '%s' "$ALL_ISSUES_JSON" | jq -c --argjson n "$n" \
            'map(select(.number == $n))[0] // {"state":"open","labels":[]}' ;;
        *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
      esac
      ;;
  esac
}

# Deterministic seams: every session is live (no stale-claim noise in these
# cases) and "now" is pinned so the foreign-claim age math never varies.
_reconcile_session_live() { return 0; }
_reconcile_now() { echo 1780790400; }   # 2026-06-07T00:00:00Z

run_status() {
  WRITES="$(mktemp)"; STATE_READ_JSON="$(mktemp)"
  TEST_TMP_DIRS+=("$WRITES" "$STATE_READ_JSON")
  OUT="$(status_reconcile_main)"
}
run_labels() {
  WRITES="$(mktemp)"; TEST_TMP_DIRS+=("$WRITES")
  OUT="$(label_reconcile_main)"
}

STATUS_LABEL="fnd:status:in-progress"
STAMP_LABEL="fnd:host/session:mini:65f6ecd5"

# =========================================================================
# Case 1: issues-only — a closed issue still wearing a status label AND a
# claim stamp is DRIFT, not "In sync". This is the #1410 regression guard.
# =========================================================================
PROJECT_NUMBER=7
ALL_ISSUES_JSON='[
  {"number":10,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"Live ready item","labels":[{"name":"fnd:status:ready"}]},
  {"number":900,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Merged via bare Closes #N","labels":[{"name":"'"$STATUS_LABEL"'"},{"name":"'"$STAMP_LABEL"'"},{"name":"bug"}]},
  {"number":901,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Cleanly closed","labels":[{"name":"bug"}]}
]'
PR_LIST_JSON='[]'
FIX=1   # even with --fix, both new classes are report-only
run_status
FIX=0

printf '%s' "$OUT" | grep -q "In sync" \
  && fail "case1: the lens must NOT report 'In sync' with a closed+labeled issue present\n$OUT"
printf '%s' "$OUT" | grep -q "residual status labels on closed issues" \
  || fail "case1: expected the residual-status section\n$OUT"
printf '%s' "$OUT" | grep -qF "#900 — CLOSED but still labeled '$STATUS_LABEL'" \
  || fail "case1: #900's residual status label should be named exactly\n$OUT"
printf '%s' "$OUT" | grep -q "stranded claim stamps on closed issues" \
  || fail "case1: expected the stranded-claim-stamp section\n$OUT"
printf '%s' "$OUT" | grep -qF "#900 — CLOSED but still stamped '$STAMP_LABEL'" \
  || fail "case1: #900's stranded claim stamp should be named exactly\n$OUT"
printf '%s' "$OUT" | grep -q "#901" \
  && fail "case1: a cleanly-closed issue (no fnd: labels) must not be flagged\n$OUT"
printf '%s' "$OUT" | grep -q "#10" \
  && fail "case1: a live open Ready item must not be flagged\n$OUT"
[ ! -s "$WRITES" ] \
  || fail "case1: --status --fix must write NOTHING for these classes (repair is --labels --apply)\n$(cat "$WRITES")"
echo "PASS: case 1 closed issue carrying fnd:status:* + fnd:host/session:* is reported as drift, report-only"

# =========================================================================
# Case 2: issues-only, genuinely clean — no false positives.
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":10,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"Live ready item","labels":[{"name":"fnd:status:ready"}]},
  {"number":901,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Cleanly closed","labels":[{"name":"bug"}]}
]'
run_status
printf '%s' "$OUT" | grep -q "In sync" \
  || fail "case2: a clean issues-only board must still report In sync\n$OUT"
printf '%s' "$OUT" | grep -q "residual status labels on closed issues" \
  && fail "case2: no residual-status section should print on a clean board\n$OUT"
printf '%s' "$OUT" | grep -q "stranded claim stamps on closed issues" \
  && fail "case2: no stranded-stamp section should print on a clean board\n$OUT"
echo "PASS: case 2 a clean issues-only board still reports In sync (no false positives)"

# =========================================================================
# Case 3: a closed issue wearing ONLY the claim stamp is still flagged — and
# --status agrees with --labels on it (same issue, same underlying read).
# =========================================================================
ALL_ISSUES_JSON='[
  {"number":10,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"Live ready item","labels":[{"name":"fnd:status:ready"}]},
  {"number":902,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Stamp survived the close","labels":[{"name":"'"$STAMP_LABEL"'"}]}
]'
LABEL_LIST_JSON='[{"name":"'"$STAMP_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS=""
run_status
STATUS_OUT="$OUT"
printf '%s' "$STATUS_OUT" | grep -q "stranded claim stamps on closed issues" \
  || fail "case3: --status must flag a stamp-only closed issue\n$STATUS_OUT"
printf '%s' "$STATUS_OUT" | grep -qF "#902 — CLOSED but still stamped '$STAMP_LABEL'" \
  || fail "case3: --status should name #902's stamp\n$STATUS_OUT"
printf '%s' "$STATUS_OUT" | grep -q "residual status labels on closed issues" \
  && fail "case3: no status label is present, so that section must not print\n$STATUS_OUT"

LABELS_APPLY=0; LABELS_UNATTENDED=0
run_labels
printf '%s' "$OUT" | grep -q "stranded claim stamps on closed issues" \
  || fail "case3: --labels (class j) must flag the same issue\n$OUT"
printf '%s' "$OUT" | grep -qF "#902 — $STAMP_LABEL" \
  || fail "case3: --labels should name #902's stamp\n$OUT"
echo "PASS: case 3 --status and --labels agree on a stranded claim stamp (no silent disagreement)"

# =========================================================================
# Case 4: Projects-v2 UNREGRESSED. Same closed+labeled issue in the issue-state
# read, but on a `backend=projects` board: neither new section may print, the
# pre-existing terminal-but-not-Done class still fires, and the issue-state
# read's --json argv is byte-identical to what it was before #1410.
# =========================================================================
PROJECT_NUMBER=3
ITEM_LIST_JSON='{"items":[
  {"id":"PVTI_it201","content":{"number":201,"title":"Closed issue still Ready"},"status":"Ready"},
  {"id":"PVTI_it203","content":{"number":203,"title":"Open, claimed"},"status":"In Progress","host/Session":"testhost:abcd1234"}
]}'
ALL_ISSUES_JSON='[
  {"number":201,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Closed issue still Ready","labels":[]},
  {"number":203,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"Open, claimed","labels":[]},
  {"number":900,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Closed, carries fnd labels","labels":[{"name":"'"$STATUS_LABEL"'"},{"name":"'"$STAMP_LABEL"'"}]}
]'
PR_LIST_JSON='[]'
run_status

printf '%s' "$OUT" | grep -q "terminal-but-not-Done" \
  || fail "case4: the pre-existing terminal class must still fire on a Projects-v2 board\n$OUT"
printf '%s' "$OUT" | grep -q "#201 — backing CLOSED but board status 'Ready'" \
  || fail "case4: #201 should still be flagged terminal with aligned fields\n$OUT"
printf '%s' "$OUT" | grep -q "residual status labels on closed issues" \
  && fail "case4: the closed-issue tail scan must NOT run on a Projects-v2 board\n$OUT"
printf '%s' "$OUT" | grep -q "stranded claim stamps on closed issues" \
  && fail "case4: the closed-issue tail scan must NOT run on a Projects-v2 board\n$OUT"
printf '%s' "$OUT" | grep -q "#900" \
  && fail "case4: an off-board closed issue must not be reported on a Projects-v2 board\n$OUT"
[ "$(cat "$STATE_READ_JSON")" = "number,state,updatedAt" ] \
  || fail "case4: the Projects-v2 issue-state read's --json argv must be unchanged (got '$(cat "$STATE_READ_JSON")')"
echo "PASS: case 4 Projects-v2 path unregressed (terminal still fires, no tail scan, identical read argv)"

# The issues-only arm asks for the two extra fields on the SAME read — proof the
# tail scan costs zero additional gh calls.
PROJECT_NUMBER=7
ALL_ISSUES_JSON='[{"number":10,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"x","labels":[]}]'
run_status
[ "$(cat "$STATE_READ_JSON")" = "number,state,updatedAt,labels,title" ] \
  || fail "case4b: the issues-only issue-state read must carry labels+title on the SAME call (got '$(cat "$STATE_READ_JSON")')"
[ "$(wc -l <"$STATE_READ_JSON" | tr -d ' ')" = "1" ] \
  || fail "case4b: exactly ONE issue-state read per run — the tail scan must not add a second\n$(cat "$STATE_READ_JSON")"
echo "PASS: case 4b the tail scan rides the existing issue-state read (zero extra gh calls)"

# =========================================================================
# Case 5: the temperloop#902 shape — a closed issue wearing ONLY a residual
# `fnd:status:*` label and NO claim stamp.
#
# Why this is not already covered: case 1 flags an issue carrying BOTH labels
# and case 3 flags a stamp-ONLY issue, so nothing yet proves class (k) fires
# INDEPENDENTLY of class (l). That is exactly the #902 population — the board-7
# closes there ran through /triage culls and merged PRs' bare `Closes #N`, which
# strand `fnd:status:backlog` while leaving no host/session stamp behind (9 of 9
# closures across two runs; the evidence block names #802/#809/#864/#821). If the
# residual-status class were reachable only via a co-present stamp, every one of
# those would still read "In sync".
#
# Also pins the exact observed label value: `fnd:status:backlog`, not the
# `fnd:status:in-progress` the other cases use — Done on this backend is "closed
# with NO fnd:status:* label" (ISSUES-ONLY-BACKEND.md § Close→Done cascade), so
# EVERY status value is drift on a closed issue, not just the in-progress one.
# And it asserts --status (class k) and --labels (class h) name the same issues
# from the same read, the status-label twin of case 3's stamp-side agreement.
# =========================================================================
PROJECT_NUMBER=7
BACKLOG_LABEL="fnd:status:backlog"
ALL_ISSUES_JSON='[
  {"number":10,"state":"OPEN","updatedAt":"2026-06-06T00:00:00Z","title":"Live ready item","labels":[{"name":"fnd:status:ready"}]},
  {"number":802,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Culled by triage","labels":[{"name":"Operational"},{"name":"'"$BACKLOG_LABEL"'"}]},
  {"number":809,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Collapse-absorbed","labels":[{"name":"bug"},{"name":"Operational"},{"name":"'"$BACKLOG_LABEL"'"}]},
  {"number":864,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Collapse-absorbed","labels":[{"name":"Operational"},{"name":"'"$BACKLOG_LABEL"'"}]},
  {"number":821,"state":"CLOSED","updatedAt":"2026-06-06T00:00:00Z","title":"Collapse-absorbed","labels":[{"name":"bug"},{"name":"'"$BACKLOG_LABEL"'"}]}
]'
PR_LIST_JSON='[]'
LABEL_LIST_JSON='[{"name":"'"$BACKLOG_LABEL"'"},{"name":"bug"},{"name":"Operational"}]'
OPEN_ATTACHED_LABELS=""
FIX=1   # class (k) stays report-only even under --fix (repair lives in --labels --apply)
run_status
FIX=0

printf '%s' "$OUT" | grep -q "In sync" \
  && fail "case5: a closed issue wearing only a residual status label must NOT report 'In sync'\n$OUT"
printf '%s' "$OUT" | grep -q "residual status labels on closed issues" \
  || fail "case5: expected the residual-status section with no claim stamp present\n$OUT"
for n in 802 809 864 821; do
  printf '%s' "$OUT" | grep -qF "#$n — CLOSED but still labeled '$BACKLOG_LABEL'" \
    || fail "case5: #$n's residual '$BACKLOG_LABEL' should be named exactly\n$OUT"
done
printf '%s' "$OUT" | grep -q "stranded claim stamps on closed issues" \
  && fail "case5: no fnd:host/session:* stamp exists here — class (k) must fire without class (l)\n$OUT"
printf '%s' "$OUT" | grep -q "#10" \
  && fail "case5: the live open Ready item must not be flagged\n$OUT"
[ ! -s "$WRITES" ] \
  || fail "case5: --status --fix must write NOTHING for class (k)\n$(cat "$WRITES")"

# Cross-lens agreement: --labels class (h) must name the same four issues.
LABELS_APPLY=0; LABELS_UNATTENDED=0
run_labels
printf '%s' "$OUT" | grep -q "stale status labels on closed issues" \
  || fail "case5: --labels (class h) must flag the same residual status labels\n$OUT"
for n in 802 809 864 821; do
  printf '%s' "$OUT" | grep -qF "#$n — $BACKLOG_LABEL" \
    || fail "case5: --labels should name #$n's residual '$BACKLOG_LABEL'\n$OUT"
done
echo "PASS: case 5 a closed issue wearing ONLY fnd:status:backlog is drift on both lenses (temperloop#902)"

echo
echo "ALL PASS: reconcile --status closed-issue tail (issues-only backend)"
