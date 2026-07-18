#!/usr/bin/env bash
#
# Fixture-replay tests for reconcile.sh's Lens 3 (label hygiene, --labels):
# board_label_hygiene-sweep — orphaned `fnd:host/session:*` repo labels and
# stale `fnd:status:*` labels left on closed issues, both artifacts of the
# issues-only backend (board 7, the kernel tracker itself). Zero network: we
# SOURCE reconcile.sh (its execute-guard suppresses the auto-run when sourced)
# and override its `_board_gh` seam, exactly like test_reconcile.sh does for
# Lens 1/2. `label_reconcile_main` is driven directly (not through the CLI
# parser) so each case sets $PROJECT_NUMBER / $LABELS_APPLY / $LABELS_UNATTENDED
# itself.
#
# Pin BOTH boards.conf discovery paths to nonexistent files (same convention
# as test_boards_conf.sh / test_board_name_aliases.sh) so board 7's backend
# resolves to the built-in default ("issues") regardless of what machine this
# runs on.
export BOARDS_CONF_MACHINE="/no-such-machine-conf-$$"
export BOARDS_CONF_REPO_LOCAL="/no-such-repo-local-conf-$$"

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

# Isolated cache dir — never the real TMPDIR/BOARD_CACHE_DIR (mirrors
# test_reconcile.sh's isolation rationale).
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-labels-cache-test-XXXXXX")"
export BOARD_CACHE_DIR
TEST_TMP_DIRS=("$BOARD_CACHE_DIR")
cleanup() { rm -rf "${TEST_TMP_DIRS[@]}"; }
trap cleanup EXIT

# shellcheck source=scripts/reconcile.sh
source "$SCRIPTS_DIR/reconcile.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# Always the issues-only kernel tracker board for this lens.
PROJECT_NUMBER=7

# --- mock _board_gh state -----------------------------------------------
# LABEL_LIST_JSON        -> `gh label list` response (every repo label, fnd:
#                            and non-fnd: mixed, exactly as a real repo would
#                            return).
# OPEN_ATTACHED_LABELS    -> space-separated set of labels currently attached
#                            to >=1 OPEN issue (drives the per-label
#                            `issue list --label X --state open` query for
#                            every label EXCEPT $RACE_LABEL, which gets its
#                            own call-counted behavior below).
# CLOSED_ISSUES_JSON      -> `gh issue list --state closed --json
#                            number,labels` bulk-read response.
# RACE_LABEL / RACE_CALLS_FILE -> simulates a claim landing in the scan->apply
#                            gap: the FIRST `issue list --label $RACE_LABEL`
#                            query (scan) returns empty (orphan); the SECOND
#                            (apply's own re-check) returns a live open issue.
#                            Proves the re-check is a FRESH read, not the
#                            scan's own snapshot. Empty ("") disables it. The
#                            call count is tracked in a FILE, not a shell
#                            variable — `_board_gh` runs inside a command-
#                            substitution subshell here (its stdout is
#                            captured), so a plain variable increment would be
#                            lost when that subshell exits; a file write is
#                            real I/O and survives the subshell boundary
#                            (same reason $DELETES/$STRIPS below are files,
#                            not variables).
# API_<n>_JSON            -> `gh api repos/<repo>/issues/<n>` response for the
#                            per-issue re-check the strip path does
#                            immediately before removing a status label.
LABEL_LIST_JSON=""
OPEN_ATTACHED_LABELS=""
CLOSED_ISSUES_JSON="[]"
RACE_LABEL=""
RACE_CALLS_FILE="/dev/null"
DELETES="/dev/null"
STRIPS="/dev/null"

_board_gh() {
  case "$1 $2" in
    "label list")
      printf '%s' "$LABEL_LIST_JSON" ;;
    "issue list")
      local has_label=0 lbl="" a want=0
      for a in "$@"; do
        if [ "$want" = 1 ]; then lbl="$a"; want=0; continue; fi
        [ "$a" = "--label" ] && { has_label=1; want=1; }
      done
      if [ "$has_label" = 1 ]; then
        if [ -n "$RACE_LABEL" ] && [ "$lbl" = "$RACE_LABEL" ]; then
          local n_calls
          printf 'x\n' >>"$RACE_CALLS_FILE"
          n_calls="$(wc -l <"$RACE_CALLS_FILE" | tr -d ' ')"
          if [ "$n_calls" -eq 1 ]; then echo '[]'; else echo '[{"number":999}]'; fi
        else
          case " $OPEN_ATTACHED_LABELS " in
            *" $lbl "*) echo '[{"number":100}]' ;;
            *)          echo '[]' ;;
          esac
        fi
      else
        printf '%s' "$CLOSED_ISSUES_JSON"
      fi
      ;;
    "label delete")
      printf '%s\n' "$3" >>"$DELETES"
      return 0 ;;
    "issue edit")
      local n="$3" a want=0 lbl=""
      for a in "$@"; do
        if [ "$want" = 1 ]; then lbl="$a"; want=0; continue; fi
        [ "$a" = "--remove-label" ] && want=1
      done
      printf '%s\t%s\n' "$n" "$lbl" >>"$STRIPS"
      return 0 ;;
    *)
      case "$1" in
        api)
          local n="${2##*/}" var json
          var="API_${n}_JSON"
          json="${!var:-}"
          [ -n "$json" ] || json='{"state":"open","labels":[]}'
          printf '%s' "$json"
          ;;
        *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
      esac
      ;;
  esac
}

run_labels() {
  DELETES="$(mktemp)"; STRIPS="$(mktemp)"; RACE_CALLS_FILE="$(mktemp)"
  TEST_TMP_DIRS+=("$DELETES" "$STRIPS" "$RACE_CALLS_FILE")
  : >"$RACE_CALLS_FILE"
  OUT="$(label_reconcile_main)"
}

LIVE_LABEL="fnd:host/session:hostA:sess0001"
ORPHAN_LABEL="fnd:host/session:hostB:sess0002"

# =========================================================================
# Case 1: dry-run is the interactive default — report only, ZERO writes.
# =========================================================================
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"'"$ORPHAN_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS="$LIVE_LABEL"
CLOSED_ISSUES_JSON='[{"number":200,"labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}]'
API_200_JSON='{"state":"closed","labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}'
RACE_LABEL=""
LABELS_APPLY=0
LABELS_UNATTENDED=0
run_labels

printf '%s' "$OUT" | grep -q "orphaned host/session labels" \
  || fail "case1: expected the orphaned-labels section\n$OUT"
printf '%s' "$OUT" | grep -qF "$ORPHAN_LABEL" \
  || fail "case1: expected the orphan label listed\n$OUT"
printf '%s' "$OUT" | grep -qF "$LIVE_LABEL" \
  && fail "case1: a label backing a live open-issue claim must NEVER be listed as a candidate\n$OUT"
printf '%s' "$OUT" | grep -q "stale status labels on closed issues" \
  || fail "case1: expected the stale-status section\n$OUT"
printf '%s' "$OUT" | grep -q "#200 — fnd:status:in-progress" \
  || fail "case1: expected #200's stale status label reported\n$OUT"
printf '%s' "$OUT" | grep -q "(dry-run" \
  || fail "case1: expected the dry-run notice\n$OUT"
printf '%s' "$OUT" | grep -q "^applied:" \
  && fail "case1: dry-run must never print an 'applied:' summary\n$OUT"
printf '%s' "$OUT" | grep -qw "bug" \
  && fail "case1: a non-fnd: label must NEVER be listed\n$OUT"
[ ! -s "$DELETES" ] || fail "case1: dry-run must issue ZERO label deletes\n$(cat "$DELETES")"
[ ! -s "$STRIPS" ] || fail "case1: dry-run must issue ZERO label strips\n$(cat "$STRIPS")"
echo "PASS: case 1 dry-run (interactive default) reports candidates with zero writes"

# =========================================================================
# Case 2: --apply — real deletes/strips, PLUS the immediate re-check skips a
# label/issue whose state changed in the scan->apply gap. A live-claimed
# label and a non-fnd: label are never touched.
# =========================================================================
RACE_LABEL="fnd:host/session:hostC:sess0003"
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"'"$ORPHAN_LABEL"'"},{"name":"'"$RACE_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS="$LIVE_LABEL"
CLOSED_ISSUES_JSON='[{"number":200,"labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]},{"number":201,"labels":[{"name":"fnd:status:ready"}]}]'
API_200_JSON='{"state":"closed","labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}'
API_201_JSON='{"state":"open","labels":[{"name":"fnd:status:ready"}]}'   # reopened between scan and apply
LABELS_APPLY=1
LABELS_UNATTENDED=0
run_labels

printf '%s' "$OUT" | grep -q "deleted: $ORPHAN_LABEL" \
  || fail "case2: expected #ORPHAN_LABEL to be deleted\n$OUT"
grep -qxF "$ORPHAN_LABEL" "$DELETES" \
  || fail "case2: expected $ORPHAN_LABEL recorded in the delete log\n$(cat "$DELETES")"
grep -qxF "$LIVE_LABEL" "$DELETES" \
  && fail "case2: a label backing a live open-issue claim must NEVER be deleted\n$(cat "$DELETES")"
grep -qxF "$RACE_LABEL" "$DELETES" \
  && fail "case2: the re-check must skip a label that became attached between scan and apply\n$(cat "$DELETES")"
printf '%s' "$OUT" | grep -q "skip (now attached to an open issue): $RACE_LABEL" \
  || fail "case2: expected the race-skip notice for $RACE_LABEL\n$OUT"
RACE_CALLS_SEEN="$(wc -l <"$RACE_CALLS_FILE" | tr -d ' ')"
[ "$RACE_CALLS_SEEN" -eq 2 ] \
  || fail "case2: expected exactly 2 open-count queries for the race label (scan + apply re-check), got $RACE_CALLS_SEEN"

printf '%s' "$OUT" | grep -q "stripped: #200 fnd:status:in-progress" \
  || fail "case2: expected #200's stale status label stripped\n$OUT"
grep -qF "$(printf '200\tfnd:status:in-progress')" "$STRIPS" \
  || fail "case2: expected #200 recorded in the strip log\n$(cat "$STRIPS")"
printf '%s' "$OUT" | grep -q "skip (no longer closed+labeled): #201" \
  || fail "case2: expected #201 (reopened) to be skipped by the re-check\n$OUT"
grep -qF "$(printf '201\t')" "$STRIPS" \
  && fail "case2: the re-check must skip an issue that was reopened between scan and apply\n$(cat "$STRIPS")"

printf '%s' "$OUT" | grep -qw "bug" \
  && fail "case2: a non-fnd: label must NEVER be listed, touched, or modified\n$OUT"
grep -qxF "bug" "$DELETES" && fail "case2: 'bug' must never be deleted\n$(cat "$DELETES")"
grep -q "bug\$" "$STRIPS" && fail "case2: 'bug' must never be stripped\n$(cat "$STRIPS")"

printf '%s' "$OUT" | grep -q "applied: deleted 1 label(s), stripped 1 status label(s)\." \
  || fail "case2: expected the exact applied-counts summary\n$OUT"
echo "PASS: case 2 --apply deletes/strips candidates; the immediate re-check protects a label/issue whose state changed"

# =========================================================================
# Case 3: fully in sync — no orphaned labels, no stale status labels. Even
# with --apply requested, there is nothing to do and zero writes fire.
# =========================================================================
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS="$LIVE_LABEL"
CLOSED_ISSUES_JSON='[]'
RACE_LABEL=""
LABELS_APPLY=1
LABELS_UNATTENDED=0
run_labels

printf '%s' "$OUT" | grep -q "In sync" \
  || fail "case3: expected the in-sync all-clear\n$OUT"
printf '%s' "$OUT" | grep -q "^orphaned host/session labels" \
  && fail "case3: unexpected orphaned-labels section header\n$OUT"
printf '%s' "$OUT" | grep -q "^stale status labels" \
  && fail "case3: unexpected stale-status section header\n$OUT"
[ ! -s "$DELETES" ] || fail "case3: in-sync must issue ZERO deletes\n$(cat "$DELETES")"
[ ! -s "$STRIPS" ] || fail "case3: in-sync must issue ZERO strips\n$(cat "$STRIPS")"
echo "PASS: case 3 fully in-sync — no candidates, zero writes even with --apply"

# =========================================================================
# Case 4: --apply is idempotent — a second run against the POST-apply state
# (as gh would actually report it) reports zero changes.
# =========================================================================
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"'"$ORPHAN_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS="$LIVE_LABEL"
CLOSED_ISSUES_JSON='[{"number":200,"labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}]'
API_200_JSON='{"state":"closed","labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}'
RACE_LABEL=""
LABELS_APPLY=1
LABELS_UNATTENDED=0
run_labels
printf '%s' "$OUT" | grep -q "applied: deleted 1 label(s), stripped 1 status label(s)\." \
  || fail "case4 (first run): expected 1 deleted + 1 stripped\n$OUT"

# Second run: gh would now report the label gone and the status label removed.
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"bug"}]'
CLOSED_ISSUES_JSON='[{"number":200,"labels":[{"name":"bug"}]}]'
run_labels
printf '%s' "$OUT" | grep -q "In sync" \
  || fail "case4 (second run): expected in-sync (zero changes) on the idempotent re-run\n$OUT"
[ ! -s "$DELETES" ] || fail "case4 (second run): must issue ZERO deletes\n$(cat "$DELETES")"
[ ! -s "$STRIPS" ] || fail "case4 (second run): must issue ZERO strips\n$(cat "$STRIPS")"
echo "PASS: case 4 --apply is idempotent — a second run against post-apply state reports zero changes"

echo
echo "=== Unattended apply: pending-decisions surface append ==="

# Fresh, isolated knowledge-store root per sub-case (never the real vault).
new_ks_root() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-labels-ks-test-XXXXXX")"
  TEST_TMP_DIRS+=("$d")
  printf '%s' "$d"
}

# =========================================================================
# Case 5: unattended apply appends a `### open` entry recording the counts;
# --unattended alone (no explicit --apply) is enough to trigger a real apply.
# Neither pending-decisions path exists yet -> creates at the LEGACY path
# (the append-target resolution rule: create at legacy until the Pipeline/
# parent folder already exists).
# =========================================================================
KS_ROOT_5="$(new_ks_root)"
export KNOWLEDGE_STORE_ROOT="$KS_ROOT_5"
LABEL_LIST_JSON='[{"name":"'"$LIVE_LABEL"'"},{"name":"'"$ORPHAN_LABEL"'"},{"name":"bug"}]'
OPEN_ATTACHED_LABELS="$LIVE_LABEL"
CLOSED_ISSUES_JSON='[{"number":200,"labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}]'
API_200_JSON='{"state":"closed","labels":[{"name":"fnd:status:in-progress"},{"name":"bug"}]}'
RACE_LABEL=""
LABELS_APPLY=0
LABELS_UNATTENDED=1
run_labels

printf '%s' "$OUT" | grep -q "applied: deleted 1 label(s), stripped 1 status label(s)\." \
  || fail "case5: --unattended alone must apply (LABELS_APPLY forced to 1)\n$OUT"
LEGACY_DOC="$KS_ROOT_5/Context/pipeline - pending decisions.md"
NEW_DOC="$KS_ROOT_5/Pipeline/pending decisions.md"
[ -f "$LEGACY_DOC" ] \
  || fail "case5: expected the pending-decisions entry created at the legacy path (neither existed)\n$(find "$KS_ROOT_5" -type f)"
[ ! -f "$NEW_DOC" ] \
  || fail "case5: must NOT create the new-path file when neither pre-existed (legacy is the creation target)\n$(cat "$NEW_DOC")"
grep -q "label hygiene sweep" "$LEGACY_DOC" || fail "case5: entry missing the sweep name\n$(cat "$LEGACY_DOC")"
grep -q "board7" "$LEGACY_DOC" || fail "case5: entry missing the board tag\n$(cat "$LEGACY_DOC")"
grep -q "Default taken:\*\* applied — deleted 1 label(s), stripped 1 status label(s)" "$LEGACY_DOC" \
  || fail "case5: entry missing the exact default-taken counts line\n$(cat "$LEGACY_DOC")"
grep -q "Disposition:\*\* auto-taken" "$LEGACY_DOC" || fail "case5: entry missing the disposition line\n$(cat "$LEGACY_DOC")"
grep -q "Status:\*\* open" "$LEGACY_DOC" || fail "case5: entry missing Status: open\n$(cat "$LEGACY_DOC")"
echo "PASS: case 5 unattended apply appends a pending-decision entry (created at the legacy path)"
unset KNOWLEDGE_STORE_ROOT

# =========================================================================
# Case 6: when the NEW-path surface already exists, the append targets it —
# never forks a second legacy-path entry stream.
# =========================================================================
KS_ROOT_6="$(new_ks_root)"
mkdir -p "$KS_ROOT_6/Pipeline"
printf '# pending decisions\n\n' >"$KS_ROOT_6/Pipeline/pending decisions.md"
export KNOWLEDGE_STORE_ROOT="$KS_ROOT_6"
run_labels

NEW_DOC="$KS_ROOT_6/Pipeline/pending decisions.md"
LEGACY_DOC="$KS_ROOT_6/Context/pipeline - pending decisions.md"
grep -q "label hygiene sweep" "$NEW_DOC" \
  || fail "case6: expected the entry appended to the EXISTING new-path file\n$(cat "$NEW_DOC")"
[ ! -f "$LEGACY_DOC" ] \
  || fail "case6: must never fork a second legacy-path entry stream when the new path already exists\n$(cat "$LEGACY_DOC")"
echo "PASS: case 6 unattended apply appends to an already-existing Pipeline/ surface, never forks the legacy path"
unset KNOWLEDGE_STORE_ROOT

# =========================================================================
# Case 7: an unavailable knowledge store degrades to best-effort — the sweep
# itself still completes (never fails) even though the append can't land.
# ENOTDIR forces mkdir -p to fail deterministically regardless of who runs
# this test / what $HOME or root perms look like.
# =========================================================================
BLOCKER_FILE="$(mktemp)"
TEST_TMP_DIRS+=("$BLOCKER_FILE")
export KNOWLEDGE_STORE_ROOT="$BLOCKER_FILE/store"
run_labels
printf '%s' "$OUT" | grep -q "applied: deleted 1 label(s), stripped 1 status label(s)\." \
  || fail "case7: the sweep itself must still complete when the knowledge store is unavailable\n$OUT"
echo "PASS: case 7 unattended apply degrades best-effort when the knowledge store is unavailable — the sweep still completes"
unset KNOWLEDGE_STORE_ROOT

echo
echo "PASS: all reconcile.sh --labels (label hygiene) assertions passed"
