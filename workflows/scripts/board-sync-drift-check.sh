#!/usr/bin/env bash
# board-sync-drift-check.sh — fail loud when a consumer's vendored board toolkit
# has drifted from foundation.
#
# The board toolkit is push-synced into consumer repos by foundation's
# `make sync-stagefind-board`, which writes a single `board-sync-manifest` file
# stamped with the pinned foundation commit SHA (the identity carrier). A stale
# consumer copy otherwise fails silently at runtime (the #232 failure class).
# This check, run inside a consumer's CI `checks` job, compares the stamped SHA
# against an expected SHA and exits non-zero on drift — converting a silent
# runtime failure into a loud build failure.
#
# Single-manifest identity (arch-review constraint, foundation #255): the SHA is
# read from ONE synced manifest, never spot-checked from a per-file banner — so a
# partially-completed sync that left different SHAs in different files cannot
# false-green. The manifest also pins the synced file list, so a missing synced
# file is drift too.
#
# Usage:
#   board-sync-drift-check.sh <synced-scripts-dir> <expected-sha>
#
#   <synced-scripts-dir>  Directory holding the board-sync-manifest and the
#                         vendored toolkit (the consumer's scripts/ dir). The
#                         manifest's `file <path>` lines are relative to THIS
#                         directory.
#   <expected-sha>        The foundation SHA the consumer expects to be synced
#                         to. In CI this is the freshly fetched foundation
#                         origin/main HEAD (the comparison target must be
#                         EXPLICIT — a check whose reference is absent must fail,
#                         not silently pass).
#
# Exits:
#   0  fresh — manifest SHA matches expected AND every listed file is present.
#   1  drift — manifest SHA differs from expected.
#   2  usage / missing manifest / missing synced file (treated as drift: a
#      missing reference is worse than no check, so it fails loud).
set -euo pipefail

MANIFEST_NAME="board-sync-manifest"

usage() {
	echo "usage: $(basename "$0") <synced-scripts-dir> <expected-sha>" >&2
	exit 2
}

[ "$#" -eq 2 ] || usage

synced_dir="$1"
expected_sha="$2"

[ -n "$expected_sha" ] || { echo "drift-check: empty expected SHA — refusing to pass" >&2; exit 2; }

manifest="$synced_dir/$MANIFEST_NAME"
if [ ! -f "$manifest" ]; then
	echo "drift-check: FAIL — no $MANIFEST_NAME in $synced_dir (toolkit not synced, or pre-manifest copy)" >&2
	exit 2
fi

# Manifest format (line-oriented, comment-tolerant):
#   sha <40-hex>
#   file scripts/<relpath>
# Read the stamped SHA and the pinned file list.
stamped_sha=""
missing=0
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		'#'*|'') continue ;;
		sha\ *)  stamped_sha="${line#sha }" ;;
		file\ *)
			rel="${line#file }"
			if [ ! -f "$synced_dir/$rel" ]; then
				echo "drift-check: FAIL — manifest lists $rel but it is missing under $synced_dir" >&2
				missing=1
			fi
			;;
	esac
done < "$manifest"

if [ -z "$stamped_sha" ]; then
	echo "drift-check: FAIL — $MANIFEST_NAME carries no 'sha <...>' line" >&2
	exit 2
fi

if [ "$missing" -ne 0 ]; then
	echo "drift-check: FAIL — vendored toolkit is incomplete (partial sync)" >&2
	exit 2
fi

if [ "$stamped_sha" != "$expected_sha" ]; then
	echo "drift-check: FAIL — vendored board toolkit is STALE." >&2
	echo "  stamped (synced):  $stamped_sha" >&2
	echo "  expected (foundation): $expected_sha" >&2
	echo "  Re-sync from foundation: make sync-stagefind-board" >&2
	exit 1
fi

echo "drift-check: OK — vendored board toolkit matches foundation $expected_sha"
exit 0
