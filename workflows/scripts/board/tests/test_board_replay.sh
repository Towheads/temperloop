#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/lib/board.sh's BACKEND-AGNOSTIC surface —
# the functions that route over plain REST (`gh api repos/…`, `gh issue edit`)
# rather than through the Projects-v2 `gh project …` / `gh api graphql` calls.
# Uses the same `_board_gh` override seam as the rest of this suite family (the
# board adapter's analogue of lib/claim_marker.sh's `_claim_marker_tmux` test
# seam): source the library, override `_board_gh` to record argv + emit canned
# JSON, and assert each accessor resolves the right values and each mutation
# issues the right gh argv.
#
# SCOPE (temperloop#524 epic, `retire-projects-arm-tests` item): this file
# used to also drive board.sh's Projects-v2 GraphQL arm (board_resolve,
# board_set_status, board_stamp, board_set_number, board_create_many,
# board_resolve_item, board_capture_item, board_item_list, and the PVTI_*
# item-id write path generally) against the `project_view.json` /
# `field_list.json` / `item_list.json` / `item_list_with_pr.json` /
# `issue_project_item.json` fixtures. ADR 0004 deprecated the Projects-v2 arm
# in v0.15.0 and ten releases of soak have passed with every registered board
# on the issues-only backend (epic #524) — that coverage is retired here,
# ordered deliberately BEFORE the library excision itself (a later #524 item)
# so removing test coverage can never fail CI while the arm is still live.
# lib/board.sh is UNCHANGED by this item: the Projects-v2 arm still works,
# it is merely no longer asserted by this file.
#
# What remains here are the functions that were never Projects-v2-specific to
# begin with — they route entirely over REST regardless of a board's
# `backend` axis (board.sh's own comments call these out: "REST, NOT
# Projects-v2 GraphQL"): board_repo (pure config lookup, no gh call),
# board_set_milestone, board_active_milestones, and
# board_set_milestone_description. The issues-only backend's OWN dedicated
# coverage (board_resolve / board_set_status / board_stamp / board_item_list
# etc. against an ISSUE_* item id) lives in test_issues_backend.sh and
# test_issues_claim_edges.sh, not here — this file only ever pinned the
# Projects-v2 branch of those dispatchers.
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
# shellcheck disable=SC1091
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$LIB_DIR/board.sh"

# The cross-process read cache (GH #93) and the pre-flight GraphQL budget guard
# (GH #156) are both Projects-v2-only concerns (their own coverage lived in the
# now-deleted test_board_cache.sh) — disabled/isolated here purely so a stray
# board.sh internal never touches a real session's /tmp state.
export BOARD_CACHE_TTL=0
export BOARD_BUDGET_GUARD_THRESHOLD=0
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/board-replay-cache-XXXXXX")"
export BOARD_CACHE_DIR

fail() { echo "FAIL: $1" >&2; exit 1; }

CALLS="$(mktemp "${TMPDIR:-/tmp}/board-replay-XXXXXX")"
cleanup() { rm -rf "$CALLS" "$BOARD_CACHE_DIR"; }
trap cleanup EXIT

# Minimal seam: the only backend-agnostic write this file still exercises is
# board_set_milestone's `gh issue edit … --milestone` (a plain repo-level REST
# write, not a Projects-v2 item-edit). Every other kept function
# (board_active_milestones / board_set_milestone_description) defines its own
# self-contained `_board_gh` override inline below.
_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "issue edit") : ;;   # write no-op, already logged above
    *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
  esac
}

last_call() { tail -n1 "$CALLS"; }

# --- board_repo -------------------------------------------------------------
[ "$(board_repo 3)" = "Towheads/stageFind" ]  || fail "board_repo 3 wrong"
[ "$(board_repo 4)" = "Towheads/foundation" ] || fail "board_repo 4 wrong"
if board_repo 9 >/dev/null 2>&1; then fail "board_repo should fail for an unknown board"; fi
echo "PASS: board_repo maps board numbers to repos"

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

echo
echo "PASS: all board.sh backend-agnostic (REST) fixture-replay assertions passed"
