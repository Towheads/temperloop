#!/usr/bin/env bash
#
# Regression test for temperloop#560 — project-agents.sh: propagate/verify
# the ADR 0007 gitignore precondition at deploy time, fleet-wide.
#
# THE GAP THIS CLOSES. ADR 0007 assumes a downstream adopter's
# .claude/agents/ and .claude/reviewer-state/ are gitignored — but
# reviewer-activate.sh was the ONLY installer that actually ensured it before
# writing. project-agents.sh deployed agent/command files into an adopter's
# .claude/ tree WITHOUT ensuring the precondition first; even after #497 made
# out-of-tree deploys real-file copies (not symlinks), those copies sat
# untracked-but-stageable in the adopter's .claude/agents/ — one `git add -A`
# from committing per-checkout state to a shared repo. The fix: reuse the
# shared workflows/scripts/install/gitignore-safety.sh helper (already used
# by reviewer-activate.sh) to ensure the precondition before ANY write.
#
# Covers:
#   1. Fresh out-of-tree adopter (a real git repo with no prior .claude/
#      gitignore entries) -> after a bulk deploy, BOTH .claude/agents/ and
#      .claude/reviewer-state/ resolve `git check-ignore`d, and `git status
#      --porcelain` in the adopter is EMPTY (no untracked-but-stageable
#      .claude/ state left behind).
#   2. The deploy prints an explicit stdout line naming the .gitignore path
#      it added (the shared helper's own notice — not a project-agents.sh
#      re-implementation).
#   3. The shared helper is actually REUSED — project-agents.sh calls
#      gitignore_ensure_all/gitignore_ensure_entry, and has no second,
#      hand-rolled gitignore-append loop of its own.
#   4. A non-git target: the deploy still proceeds (agents/commands land),
#      warns to stderr, and does not crash.
#
# No network, no HOME mutation — every case uses a throwaway tmpdir project.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_SH="${REPO_ROOT}/workflows/scripts/install/project-agents.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-pa-gitignore-prop-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DEPLOY_SH" ] || fail "0: deploy script not found at $DEPLOY_SH"

# ---------------------------------------------------------------------------
# Test 1+2: fresh out-of-tree adopter, a real git repo with no prior .claude/
# gitignore entries -> deploy ensures BOTH paths ignored, leaves git status
# clean, and prints the shared helper's own "added ... to <gi>" notice.
# ---------------------------------------------------------------------------
P1="${TMP}/adopter"
mkdir -p "$P1"
git -C "$P1" init -q
git -C "$P1" config user.email "test@example.com"
git -C "$P1" config user.name "Test"
# A pre-existing tracked file so the repo has a real initial commit (an
# empty repo's `git status --porcelain` is trivially empty regardless).
echo "hello" >"${P1}/README.md"
git -C "$P1" add README.md
git -C "$P1" commit -q -m "init"

out1="$(bash "$DEPLOY_SH" --project-dir "$P1" 2>&1)" || fail "1: deploy exited non-zero"

git -C "$P1" check-ignore -q .claude/agents/foo \
  || fail "1: .claude/agents/ does not resolve ignored after deploy"
pass "1: .claude/agents/ resolves ignored after deploy"

git -C "$P1" check-ignore -q .claude/reviewer-state/foo \
  || fail "1: .claude/reviewer-state/ does not resolve ignored after deploy"
pass "1: .claude/reviewer-state/ resolves ignored after deploy"

# project-agents.sh also deploys into .claude/commands/ — the fixture's
# "git status clean" check (below) requires that path ignored too, so the
# propagation covers all three, not just the two ADR-named paths.
git -C "$P1" check-ignore -q .claude/commands/foo \
  || fail "1: .claude/commands/ does not resolve ignored after deploy"
pass "1: .claude/commands/ resolves ignored after deploy"

# The .gitignore itself is a legitimate, intentional repo change the deploy
# makes on the adopter's behalf — a real adopter commits it like any other
# config file, exactly as they'd commit a hand-edited .gitignore. The
# invariant this fixture guards is that NOTHING under .claude/ is left
# untracked-but-stageable once that (normal, expected) commit happens — i.e.
# no per-checkout .claude/ state sneaks into a `git add -A`.
git -C "$P1" add .gitignore
git -C "$P1" commit -q -m "adopt kernel-managed .gitignore entries"

status1="$(git -C "$P1" status --porcelain)"
[ -z "$status1" ] || fail "1: git status is not clean after deploy + committing .gitignore — got:
$status1"
pass "1: git status is clean after deploy (no untracked-but-stageable .claude/ state)"

echo "$out1" | grep -q "added '.claude/agents/' to .*\.gitignore" \
  || fail "2: deploy did not print an explicit stdout line naming the .gitignore path it added for .claude/agents/"
echo "$out1" | grep -q "added '.claude/reviewer-state/' to .*\.gitignore" \
  || fail "2: deploy did not print an explicit stdout line naming the .gitignore path it added for .claude/reviewer-state/"
pass "2: deploy prints an explicit stdout line naming the .gitignore path it added, for both entries"

# ---------------------------------------------------------------------------
# Test 3: the shared helper is REUSED — no third, hand-rolled append copy.
# ---------------------------------------------------------------------------
ensure_calls="$(grep -c 'gitignore_ensure' "$DEPLOY_SH" || true)"
[ "$ensure_calls" -gt 0 ] || fail "3: project-agents.sh does not call the shared gitignore_ensure_* helper at all"
pass "3: project-agents.sh calls the shared gitignore_ensure_* helper ($ensure_calls reference(s))"

# No re-implemented append loop: project-agents.sh itself must not contain a
# literal '>>' redirect into a .gitignore path (that would be a second,
# hand-rolled copy of the append logic gitignore-safety.sh already owns).
if grep -nE '>>\s*"?\$?\{?[A-Za-z_]*gi\}?"?.*gitignore|gitignore.*>>' "$DEPLOY_SH" | grep -v '^[0-9]*:#' >/dev/null 2>&1; then
  fail "3: project-agents.sh appears to hand-roll its own .gitignore append (should reuse gitignore-safety.sh exclusively)"
fi
pass "3: no re-implemented .gitignore append loop found in project-agents.sh"

# ---------------------------------------------------------------------------
# Test 4 (optional per spec, included): non-git target -> deploy still
# proceeds, warns, doesn't crash.
# ---------------------------------------------------------------------------
P4="${TMP}/non-git-adopter"
mkdir -p "$P4"
out4="$(bash "$DEPLOY_SH" --project-dir "$P4" 2>&1)" || fail "4: deploy into a non-git target exited non-zero (should proceed anyway)"
echo "$out4" | grep -qi "not a git repository" || fail "4: deploy into a non-git target did not warn about the missing git repo"
[ -d "${P4}/.claude/agents" ] || fail "4: deploy into a non-git target did not deploy agents (should still proceed)"
[ "$(find "${P4}/.claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')" -gt 0 ] \
  || fail "4: deploy into a non-git target deployed zero agent files"
pass "4: non-git target still gets the deploy, with a warning, no crash"

echo
echo "PASS: all project-agents gitignore-propagation tests passed"
