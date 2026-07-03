#!/usr/bin/env bash
# Unit tests for scripts/prune-merged-branches.sh (F#551, robustness fix F#650).
#
# The load-bearing scenario is the F#650 regression: a merged LOCAL branch bound
# to a worktree cannot be `git branch -d`-deleted, and must NOT abort the run or
# block the REMOTE sweep. Pre-fix, the batched `git branch -d` tripped `set -e`
# and the remote backlog was silently stranded.
#
# All scenarios use an isolated real-git tmpdir (bare origin + clone). No HOME or
# network access; nothing outside the tmpdir is touched.
set -uo pipefail

FOUNDATION="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$FOUNDATION/scripts/prune-merged-branches.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; (( PASS++ )); }
fail() { echo "  ✗ $1"; (( FAIL++ )); }

# ---------------------------------------------------------------------------
# Fixture: a clone whose origin/main has absorbed two merged branches (one of
# which is then bound to a worktree) plus an unmerged branch. Echoes the work
# checkout path; the worktree lives at <tmp>/wt.
# ---------------------------------------------------------------------------
build_fixture() {
  local tmp work
  tmp="$(mktemp -d)"
  work="$tmp/work"
  git init -q --bare "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$work" 2>/dev/null
  git -C "$work" config user.email test@test
  git -C "$work" config user.name Test
  git -C "$work" commit -q --allow-empty -m init
  git -C "$work" branch -M main
  git -C "$work" push -q origin main

  # merged-normal: merged into main, remote head pushed — should be deleted both sides.
  git -C "$work" checkout -q -b merged-normal
  git -C "$work" commit -q --allow-empty -m normal
  git -C "$work" checkout -q main
  git -C "$work" merge -q --no-ff merged-normal -m "merge merged-normal"
  git -C "$work" push -q origin main merged-normal

  # merged-worktree: merged into main, remote head pushed, THEN bound to a worktree
  # so `git branch -d` will refuse the local — the F#650 trigger.
  git -C "$work" checkout -q -b merged-worktree
  git -C "$work" commit -q --allow-empty -m wt
  git -C "$work" checkout -q main
  git -C "$work" merge -q --no-ff merged-worktree -m "merge merged-worktree"
  git -C "$work" push -q origin main merged-worktree
  git -C "$work" worktree add -q "$tmp/wt" merged-worktree

  # unmerged: never merged — must be kept (git branch -d refuses it anyway).
  git -C "$work" checkout -q -b unmerged
  git -C "$work" commit -q --allow-empty -m unmerged
  git -C "$work" checkout -q main

  echo "$work"
}

echo "test_prune_merged_branches.sh"

work="$(build_fixture)"
out="$(cd "$work" && bash "$SCRIPT" --remote --apply 2>&1)"; rc=$?

# 1. Exit 0 — the worktree-bound branch must not make the script fail.
if [ "$rc" -eq 0 ]; then pass "exit 0 despite a worktree-bound merged branch"
else fail "expected exit 0, got $rc — output:"$'\n'"$out"; fi

# 2. The deletable merged local is gone.
if ! git -C "$work" rev-parse --verify -q merged-normal >/dev/null; then
  pass "merged-normal local deleted"
else fail "merged-normal local should have been deleted"; fi

# 3. The worktree-bound merged local is SKIPPED (still present, not fatal).
if git -C "$work" rev-parse --verify -q merged-worktree >/dev/null; then
  pass "merged-worktree local skipped (worktree-bound, retained)"
else fail "merged-worktree local should have been skipped, not deleted"; fi
if grep -q "skipped (in use / worktree-bound): merged-worktree" <<<"$out"; then
  pass "skip is reported on stdout"
else fail "expected a 'skipped … merged-worktree' notice — output:"$'\n'"$out"; fi

# 4. The unmerged local is kept.
if git -C "$work" rev-parse --verify -q unmerged >/dev/null; then
  pass "unmerged local kept"
else fail "unmerged local must never be deleted"; fi

# 5. THE REGRESSION: the remote sweep still ran despite the local skip — both
#    merged remote heads are gone (only origin/main + the HEAD symref remain).
if ! git -C "$work" show-ref --verify -q refs/remotes/origin/merged-normal \
   && ! git -C "$work" show-ref --verify -q refs/remotes/origin/merged-worktree; then
  pass "remote sweep ran despite worktree skip — both merged remote heads gone"
else
  fail "remote heads not swept (F#650 regression): $(git -C "$work" branch -r | xargs)"
fi

# 6. Summary line reflects 1 deleted local + 2 remote + 1 skipped (the worktree
#    branch's REMOTE head is not worktree-bound, so it is still swept).
if grep -qE "deleted 1 local / 2 remote; skipped 1 local" <<<"$out"; then
  pass "summary reports deleted + skipped counts"
else fail "summary line wrong — output:"$'\n'"$out"; fi

echo "  ---"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
