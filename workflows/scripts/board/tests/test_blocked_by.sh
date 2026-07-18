#!/usr/bin/env bash
#
# Tests for board.sh's board_blocked_by_open accessor (foundation #137) — the
# read that lets /triage + /next honor GitHub native issue dependencies
# (blocked_by). The accessor reads the per-issue REST dependencies endpoint and
# must print ONLY the OPEN blockers (a closed blocker no longer gates), one
# number per line, with empty output meaning "not blocked".
#
# Replays the `_board_gh` seam like test_board_replay.sh — no network, no PATH
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

# --- 1. open + closed blockers: only the OPEN number is printed -------------
# A wrong-direction filter (printing closed blockers, or all) is the bug this
# guards: a closed blocker has been resolved and no longer gates the item.
_board_gh() {
  cat <<'JSON'
[
  { "number": 517, "state": "open",   "title": "Promote vision eval axis to gating" },
  { "number": 400, "state": "closed", "title": "Some already-resolved blocker" }
]
JSON
}
out="$(board_blocked_by_open 3 261)"
[ "$out" = "517" ] || fail "expected only the open blocker 517, got: [$out]"

# --- 2. no blockers (empty array): empty output = not blocked ---------------
_board_gh() { echo '[]'; }
out="$(board_blocked_by_open 3 437)"
[ -z "$out" ] || fail "an unblocked issue must print nothing, got: [$out]"

# --- 3. multiple open blockers: all printed, one per line ------------------
_board_gh() {
  cat <<'JSON'
[
  { "number": 517, "state": "open" },
  { "number": 600, "state": "open" }
]
JSON
}
out="$(board_blocked_by_open 3 261)"
[ "$out" = "517
600" ] || fail "expected both open blockers (517,600), got: [$out]"

# --- 4. emptiness is a usable gate: -n on the result ----------------------
_board_gh() { echo '[]'; }
if [ -n "$(board_blocked_by_open 3 437)" ]; then fail "unblocked must test as -z"; fi
_board_gh() { echo '[{"number":517,"state":"open"}]'; }
if [ -z "$(board_blocked_by_open 3 261)" ]; then fail "blocked must test as -n"; fi

echo "PASS: board_blocked_by_open prints only OPEN blockers (one per line), empty when unblocked (foundation #137)"
