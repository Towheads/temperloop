#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/worktree.sh — the build worktree
# lifecycle CLI (epic #253, spike #245). Board-toolkit fixture style: a
# throwaway real-git repo in a tmpdir, zero network, structured-output
# assertions via jq.
#
# Covers:
#   - create: deterministic path/branch, marker dropped, structured CREATED
#   - create over a stale path (aborted run debris) recovers
#   - marker is excluded from `git status` (a worker's `git add -A` can't commit it)
#   - remove: cleans worktree + branch + marker → REMOVED; second call → NOT_FOUND
#   - prune: removes merged+clean, skips unmerged, skips dirty unless --force
#   - error: non-toplevel repo-root → ERROR + non-zero exit
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/worktree.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fixture: an "upstream" with a main branch, cloned so origin/<default> and
# origin/HEAD exist — the same shape a real checkout has.
git init -q --initial-branch=main "$TMP/upstream"
git -C "$TMP/upstream" commit -q --allow-empty -m init
git clone -q "$TMP/upstream" "$TMP/repo"
REPO="$(cd "$TMP/repo" && pwd -P)"

# --- create: deterministic path/branch + marker + structured output ----------
out="$(bash "$SCRIPT" create "$REPO" alpha)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "create outcome (got: $out)"
[ "$(jq -r .path <<<"$out")" = "$REPO.wt/alpha" ] || fail "create path (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "build/alpha" ] || fail "create branch (got: $out)"
[ "$(jq -r .base <<<"$out")" = "origin/main" ] || fail "create base (got: $out)"
[ -d "$REPO.wt/alpha" ] || fail "worktree dir not created"
[ -f "$REPO.wt/alpha/.build-guard" ] || fail "marker not dropped"
[ "$(git -C "$REPO.wt/alpha" rev-parse --abbrev-ref HEAD)" = "build/alpha" ] \
  || fail "worktree not on build/alpha"
echo "PASS: create → CREATED with deterministic path/branch + .build-guard marker"

# --- markers never read as dirt (info/exclude) -------------------------------
[ -z "$(git -C "$REPO.wt/alpha" status --porcelain)" ] \
  || fail "fresh worktree not clean — marker leaked into git status"
# The #418 verification-surface artifact is excluded too, so a worker writing it
# (then `git add -A`) can never commit it into the PR branch.
printf 'surface body\n' > "$REPO.wt/alpha/.build-verification.md"
[ -z "$(git -C "$REPO.wt/alpha" status --porcelain)" ] \
  || fail ".build-verification.md not excluded — would leak into git status / a worker commit"
rm -f "$REPO.wt/alpha/.build-verification.md"
echo "PASS: markers (.build-guard + .build-verification.md) are git-status-invisible (info/exclude)"

# --- create over a stale path recovers ---------------------------------------
# (a) registered worktree whose dir was rm'd (crashed run debris)
rm -rf "$REPO.wt/alpha"
out="$(bash "$SCRIPT" create "$REPO" alpha)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "create over stale registration (got: $out)"
[ -f "$REPO.wt/alpha/.build-guard" ] || fail "marker missing after stale-recovery create"
# (b) live worktree + branch already present (aborted run left both)
out="$(bash "$SCRIPT" create "$REPO" alpha)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "create over existing worktree (got: $out)"
echo "PASS: create over a stale path force-removes and re-adds (CREATED)"

# --- remove: worktree + branch + marker gone → REMOVED; again → NOT_FOUND ----
out="$(bash "$SCRIPT" remove "$REPO" alpha)"
[ "$(jq -r .outcome <<<"$out")" = "REMOVED" ] || fail "remove outcome (got: $out)"
[ ! -e "$REPO.wt/alpha" ] || fail "worktree dir survived remove"
git -C "$REPO" show-ref --verify --quiet refs/heads/build/alpha \
  && fail "branch build/alpha survived remove"
out="$(bash "$SCRIPT" remove "$REPO" alpha)"
[ "$(jq -r .outcome <<<"$out")" = "NOT_FOUND" ] || fail "second remove not NOT_FOUND (got: $out)"
echo "PASS: remove cleans worktree+branch+marker (REMOVED), repeat is NOT_FOUND"

# --- prune: merged+clean PRUNED; unmerged skipped; dirty skipped sans --force -
bash "$SCRIPT" create "$REPO" merged-clean >/dev/null
bash "$SCRIPT" create "$REPO" unmerged >/dev/null
bash "$SCRIPT" create "$REPO" dirty >/dev/null
git -C "$REPO.wt/unmerged" commit -q --allow-empty -m "unlanded work"
echo scratch > "$REPO.wt/dirty/junk.txt"

out="$(bash "$SCRIPT" prune "$REPO")"
oc() { jq -r --arg p "$REPO.wt/$1" 'select(.path==$p).outcome' <<<"$out"; }
[ "$(oc merged-clean)" = "PRUNED" ] || fail "merged-clean not PRUNED (got: $out)"
[ "$(oc unmerged)" = "SKIPPED_UNMERGED" ] || fail "unmerged not skipped (got: $out)"
[ "$(oc dirty)" = "SKIPPED_DIRTY" ] || fail "dirty not skipped (got: $out)"
[ ! -e "$REPO.wt/merged-clean" ] || fail "merged-clean dir survived prune"
[ -e "$REPO.wt/unmerged" ] || fail "unmerged dir was pruned"
[ -e "$REPO.wt/dirty" ] || fail "dirty dir was pruned without --force"
git -C "$REPO" show-ref --verify --quiet refs/heads/build/merged-clean \
  && fail "branch build/merged-clean survived prune"
echo "PASS: prune removes merged+clean only (PRUNED / SKIPPED_UNMERGED / SKIPPED_DIRTY)"

out="$(bash "$SCRIPT" prune "$REPO" --force)"
[ "$(oc dirty)" = "PRUNED" ] || fail "dirty not PRUNED under --force (got: $out)"
[ ! -e "$REPO.wt/dirty" ] || fail "dirty dir survived prune --force"
[ "$(oc unmerged)" = "SKIPPED_UNMERGED" ] || fail "--force pruned an UNMERGED worktree (got: $out)"
echo "PASS: prune --force overrides dirty-skip but never removes unmerged work"

# --- prune: squash/rebase-merged branch (tip NOT an ancestor of origin/main) --
# is still detected MERGED via the merge-queue-safe helper (#171/#173) and
# pruned — the ancestor-only test this replaces would misread it as unmerged.
bash "$SCRIPT" create "$REPO" squashed >/dev/null
printf 'squash content\n' > "$REPO.wt/squashed/squash.txt"
git -C "$REPO.wt/squashed" add squash.txt
git -C "$REPO.wt/squashed" commit -q -m "squashed: add squash.txt"
# Land the identical cumulative diff as ONE new commit directly on upstream's
# main (what a merge-queue squash produces), then advance main again so the
# squashed branch's tip is provably NOT an ancestor of origin/main.
printf 'squash content\n' > "$TMP/upstream/squash.txt"
git -C "$TMP/upstream" add squash.txt
git -C "$TMP/upstream" commit -q -m "squashed (#999) squash-merged"
git -C "$TMP/upstream" commit -q --allow-empty -m "main advances again after the squash"
git -C "$REPO" fetch -q origin main
git -C "$REPO.wt/squashed" merge-base --is-ancestor HEAD origin/main \
  && fail "test setup bug: squashed branch tip must NOT be an ancestor of origin/main"

out="$(bash "$SCRIPT" prune "$REPO")"
[ "$(oc squashed)" = "PRUNED" ] || fail "squash-merged branch not PRUNED (got: $out)"
[ ! -e "$REPO.wt/squashed" ] || fail "squashed dir survived prune"
git -C "$REPO" show-ref --verify --quiet refs/heads/build/squashed \
  && fail "branch build/squashed survived prune"
echo "PASS: prune detects a squash/rebase-merged branch (tip not an ancestor) via the merge-queue-safe helper and PRUNES it (#171/#173)"

# --- error: closed ERROR outcome + non-zero exit ------------------------------
rc=0; out="$(bash "$SCRIPT" create "$TMP" bad-root 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-toplevel repo-root did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "non-toplevel repo-root not ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" create "$REPO" 'Bad Slug!' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "invalid slug did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "invalid slug not ERROR (got: $out)"
echo "PASS: failures emit structured ERROR + non-zero exit (closed outcome set)"

# --- create freshens origin/<default> before basing (stale-base guard, #337) --
# Advance upstream AFTER the clone (and the prune fetches above) so the local
# origin/main is now one commit stale. create must `git fetch origin <default>`
# before `worktree add`, else the worktree is based on the old tip and silently
# misses the new commit — the two stale-base incidents #337 fixes.
newsha="$(git -C "$TMP/upstream" commit -q --allow-empty -m advance && git -C "$TMP/upstream" rev-parse HEAD)"
bash "$SCRIPT" create "$REPO" freshbase >/dev/null
git -C "$REPO.wt/freshbase" merge-base --is-ancestor "$newsha" HEAD \
  || fail "#337: create must fetch origin/<default> first — worktree based on a stale origin/main (missing $newsha)"
echo "PASS: create fetches origin/<default> before basing the worktree (#337 stale-base)"

# --- self-heal: untrack a legacy-committed .build-verification.md (#529) -------
# A consuming repo where the verification-surface artifact was committed before
# info/exclude existed: every item re-commits it → multi-item serial-merge hits a
# content conflict on it. create must untrack it as its OWN commit so all level
# branches make the identical (clean-merging) removal; once main is clean it's a
# no-op (asserted separately below).
git init -q --initial-branch=main "$TMP/up529"
printf 'stale surface\n' > "$TMP/up529/.build-verification.md"
git -C "$TMP/up529" add .build-verification.md
git -C "$TMP/up529" commit -q -m "legacy: commit build-verification artifact"
git clone -q "$TMP/up529" "$TMP/repo529"
REPO529="$(cd "$TMP/repo529" && pwd -P)"

bash "$SCRIPT" create "$REPO529" heal >/dev/null
[ -z "$(git -C "$REPO529.wt/heal" ls-files .build-verification.md)" ] \
  || fail "#529: .build-verification.md still tracked after create — self-heal did not untrack it"
[ "$(git -C "$REPO529.wt/heal" rev-list --count origin/main..HEAD)" = "1" ] \
  || fail "#529: expected exactly one self-heal commit ahead of base (got $(git -C "$REPO529.wt/heal" rev-list --count origin/main..HEAD))"
case "$(git -C "$REPO529.wt/heal" log -1 --format=%s)" in
  "chore: untrack dev-local build-verification artifact"*) : ;;
  *) fail "#529: HEAD is not the self-heal commit (got: $(git -C "$REPO529.wt/heal" log -1 --format=%s))" ;;
esac
# A worker can still write the surface afterwards and it stays git-status-invisible.
printf 'fresh surface\n' > "$REPO529.wt/heal/.build-verification.md"
[ -z "$(git -C "$REPO529.wt/heal" status --porcelain)" ] \
  || fail "#529: post-heal surface write leaked into git status (exclude not honoured)"
echo "PASS: create untracks a legacy-committed .build-verification.md as its own commit (#529)"

# steady state: a repo that does NOT track the artifact gets NO commit (no churn)
bash "$SCRIPT" create "$REPO" nohealspurious >/dev/null
[ "$(git -C "$REPO.wt/nohealspurious" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ] \
  || fail "#529: create added a spurious commit on a repo with nothing to untrack"
echo "PASS: create adds NO commit when there's nothing to untrack (steady-state no-op)"

# --- deps-merged: the dep-merge precondition gate (#108) ----------------------
# /build's 3b-0 refuses to create a dependent item's worktree until every
# `depends-on` target's head sha is an ancestor of origin/<default> — i.e. the
# depended-on PR has MERGED — so the worker builds and self-verifies against
# merged dependency code, not a pre-merge base. deps-merged fetches origin first
# (like create), then tests each comma-separated sha for ancestry.
#
# A commit that lands on upstream main stands in for a MERGED dependency; a real
# commit object that is a CHILD of origin/main (but not an ancestor) stands in for
# a pushed-but-UNMERGED PR head (the exact pre-merge window #108 guards).
mergedsha="$(git -C "$TMP/upstream" commit -q --allow-empty -m 'dep merged' && git -C "$TMP/upstream" rev-parse HEAD)"
unmergedsha="$(git -C "$REPO" commit-tree "origin/main^{tree}" -p origin/main -m 'dep unmerged head')"

out="$(bash "$SCRIPT" deps-merged "$REPO" "$mergedsha")"
[ "$(jq -r .outcome <<<"$out")" = "DEPS_MERGED" ] \
  || fail "#108: a merged dep sha must be DEPS_MERGED (got: $out)"

out="$(bash "$SCRIPT" deps-merged "$REPO" "$unmergedsha")"
[ "$(jq -r .outcome <<<"$out")" = "DEPS_UNMERGED" ] \
  || fail "#108: a pushed-but-unmerged dep sha must be DEPS_UNMERGED (got: $out)"
[ "$(jq -r '.unmerged[0]' <<<"$out")" = "$unmergedsha" ] \
  || fail "#108: DEPS_UNMERGED must name the unmerged sha (got: $out)"

# unknown/unfetched object → conservatively UNMERGED (never a false green)
out="$(bash "$SCRIPT" deps-merged "$REPO" "0000000000000000000000000000000000000000")"
[ "$(jq -r .outcome <<<"$out")" = "DEPS_UNMERGED" ] \
  || fail "#108: an unknown sha must conservatively read DEPS_UNMERGED (got: $out)"

# ALL shas must be merged — one unmerged fails the gate, and only it is listed.
out="$(bash "$SCRIPT" deps-merged "$REPO" "$mergedsha,$unmergedsha")"
[ "$(jq -r .outcome <<<"$out")" = "DEPS_UNMERGED" ] \
  || fail "#108: a mixed set (one unmerged) must be DEPS_UNMERGED (got: $out)"
[ "$(jq -r '.unmerged | length' <<<"$out")" = "1" ] \
  || fail "#108: a mixed set must list exactly the unmerged sha(s) (got: $out)"
echo "PASS: deps-merged gates on every dep sha being an ancestor of origin/<default> (#108)"

# empty sha list → structured ERROR + non-zero exit (closed outcome set)
rc=0; out="$(bash "$SCRIPT" deps-merged "$REPO" "" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "#108: deps-merged with an empty sha list did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "#108: empty sha list not ERROR (got: $out)"
echo "PASS: deps-merged with an empty sha list emits structured ERROR + non-zero exit"
