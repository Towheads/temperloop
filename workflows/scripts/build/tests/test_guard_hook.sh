#!/usr/bin/env bash
#
# Tests for claude/hooks/build-worktree-guard.sh — the build write-jail
# PreToolUse hook, marker-file arming (#171/#212, epic #253).
#
# The hook arms iff the tool cwd's git toplevel carries a `.build-guard`
# marker AND that toplevel sits under a `<repo>.wt/` dir. Covers:
#   - armed (marker + convention): denies a write outside the worktree
#   - armed: allows writes inside the worktree and to /tmp//$TMPDIR
#   - per-worktree scoping: cwd in worktree A denies a write into sibling
#     worktree B (concurrency-safe — no global state)
#   - marker outside the .wt convention: warns on stderr, fails OPEN
#   - no marker: inert (allows everything), incl. after worktree.sh remove
#
# Fixture note: the repos live under $HOME (not mktemp) ON PURPOSE — the
# hook allow-lists /tmp and $TMPDIR, so a tmpdir fixture could never assert a
# deny (every out-of-worktree target would be allow-listed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HOOK="$ROOT/claude/hooks/build-worktree-guard.sh"
WORKTREE_SH="$ROOT/workflows/scripts/build/worktree.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

SCRATCH="$HOME/.build-guard-test.$$"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
mkdir -p "$SCRATCH"

# Fixture: upstream + clone, two worktrees via worktree.sh (also exercises the
# create→arm integration the contract specifies), plus a NON-convention repo
# carrying a stray marker.
git init -q --initial-branch=main "$SCRATCH/upstream"
git -C "$SCRATCH/upstream" commit -q --allow-empty -m init
git clone -q "$SCRATCH/upstream" "$SCRATCH/repo"
REPO="$(cd "$SCRATCH/repo" && pwd -P)"
bash "$WORKTREE_SH" create "$REPO" wt-a >/dev/null
bash "$WORKTREE_SH" create "$REPO" wt-b >/dev/null
WT_A="$REPO.wt/wt-a"
WT_B="$REPO.wt/wt-b"

git init -q --initial-branch=main "$SCRATCH/plain"
git -C "$SCRATCH/plain" commit -q --allow-empty -m init
touch "$SCRATCH/plain/.build-guard"   # stray marker OUTSIDE the .wt convention

# run_hook <cwd> <file_path> → stdout (stderr to $ERR)
ERR="$SCRATCH/stderr.txt"
run_hook() {
  jq -cn --arg cwd "$1" --arg fp "$2" \
    '{tool_name:"Write", tool_input:{file_path:$fp}, cwd:$cwd}' \
    | bash "$HOOK" 2>"$ERR"
}
denied() { grep -q '"permissionDecision":"deny"' <<<"$1"; }

OUTSIDE="$SCRATCH/outside-target.txt"   # under $HOME, not /tmp — not allow-listed

# --- armed: marker + convention → outside write DENIED ------------------------
out="$(run_hook "$WT_A" "$OUTSIDE")"
denied "$out" || fail "armed hook allowed an out-of-worktree write (out: $out)"
grep -q "$WT_A" <<<"$out" || fail "deny reason does not name the jail root (out: $out)"
echo "PASS: armed (marker + .wt convention) denies an out-of-worktree write"

# --- armed: parent-checkout write DENIED (the #10 leak shape) ------------------
out="$(run_hook "$WT_A" "$REPO/leaked-edit.txt")"
denied "$out" || fail "armed hook allowed a parent-checkout write"
echo "PASS: armed denies a bare parent-root write (the #10 leak shape)"

# --- armed: inside write + /tmp//$TMPDIR allow-list still ALLOWED --------------
out="$(run_hook "$WT_A" "$WT_A/some/new/file.txt")"
denied "$out" && fail "armed hook denied an in-worktree write"
out="$(run_hook "$WT_A" "${TMPDIR:-/tmp}/guard-test-scratch.txt")"
denied "$out" && fail "armed hook denied a tmp-allow-listed write"
echo "PASS: armed allows in-worktree writes and the /tmp/\$TMPDIR allow-list"

# --- per-worktree scoping: A's jail rejects B, B's jail rejects A --------------
# Two concurrent sessions' guards must be independent: arming comes from each
# worktree's own marker, so cwd decides the jail root — no global state.
out="$(run_hook "$WT_A" "$WT_B/cross-write.txt")"
denied "$out" || fail "worktree A allowed a write into sibling worktree B"
out="$(run_hook "$WT_B" "$WT_A/cross-write.txt")"
denied "$out" || fail "worktree B allowed a write into sibling worktree A"
out="$(run_hook "$WT_B" "$WT_B/own-file.txt")"
denied "$out" && fail "worktree B denied its own in-worktree write"
echo "PASS: per-worktree marker scoping — concurrent worktrees jail independently"

# --- marker outside the .wt convention: warn + fail OPEN -----------------------
out="$(run_hook "$SCRATCH/plain" "$OUTSIDE")"
denied "$out" && fail "stale marker outside .wt convention DENIED (must fail open)"
grep -qi "failing OPEN" "$ERR" || fail "no stderr warning on marker-outside-convention (stderr: $(cat "$ERR"))"
echo "PASS: marker outside <repo>.wt/ convention warns on stderr and fails OPEN"

# --- no marker: inert ----------------------------------------------------------
out="$(run_hook "$REPO" "$OUTSIDE")"
denied "$out" && fail "hook denied with no marker present (must be inert)"
rm "$SCRATCH/plain/.build-guard"
out="$(run_hook "$SCRATCH/plain" "$OUTSIDE")"
denied "$out" && fail "hook denied after marker removal (must be inert)"
echo "PASS: no marker → inert (interactive sessions unaffected)"

# --- worktree.sh remove disarms ------------------------------------------------
# remove deletes the whole worktree; a re-created markerless dir at the same
# path must be inert (the marker, not the path, is the arming state).
bash "$WORKTREE_SH" remove "$REPO" wt-b >/dev/null
git -C "$REPO" worktree add -q "$WT_B" origin/main   # same path, no marker
out="$(run_hook "$WT_B" "$OUTSIDE")"
denied "$out" && fail "markerless re-created worktree was armed"
echo "PASS: after worktree.sh remove, the same path without a marker is inert"
