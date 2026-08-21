#!/usr/bin/env bash
#
# test_env_reconcile_worktree_class.sh — the worktree-classification
# discrimination suite for env-reconcile.sh's classify_worktree
# (temperloop#658).
#
# WHY THIS SUITE EXISTS. classify_worktree used to compute a worktree's branch
# as `build/$(basename "$wt")` — the naming convention worktree.sh happens to
# use — instead of reading the branch git itself records for that worktree. Any
# worktree on another prefix (`fix/…`, the isolated worktree the kernel's own
# § Working-tree ownership rule PRESCRIBES for cross-repo work) resolved to a
# branch name that had never existed, missed `show-ref`, and was reported
# LEAKED_WORKTREE:BRANCH_GONE while alive. /tidy's env-hygiene auto-heal then
# `git worktree remove --force`d it and DESTROYED uncommitted work with no
# recovery (observed 2026-07-21). So the contract under test is two-sided:
#
#   1. Classify from the REAL signal — git's own `worktree list --porcelain`
#      branch record — so prefix has nothing to do with the verdict, AND the
#      genuinely-gone branch is still caught (a fix that made everything look
#      live would be exactly as wrong as the bug).
#   2. NEVER hand a consumer a removable verdict on an uncertain
#      classification. A leak reason over a worktree carrying uncommitted work
#      downgrades to the report-only DIRTY_WORKTREE; a verdict that could not
#      be established at all is UNCERTAIN_WORKTREE. Only a confirmed-clean
#      leak is ever emitted as the auto-removable LEAKED_WORKTREE.
#
# FIXTURE-BASED AND HERMETIC: throwaway real-git repos in a tmpdir plus a
# stubbed `gh` on PATH. It never reads the ambient checkout's real worktrees,
# never touches the network, and asserts at the end that it mutated nothing.
#
# DISCRIMINATION IS BUILT IN, not asserted in prose: the last two sections
# re-run the identical fixtures against a MUTATED classifier — one with the
# pre-fix `build/<slug>` branch guess restored, one with the dirty-tree
# downgrade removed — and require the suite's own assertions to go RED there.
# A green run therefore proves the assertions can fail, not merely that they
# currently pass.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/env-reconcile.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fixture: an upstream + one operator checkout that hosts the worktrees ────
git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init

git clone -q "$TMP/upstream" "$TMP/operator"
REPO="$(cd "$TMP/operator" && pwd -P)"
WT_ROOT="${REPO}.wt"

# add_wt <dir-slug> <branch> — a worktree with one real commit of its own.
add_wt() {
  git -C "$REPO" worktree add -q -b "$2" "$WT_ROOT/$1" origin/main
  printf 'work for %s\n' "$1" > "$WT_ROOT/$1/$1.txt"
  git -C "$WT_ROOT/$1" add "$1.txt"
  git -C "$WT_ROOT/$1" commit -q -m "$1: committed work"
}

# LIVE worktrees, three branch prefixes, none of them leaked.
add_wt build-live build/build-live        # the convention worktree.sh uses
add_wt fix-live fix/fix-live              # the #658 case: hand-made fix/ worktree
add_wt odd-live scratch_experiment-7      # no prefix, no slug relationship at all
# The incident's worktree was DIRTY when it was destroyed — reproduce that.
printf 'unsaved edit nobody has committed\n' > "$WT_ROOT/fix-live/UNSAVED.txt"

# GENUINELY branch-gone worktrees (ref deleted out from under the worktree;
# `git branch -D` refuses a checked-out branch, update-ref does not).
add_wt gone-clean build/gone-clean
git -C "$REPO" update-ref -d refs/heads/build/gone-clean
add_wt gone-dirty fix/gone-dirty
git -C "$REPO" update-ref -d refs/heads/fix/gone-dirty
printf 'uncommitted work in a branch-gone worktree\n' > "$WT_ROOT/gone-dirty/UNSAVED.txt"

# MERGED worktrees (the stubbed gh reports their PR merged).
add_wt merged-clean build/merged-clean
add_wt merged-dirty fix/merged-dirty
printf 'uncommitted work in a merged worktree\n' > "$WT_ROOT/merged-dirty/UNSAVED.txt"

# DETACHED worktree — registered, but on no branch at all.
git -C "$REPO" worktree add -q --detach "$WT_ROOT/detached" origin/main

# ORPHAN — a directory under .wt/ that is not a registered worktree.
mkdir -p "$WT_ROOT/orphan"
printf 'someone else files\n' > "$WT_ROOT/orphan/keep.txt"

MERGED_BRANCHES="build/merged-clean fix/merged-dirty"

# ── Stub gh on PATH (same shape as test_env_reconcile.sh's) ──────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  branch="$3"
  case " ${GH_MOCK_MERGED_BRANCHES:-} " in
    *" $branch "*) echo MERGED ;;
    *) echo OPEN ;;
  esac
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

# ── Harness: call classify_worktree directly, optionally with a MUTATION ─────
# env-reconcile.sh is safely sourceable (its own header contract) — `set --`
# first so the sourced arg-parse loop sees no positional parameters.
cat > "$TMP/classify.sh" <<'HARNESS'
#!/usr/bin/env bash
set -uo pipefail
script="$1"; repo="$2"; wt="$3"; mutation="${4:-none}"
set --
# shellcheck disable=SC1090
source "$script"
case "$mutation" in
  prefix-guess)
    # PRE-FIX behaviour: guess the branch from the directory name.
    _worktree_branch_of() { printf 'build/%s\n' "$(basename "$2")"; }
    ;;
  always-leaked)
    # PRE-FIX behaviour: every leak reason is emitted as removable.
    _worktree_verdict() { printf 'LEAKED_WORKTREE:%s:%s' "$1" "$2"; }
    ;;
esac
classify_worktree "$repo" "$wt"
printf '\n'
HARNESS
chmod +x "$TMP/classify.sh"

classify() {  # <dir-slug> [mutation] -> the class token (empty = OK)
  PATH="$TMP/bin:$PATH" GH_MOCK_MERGED_BRANCHES="$MERGED_BRANCHES" \
    bash "$TMP/classify.sh" "$SCRIPT" "$REPO" "$WT_ROOT/$1" "${2:-none}"
}

expect() {  # <dir-slug> <expected-class> <what>
  local got
  got="$(classify "$1")"
  [ "$got" = "$2" ] || fail "$3: expected '$2' for $1, got '$got'"
  echo "PASS: $3"
}

# ── 1. A LIVE worktree is OK whatever its branch prefix ─────────────────────
expect build-live "" "live worktree on build/<slug> -> OK"
expect fix-live "" "live worktree on fix/<slug>, uncommitted edit present -> OK (the #658 false positive)"
expect odd-live "" "live worktree on a branch unrelated to its directory name -> OK"

# ── 2. The genuinely-gone branch is STILL detected ──────────────────────────
# BRANCH_GONE is detected as drift but reported UNCERTAIN, never removable: a
# deleted ref leaves `git status` no base to diff against (every tracked file
# reads as a new addition), so neither "clean" nor "dirty" is establishable —
# and the vanished ref may have been the only pointer to that work.
expect gone-clean "UNCERTAIN_WORKTREE:BRANCH_GONE:gone-clean" \
  "worktree whose branch ref is genuinely deleted -> detected, as UNCERTAIN_WORKTREE:BRANCH_GONE"
expect gone-dirty "UNCERTAIN_WORKTREE:BRANCH_GONE:gone-dirty" \
  "branch-gone worktree carrying uncommitted work -> UNCERTAIN_WORKTREE, never removable"
expect merged-clean "LEAKED_WORKTREE:MERGED:merged-clean" \
  "clean worktree whose PR merged -> LEAKED_WORKTREE:MERGED (the true-leak path still auto-heals)"

# ── 3. Uncommitted work is NEVER handed to a consumer as removable ──────────
expect merged-dirty "DIRTY_WORKTREE:MERGED:merged-dirty" \
  "merged worktree carrying uncommitted work -> DIRTY_WORKTREE, not LEAKED_WORKTREE"

# ── 4. An UNDETERMINED verdict reports, it never removes ────────────────────
expect detached "UNCERTAIN_WORKTREE:BRANCH_UNRESOLVED:detached" \
  "detached worktree (no branch to classify from) -> UNCERTAIN_WORKTREE"
expect orphan "UNCERTAIN_WORKTREE:ORPHANED:orphan" \
  "unregistered directory whose contents cannot be probed -> UNCERTAIN_WORKTREE"

# ── 5. End-to-end: the report's finding lines carry the DISPOSITION ─────────
rc=0
out="$(
  PATH="$TMP/bin:$PATH" \
  GH_MOCK_MERGED_BRANCHES="$MERGED_BRANCHES" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$REPO" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format report
)" || rc=$?
[ "$rc" -eq 0 ] || fail "--format report: expected exit 0 (got $rc); output:
$out"

grep -qE "OK +$WT_ROOT/fix-live\$" <<<"$out" \
  || fail "the live fix/ worktree should report OK; output:
$out"
echo "PASS: report shows the live fix/ worktree as OK, not drift"

grep -q "LEAKED_WORKTREE:[A-Z_]*:fix-live" <<<"$out" \
  && fail "the live fix/ worktree was reported as a leak; output:
$out"
grep -q "LEAKED_WORKTREE:[A-Z_]*:gone-dirty" <<<"$out" \
  && fail "a worktree with uncommitted work was reported as removable; output:
$out"
echo "PASS: no live or not-provably-clean worktree is ever emitted as LEAKED_WORKTREE"

# The `entry` block is what /tidy appends and acts on — its ⚠️ finding lines
# must carry the DISPOSITION, not just the class token, so a consumer cannot
# read a report-only verdict as a removal instruction.
rc=0
entry="$(
  PATH="$TMP/bin:$PATH" \
  GH_MOCK_MERGED_BRANCHES="$MERGED_BRANCHES" \
  ENV_RECONCILE_CRON_CHECKOUTS="$TMP/no-such-cron-checkout" \
  ENV_RECONCILE_OPERATOR_CHECKOUTS="$REPO" \
  ENV_RECONCILE_LAUNCHD_DIRS="$TMP/no-such-launchd-dir" \
  bash "$SCRIPT" --format entry
)" || rc=$?
[ "$rc" -eq 0 ] || fail "--format entry: expected exit 0 (got $rc); output:
$entry"

grep -qF "leaked worktree (clean tree, safe to remove): $WT_ROOT/merged-clean" <<<"$entry" \
  || fail "clean leak finding should say it is safe to remove; output:
$entry"
for slug in merged-dirty gone-clean gone-dirty detached orphan; do
  grep -qF "REPORT ONLY, never remove: $WT_ROOT/$slug" <<<"$entry" \
    || fail "the finding for $slug must tell the consumer not to remove it; output:
$entry"
done
echo "PASS: each finding line names its disposition (removable vs REPORT ONLY)"

# ── 6. READ-ONLY: every fixture worktree and every unsaved byte survives ────
for d in build-live fix-live odd-live gone-clean gone-dirty merged-clean merged-dirty detached orphan; do
  [ -d "$WT_ROOT/$d" ] || fail "env-reconcile.sh removed $WT_ROOT/$d (it must be READ-ONLY)"
done
grep -q 'unsaved edit nobody has committed' "$WT_ROOT/fix-live/UNSAVED.txt" \
  || fail "uncommitted work in fix-live was altered (env-reconcile.sh must be READ-ONLY)"
grep -q 'uncommitted work in a branch-gone worktree' "$WT_ROOT/gone-dirty/UNSAVED.txt" \
  || fail "uncommitted work in gone-dirty was altered (env-reconcile.sh must be READ-ONLY)"
echo "PASS: read-only -- every worktree and every uncommitted byte survived"

# ── 7. DISCRIMINATION A: restore the pre-fix build/<slug> branch guess ──────
# Every LIVE non-build/ worktree must go RED — that IS the #658 defect.
for slug in fix-live odd-live; do
  got="$(classify "$slug" prefix-guess)"
  case "$got" in
    *BRANCH_GONE:"$slug") ;;
    *) fail "discrimination A: with the build/<slug> guess restored, $slug should be misclassified BRANCH_GONE (got '$got') — the suite would not have caught #658" ;;
  esac
done
# ...and the genuinely-gone case must NOT be what tells them apart: with the
# guess restored, gone-clean reports exactly what it reports after the fix, so
# only the LIVE worktrees discriminate.
[ "$(classify gone-clean prefix-guess)" = "UNCERTAIN_WORKTREE:BRANCH_GONE:gone-clean" ] \
  || fail "discrimination A: the genuinely-gone case should be unaffected by the branch-resolution mutation"
echo "PASS: discrimination A -- the pre-fix build/<slug> guess turns every live non-build/ worktree RED"

# ── 8. DISCRIMINATION B: remove the dirty-tree downgrade ────────────────────
# Every not-provably-clean leak must go RED — that is the half that destroyed
# the work (`merged-dirty` carries live uncommitted bytes; `gone-dirty` cannot
# be shown to be expendable at all).
for slug in gone-dirty merged-dirty; do
  got="$(classify "$slug" always-leaked)"
  case "$got" in
    LEAKED_WORKTREE:*:"$slug") ;;
    *) fail "discrimination B: without the dirty downgrade, $slug should be emitted as removable LEAKED_WORKTREE (got '$got') — the suite would not have caught the data loss" ;;
  esac
done
[ "$(classify merged-clean always-leaked)" = "LEAKED_WORKTREE:MERGED:merged-clean" ] \
  || fail "discrimination B: a genuinely clean leak should be unaffected by the verdict mutation"
echo "PASS: discrimination B -- removing the dirty downgrade turns every dirty leak RED"

echo "ALL PASS: test_env_reconcile_worktree_class.sh"
