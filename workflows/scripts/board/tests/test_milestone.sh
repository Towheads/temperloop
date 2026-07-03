#!/usr/bin/env bash
#
# Fixture-replay tests for scripts/milestone.sh. Zero network: we SOURCE
# milestone.sh (its execute-guard suppresses the auto-run when sourced) and
# override board.sh's `_board_gh` seam to record argv + replay canned milestone
# JSON, then drive milestone_activate / milestone_deactivate / milestone_list and
# assert the right milestone-description writes fire (and only those).
#
# The new model (foundation #206): a milestone is "active" iff its GitHub
# DESCRIPTION carries the machine-owned `<!-- triage:active -->` marker. activate
# ADDS it, deactivate REMOVES it (both idempotent), list flags the active ones.
# The old per-item `park` / `Status=Parked` flip is gone.
#
# The `_board_gh` overrides are invoked indirectly (the library calls _board_gh,
# which the test redefines), so shellcheck's "never invoked" check is a false
# positive — disabled file-wide, as in test_board_replay.sh.
# shellcheck disable=SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"

# Source the shared replay component for _fake_gh_log_argv (argv-log-v1).
# shellcheck source=scripts/tests/fixtures/fake_gh.sh
FAKE_GH_SOURCE=1 source "$FIX/fake_gh.sh"

# Isolate + disable the on-disk read cache so every case sees the canned data.
export BOARD_CACHE_TTL=0
BOARD_CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/milestone-cache-XXXXXX")"
export BOARD_CACHE_DIR

# shellcheck source=scripts/milestone.sh
source "$SCRIPTS_DIR/milestone.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

CALLS="$(mktemp "${TMPDIR:-/tmp}/milestone-calls-XXXXXX")"
# The PATCH description is captured to a FILE (not a var) because cases drive the
# verbs inside a `$(...)` subshell, where a variable assignment would be lost.
PATCH_DESC_FILE="$(mktemp "${TMPDIR:-/tmp}/milestone-patch-XXXXXX")"
cleanup() { rm -rf "$CALLS" "$PATCH_DESC_FILE" "$BOARD_CACHE_DIR"; }
trap cleanup EXIT

# Per-case milestone fixture: a JSON array of {title, number, description} the
# stub serves for every `gh api repos/.../milestones...` GET (state=open|all).
MILESTONES_JSON='[]'

# Read the description body of the last captured PATCH.
last_patch_desc() { cat "$PATCH_DESC_FILE"; }

_board_gh() {
  _fake_gh_log_argv "$@" >>"$CALLS"
  case "$1 $2" in
    "project view")       echo '{"id":"PVT_TESTPROJECT"}' ;;
    "api --method")
      # PATCH repos/<owner>/<repo>/milestones/<n> -f description=...
      local a
      for a in "$@"; do
        case "$a" in description=*) printf '%s' "${a#description=}" >"$PATCH_DESC_FILE" ;; esac
      done
      : ;;
    "api graphql")        : ;;
    *)
      # Any other `api <path>` is a milestones GET (state=open or state=all).
      case "$2" in
        repos/*/milestones*) printf '%s' "$MILESTONES_JSON" ;;
        *) echo "test _board_gh: unhandled '$1 $2'" >&2; return 3 ;;
      esac ;;
  esac
}

MARKER='<!-- triage:active -->'

# --- milestone_activate: ADDS the marker to an inactive milestone ----------------
MILESTONES_JSON='[
  {"title":"Production Live","number":7,"description":"Ship to prod."},
  {"title":"v2","number":8,"description":""}
]'
: >"$CALLS"; : >"$PATCH_DESC_FILE"
OUT="$(milestone_activate 3 "Production Live")"
grep -q 'gh api --method PATCH repos/Towheads/stageFind/milestones/7' "$CALLS" \
  || fail "activate: expected a PATCH to milestone #7\n$(cat "$CALLS")"
DESC="$(last_patch_desc)"
case "$DESC" in
  *"$MARKER"*) ;;
  *) fail "activate: written description must contain the marker, got: '$DESC'" ;;
esac
case "$DESC" in
  *"Ship to prod."*) ;;
  *) fail "activate: must PRESERVE the existing description, got: '$DESC'" ;;
esac
printf '%s' "$OUT" | grep -q "Activated milestone 'Production Live'" || fail "activate: expected a confirmation\n$OUT"
echo "PASS: milestone_activate adds the triage:active marker, preserving existing text"

# Empty existing description -> description becomes just the marker.
: >"$CALLS"; : >"$PATCH_DESC_FILE"
milestone_activate 3 "v2" >/dev/null
DESC="$(last_patch_desc)"
[ "$DESC" = "$MARKER" ] || fail "activate(empty desc): description should be exactly the marker, got: '$DESC'"
echo "PASS: milestone_activate on an empty description writes just the marker"

# --- milestone_activate is idempotent: marker already present -> no PATCH --------
MILESTONES_JSON='[
  {"title":"Production Live","number":7,"description":"Ship to prod.\n<!-- triage:active -->"}
]'
: >"$CALLS"
milestone_activate 3 "Production Live" >/dev/null
grep -q 'gh api --method PATCH' "$CALLS" && fail "activate(idempotent): must NOT PATCH an already-active milestone\n$(cat "$CALLS")"
echo "PASS: milestone_activate is idempotent — no write when already active"

# --- milestone_deactivate: REMOVES the marker -----------------------------------
MILESTONES_JSON='[
  {"title":"Production Live","number":7,"description":"Ship to prod.\n<!-- triage:active -->"}
]'
: >"$CALLS"; : >"$PATCH_DESC_FILE"
OUT="$(milestone_deactivate 3 "Production Live")"
grep -q 'gh api --method PATCH repos/Towheads/stageFind/milestones/7' "$CALLS" \
  || fail "deactivate: expected a PATCH to milestone #7\n$(cat "$CALLS")"
DESC="$(last_patch_desc)"
case "$DESC" in
  *"$MARKER"*) fail "deactivate: written description must NOT contain the marker, got: '$DESC'" ;;
esac
case "$DESC" in
  *"Ship to prod."*) ;;
  *) fail "deactivate: must preserve the rest of the description, got: '$DESC'" ;;
esac
printf '%s' "$OUT" | grep -q "Deactivated milestone 'Production Live'" || fail "deactivate: expected a confirmation\n$OUT"
echo "PASS: milestone_deactivate removes the marker, preserving the rest"

# --- milestone_deactivate is idempotent: no marker -> no PATCH ------------------
MILESTONES_JSON='[
  {"title":"v2","number":8,"description":"No marker here."}
]'
: >"$CALLS"
milestone_deactivate 3 "v2" >/dev/null
grep -q 'gh api --method PATCH' "$CALLS" && fail "deactivate(idempotent): must NOT PATCH an already-inactive milestone\n$(cat "$CALLS")"
echo "PASS: milestone_deactivate is idempotent — no write when already inactive"

# --- milestone_list: distinguishes active vs inactive milestones ----------------
MILESTONES_JSON='[
  {"title":"Production Live","number":7,"description":"Ship.\n<!-- triage:active -->"},
  {"title":"v2","number":8,"description":"Future work."},
  {"title":"hardening","number":9,"description":"<!-- triage:active -->"}
]'
: >"$CALLS"
OUT="$(milestone_list 3)"
printf '%s' "$OUT" | grep -q "Production Live.*active" || fail "list: Production Live should be flagged active\n$OUT"
printf '%s' "$OUT" | grep -q "hardening.*active"       || fail "list: hardening should be flagged active\n$OUT"
printf '%s' "$OUT" | grep -Eq '○ v2' || fail "list: v2 should be shown as inactive\n$OUT"
# v2 must not be in the active group.
printf '%s' "$OUT" | grep -q "v2.*active" && fail "list: v2 (no marker) must NOT be flagged active\n$OUT"
echo "PASS: milestone_list flags active milestones and shows inactive ones plainly"

# --- park is gone: the subcommand no longer dispatches --------------------------
if milestone_main park 601 "Production Live" --board 3 >/dev/null 2>&1; then
  fail "park: the removed subcommand must not succeed"
fi
echo "PASS: the park subcommand is removed (rejected as unknown)"

echo
echo "PASS: all milestone.sh fixture-replay assertions passed"
