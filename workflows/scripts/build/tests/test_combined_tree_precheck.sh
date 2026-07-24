#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/combined-tree-precheck.sh — the Step-4
# level-merge-gate UNION check of /build (temperloop#865).
#
# Unlike test_gate.sh (which mocks the GitHub API seam and never touches real
# git — gate.sh is network-pure per temperloop#242), this check IS local-git by
# nature: it builds a throwaway worktree and merges real branches. So this test
# is a REAL-GIT integration test — it constructs a scratch repository with
# fixture branches in a temp dir, invokes the script as a subprocess, and
# asserts on the structured JSON + exit code. The gate suite is injected via the
# COMBINED_TREE_SUITE_CMD seam as a SELF-CONTAINED synthetic gate: it fails iff
# BOTH a `GATE` marker file (from the "adds a gate" branch) AND a `SCANNED` file
# (from the "adds files it scans" branch) are present in the merged tree — the
# exact green-alone / red-combined shape the retro's collisions took (F#847).
#
# Covers:
#   - SKIP: fewer than two branches → no union check (single-PR levels, #3)
#   - CLEAN: two disjoint branches that don't co-trigger the gate → CLEAN (exit 0)
#   - GATE_FAILED: the synthetic collision (gate branch + scanned branch merge
#     clean textually but fail the suite together) → GATE_FAILED (exit 4),
#     caught LOCALLY, pre-queue (acceptance #2)
#   - CONFLICT: two branches that edit the same line → CONFLICT (exit 3),
#     naming the offending branch, suite never run
#   - ERROR: a non-existent branch ref → clean ERROR (exit 1), no half-built tree
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../combined-tree-precheck.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Self-contained synthetic gate: red iff the merged tree has BOTH marker files.
# Runs with cwd == the merged worktree (the script's contract).
SUITE_CMD='bash -c '"'"'if [ -f GATE ] && [ -f SCANNED ]; then echo "COLLISION: gate + scanned file both present"; exit 1; fi; exit 0'"'"''

# --- scratch repo with fixture branches --------------------------------------
REPO="$(mktemp -d "${TMPDIR:-/tmp}/ctp-repo.XXXXXX")"
cleanup() { rm -rf "$REPO"; }
trap cleanup EXIT

git -c init.defaultBranch=main init --quiet "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name  "Test"
# Base commit on main: a shared file every branch descends from.
printf 'base\n' > "$REPO/README.md"
printf 'line1\nline2\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A
git -C "$REPO" commit --quiet -m "base"

# add-gate: drops a GATE marker (models "a branch adds a new gate").
git -C "$REPO" checkout --quiet -b add-gate
printf 'gate\n' > "$REPO/GATE"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add gate"

# add-scanned: drops a SCANNED file the gate would flag (disjoint path).
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-scanned
printf 'scanned\n' > "$REPO/SCANNED"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add scanned file"

# add-foo / add-bar: two genuinely disjoint, non-colliding branches.
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-foo
printf 'foo\n' > "$REPO/foo.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add foo"

git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b add-bar
printf 'bar\n' > "$REPO/bar.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "add bar"

# conflict-a / conflict-b: both rewrite the SAME line of shared.txt.
git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b conflict-a
printf 'line1\nAAA\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "conflict a"

git -C "$REPO" checkout --quiet main
git -C "$REPO" checkout --quiet -b conflict-b
printf 'line1\nBBB\nline3\n' > "$REPO/shared.txt"
git -C "$REPO" add -A && git -C "$REPO" commit --quiet -m "conflict b"

git -C "$REPO" checkout --quiet main

# Runner: invoke the script, capturing JSON + exit code (never abort on non-zero).
run() {
  local rc
  set +e
  OUT="$(COMBINED_TREE_SUITE_CMD="$SUITE_CMD" bash "$SCRIPT" "$REPO" "$@" --base main 2>&1)"
  rc=$?
  set -e
  RC=$rc
}

# --- SKIP: single branch -----------------------------------------------------
run add-gate
[ "$RC" -eq 0 ] || fail "SKIP should exit 0 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "SKIP" ] || fail "single branch → SKIP (got: $OUT)"
echo "PASS: fewer than two branches → SKIP (exit 0) — single-PR levels need no union check"

# --- CLEAN: two disjoint, non-colliding branches -----------------------------
run add-foo add-bar
[ "$RC" -eq 0 ] || fail "CLEAN should exit 0 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "CLEAN" ] || fail "disjoint set → CLEAN (got: $OUT)"
[ "$(jq -r '.branches | length' <<<"$OUT")" = "2" ] || fail "CLEAN branches echoed (got: $OUT)"
echo "PASS: two disjoint branches that merge clean and pass the suite → CLEAN (exit 0)"

# --- GATE_FAILED: the synthetic semantic collision ---------------------------
run add-gate add-scanned
[ "$RC" -eq 4 ] || fail "GATE_FAILED should exit 4 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "GATE_FAILED" ] || fail "collision → GATE_FAILED (got: $OUT)"
jq -e '.output | test("COLLISION")' <<<"$OUT" >/dev/null \
  || fail "GATE_FAILED surfaces the failing gate's output (got: $OUT)"
[ "$(jq -r .exit_code <<<"$OUT")" = "1" ] || fail "GATE_FAILED carries the suite exit code (got: $OUT)"
echo "PASS: a green-alone/red-combined pair (gate branch + scanned branch) → GATE_FAILED (exit 4), caught locally pre-queue"

# --- CONFLICT: same-line edits, suite never reached --------------------------
run conflict-a conflict-b
[ "$RC" -eq 3 ] || fail "CONFLICT should exit 3 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "CONFLICT" ] || fail "same-line edits → CONFLICT (got: $OUT)"
[ "$(jq -r .branch <<<"$OUT")" = "conflict-b" ] || fail "CONFLICT names the offending (second) branch (got: $OUT)"
echo "PASS: two branches editing the same line → CONFLICT (exit 3), naming the offending branch"

# --- ERROR: a non-existent branch ref ----------------------------------------
run add-foo no-such-branch
[ "$RC" -eq 1 ] || fail "bad ref should exit 1 (rc=$RC, out=$OUT)"
[ "$(jq -r .outcome <<<"$OUT")" = "ERROR" ] || fail "bad ref → ERROR (got: $OUT)"
jq -e '.error | test("not found")' <<<"$OUT" >/dev/null \
  || fail "ERROR names the missing ref (got: $OUT)"
echo "PASS: a non-existent branch ref → ERROR (exit 1), no half-built worktree"

# --- no leaked worktrees: the throwaway tree is always torn down -------------
leaked="$(git -C "$REPO" worktree list --porcelain | grep -c 'combined-tree' || true)"
[ "$leaked" -eq 0 ] || fail "throwaway worktree leaked ($leaked still registered)"
echo "PASS: no throwaway worktree leaked after all outcomes (clean/conflict/gate-fail/error)"

echo "ALL COMBINED-TREE-PRECHECK TESTS PASSED"
