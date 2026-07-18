#!/usr/bin/env bash
#
# Tests for board.sh's board_parent_issue accessor (foundation #159) — the read
# that lets /next discriminate an epic's sub-issue from a directly-workable
# singleton. The REST issue object has NO `.parent` key; the parent link is
# `.parent_issue_url` (".../issues/<epic>"). Reading the wrong field (`.parent`)
# resolves empty for EVERY issue, so every epic child is mis-classified as a
# parentless singleton — the bug this accessor exists to prevent. The accessor
# must print the trailing parent number for a child and NOTHING for a singleton
# (absent `.parent_issue_url`), with empty output usable as a gate.
#
# Replays the `_board_gh` seam like test_blocked_by.sh — no network, no PATH
# shim. The payloads are inlined (no fixture file) so the contract is readable
# in one place.
#
# The `_board_gh` overrides below are invoked indirectly (the library calls
# `_board_gh`, which this test redefines) and are redefined mid-file per case —
# so shellcheck's "never invoked" / "unreachable" checks are false positives.
# Disabled file-wide, like the sibling replay tests.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/../lib" && pwd)"

# shellcheck source=scripts/lib/board.sh
source "$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1. a real sub-issue: print the parent epic number ----------------------
# The whole point: a child must resolve to its epic. Reading `.parent` (the bug)
# would return empty here and mis-classify #139 as a singleton.
_board_gh() {
  cat <<'JSON'
{
  "number": 139,
  "parent_issue_url": "https://api.github.com/repos/Towheads/foundation/issues/145",
  "sub_issues_summary": { "total": 0 }
}
JSON
}
out="$(board_parent_issue 4 139)"
[ "$out" = "145" ] || fail "a sub-issue must resolve to its epic 145, got: [$out]"

# --- 2. a singleton (no parent_issue_url): empty output = no parent ----------
_board_gh() {
  cat <<'JSON'
{
  "number": 149,
  "sub_issues_summary": { "total": 0 }
}
JSON
}
out="$(board_parent_issue 4 149)"
[ -z "$out" ] || fail "a singleton must print nothing, got: [$out]"

# --- 3. an EPIC (has children, no parent): still a parentless singleton ------
# sub_issues_summary describes the issue's OWN children — it must NOT be mistaken
# for a parent link. An epic has no parent of its own, so output is empty.
_board_gh() {
  cat <<'JSON'
{
  "number": 145,
  "sub_issues_summary": { "total": 2 }
}
JSON
}
out="$(board_parent_issue 4 145)"
[ -z "$out" ] || fail "an epic has no parent of its own, expected empty, got: [$out]"

# --- 4. emptiness is a usable gate: -n / -z on the result -------------------
_board_gh() { echo '{"number":149}'; }
if [ -n "$(board_parent_issue 4 149)" ]; then fail "a singleton must test as -z"; fi
_board_gh() { echo '{"number":139,"parent_issue_url":"https://api.github.com/repos/Towheads/foundation/issues/145"}'; }
if [ -z "$(board_parent_issue 4 139)" ]; then fail "a sub-issue must test as -n"; fi

echo "PASS: board_parent_issue resolves a child to its epic, empty for a singleton/epic (foundation #159)"
