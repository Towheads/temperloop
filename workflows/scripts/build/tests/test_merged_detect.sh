#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/lib/merged-detect.sh — the merge-queue
# -safe merged-detection helper (#171). Board-toolkit fixture style: a
# throwaway real-git repo in a tmpdir, zero network — `_merged_detect_gh` is
# overridden after sourcing to stand in for the real `gh` binary (same seam
# style as gate.sh's `_gate_gh` / board.sh's `_board_gh`).
#
# Covers:
#   - gh reports MERGED → true, even when the branch tip is NOT an ancestor
#     of origin/main (squash/rebase/merge-queue topology — the exact case
#     the old ancestor-only test gets wrong)
#   - gh reports OPEN / CLOSED → false
#   - gh errors (offline/unauthenticated/rate-limited) → falls back to the
#     local patch-equivalence heuristic:
#       - a squash-equivalent commit present on origin/main → true
#       - a genuinely unmerged branch → false
#   - gh error AND no local equivalent (fully offline, nothing to fall back
#     on) → fail-open false, exit 0 (never aborts the caller)
#   - caller misuse (missing repo-root or branch) → return 2, nothing printed
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/merged-detect.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# shellcheck source=../lib/merged-detect.sh
source "$SCRIPT"

# Fixture: an "upstream" with a main branch, cloned so origin/main exists —
# the same shape a real checkout has.
git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init
git clone -q "$TMP/upstream" "$TMP/repo"
REPO="$(cd "$TMP/repo" && pwd -P)"

# A branch with real work, diverged from main at the current tip.
git -C "$REPO" checkout -q -b feature-a
printf 'line one\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m "feature-a: add a.txt"
printf 'line two\n' >> "$REPO/a.txt"
git -C "$REPO" commit -qa -m "feature-a: extend a.txt"
git -C "$REPO" checkout -q main

# --- gh reports MERGED → true, even though feature-a is NOT an ancestor of --
# --- origin/main (simulates squash/rebase/merge-queue topology) ------------
# Advance origin/main with an UNRELATED commit so feature-a's tip is
# provably not an ancestor — the exact case the ancestor-only test misreads.
git -C "$TMP/upstream" commit -q --allow-empty -m "unrelated main advance"
git -C "$REPO" fetch -q origin main
git -C "$REPO" merge-base --is-ancestor feature-a origin/main \
  && fail "test setup bug: feature-a must NOT be an ancestor of origin/main"

# _merged_detect_gh stands in for `gh pr view <branch> --json state --jq
# .state` — which itself prints the bare filtered value (e.g. "MERGED"), not
# a JSON object — so the mock echoes that same bare shape.
_merged_detect_gh() { echo "MERGED"; }
out="$(merged_detect_is_merged "$REPO" feature-a)"
rc=$?
[ "$rc" -eq 0 ] || fail "gh MERGED path: expected exit 0 (got $rc)"
[ "$out" = "true" ] || fail "gh MERGED path: expected 'true' (got: $out)"
echo "PASS: gh reports MERGED -> true, even when branch tip is not an ancestor of origin/main"

# --- gh reports OPEN / CLOSED → false ---------------------------------------
_merged_detect_gh() { echo "OPEN"; }
out="$(merged_detect_is_merged "$REPO" feature-a)"
[ "$out" = "false" ] || fail "gh OPEN path: expected 'false' (got: $out)"

_merged_detect_gh() { echo "CLOSED"; }
out="$(merged_detect_is_merged "$REPO" feature-a)"
[ "$out" = "false" ] || fail "gh CLOSED path: expected 'false' (got: $out)"
echo "PASS: gh reports OPEN/CLOSED -> false"

# --- gh errors, but a squash-equivalent commit already exists on main ------
# Land the exact same cumulative diff feature-a introduces as ONE new commit
# on origin/main (what a squash merge produces) — origin/main has moved
# further ahead too, proving the heuristic survives that.
git -C "$TMP/upstream" checkout -q main
printf 'line one\nline two\n' > "$TMP/upstream/a.txt"
git -C "$TMP/upstream" add a.txt
git -C "$TMP/upstream" commit -q -m "feature-a (#42) squash-merged"
git -C "$TMP/upstream" commit -q --allow-empty -m "main advances again after the squash"
git -C "$REPO" fetch -q origin main

_merged_detect_gh() { return 1; }   # simulates gh unavailable / offline / unauthenticated
out="$(merged_detect_is_merged "$REPO" feature-a)"
rc=$?
[ "$rc" -eq 0 ] || fail "gh-error + squash-equivalent path: expected exit 0 (got $rc)"
[ "$out" = "true" ] || fail "gh-error + squash-equivalent path: expected 'true' (got: $out)"
echo "PASS: gh error falls back to the patch-equivalence heuristic -> true for a squash-merged branch"

# --- gh errors AND the branch is genuinely unmerged → fail-open false ------
git -C "$REPO" checkout -q -b feature-b
printf 'never landed\n' > "$REPO/b.txt"
git -C "$REPO" add b.txt
git -C "$REPO" commit -q -m "feature-b: unlanded work"
git -C "$REPO" checkout -q main

_merged_detect_gh() { return 1; }   # gh unavailable, no network
out="$(merged_detect_is_merged "$REPO" feature-b)"
rc=$?
[ "$rc" -eq 0 ] || fail "gh-error + unmerged path: expected exit 0, not an abort (got $rc)"
[ "$out" = "false" ] || fail "gh-error + unmerged path: expected fail-open 'false' (got: $out)"
echo "PASS: gh error + genuinely unmerged branch -> fail-open false, exit 0 (never aborts the caller)"

# --- caller misuse: missing args -> return 2, nothing printed --------------
rc=0; out="$(merged_detect_is_merged "" feature-a 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "missing repo-root: expected return 2 (got $rc)"
[ -z "$out" ] || fail "missing repo-root: expected no stdout (got: $out)"

rc=0; out="$(merged_detect_is_merged "$REPO" "" 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "missing branch: expected return 2 (got $rc)"
[ -z "$out" ] || fail "missing branch: expected no stdout (got: $out)"
echo "PASS: caller misuse (missing repo-root or branch) -> return 2, nothing printed"

echo "ALL PASS: test_merged_detect.sh"
