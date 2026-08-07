#!/usr/bin/env bash
# test_board_sync_drift_check.sh — unit tests for board-sync-drift-check.sh.
#
# Verifies the consumer-side drift gate independently of any live stageFind
# checkout: it builds a synthetic synced-dir + manifest in a temp dir and
# asserts fresh→exit0, stale→exit1, missing-manifest→exit2,
# partial-sync (missing listed file)→exit2, and empty/absent expected SHA→exit2.
set -euo pipefail

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_CHECK="$HERE/../../board-sync-drift-check.sh"

fail=0
# assert_rc <expected> <actual> <description>
assert_rc() {
	if [ "$2" = "$1" ]; then
		echo "  ✓ $3 (exit $1)"
	else
		echo "  ✗ $3: expected $1, got $2"
		fail=1
	fi
}

# Run the drift-check, capture its exit code without tripping set -e.
run_rc() {
	local rc=0
	"$DRIFT_CHECK" "$@" >/dev/null 2>&1 || rc=$?
	echo "$rc"
}

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

make_synced_dir() {
	# $1 = sha to stamp. Creates a temp synced dir with a manifest listing one
	# real file. Echoes the dir path.
	local sha="$1"
	local d
	d="$(mktemp -d)"
	mkdir -p "$d/lib"
	echo "# board.sh" > "$d/lib/board.sh"
	{
		echo "# generated"
		echo "sha $sha"
		echo "file lib/board.sh"
	} > "$d/board-sync-manifest"
	echo "$d"
}

# 1. Fresh: stamped SHA == expected -> exit 0.
d="$(make_synced_dir "$SHA_A")"
rc="$(run_rc "$d" "$SHA_A")"
assert_rc 0 "$rc" "fresh copy passes"
rm -rf "$d"

# 2. Stale: stamped SHA != expected -> exit 1.
d="$(make_synced_dir "$SHA_A")"
rc="$(run_rc "$d" "$SHA_B")"
assert_rc 1 "$rc" "stale copy fails"
rm -rf "$d"

# 3. Missing manifest -> exit 2.
d="$(mktemp -d)"
rc="$(run_rc "$d" "$SHA_A")"
assert_rc 2 "$rc" "missing manifest fails loud"
rm -rf "$d"

# 4. Partial sync: manifest lists a file that is absent -> exit 2.
d="$(make_synced_dir "$SHA_A")"
rm -f "$d/lib/board.sh"
rc="$(run_rc "$d" "$SHA_A")"
assert_rc 2 "$rc" "partial sync (missing file) fails loud"
rm -rf "$d"

# 5. Empty expected SHA -> exit 2 (never silently pass on an absent reference).
d="$(make_synced_dir "$SHA_A")"
rc="$(run_rc "$d" "")"
assert_rc 2 "$rc" "empty expected SHA refuses to pass"
rm -rf "$d"

# 6. Manifest with no sha line -> exit 2.
d="$(mktemp -d)"
{ echo "# no sha here"; echo "file lib/board.sh"; } > "$d/board-sync-manifest"
mkdir -p "$d/lib"; echo x > "$d/lib/board.sh"
rc="$(run_rc "$d" "$SHA_A")"
assert_rc 2 "$rc" "manifest without sha line fails loud"
rm -rf "$d"

# 7. Wrong argument count -> exit 2 (usage).
rc="$(run_rc "$SHA_A")"
assert_rc 2 "$rc" "missing args yields usage"

if [ "$fail" -ne 0 ]; then
	echo "FAIL: test_board_sync_drift_check.sh"
	exit 1
fi
echo "PASS: test_board_sync_drift_check.sh"
