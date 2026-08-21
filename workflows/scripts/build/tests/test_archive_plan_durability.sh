#!/usr/bin/env bash
#
# Tests for temperloop#1523 — archive-plan.sh must not report success for a
# snapshot that never landed, and a later run must not destroy one that is still
# pending. Zero network, fully hermetic: a local bare repo stands in for origin
# and a fake gh drives every PR call. Exercises the shared protected-main kernel
# (../../lib/land-on-protected-main.sh) through its real caller.
#
# The two halves of the defect, and the case that pins each:
#
#   DESTRUCTIVE half — `land__via_pr` force-rebuilt $LAND_BRANCH off origin/main
#     every run and force-pushed it, so a prior run's snapshot whose PR had not
#     merged (CI red, queue stall, PR left open) was overwritten and gone, while
#     the run that destroyed it printed a success-reading status line.
#       -> case 1 (a second note must not evict the first)
#       -> case 2 (re-archiving a pending note must not evict its sibling)
#
#   FALSE-SUCCESS half — three distinct states all read as success:
#       -> case 2  a snapshot that is only on the PENDING branch reported
#                  `plan-archived: ... (already on origin)`
#       -> case 3  a FAILED `gh pr merge --auto` was discarded with `|| true`,
#                  so an un-queued PR reported identically to a queued one
#       -> case 4  a snapshot git refused to stage (ignored path) left an empty
#                  staged diff, which the short-circuit read as "already current"
#       -> case 5  a snapshot that could not be WRITTEN at all
#
#   And the other side of the discrimination — success must still report success:
#       -> case 6 (landed on main, both the direct and the merged-PR path)
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/archive-plan.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/archive-plan-durability-XXXXXX")"
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Two done plan notes: A is archived first, B by the following run.
NOTE_A="$WORK/2026-08-10 temperloop - note a.md"
NOTE_B="$WORK/2026-08-14 temperloop - note b.md"
printf -- '---\nstatus: done\nepic: 1401\n---\n# Plan A\n\n- [x] a\n' > "$NOTE_A"
printf -- '---\nstatus: done\nepic: 1402\n---\n# Plan B\n\n- [x] b\n' > "$NOTE_B"
A_BASE="$(basename "$NOTE_A")"; B_BASE="$(basename "$NOTE_B")"

# A neutral placeholder host/org — shippable kernel test data carries no real org
# (see workflows/scripts/kernel/personal-token-denylist.tsv).
ORIGIN_URL="https://example.test/example-org/example-repo"

# Build a fresh repo + bare origin + a fake gh with the given case body.
# Sets REPO/BARE/GH/GHLOG in the caller's scope.
setup_case() {  # <case-name> <gh-case-body>
  local name="$1" body="$2" fakebin="$WORK/$1-bin"
  BARE="$WORK/$name-origin.git"
  REPO="$WORK/$name-repo"
  GHLOG="$WORK/$name-gh.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GHLOG"
$body
EOF
  chmod +x "$fakebin/gh"
  GH="$fakebin/gh"

  git init -q --bare "$BARE"
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  mkdir -p "$REPO"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  ( cd "$REPO" && : > .keep && git add -A && git commit -qm seed )
  git -C "$REPO" remote add origin "$BARE"
  git -C "$REPO" push -q -u origin main
}

# A local repo with NO remote (the direct in-place path).
setup_local() {  # <case-name>
  REPO="$WORK/$1-repo"
  mkdir -p "$REPO"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  ( cd "$REPO" && : > .keep && git add -A && git commit -qm seed )
}

archive() {  # <note> <epic>
  PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$GH" \
    bash "$SCRIPT" "$1" "$2" "$REPO"
}

# One open PR (#777) that never merges: `pr list` lags (empty), `pr create` mints it.
GH_OPEN_PR='
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "'"$ORIGIN_URL"'/pull/777" ;;
  *)           exit 0 ;;
esac
'

on_branch() {  # <bare> <path>  -> 0 when the archive branch carries <path>
  git -C "$1" cat-file -e "chore/plan-archive:Plans-archive/$2" 2>/dev/null
}

# --- 1. a pending snapshot survives the NEXT run ------------------------------
# The data-loss half. Run 1 pushes note A onto chore/plan-archive behind PR #777.
# The PR never merges (origin/main stays put). Run 2 archives note B. Before the
# fix, run 2 rebuilt the branch off origin/main and A was destroyed — while run 2
# still printed a success-reading line for its own note.
setup_case pending-survives "$GH_OPEN_PR"

out="$(archive "$NOTE_A" 1401)"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "run 1: expected 'plan-archive-pending: 777' (got: $out)"
[[ "$out" == *"plan-archived:"* ]] && fail "run 1: reported LANDED for a snapshot that is only on a PR (got: $out)"
on_branch "$BARE" "$A_BASE" || fail "run 1: note A never reached the archive branch"

out="$(archive "$NOTE_B" 1402)"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "run 2: expected 'plan-archive-pending: 777' (got: $out)"
on_branch "$BARE" "$B_BASE" || fail "run 2: note B never reached the archive branch"
on_branch "$BARE" "$A_BASE" \
  || fail "run 2 DESTROYED the pending snapshot of note A (#1523 data-loss half)"
pass "1. a later run extends the pending archive branch instead of destroying it"

# --- 2. a note that is only on the PENDING branch is NOT reported as landed ---
# Re-archiving A while PR #777 is still open: the bytes match the branch, not main.
# Reporting `plan-archived: ... (already on origin)` here would be a success verdict
# for a snapshot that is not on origin/main at all.
out="$(archive "$NOTE_A" 1401)"
[[ "$out" == *"plan-archived:"* ]] \
  && fail "re-archive of a still-pending note reported LANDED (got: $out)"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "re-archive of a still-pending note: expected pending (got: $out)"
on_branch "$BARE" "$A_BASE" || fail "re-archive lost note A"
on_branch "$BARE" "$B_BASE" || fail "re-archive of A destroyed the pending note B"
git -C "$BARE" cat-file -e "main:Plans-archive/$A_BASE" 2>/dev/null \
  && fail "test bug: note A reached main, so 'pending' was not the state under test"
pass "2. a snapshot present only on the open archive PR reports pending, never landed"

# --- 3. a FAILED enqueue is not reported as queued ----------------------------
# `gh pr merge --auto` used to run under `|| true`, so a PR nothing would ever
# merge reported exactly like a queued one.
setup_case enqueue-fails '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "'"$ORIGIN_URL"'/pull/777" ;;
  "pr merge")  echo "GraphQL: Pull request Auto merge is not allowed for this repository" >&2; exit 1 ;;
  *)           exit 0 ;;
esac
'
out="$(archive "$NOTE_A" 1401)"
grep -q "pr merge 777 --auto" "$GHLOG" || fail "enqueue-fails: 'pr merge 777 --auto' not attempted"
[[ "$out" == *"plan-archive-pending:"* ]] \
  && fail "a failed enqueue reported as pending/queued (got: $out)"
[[ "$out" == *"plan-archive-failed:"* && "$out" == *"777"* ]] \
  || fail "expected 'plan-archive-failed: ... 777 ... NOT queued' (got: $out)"
# The payload is still preserved on the branch — a failed enqueue loses nothing.
on_branch "$BARE" "$A_BASE" || fail "enqueue-fails: the snapshot was not preserved on the branch"
pass "3. a failed 'gh pr merge --auto' reports failure, naming the PR that will not merge"

# --- 3b. an ALREADY-queued PR is still a success ------------------------------
# gh reports a redundant enqueue as an error; the desired end state holds, so the
# fix must not turn idempotence into a false failure.
#
# The stub answers `pr view --json autoMergeRequest,mergeQueueEntry` because that
# is what land__enqueue now PROBES. It deliberately no longer keys on gh's error
# prose (the §3e MEDIUM on this branch): that text is not a contract, it is
# localised and reworded between gh releases, so a glob over it becomes a false
# verdict the first time the wording moves. The end state is the contract.
setup_case enqueue-idempotent '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "'"$ORIGIN_URL"'/pull/777" ;;
  "pr merge")  echo "! Pull request #777 is already queued to merge" >&2; exit 1 ;;
  "pr view")   echo "{\"number\":777}" ;;
  *)           exit 0 ;;
esac
'
out="$(archive "$NOTE_A" 1401)"
[[ "$out" == *"plan-archive-pending: 777"* ]] \
  || fail "an already-queued PR must still report pending (got: $out)"
pass "3b. 'already queued to merge' is treated as an armed queue, not a failure"

# --- 3c. a failed enqueue whose END STATE does not hold is still a failure ----
# The discriminating twin of 3b. Same non-zero `gh pr merge`, but the probe finds
# neither auto-merge armed nor a queue entry — so the run must NOT report pending.
# Without this, 3b alone would pass just as happily if the probe always said yes.
setup_case enqueue-genuinely-failed '
case "$1 $2" in
  "pr list")   exit 0 ;;
  "pr create") echo "'"$ORIGIN_URL"'/pull/778" ;;
  "pr merge")  echo "! something went wrong" >&2; exit 1 ;;
  "pr view")   echo "" ;;
  *)           exit 0 ;;
esac
'
out="$(archive "$NOTE_A" 1402)"
[[ "$out" == *"plan-archive-failed:"* ]] \
  || fail "a failed enqueue with no armed queue must report failure (got: $out)"
pass "3c. a failed enqueue whose end state does NOT hold still reports failure"

# --- 4. a snapshot git refuses to STAGE reports failure -----------------------
# Injected failure: Plans-archive/ is .gitignore'd, so `git add` takes nothing and
# the staged diff is empty. Before the fix that empty diff was read as
# "already current" — a success verdict for a snapshot that never entered git.
setup_local ignored-path
printf 'Plans-archive/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "ignore Plans-archive"
out="$( bash "$SCRIPT" "$NOTE_A" 1401 "$REPO" )"
[[ "$out" == *"plan-archived:"* ]] \
  && fail "an un-stageable snapshot reported LANDED (got: $out)"
[[ "$out" == *"plan-archive-failed:"* ]] \
  || fail "expected 'plan-archive-failed:' for an un-stageable snapshot (got: $out)"
git -C "$REPO" cat-file -e "main:Plans-archive/$A_BASE" 2>/dev/null \
  && fail "test bug: the snapshot did reach main, so 'un-stageable' was not the state under test"
pass "4. a snapshot the index refused reports failure, not 'already current'"

# --- 5. a snapshot that cannot be WRITTEN reports failure ---------------------
# Injected failure: the destination directory is not writable. Before the fix the
# bare `cp` aborted the script under `set -e` with no status line at all.
if [ "$(id -u)" != 0 ]; then
  setup_local unwritable
  mkdir -p "$REPO/Plans-archive"
  printf '# keep\n' > "$REPO/Plans-archive/.keep"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "seed Plans-archive"
  before="$(cksum < "$NOTE_A")"
  chmod 500 "$REPO/Plans-archive"
  rc=0
  out="$( bash "$SCRIPT" "$NOTE_A" 1401 "$REPO" 2>/dev/null )" || rc=$?
  chmod 700 "$REPO/Plans-archive"
  [ "$rc" -eq 0 ] || fail "an unwritable destination must still print a verdict (exit $rc)"
  [[ "$out" == *"plan-archived:"* ]] && fail "an unwritable destination reported LANDED (got: $out)"
  [[ "$out" == *"plan-archive-failed:"* && "$out" == *"$A_BASE"* ]] \
    || fail "expected 'plan-archive-failed: <note> did not land — ...' (got: $out)"
  # The source is left recoverable: this script only ever READS the vault note.
  [ "$before" = "$(cksum < "$NOTE_A")" ] || fail "the source plan note was modified by a failed archive"
  pass "5. an unwritable destination reports failure and leaves the source note intact"
else
  echo "SKIP: 5 (running as root — an unwritable directory is not enforceable)"
fi

# --- 6. the success paths still report success --------------------------------
# 6a. no remote: the snapshot is committed in place on main.
setup_local success-direct
out="$( bash "$SCRIPT" "$NOTE_A" 1401 "$REPO" )"
[[ "$out" == *"plan-archived:"* ]] || fail "6a: expected plan-archived on the direct path (got: $out)"
git -C "$REPO" cat-file -e "main:Plans-archive/$A_BASE" 2>/dev/null \
  || fail "6a: the snapshot is not on main despite a landed verdict"

# 6b. protected path, PR merged: the branch's content is now on origin/main.
setup_case success-merged "$GH_OPEN_PR"
out="$(archive "$NOTE_A" 1401)"
[[ "$out" == *"plan-archive-pending: 777"* ]] || fail "6b: expected pending before the merge (got: $out)"
git -C "$BARE" update-ref refs/heads/main refs/heads/chore/plan-archive   # PR "merged"
git -C "$BARE" update-ref -d refs/heads/chore/plan-archive                # head auto-deleted
git -C "$REPO" fetch -q origin main
out="$(archive "$NOTE_A" 1401)"
[[ "$out" == *"plan-archived:"* && "$out" == *"already on origin"* ]] \
  || fail "6b: expected 'plan-archived: ... (already on origin)' once merged (got: $out)"
pass "6. success still reports success — direct commit, and already-on-origin after the merge"

echo "ALL PASS: test_archive_plan_durability.sh (#1523)"
