#!/usr/bin/env bash
#
# Fixture-replay tests for migrate-board-to-issues.sh — the Projects-v2 ->
# issues-only board migration script. Zero network: we SOURCE the script
# (its own execute-guard suppresses the auto-run when sourced — mirrors
# reconcile.sh / test_issues_backend.sh's own sourcing convention), which in
# turn sources board.sh, then override board.sh's `_board_gh` seam to record
# argv and replay canned JSON.
#
# A single placeholder board (30) carries the whole suite, its repo/owner/
# project axes fully overridden via a scoped boards.conf (never the real
# org — this file is NOT on the personal-token-denylist exempt list, so it
# must stay clean; see workflows/scripts/kernel/personal-token-denylist.tsv).
# backend is left UNSET (falls through to the default "projects" — the
# precondition this whole script exists for: read Projects, write issues).
#
# Covered (acceptance criteria 1/3/2/4 in that order — the natural
# dry-run -> refuse-bad-schema -> apply -> idempotence narrative):
#   1. Dry-run mapping table (acceptance #1) — the full Status/Component ->
#      fnd:* mapping prints with the correct per-option item counts, and
#      ZERO gh calls beyond the three board_resolve reads (no issue edit/api
#      calls at all).
#   2. Stop-on-unrecognized (acceptance #3) — a board schema carrying an
#      extra single-select field ("Workflow") and a retired Status option
#      ("Blocked") is refused BEFORE any write, in BOTH dry-run and --apply
#      mode, with both problems named in the report.
#   3. Apply + verify (acceptance #2) — --apply writes fnd:status:*/
#      fnd:component:* labels via board_set_status/board_set_component (the
#      existing write path, unchanged), and the post-write verify pass reads
#      every item back through the issues arm and confirms it matches.
#   4. Idempotence (acceptance #4) — a second --apply against the SAME
#      Projects-arm data reports zero changes and fires zero further
#      `gh issue edit` calls.
#
# shellcheck disable=SC2329  # _board_gh overrides are invoked indirectly by board.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"

# shellcheck source=scripts/tests/fixtures/fake_gh.sh
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export BOARD_CACHE_TTL=0
export BOARD_BUDGET_GUARD_THRESHOLD=0
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/migrate-board-cache-XXXXXX")"
export BOARD_CACHE_DIR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/migrate-board-conf-XXXXXX")"
CALLS="$(mktemp "${TMPDIR:-/tmp}/migrate-board-calls-XXXXXX")"
OUTFILE="$(mktemp "${TMPDIR:-/tmp}/migrate-board-out-XXXXXX")"
cleanup() { rm -rf "$WORK" "$CALLS" "$OUTFILE" "$BOARD_CACHE_DIR"; }
trap cleanup EXIT

# Board 30 = a placeholder Projects-v2 board (generic org/repo — no personal
# token), fully controlled via a scoped boards.conf. backend is intentionally
# absent (defaults "projects" — see board_backend's ISSUES-ONLY-BACKEND.md
# contract).
cat > "$WORK/boards.conf" <<'EOF'
board.30.repo=Acme/kernel-test2
board.30.owner=Acme
board.30.project=77
EOF
export BOARDS_CONF_REPO_LOCAL="$WORK/boards.conf"
export BOARDS_CONF_MACHINE="$WORK/no-such-machine-conf"

# shellcheck source=scripts/migrate-board-to-issues.sh
source "$SCRIPTS_DIR/migrate-board-to-issues.sh"

# ============================================================================
# 1: dry-run mapping table, zero writes (acceptance #1)
# ============================================================================
PROJECT_VIEW_GOOD='{"id":"PVT_kwMIGRATE30","number":77,"title":"t","owner":{"login":"Acme"}}'
FIELDS_JSON_GOOD='{"fields":[
  {"id":"PVTF_title","name":"Title","type":"ProjectV2Field"},
  {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_backlog","name":"Backlog"},{"id":"opt_ready","name":"Ready"},
    {"id":"opt_inprogress","name":"In Progress"},{"id":"opt_done","name":"Done"}]},
  {"id":"PVTF_hostsession","name":"Host/Session","type":"ProjectV2Field"},
  {"id":"PVTF_seq","name":"Seq","type":"ProjectV2Field"},
  {"id":"PVTSSF_component","name":"Component","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_ingest","name":"Ingest"},{"id":"opt_datastore","name":"Datastore"}]}
]}'
ITEMS_JSON_GOOD='{"items":[
  {"id":"PVTI_1","content":{"number":201,"title":"a","type":"Issue"},"status":"Ready","component":"Ingest"},
  {"id":"PVTI_2","content":{"number":202,"title":"b","type":"Issue"},"status":"In Progress"},
  {"id":"PVTI_3","content":{"number":203,"title":"c","type":"Issue"},"status":"Backlog","component":"Datastore"}
],"totalCount":3}'

_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       printf '%s' "$PROJECT_VIEW_GOOD" ;;
    "project field-list") printf '%s' "$FIELDS_JSON_GOOD" ;;
    "project item-list")  printf '%s' "$ITEMS_JSON_GOOD" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

: >"$CALLS"
OUT="$(migrate_board 30 0)" || fail "dry run should exit 0, got rc=$?"
grep -q "Board 30 (Acme/kernel-test2)" <<<"$OUT"                                    || fail "missing board/repo header: $OUT"
grep -q "3 open item(s)"               <<<"$OUT"                                    || fail "missing total item count: $OUT"
grep -q "Ready.*-> fnd:status:ready.*(1 item(s))"                     <<<"$OUT"     || fail "missing Ready mapping row: $OUT"
grep -q "In Progress.*-> fnd:status:in-progress.*(1 item(s))"         <<<"$OUT"     || fail "missing In Progress mapping row: $OUT"
grep -q "Backlog.*-> fnd:status:backlog.*(1 item(s))"                 <<<"$OUT"     || fail "missing Backlog mapping row: $OUT"
grep -q "Ingest.*-> fnd:component:ingest.*(1 item(s))"                <<<"$OUT"     || fail "missing Ingest mapping row: $OUT"
grep -q "Datastore.*-> fnd:component:datastore.*(1 item(s))"          <<<"$OUT"     || fail "missing Datastore mapping row: $OUT"
grep -q "(none).*1 item(s) — no Component set"                        <<<"$OUT"     || fail "missing (none)-component row for #202: $OUT"
grep -q "NOT migrated: Host/Session"                                  <<<"$OUT"     || fail "missing Host/Session non-migration note: $OUT"
grep -q "0 writes (dry run"                                           <<<"$OUT"     || fail "missing zero-writes dry-run trailer: $OUT"
[ "$(grep -c '^gh ' "$CALLS")" -eq 3 ] || fail "dry run should make exactly 3 gh calls (project view/field-list/item-list), got: $(cat "$CALLS")"
grep -q '^gh issue\|^gh api' "$CALLS" && fail "dry run must NEVER touch the issues arm (issue edit/api calls found): $(cat "$CALLS")"
echo "PASS: dry-run prints the full field->label mapping table with zero writes (acceptance #1)"

# ============================================================================
# 2: stop-on-unrecognized field/option BEFORE any write (acceptance #3)
# ============================================================================
FIELDS_JSON_BAD='{"fields":[
  {"id":"PVTF_title","name":"Title","type":"ProjectV2Field"},
  {"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_backlog","name":"Backlog"},{"id":"opt_ready","name":"Ready"},
    {"id":"opt_inprogress","name":"In Progress"},{"id":"opt_done","name":"Done"},
    {"id":"opt_blocked","name":"Blocked"}]},
  {"id":"PVTSSF_workflow","name":"Workflow","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_wf_backlog","name":"Backlog"}]},
  {"id":"PVTSSF_component","name":"Component","type":"ProjectV2SingleSelectField","options":[
    {"id":"opt_ingest","name":"Ingest"}]}
]}'
ITEMS_JSON_BAD='{"items":[
  {"id":"PVTI_9","content":{"number":301,"title":"x","type":"Issue"},"status":"Ready"}
],"totalCount":1}'

_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       printf '%s' "$PROJECT_VIEW_GOOD" ;;
    "project field-list") printf '%s' "$FIELDS_JSON_BAD" ;;
    "project item-list")  printf '%s' "$ITEMS_JSON_BAD" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

: >"$CALLS"
set +e
ERR="$(migrate_board 30 0 2>&1 1>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "a board with an unrecognized field/option should refuse with rc 2, got rc=$RC (stderr: $ERR)"
grep -q "UNRECOGNIZED FIELD: 'Workflow'"        <<<"$ERR" || fail "should name the unrecognized 'Workflow' field: $ERR"
grep -q "UNRECOGNIZED STATUS OPTION: 'Blocked'" <<<"$ERR" || fail "should name the unrecognized 'Blocked' status option: $ERR"
grep -q "no invented mappings"                  <<<"$ERR" || fail "should state the no-invented-mappings refusal: $ERR"
grep -q '^gh issue\|^gh api' "$CALLS" && fail "an unrecognized-schema dry run must never touch the issues arm: $(cat "$CALLS")"
echo "PASS: dry-run refuses a board with an unrecognized field/option, before any write"

: >"$CALLS"
set +e
ERR="$(migrate_board 30 1 2>&1 1>/dev/null)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "--apply against an unrecognized-schema board should refuse with rc 2, got rc=$RC (stderr: $ERR)"
grep -q "UNRECOGNIZED FIELD: 'Workflow'" <<<"$ERR" || fail "--apply refusal should also name the field: $ERR"
grep -q '^gh issue\|^gh api' "$CALLS" && fail "--apply against an unrecognized-schema board must write NOTHING: $(cat "$CALLS")"
echo "PASS: --apply refuses (rc 2, zero writes) a board with an unrecognized field/option (acceptance #3)"

# ============================================================================
# 3 + 4: apply + verify (acceptance #2), then idempotence (acceptance #4)
# ============================================================================
# Stateful fake tracking each issue's fnd: labels across board_set_status /
# board_set_component calls, mirroring test_issues_backend.sh's own style.
FAKE_L_201=""; FAKE_L_202=""; FAKE_L_203=""
_fake_get_labels() { case "$1" in 201) printf '%s' "$FAKE_L_201" ;; 202) printf '%s' "$FAKE_L_202" ;; 203) printf '%s' "$FAKE_L_203" ;; esac; }
_fake_set_labels() { case "$1" in 201) FAKE_L_201="$2" ;; 202) FAKE_L_202="$2" ;; 203) FAKE_L_203="$2" ;; esac; }
_fake_labels_json() {
  local labels; labels="$(_fake_get_labels "$1")"
  if [ -z "$labels" ]; then printf '[]'; return; fi
  printf '%s\n' $labels | jq -R . | jq -s 'map({name:.})'
}

_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       printf '%s' "$PROJECT_VIEW_GOOD" ;;
    "project field-list") printf '%s' "$FIELDS_JSON_GOOD" ;;
    "project item-list")  printf '%s' "$ITEMS_JSON_GOOD" ;;
    "issue list")
      jq -n --argjson l201 "$(_fake_labels_json 201)" --argjson l202 "$(_fake_labels_json 202)" --argjson l203 "$(_fake_labels_json 203)" '
        [ {number:201,title:"a",labels:$l201,milestone:null},
          {number:202,title:"b",labels:$l202,milestone:null},
          {number:203,title:"c",labels:$l203,milestone:null} ]
      '
      ;;
    "api repos/Acme/kernel-test2/issues/"*)
      local n="${2##*/}" ljson
      ljson="$(_fake_labels_json "$n")"
      printf '{"number":%s,"title":"t","state":"open","labels":%s}' "$n" "$ljson"
      ;;
    "issue edit")
      local n="$3" cur prev="" a
      shift 3
      cur="$(_fake_get_labels "$n")"
      for a in "$@"; do
        case "$prev" in
          --remove-label) cur="$(printf '%s\n' $cur | grep -vx "$a" | tr '\n' ' ')" ;;
          --add-label)    cur="$cur $a" ;;
        esac
        prev="$a"
      done
      _fake_set_labels "$n" "$cur"
      ;;
    "label create") : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

# NOTE: capture apply output via a FILE redirect, never `OUT="$(migrate_board …)"`
# — command substitution forks a subshell, and the stateful fake's FAKE_L_*
# mutations (plain globals `_fake_set_labels` writes) would be lost the
# moment that subshell exits, silently making every write look like a no-op
# to the parent shell's own FAKE_L_* checks below.
: >"$CALLS"
set +e
migrate_board 30 1 >"$OUTFILE" 2>&1
RC=$?
set -e
OUT="$(cat "$OUTFILE")"
[ "$RC" -eq 0 ] || fail "first --apply should exit 0, got rc=$RC: $OUT"
grep -q "0 already-correct item(s), 3 item(s) needed a write (0 failed)" <<<"$OUT" || fail "wrong first-apply write summary: $OUT"
grep -q "verify (reading back through backend=issues): 3/3 item(s) match" <<<"$OUT" || fail "wrong first-apply verify summary: $OUT"
grep -q "#201  Status -> Ready  (fnd:status:ready)"        <<<"$OUT" || fail "missing #201 status write log: $OUT"
grep -q "#201  Component -> Ingest  (fnd:component:ingest)" <<<"$OUT" || fail "missing #201 component write log: $OUT"
grep -q "#202  Status -> In Progress  (fnd:status:in-progress)" <<<"$OUT" || fail "missing #202 status write log: $OUT"
[ "$FAKE_L_201" = " fnd:status:ready fnd:component:ingest" ]     || fail "unexpected label state for #201: '$FAKE_L_201'"
[ "$FAKE_L_202" = " fnd:status:in-progress" ]                    || fail "unexpected label state for #202: '$FAKE_L_202'"
[ "$FAKE_L_203" = " fnd:status:backlog fnd:component:datastore" ] || fail "unexpected label state for #203: '$FAKE_L_203'"
echo "PASS: --apply writes fnd: labels via the existing write path and verifies every item matches through backend=issues (acceptance #2)"

# --- idempotence: a second --apply against the SAME Projects data reports
# zero changes and fires zero further `gh issue edit` calls (acceptance #4) --
: >"$CALLS"
set +e
migrate_board 30 1 >"$OUTFILE" 2>&1
RC=$?
set -e
OUT="$(cat "$OUTFILE")"
[ "$RC" -eq 0 ] || fail "second --apply should exit 0, got rc=$RC: $OUT"
grep -q "3 already-correct item(s), 0 item(s) needed a write (0 failed)" <<<"$OUT" || fail "second apply should report zero changes: $OUT"
grep -q "verify (reading back through backend=issues): 3/3 item(s) match" <<<"$OUT" || fail "second apply verify summary wrong: $OUT"
grep -q '^gh issue edit' "$CALLS" && fail "a second --apply against unchanged data must fire ZERO issue edit calls: $(cat "$CALLS")"
echo "PASS: a second --apply reports zero changes and writes nothing further (acceptance #4)"

echo
echo "ALL PASS: test_migrate_board_to_issues.sh"
