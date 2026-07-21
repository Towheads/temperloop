#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/lib/board.sh via the `_board_gh` override
# seam (the board adapter's analogue of lib/claim_marker.sh's `_claim_marker_tmux`
# test seam). No PATH shim, no network: we source the library, override
# `_board_gh` to record argv + emit canned fixture JSON, and assert each public
# accessor resolves the right ids and each mutation issues the right gh argv.
#
# The `_board_gh` overrides below are invoked indirectly (the library calls
# `_board_gh`, which the test redefines), so shellcheck's "never invoked" check
# is a false positive for them — disabled file-wide.
# shellcheck disable=SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"
FIX="$HERE/fixtures"

# Source the shared replay component for _fake_gh_log_argv (argv-log-v1).
# FAKE_GH_SOURCE=1 suppresses exec-time side-effects; only the helper is loaded.
# shellcheck source=scripts/tests/fixtures/fake_gh.sh
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

# This suite pins the LIVE gh call contract (exact counts + argv per accessor).
# The cross-process read cache (GH #93) is a separate layer with its own test
# (test_board_cache.sh); disable it here so every assertion sees the canonical
# live sequence, and isolate the cache dir so a real session's /tmp board cache
# can never leak into these counts.
export BOARD_CACHE_TTL=0
# The pre-flight GraphQL budget guard (GH #156) is likewise a separate layer with
# its own coverage (test_board_cache.sh #14). It fires before board_resolve's heavy
# item-list whenever a LIVE read is due (which, with the cache off above, is always),
# adding a free REST `gh api rate_limit` call that would inflate these GraphQL-call
# counts. Disable it here via its documented opt-out so the counts stay canonical.
export BOARD_BUDGET_GUARD_THRESHOLD=0
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/board-replay-cache-XXXXXX")"
export BOARD_CACHE_DIR

fail() { echo "FAIL: $1" >&2; exit 1; }

CALLS="$(mktemp "${TMPDIR:-/tmp}/board-replay-XXXXXX")"
cleanup() { rm -rf "$CALLS" "$BOARD_CACHE_DIR"; }
trap cleanup EXIT

# Override the ONE seam: record argv (one line per call) and replay fixtures
# for the read subcommands. Mutations (item-add / item-edit) record only.
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")  cat "$FIX/item_list.json" ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    "issue edit")         : ;;
    "api graphql")        cat "$FIX/issue_project_item.json" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

last_call() { tail -n1 "$CALLS"; }

# --- board_resolve + accessors -------------------------------------------
: >"$CALLS"
board_resolve 3
[ "$(grep -c '^gh ' "$CALLS")" -eq 3 ] \
  || fail "board_resolve should make exactly 3 gh calls (view+field-list+item-list)"
grep -q 'gh project view 4 --owner Towheads --format json'                 "$CALLS" || fail "missing project view call"
grep -q 'gh project field-list 4 --owner Towheads --format json'           "$CALLS" || fail "missing field-list call"
grep -q 'gh project item-list 4 --owner Towheads --limit 500 --query -status:Done --format json' "$CALLS" || fail "missing item-list active-set call"
[ "$BOARD_PROJECT_ID" = "PVT_kwTESTPROJECT123" ] || fail "BOARD_PROJECT_ID wrong: $BOARD_PROJECT_ID"

[ "$(board_field_id "$BOARD_FIELD_STATUS")" = "PVTSSF_status" ] || fail "Status field id wrong"
[ "$(board_field_id "$BOARD_FIELD_HOSTSESSION")" = "PVTF_hostsession" ] || fail "Host/Session field id wrong"
[ "$(board_option_id "$BOARD_FIELD_STATUS" "$BOARD_OPT_INPROGRESS")" = "opt_inprogress" ] || fail "In Progress opt id wrong"
[ "$(board_option_id "$BOARD_FIELD_STATUS" "$BOARD_OPT_BACKLOG")" = "opt_backlog" ] || fail "Backlog opt id wrong"
[ "$(board_option_id "$BOARD_FIELD_STATUS" "$BOARD_OPT_DONE")" = "opt_done" ] || fail "Done opt id wrong"
[ "$(board_item_id 227)" = "PVTI_item227" ] || fail "item id for #227 wrong"
[ "$(board_item_title 227)" = "Some board item title" ] || fail "item title for #227 wrong"
[ -z "$(board_item_id 12345)" ] || fail "absent issue should resolve to empty item id"
echo "PASS: board_resolve issues 3 gh calls and accessors resolve ids by name"

# --- board_item_milestone: read the built-in (read-only) Milestone mirror ------
# The release-phase axis rides GitHub's native milestone, surfaced on the board as
# .milestone.title — readable straight from the item-list (no GraphQL branch).
[ "$(board_item_milestone 227)" = "Production Live" ] || fail "milestone title for #227 wrong: $(board_item_milestone 227)"
[ -z "$(board_item_milestone 228)" ] || fail "item with no milestone should read empty"
[ -z "$(board_item_milestone 12345)" ] || fail "absent issue should read empty milestone"
echo "PASS: board_item_milestone reads the built-in Milestone mirror by issue number"

# --- board_item_milestone arg guard (temperloop#594) --------------------------
# It takes a SINGLE issue# arg — no leading board arg. The guessable accessor-family
# leading-board-arg form `board_item_milestone 7 592` must fail LOUD (non-zero +
# stderr) instead of silently selecting issue #7 and returning empty ("unmilestoned"
# read that masked 8 milestoned Backlog items in a live /triage run).
merr="$(board_item_milestone 7 592 2>&1 1>/dev/null)" \
  && fail "board_item_milestone must reject the leading-board-arg form '7 592'"
case "$merr" in
  *"board arg"* | *"ONE issue"*) : ;;
  *) fail "board_item_milestone wrong-arity error should be loud (got: $merr)" ;;
esac
# A non-numeric single arg is also rejected loud.
board_item_milestone abc >/dev/null 2>&1 \
  && fail "board_item_milestone must reject a non-numeric issue#"
# The correct single-arg call still works unchanged (regression).
[ "$(board_item_milestone 227)" = "Production Live" ] \
  || fail "board_item_milestone must still read the milestone for a valid single arg"
echo "PASS: board_item_milestone arg guard rejects the leading-board-arg/non-numeric misuse, accepts the single-arg call"

# --- board_set_component: the board-native subsystem single-select -------------
# Thin wrapper over board_set_status's field-override arm; resolves the Component
# field id + option id by NAME and issues the item-edit.
: >"$CALLS"
board_set_component "PVTI_item227" "Datastore"
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTSSF_component --single-select-option-id opt_datastore" ] \
  || fail "board_set_component argv wrong: $(last_call)"
echo "PASS: board_set_component issues the expected Component item-edit argv"

# unknown component option -> non-zero, no edit
: >"$CALLS"
if board_set_component "PVTI_item227" "No Such Component"; then
  fail "board_set_component should fail for an unknown option"
fi
[ ! -s "$CALLS" ] || fail "board_set_component must not edit when the option is unknown"
echo "PASS: board_set_component refuses (no edit) on an unknown component"

# --- board_set_milestone: repo-level write (board mirror is read-only) ----------
# Keyed by issue NUMBER (not item id): the board's Milestone column can't be
# written via item-edit, so this routes a `gh issue edit --milestone` through the
# seam and resolves the repo from board_repo.
: >"$CALLS"
board_set_milestone 3 227 "v2"
[ "$(last_call)" = "gh issue edit 227 -R Towheads/stageFind --milestone v2" ] \
  || fail "board_set_milestone argv wrong: $(last_call)"
echo "PASS: board_set_milestone issues a repo-level gh issue edit --milestone"

# unknown board -> non-zero, no gh call
: >"$CALLS"
if board_set_milestone 9 227 "v2"; then fail "board_set_milestone should fail for an unknown board"; fi
[ ! -s "$CALLS" ] || fail "board_set_milestone must not call gh for an unknown board"
echo "PASS: board_set_milestone refuses (no gh) on an unknown board"

# --- board_active_milestones: read the machine-owned triage:active marker (foundation #210) ---
# A milestone is "active" iff its GitHub DESCRIPTION carries the literal
# `<!-- triage:active -->` HTML-comment marker. The accessor reads the OPEN
# milestones over REST (repos/<owner>/<repo>/milestones?state=open) through the
# `_board_gh` seam and prints ONLY the marked titles, one per line. A milestones
# list with one marked + one unmarked must yield only the marked title.
DEFAULT_BOARD_GH="$(declare -f _board_gh)"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Towheads/stageFind/milestones?state=open")
      cat <<'JSON'
[
  { "number": 7, "title": "Production Live", "description": "Phase 2 work\n<!-- triage:active -->" },
  { "number": 8, "title": "Backlog Phase",   "description": "future-only, no marker" },
  { "number": 9, "title": "No Description",   "description": null }
]
JSON
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
out="$(board_active_milestones 3)"
[ "$out" = "Production Live" ] \
  || fail "board_active_milestones should print only the marked title, got: [$out]"
# Asserts the GET parse path's argv: REST milestones?state=open through the seam.
# (last_call %q-quotes the `?` to `\?`; match the literal it actually records.)
[ "$(last_call)" = 'gh api repos/Towheads/stageFind/milestones\?state=open' ] \
  || fail "board_active_milestones argv wrong: $(last_call)"
echo "PASS: board_active_milestones reads the open milestones over REST and prints only triage:active titles"

# genuinely-none-active: a SUCCESSFUL fetch that finds zero triage:active markers
# must stay exit 0 with empty output. "None active" is the normal default state
# (milestones default inactive) — NOT a failure. This is the case /triage's guard
# must treat as "proceed", not "STOP" (temperloop#152).
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Towheads/stageFind/milestones?state=open")
      cat <<'JSON'
[
  { "number": 8, "title": "Backlog Phase",  "description": "future-only, no marker" },
  { "number": 9, "title": "No Description",  "description": null }
]
JSON
      ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
if out="$(board_active_milestones 3)"; then :; else fail "board_active_milestones must exit 0 on a successful fetch with no active markers"; fi
[ -z "$out" ] || fail "board_active_milestones should print nothing when no milestone is active, got: [$out]"
echo "PASS: board_active_milestones returns exit 0 + empty output when a successful fetch finds zero active markers"

# fetch failure: when the milestone REST fetch ITSELF fails (non-zero from the
# seam), board_active_milestones must PROPAGATE that failure (return non-zero)
# rather than mask it behind jq's exit code and look like "empty / none active".
# This is the disambiguation /triage's guard relies on to STOP only on a real
# REST failure, never on a genuinely-empty active set (temperloop#152).
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Towheads/stageFind/milestones?state=open") return 1 ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
if board_active_milestones 3 >/dev/null 2>&1; then fail "board_active_milestones must return non-zero when the milestone fetch fails"; fi
echo "PASS: board_active_milestones propagates a fetch failure (non-zero) instead of masking it as empty"

# unknown board -> non-zero, no gh call
: >"$CALLS"
if board_active_milestones 9 >/dev/null 2>&1; then fail "board_active_milestones should fail for an unknown board"; fi
[ ! -s "$CALLS" ] || fail "board_active_milestones must not call gh for an unknown board"
echo "PASS: board_active_milestones refuses (no gh) on an unknown board"

# --- board_set_milestone_description: REST GET (resolve by title) + PATCH (foundation #210) ---
# Resolves the milestone by TITLE over REST (state=all), then PATCHes its
# description on repos/<owner>/<repo>/milestones/<number> through the seam. The
# PATCH body must carry the new description as -f description=<text>.
MS_DESC_DB='[
  { "number": 7, "title": "Production Live", "description": "old description" },
  { "number": 8, "title": "Backlog Phase",   "description": "another" }
]'
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "api repos/Towheads/stageFind/milestones?state=all") printf '%s' "$MS_DESC_DB" ;;
    "api --method")                                     : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_set_milestone_description 3 "Production Live" "Phase 2\n<!-- triage:active -->"
# GET to resolve the title, then PATCH the resolved milestone number with the body.
# (last_call %q-quotes `?` to `\?`; grep -F so the backslash is matched literally.)
grep -qF 'gh api repos/Towheads/stageFind/milestones\?state=all' "$CALLS" \
  || fail "board_set_milestone_description must GET the milestones list to resolve the title"
[ "$(last_call)" = "gh api --method PATCH repos/Towheads/stageFind/milestones/7 -f description=Phase\\ 2\\\\n\\<\\!--\\ triage:active\\ --\\>" ] \
  || fail "board_set_milestone_description PATCH argv wrong: $(last_call)"
echo "PASS: board_set_milestone_description GETs by title then PATCHes the description (REST)"

# idempotent: target == current description -> NO patch (no double-write)
: >"$CALLS"
board_set_milestone_description 3 "Production Live" "old description"
[ "$(grep -c 'gh api --method PATCH' "$CALLS")" -eq 0 ] \
  || fail "board_set_milestone_description must NOT PATCH when the description is unchanged"
echo "PASS: board_set_milestone_description is idempotent (skips the PATCH on an unchanged description)"

# unknown milestone title -> non-zero, no PATCH, loud stderr
: >"$CALLS"
err="$(board_set_milestone_description 3 "No Such Milestone" "x" 2>&1 >/dev/null)" \
  && fail "board_set_milestone_description should fail for an unknown milestone title"
[ "$(grep -c 'gh api --method PATCH' "$CALLS")" -eq 0 ] \
  || fail "board_set_milestone_description must NOT PATCH for an unknown milestone title"
case "$err" in
  *"No Such Milestone"*) : ;;
  *) fail "board_set_milestone_description must name the missing title on stderr (got: $err)" ;;
esac
echo "PASS: board_set_milestone_description fails loud (no PATCH) on an unknown milestone title"

# unknown board -> non-zero, no gh call, loud stderr
: >"$CALLS"
err="$(board_set_milestone_description 9 "Production Live" "x" 2>&1 >/dev/null)" \
  && fail "board_set_milestone_description should fail for an unknown board"
[ ! -s "$CALLS" ] || fail "board_set_milestone_description must not call gh for an unknown board"
case "$err" in
  *"unknown board"*) : ;;
  *) fail "board_set_milestone_description must name the unknown board on stderr (got: $err)" ;;
esac
echo "PASS: board_set_milestone_description refuses (no gh) on an unknown board"

# Restore the default fixture-replay seam for the remaining assertions.
eval "$DEFAULT_BOARD_GH"

# --- board_set_status ---------------------------------------------------
: >"$CALLS"
board_set_status "PVTI_item227" "$BOARD_OPT_INPROGRESS"
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTSSF_status --single-select-option-id opt_inprogress" ] \
  || fail "board_set_status argv wrong: $(last_call)"
echo "PASS: board_set_status issues the expected item-edit argv"

# unresolvable option -> non-zero, no edit
: >"$CALLS"
if board_set_status "PVTI_item227" "No Such Option"; then
  fail "board_set_status should fail for an unknown option"
fi
[ ! -s "$CALLS" ] || fail "board_set_status must not edit when the option is unknown"
echo "PASS: board_set_status refuses (no edit) on an unknown option"

# --- board_set_status honors an explicit field-name override --------------
# The optional 3rd arg targets a named single-select field other than the
# default Status. All boards now govern on Status (the per-board
# board_status_field() shim was retired when foundation #4 migrated onto Status),
# but the override mechanism remains a public contract; the fixture's spare
# single-select field exercises it.
: >"$CALLS"
board_set_status "PVTI_item227" "$BOARD_OPT_BACKLOG" "Workflow"
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTSSF_workflow4 --single-select-option-id opt_wf_backlog" ] \
  || fail "board_set_status explicit-field argv wrong: $(last_call)"
echo "PASS: board_set_status honors an explicit field-name override"

# --- board_stamp ----------------------------------------------------------
: >"$CALLS"
board_stamp "PVTI_item227" "$BOARD_FIELD_HOSTSESSION" "testhost:abcd1234"
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTF_hostsession --text testhost:abcd1234" ] \
  || fail "board_stamp argv wrong: $(last_call)"
echo "PASS: board_stamp issues the expected --text item-edit argv"

# An EMPTY text CLEARS the field via --clear, never --text '' (which gh rejects
# as "no changes to make" — the foundation #259 epic park-back no-op).
: >"$CALLS"
board_stamp "PVTI_item227" "$BOARD_FIELD_HOSTSESSION" ""
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTF_hostsession --clear" ] \
  || fail "board_stamp empty-text must issue --clear, got: $(last_call)"
case "$(last_call)" in *--text*) fail "board_stamp empty-text must NOT pass --text" ;; esac
echo "PASS: board_stamp clears the field with --clear on empty text"

# --- board_set_number (e.g. /triage Seq) ----------------------------------
: >"$CALLS"
board_set_number "PVTI_item227" "Seq" 3
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTF_seq --number 3" ] \
  || fail "board_set_number argv wrong: $(last_call)"
echo "PASS: board_set_number issues the expected --number item-edit argv"

# unresolvable field -> non-zero, no edit
: >"$CALLS"
if board_set_number "PVTI_item227" "No Such Field" 3; then
  fail "board_set_number should fail for an unknown field"
fi
[ ! -s "$CALLS" ] || fail "board_set_number must not edit when the field is unknown"
echo "PASS: board_set_number refuses (no edit) on an unknown field"

# --- item-id arg-shape guard (foundation #128) ----------------------------
# The item-edit writers are keyed by a PVTI_* item-id. Called with a bare board
# number or issue# (the documented misuse that silently no-opped F103 / #489),
# they must fail non-zero, issue NO item-edit, and print a loud stderr message —
# so the bug can't hide behind a caller's swallowed exit code.
# $1 = label; $2.. = the guarded call (run with a bare issue# as arg1).
assert_guarded() {
  local label="$1"; shift
  local err
  : >"$CALLS"
  err="$("$@" 2>&1 1>/dev/null)" && fail "$label must fail when arg1 is a bare issue#, not a PVTI_* item-id"
  [ ! -s "$CALLS" ] || fail "$label must not issue an item-edit on a bad item-id"
  case "$err" in
    *item-id*) : ;;
    *) fail "$label must emit a loud item-id error to stderr (got: $err)" ;;
  esac
  echo "PASS: $label fails loud (no edit) on a bare issue# instead of a PVTI_* item-id"
}
assert_guarded board_set_status board_set_status 489 "$BOARD_OPT_INPROGRESS"
assert_guarded board_set_number board_set_number 489 "Seq" 3
assert_guarded board_stamp      board_stamp 489 "$BOARD_FIELD_HOSTSESSION" "x"

# A well-formed PVTI_* id still passes the guard (regression: guard must not
# reject the legitimate happy path exercised above).
: >"$CALLS"
board_set_status "PVTI_item227" "$BOARD_OPT_INPROGRESS" \
  || fail "board_set_status must still accept a valid PVTI_* item-id"
echo "PASS: item-id guard lets a valid PVTI_* id through"

# --- board_create_on_board (capture.sh flow) ------------------------------
: >"$CALLS"
board_create_on_board 3 "https://github.com/Towheads/stageFind/issues/999" 999
# Expected exactly: item-add, view, field-list, item-list, item-edit(Backlog).
[ "$(grep -c '^gh ' "$CALLS")" -eq 5 ] || fail "board_create_on_board should make exactly 5 gh calls, made $(grep -c '^gh ' "$CALLS")"
[ "$(grep -c 'gh project field-list' "$CALLS")" -eq 1 ] || fail "board_create_on_board must make exactly ONE field-list call (dedup)"
grep -q 'gh project item-add 4 --owner Towheads --url https://github.com/Towheads/stageFind/issues/999' "$CALLS" || fail "missing item-add"
grep -q 'gh project item-edit --id PVTI_item999 --project-id PVT_kwTESTPROJECT123 --field-id PVTSSF_status --single-select-option-id opt_backlog' "$CALLS" || fail "missing Backlog item-edit"
echo "PASS: board_create_on_board adds + sets Backlog with a single field-list call"

# --- board_create_many: batch add pays ONE resolve for the whole batch (GH #40) ---
# board_create_on_board now delegates here; the 5-call single-item contract above
# still holds. The batch contract: N item-adds, but only ONE view / field-list /
# item-list (the single shared resolve), then N Backlog edits — NOT O(N) re-lists.
: >"$CALLS"
board_create_many 3 \
  "https://github.com/Towheads/stageFind/issues/999" 999 \
  "https://github.com/Towheads/stageFind/issues/228" 228
[ "$(grep -c 'gh project item-add' "$CALLS")" -eq 2 ] \
  || fail "board_create_many should item-add both URLs, got $(grep -c 'gh project item-add' "$CALLS")"
[ "$(grep -c 'gh project view' "$CALLS")" -eq 1 ] \
  || fail "board_create_many must resolve ONCE (view), got $(grep -c 'gh project view' "$CALLS")"
[ "$(grep -c 'gh project field-list' "$CALLS")" -eq 1 ] \
  || fail "board_create_many must resolve ONCE (field-list), got $(grep -c 'gh project field-list' "$CALLS")"
[ "$(grep -c 'gh project item-list' "$CALLS")" -eq 1 ] \
  || fail "board_create_many must list ONCE for the whole batch (GH #40), got $(grep -c 'gh project item-list' "$CALLS")"
grep -q 'gh project item-edit --id PVTI_item999 .* --single-select-option-id opt_backlog' "$CALLS" \
  || fail "board_create_many missing Backlog edit for #999"
grep -q 'gh project item-edit --id PVTI_item228 .* --single-select-option-id opt_backlog' "$CALLS" \
  || fail "board_create_many missing Backlog edit for #228"
echo "PASS: board_create_many adds N items with a single board resolve (GH #40)"

# --- board_repo -----------------------------------------------------------
[ "$(board_repo 3)" = "Towheads/stageFind" ]  || fail "board_repo 3 wrong"
[ "$(board_repo 4)" = "Towheads/foundation" ] || fail "board_repo 4 wrong"
if board_repo 9 >/dev/null 2>&1; then fail "board_repo should fail for an unknown board"; fi
echo "PASS: board_repo maps board numbers to repos"

# --- board_item_list (worklist.sh flow) -----------------------------------
: >"$CALLS"
out="$(board_item_list 3)"
[ "$(last_call)" = "gh project item-list 4 --owner Towheads --limit 500 --query -status:Done --format json" ] \
  || fail "board_item_list argv wrong: $(last_call)"
[ "$(grep -c '^gh ' "$CALLS")" -eq 1 ] || fail "board_item_list should make exactly ONE gh call"
printf '%s' "$out" | jq -e '.items | length == 3' >/dev/null || fail "board_item_list did not return the fixture items"
echo "PASS: board_item_list issues a single active-set item-list call"

# --- #168 regression guard: whole-board reads filter the Done tail ----------
# board 3 crossed 200 TOTAL items; `gh project item-list --limit N` only returns
# the first page, so an unfiltered read silently truncated the active slice. The
# fix filters to the active (non-Done) set server-side via `--query -status:Done`
# AND raises the page cap, both via knobs. Guard the filter, the cap, the escape
# hatch, and the fresh-path (board_create_many's index-wait) so a future edit
# can't quietly drop them and reintroduce the truncation.
: >"$CALLS"
board_item_list 3 >/dev/null
grep -q -- '--query -status:Done' "$CALLS" || fail "#168: whole-board read must filter -status:Done"
grep -q -- '--limit 500'         "$CALLS" || fail "#168: default page cap should be 500"

# escape hatch: BOARD_ITEM_QUERY="" fetches ALL items (no --query flag) for a
# future reverse-drift audit that genuinely needs the Done set.
: >"$CALLS"
BOARD_ITEM_QUERY='' board_item_list 3 >/dev/null
if grep -q -- '--query' "$CALLS"; then fail "#168: empty BOARD_ITEM_QUERY must omit --query"; fi
grep -q 'gh project item-list 4 --owner Towheads --limit 500 --format json' "$CALLS" \
  || fail "#168: empty-query argv wrong: $(last_call)"

# knob: BOARD_ITEM_LIMIT overrides the cap.
: >"$CALLS"
BOARD_ITEM_LIMIT=999 board_item_list 3 >/dev/null
grep -q -- '--limit 999' "$CALLS" || fail "#168: BOARD_ITEM_LIMIT must override the cap"

# the index-wait fresh path carries the same filter (just-added items are Backlog).
: >"$CALLS"
_board_item_list_fresh 3 >/dev/null
grep -q -- '--query -status:Done' "$CALLS" || fail "#168: _board_item_list_fresh must also filter -status:Done"
echo "PASS: whole-board reads filter the Done tail with a cap + escape hatch (GH #168)"

# --- board_resolve_item: single-issue resolve, NO whole-board item-list (GH #53) ---
# Resolves project id + fields + ONE issue's item via a targeted GraphQL query
# instead of `item-list --limit 200`. Must populate the SAME globals as
# board_resolve, reshaped to the item-list item form so every accessor works.
: >"$CALLS"
board_resolve_item 3 227
[ "$(grep -c '^gh ' "$CALLS")" -eq 3 ] \
  || fail "board_resolve_item should make exactly 3 gh calls (view+field-list+graphql), made $(grep -c '^gh ' "$CALLS")"
grep -q 'gh project view 4 --owner Towheads --format json'       "$CALLS" || fail "board_resolve_item missing project view"
grep -q 'gh project field-list 4 --owner Towheads --format json' "$CALLS" || fail "board_resolve_item missing field-list"
grep -q 'gh api graphql'                                        "$CALLS" || fail "board_resolve_item missing the single-issue graphql lookup"
[ "$(grep -c 'gh project item-list' "$CALLS")" -eq 0 ] \
  || fail "board_resolve_item must NOT pull the whole-board item-list (GH #53)"
# graphql passes the issue number as a typed Int var, and the repo from board_repo.
grep -q 'num=227' "$CALLS"        || fail "board_resolve_item must pass num=227 to graphql"
grep -q 'name=stageFind' "$CALLS" || fail "board_resolve_item must resolve the repo (name=stageFind) for board 3"
[ "$BOARD_PROJECT_ID" = "PVT_kwTESTPROJECT123" ] || fail "board_resolve_item BOARD_PROJECT_ID wrong: $BOARD_PROJECT_ID"
# Accessors resolve against the reshaped single item.
[ "$(board_item_id 227)" = "PVTI_item227" ]            || fail "board_resolve_item: item id for #227 wrong"
[ "$(board_item_title 227)" = "Some board item title" ] || fail "board_resolve_item: item title for #227 wrong"
[ "$(board_field_id "$BOARD_FIELD_STATUS")" = "PVTSSF_status" ] || fail "board_resolve_item: field-list not populated"
# Single-select / text / number field values flatten to the item-list keys.
printf '%s' "$BOARD_ITEMS_JSON" | jq -e '.items[0].status == "Ready"'                   >/dev/null || fail "board_resolve_item: Status didn't flatten to .status"
printf '%s' "$BOARD_ITEMS_JSON" | jq -e '.items[0]["host/Session"] == "hostX:sess1234"'  >/dev/null || fail "board_resolve_item: Host/Session didn't flatten to .[\"host/Session\"]"
printf '%s' "$BOARD_ITEMS_JSON" | jq -e '.items[0].seq == 12'                            >/dev/null || fail "board_resolve_item: Seq didn't flatten to .seq"
# The resolved item is a drop-in for a mutator with no further board read.
: >"$CALLS"
board_set_status "$(board_item_id 227)" "$BOARD_OPT_INPROGRESS"
[ "$(last_call)" = "gh project item-edit --id PVTI_item227 --project-id PVT_kwTESTPROJECT123 --field-id PVTSSF_status --single-select-option-id opt_inprogress" ] \
  || fail "board_resolve_item -> board_set_status argv wrong: $(last_call)"
echo "PASS: board_resolve_item resolves one issue via graphql (no whole-board list) and feeds the accessors+mutators"

# An issue that is on NO matching project resolves to an empty item set (so a
# caller's `[ -n "$(board_item_id N)" ]` guard fires "not on this board").
: >"$CALLS"
board_resolve_item 4 227   # fixture's nodes are projects 3 and 99 — none is 4
[ -z "$(board_item_id 227)" ] || fail "board_resolve_item: issue not on the target board must resolve to empty item id"
echo "PASS: board_resolve_item yields an empty item when the issue isn't on the target board"

# --- the seam: board_resolve_item routes through board_project_number() (foundation #330/#332) ---
# A board migrated into an org keeps its logical --board number but its gh project
# number differs. board_resolve_item's reverse-lookup filter `select(.project.number
# == $b)` AND its `gh project view/field-list` identifier MUST use the MAPPED number,
# not the logical board — else the filter silently matches nothing (the cross-owner
# [] symptom that motivated the org migration). Override the seam non-identity and
# assert the filter + argv follow it. The fixture carries a project-99 node
# (PVTI_other) distinct from the mapped node (PVTI_item227, project 4 — board 3's
# real org project post-#330). Save/restore the REAL mapping (not identity) so the
# downstream tests keep resolving #227 against its real project-4 fixture node.
: >"$CALLS"
_real_bpn="$(declare -f board_project_number)"   # save the real (post-#330) mapping
board_project_number() { echo 99; }              # override: logical board -> org project 99
board_resolve_item 3 227
[ "$(board_item_id 227)" = "PVTI_other" ] \
  || fail "board_resolve_item filter must compare board_project_number() (expected project-99 node PVTI_other, got '$(board_item_id 227)')"
grep -q 'gh project view 99 --owner Towheads --format json' "$CALLS" \
  || fail "board_resolve_item must pass the MAPPED project number (99) to gh project view, not the logical board"
eval "$_real_bpn"                                # restore the real mapping for the remaining tests
echo "PASS: board_resolve_item routes its filter + gh project calls through board_project_number()"

# --- board_capture_item: ride auto-add, make the explicit add a fallback (GH #53) ---
# Default seam: the issue already resolves on the board WITH a Status (the fixture
# gives #227 status "Ready") — i.e. auto-add already placed + statused it.
# board_capture_item must do nothing further: no item-add, no item-edit, and
# never the whole-board item-list.
: >"$CALLS"
board_capture_item 3 "https://github.com/Towheads/stageFind/issues/227" 227
[ "$(grep -c 'gh project item-add'  "$CALLS")" -eq 0 ] || fail "board_capture_item must NOT item-add when auto-add already placed the issue"
[ "$(grep -c 'gh project item-edit' "$CALLS")" -eq 0 ] || fail "board_capture_item must NOT re-set status on an already-statused item"
[ "$(grep -c 'gh project item-list' "$CALLS")" -eq 0 ] || fail "board_capture_item must use the single-item resolve, not the whole-board list"
echo "PASS: board_capture_item rides auto-add (no add, no whole-board list) when the issue is already placed"

# --- #223: whole-board reads drop PR-type cards -----------------------------
# GitHub's "Auto-add to project" workflow lands PRs as board cards; a merged PR's
# card orphans at Status (none) because the close→Done cascade fires on issue-close,
# not PR-merge. Both raw whole-board read exits — board_item_list (cached) and
# _board_item_list_fresh (always-live) — must filter PR cards out so BOARD_ITEMS_JSON
# is issues-only. This block redefines _board_gh to serve a list containing a PR card,
# so (like the create_on_board cases below) it runs AFTER every test using the default
# seam. BOARD_CACHE_TTL=0 forces a live read past the items cached by earlier tests.
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")  cat "$FIX/item_list_with_pr.json" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
out="$(BOARD_CACHE_TTL=0 board_item_list 3)"
printf '%s' "$out" | jq -e '[.items[]|select(.content.type=="PullRequest")]|length==0' >/dev/null \
  || fail "#223: board_item_list must drop PR-type cards"
printf '%s' "$out" | jq -e '(.items|length)==3 and (([.items[].content.number]|sort)==[227,228,999])' >/dev/null \
  || fail "#223: board_item_list must keep exactly the 3 issue cards"
: >"$CALLS"
out="$(_board_item_list_fresh 3)"
printf '%s' "$out" | jq -e '[.items[]|select(.content.type=="PullRequest")]|length==0' >/dev/null \
  || fail "#223: _board_item_list_fresh must also drop PR-type cards"
printf '%s' "$out" | jq -e '.items|length==3' >/dev/null \
  || fail "#223: _board_item_list_fresh must keep the 3 issue cards"
echo "PASS: whole-board reads drop PR-type cards (#223)"

# --- #224: whole-board reads sanitize control chars at the jq boundary ------
# A raw ASCII control char (0x00–0x1f) inside an item title/body is invalid in a
# JSON string value, so it breaks jq's parse — and the whole-board read is bulk, so
# ONE poisoned item takes down the entire list. This recurred because earlier fixes
# patched it per-call-site; the durable fix is _board_sanitize_control_chars, a
# shared pipe-stage applied at BOTH raw exits (board_item_list cached, and
# _board_item_list_fresh live) on the raw TEXT before any jq sees it. This block
# injects a raw 0x07 (BEL) into a title and asserts the bulk read still succeeds.
# It builds the poisoned fixture on the fly (a raw control char in a checked-in
# JSON file is fragile / editor-mangled). The byte is spliced into the SERIALIZED
# JSON text with perl — NOT via jq, which would emit the safe \uXXXX escape and
# leave the JSON valid. Splicing a raw 0x07 into a string value is exactly the
# invalid-JSON that breaks a downstream jq parse, which is the class #224 fixes.
POISONED_LIST="$(perl -pe 's/board item/board\x07item/' "$FIX/item_list.json")"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")  printf '%s\n' "$POISONED_LIST" ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
# Prove the boundary is poisoned without the sanitizer: feeding the raw text
# straight to jq (the pre-fix shape) MUST fail to parse.
if printf '%s\n' "$POISONED_LIST" | jq -e '.items|length' >/dev/null 2>&1; then
  fail "#224: test setup wrong — raw control char did not break a bare jq parse"
fi
: >"$CALLS"
out="$(BOARD_CACHE_TTL=0 board_item_list 3)" \
  || fail "#224: board_item_list must not error on a control char in an item title"
printf '%s' "$out" | jq -e '.items|length==3' >/dev/null \
  || fail "#224: board_item_list must return all 3 items after sanitizing control chars"
printf '%s' "$out" | jq -e 'any(.items[].content.title; . == "Some boarditem title")' >/dev/null \
  || fail "#224: board_item_list must strip the control char from the title"
: >"$CALLS"
out="$(_board_item_list_fresh 3)" \
  || fail "#224: _board_item_list_fresh must not error on a control char in an item title"
printf '%s' "$out" | jq -e '.items|length==3' >/dev/null \
  || fail "#224: _board_item_list_fresh must return all 3 items after sanitizing control chars"
echo "PASS: whole-board reads sanitize control chars at the jq boundary (#224)"

# --- board_create_on_board: retry until the added item is indexed (GH #387/#386) ---
# These cases redefine _board_gh to vary the item-list across calls, so they run
# AFTER every test that relies on the original (always-populated) seam above.
# Stub sleep so the retry backoff doesn't slow the suite.
sleep() { :; }

# Stateful seam: the FIRST item-list (inside board_resolve) returns no items —
# mimicking Projects-v2 not having indexed the just-added item yet — and the
# retry's item-list returns the populated fixture.
ILCOUNT="$(mktemp "${TMPDIR:-/tmp}/board-ilcount-XXXXXX")"
echo 0 >"$ILCOUNT"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")
      c=$(($(cat "$ILCOUNT") + 1)); echo "$c" >"$ILCOUNT"
      if [ "$c" -eq 1 ]; then echo '{"items":[],"totalCount":0}'; else cat "$FIX/item_list.json"; fi ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_create_on_board 3 "https://github.com/Towheads/stageFind/issues/999" 999
grep -q 'gh project item-edit --id PVTI_item999 .* --single-select-option-id opt_backlog' "$CALLS" \
  || fail "retry: Backlog must be set once the item indexes on a retry"
[ "$(grep -c 'gh project item-list' "$CALLS")" -eq 2 ] \
  || fail "retry: expected 2 item-list calls (resolve + 1 retry), got $(grep -c 'gh project item-list' "$CALLS")"
rm -f "$ILCOUNT"
echo "PASS: board_create_on_board retries the item-list until the item indexes, then sets Backlog"

# Item never indexes: warn on stderr, issue NO item-edit (no silent unstatused).
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")  echo '{"items":[],"totalCount":0}' ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
rc=0
# NB: capture stderr to a FILE, not via `err="$(... 2>&1)"` — a command
# substitution runs in a subshell, so a BOARD_UNLANDED_ISSUES assignment made
# inside board_create_on_board there would be invisible back in THIS shell
# once the subshell exits. Redirecting to a file keeps the call in-process so
# the global lands here, where the assertion below reads it.
ERRFILE="$(mktemp "${TMPDIR:-/tmp}/board-never-indexed-err-XXXXXX")"
board_create_on_board 3 "https://github.com/Towheads/stageFind/issues/999" 999 >/dev/null 2>"$ERRFILE" || rc=$?
err="$(cat "$ERRFILE")"; rm -f "$ERRFILE"
printf '%s' "$err" | grep -q "may be unstatused" \
  || fail "never-indexed: expected an 'unstatused' warning on stderr, got: $err"
[ "$(grep -c 'gh project item-edit' "$CALLS")" -eq 0 ] \
  || fail "never-indexed: must NOT issue an item-edit when the item never resolves"
# foundation #1226: a never-landed item is now a truthful non-zero return (a
# single item that fails is, by definition, the WHOLE batch failing — the
# total-failure code 2), not the old always-0 that let this print as success
# one line later in every caller.
[ "$rc" -eq 2 ] \
  || fail "never-indexed: board_create_on_board must return 2 (total failure) when the item never lands, got rc=$rc (#1226)"
[ "$BOARD_UNLANDED_ISSUES" = "999" ] \
  || fail "never-indexed: BOARD_UNLANDED_ISSUES must name the un-landed issue, got: '$BOARD_UNLANDED_ISSUES' (#1226)"
echo "PASS: board_create_on_board warns (no edit) and returns non-zero with BOARD_UNLANDED_ISSUES set when the added item never indexes (#1226)"

# --- board_create_on_board: widened index-lag retry budget (foundation #589) ---
# An item that only indexes on the 4th item-list call must STILL get Backlog set:
# the old 3-attempt / ~6s window would have dropped it unstatused (the 2026-06-21
# friction). Default budget is now 5, so the 4th-call index is inside the window.
SLOWCOUNT="$(mktemp "${TMPDIR:-/tmp}/board-slowcount-XXXXXX")"
echo 0 >"$SLOWCOUNT"
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "project item-list")
      c=$(($(cat "$SLOWCOUNT") + 1)); echo "$c" >"$SLOWCOUNT"
      # Empty until the 4th call (mimics slow Projects-v2 indexing), then populated.
      if [ "$c" -lt 4 ]; then echo '{"items":[],"totalCount":0}'; else cat "$FIX/item_list.json"; fi ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_create_on_board 3 "https://github.com/Towheads/stageFind/issues/999" 999
grep -q 'gh project item-edit --id PVTI_item999 .* --single-select-option-id opt_backlog' "$CALLS" \
  || fail "widened-budget: Backlog must be set for an item that indexes on the 4th attempt"
rm -f "$SLOWCOUNT"
echo "PASS: board_create_on_board's widened retry budget statuses an item that needs >3 attempts"

# --- board_capture_item: auto-add placed it UNSTATUSED -> ensure Backlog -------
# (sleep is already stubbed above.) The single-item resolve finds the item but it
# carries no Status value; board_capture_item must set Backlog, and still NOT
# item-add (it's already on the board).
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "api graphql")        printf '%s' '{"data":{"repository":{"issue":{"title":"Unstatused","projectItems":{"nodes":[{"id":"PVTI_item227","project":{"number":4},"fieldValues":{"nodes":[]}}]}}}}}' ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_capture_item 3 "https://github.com/Towheads/stageFind/issues/227" 227
[ "$(grep -c 'gh project item-add' "$CALLS")" -eq 0 ] || fail "board_capture_item (unstatused) must not item-add"
grep -q 'gh project item-edit --id PVTI_item227 .* --single-select-option-id opt_backlog' "$CALLS" \
  || fail "board_capture_item (unstatused) must set Backlog on the auto-added item"
echo "PASS: board_capture_item sets Backlog when auto-add placed the item unstatused"

# --- board_capture_item: auto-add NEVER fires -> fall back to the explicit add --
# api graphql always returns no project item; after the bounded poll the call must
# fall back to board_create_on_board (the explicit item-add path).
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       cat "$FIX/project_view.json" ;;
    "project field-list") cat "$FIX/field_list.json" ;;
    "api graphql")        printf '%s' '{"data":{"repository":{"issue":{"title":"Not added","projectItems":{"nodes":[]}}}}}' ;;
    "project item-list")  cat "$FIX/item_list.json" ;;
    "project item-add")   : ;;
    "project item-edit")  : ;;
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}
: >"$CALLS"
board_capture_item 3 "https://github.com/Towheads/stageFind/issues/999" 999
grep -q 'gh project item-add 4 --owner Towheads --url https://github.com/Towheads/stageFind/issues/999' "$CALLS" \
  || fail "board_capture_item must fall back to the explicit item-add when auto-add never fires"
echo "PASS: board_capture_item falls back to the explicit add when auto-add never fires"

echo
echo "PASS: all board.sh fixture-replay assertions passed"
