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

# --- prune: merged+clean PRUNED; unmerged/dirty/fresh skipped sans --force ----
# A GENUINELY merged branch has commits of its OWN that are ancestors of
# origin/main — so its tip is NOT equal to origin/main. Build that shape for
# `merged-clean` and `dirty`: land a commit on upstream main, advance main once
# more, then point the build branch at the landed commit. (Before #891 these
# fixtures were zero-commit worktrees, which the ancestor-only gate 1 read as
# merged — exactly the live-worktree-reaping bug; that shape is now
# SKIPPED_FRESH and is asserted separately below.)
bash "$SCRIPT" create "$REPO" merged-clean >/dev/null
bash "$SCRIPT" create "$REPO" dirty >/dev/null
landedsha="$(git -C "$TMP/upstream" commit -q --allow-empty -m 'merged-clean work lands on main' && git -C "$TMP/upstream" rev-parse HEAD)"
git -C "$TMP/upstream" commit -q --allow-empty -m 'main advances after that merge'
git -C "$REPO" fetch -q origin main
git -C "$REPO.wt/merged-clean" reset -q --hard "$landedsha"
git -C "$REPO.wt/dirty" reset -q --hard "$landedsha"

bash "$SCRIPT" create "$REPO" unmerged >/dev/null
git -C "$REPO.wt/unmerged" commit -q --allow-empty -m "unlanded work"
echo scratch > "$REPO.wt/dirty/junk.txt"
# The #891 case: a worktree exactly as `create` leaves it — zero commits ahead,
# tip == origin/main. This is a LIVE build worktree in the window between
# `create` and its worker's first commit.
bash "$SCRIPT" create "$REPO" fresh >/dev/null
[ "$(git -C "$REPO.wt/fresh" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ] \
  || fail "#891 test setup bug: fresh worktree tip must equal origin/main"

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

# --- #891: a fresh, ZERO-COMMIT worktree survives a non-forced prune ---------
# Zero commits ahead is evidence of NO WORK YET, not of a merge. Gate 1's
# ancestor test alone cannot tell a live, just-created build worktree from a
# finished merged one — `head != origin/<default>` can, and does.
[ "$(oc fresh)" = "SKIPPED_FRESH" ] || fail "#891: zero-commit worktree not SKIPPED_FRESH (got: $out)"
[ -e "$REPO.wt/fresh" ] || fail "#891: live zero-commit worktree dir was reaped by prune"
[ -f "$REPO.wt/fresh/.build-guard" ] || fail "#891: fresh worktree's .build-guard marker was removed"
git -C "$REPO" show-ref --verify --quiet refs/heads/build/fresh \
  || fail "#891: branch build/fresh was deleted out from under a live worker"
echo "PASS: prune spares a fresh, zero-commit worktree (SKIPPED_FRESH — #891)"

out="$(bash "$SCRIPT" prune "$REPO" --force)"
[ "$(oc dirty)" = "PRUNED" ] || fail "dirty not PRUNED under --force (got: $out)"
[ ! -e "$REPO.wt/dirty" ] || fail "dirty dir survived prune --force"
[ "$(oc unmerged)" = "SKIPPED_UNMERGED" ] || fail "--force pruned an UNMERGED worktree (got: $out)"
# --force bypasses the #891 fresh guard exactly as it bypasses the dirty gate:
# an aborted `create` leaves a legitimate zero-commit worktree that must stay
# reapable, so the guard protects the default path without making stale fresh
# worktrees immortal.
[ "$(oc fresh)" = "PRUNED" ] || fail "#891: --force did not reap a fresh worktree (got: $out)"
[ ! -e "$REPO.wt/fresh" ] || fail "#891: fresh dir survived prune --force"
git -C "$REPO" show-ref --verify --quiet refs/heads/build/fresh \
  && fail "#891: branch build/fresh survived prune --force"
echo "PASS: prune --force overrides the dirty- and fresh-skips but never removes unmerged work"

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

# --- review-agent propagation into the worktree (#1005) -----------------------
# `.claude/agents/` is gitignored (ADR 0007) so it never rides into a fresh
# worktree, and the capability probe resolves an agent iff a file sits at
# `.claude/agents/<name>.md` — so before #1005 every worker-side review pass
# read as `skipped — <agent> unavailable`, including build.md 3e's MANDATORY
# workflow-reviewer pass for a `claude/commands/*.md` diff (#1007). `create`
# must now materialize the FLAT catalog itself.
git init -q --initial-branch=main "$TMP/up1005"
mkdir -p "$TMP/up1005/claude/agents/reviewers"
printf -- '---\nname: workflow-reviewer\n---\nspec review lens\n' \
  > "$TMP/up1005/claude/agents/workflow-reviewer.md"
printf -- '---\nname: docs-reviewer\n---\nprose review lens\n' \
  > "$TMP/up1005/claude/agents/docs-reviewer.md"
# The opt-in per-language catalog lives one dir DOWN and stays inert (ADR 0007).
printf -- '---\nname: python-reviewer\n---\nopt-in only\n' \
  > "$TMP/up1005/claude/agents/reviewers/python-reviewer.md"
git -C "$TMP/up1005" add -A
git -C "$TMP/up1005" commit -q -m "kernel-shaped agent catalog"
git clone -q "$TMP/up1005" "$TMP/repo1005"
REPO1005="$(cd "$TMP/repo1005" && pwd -P)"

bash "$SCRIPT" create "$REPO1005" lenses >/dev/null
WT1005="$REPO1005.wt/lenses"
for a in workflow-reviewer docs-reviewer; do
  [ -L "$WT1005/.claude/agents/$a.md" ] \
    || fail "#1005: .claude/agents/$a.md not materialized as a symlink in a fresh worktree"
  [ "$(readlink "$WT1005/.claude/agents/$a.md")" = "../../claude/agents/$a.md" ] \
    || fail "#1005: $a.md link is not the relative in-worktree target (got: $(readlink "$WT1005/.claude/agents/$a.md"))"
  # The link must RESOLVE — a dangling link fails the probe just as an absent
  # file does, and an ABSOLUTE link back into the parent checkout would serve
  # the worker a charter from the wrong commit.
  [ -f "$WT1005/.claude/agents/$a.md" ] \
    || fail "#1005: $a.md link does not resolve inside the worktree"
  grep -q "review lens" "$WT1005/.claude/agents/$a.md" \
    || fail "#1005: $a.md link does not resolve to the tracked claude/agents/ source"
done
echo "PASS: create materializes the flat claude/agents/ catalog into the worktree's .claude/agents/ (#1005)"

# ADR 0007: the per-language catalog under claude/agents/reviewers/ is opt-in
# via reviewer-activate.sh and must NEVER be bulk-deployed by this step.
[ ! -e "$WT1005/.claude/agents/python-reviewer.md" ] \
  || fail "#1005/ADR 0007: an opt-in catalog reviewer was flat-deployed into the worktree"
[ ! -e "$WT1005/.claude/agents/reviewers" ] \
  || fail "#1005/ADR 0007: claude/agents/reviewers/ was propagated into the worktree"
echo "PASS: create leaves the opt-in reviewers/ catalog inert (ADR 0007)"

# The materialized tree must stay git-status-invisible even in a repo whose own
# .gitignore says nothing about .claude/ (this fixture has no .gitignore at
# all): an untracked .claude/ would both leak into a worker's `git add -A` and
# make every LIVE worktree read SKIPPED_DIRTY at prune time.
[ -z "$(git -C "$WT1005" status --porcelain)" ] \
  || fail "#1005: materialized .claude/agents/ leaked into git status (got: $(git -C "$WT1005" status --porcelain))"
[ -z "$(git -C "$REPO1005" status --porcelain)" ] \
  || fail "#1005: materialization dirtied the parent checkout (.gitignore must not be written)"
echo "PASS: materialized .claude/agents/ is git-status-invisible and writes no .gitignore (#1005)"

# Never clobber: a repo that TRACKS its own .claude/agents/<name>.md wins.
git init -q --initial-branch=main "$TMP/up1005own"
mkdir -p "$TMP/up1005own/claude/agents" "$TMP/up1005own/.claude/agents"
printf 'kernel source\n' > "$TMP/up1005own/claude/agents/docs-reviewer.md"
printf 'kernel source\n' > "$TMP/up1005own/claude/agents/workflow-reviewer.md"
printf 'PROJECT OVERRIDE\n' > "$TMP/up1005own/.claude/agents/docs-reviewer.md"
git -C "$TMP/up1005own" add -A
git -C "$TMP/up1005own" commit -q -m "repo tracks its own docs-reviewer override"
git clone -q "$TMP/up1005own" "$TMP/repo1005own"
REPO1005OWN="$(cd "$TMP/repo1005own" && pwd -P)"
bash "$SCRIPT" create "$REPO1005OWN" own >/dev/null
WT1005OWN="$REPO1005OWN.wt/own"
[ ! -L "$WT1005OWN/.claude/agents/docs-reviewer.md" ] \
  || fail "#1005: a repo's own tracked .claude/agents/ entry was clobbered by a link"
grep -q 'PROJECT OVERRIDE' "$WT1005OWN/.claude/agents/docs-reviewer.md" \
  || fail "#1005: the repo's own tracked agent content did not survive create"
[ -L "$WT1005OWN/.claude/agents/workflow-reviewer.md" ] \
  || fail "#1005: the un-conflicting agent was not materialized alongside the tracked one"
[ -z "$(git -C "$WT1005OWN" status --porcelain)" ] \
  || fail "#1005: materializing alongside a tracked .claude/agents/ dirtied the worktree"
echo "PASS: create never clobbers a repo's own tracked .claude/agents/ entry (#1005)"

# A repo with no claude/agents/ source at all is a clean no-op — no .claude/ is
# invented, and create still emits CREATED.
out="$(bash "$SCRIPT" create "$REPO" nosrc)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "#1005: no-source create not CREATED (got: $out)"
[ ! -e "$REPO.wt/nosrc/.claude" ] \
  || fail "#1005: a repo with no claude/agents/ source got a spurious .claude/ directory"
echo "PASS: create is a clean no-op in a repo with no claude/agents/ source (#1005)"

# =============================================================================
# Unlanded-work preservation (temperloop#1699)
# =============================================================================
# `clear_path` force-removes the worktree AND `git branch -D`s build/<slug>, so
# committing is not protection. The guard captures whatever would be lost to a
# LOCAL-ONLY ref outside refs/heads/ before the destruction, and reports the
# verdict as CREATED fields (never a new outcome string, never a refusal).
#
# A private upstream/clone pair per case keeps each assertion independent, in
# the same local-bare-upstream fixture style as the suite above. `gh` is stubbed
# onto PATH for every call in this section so nothing here touches the network:
# both merged-detect's Method 1 and the reap's issue-disposition gate would
# otherwise shell out to the real binary.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Offline gh stub. Default: fail like an unauthenticated/offline gh, which is
# the conservative arm every caller here is specified to take. `issue view` is
# answered from $GH_ISSUE_STATE when it is set, so the reap's disposition gate
# is exercised deterministically.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ] && [ -n "${GH_ISSUE_STATE:-}" ]; then
  printf '%s\n' "$GH_ISSUE_STATE"
  exit 0
fi
exit 1
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# mkfix <name> — a fresh upstream+clone pair; prints the clone's abs path.
mkfix() {
  git init -q --initial-branch=main "$TMP/up_$1"
  git -C "$TMP/up_$1" commit -q --allow-empty -m init
  git clone -q "$TMP/up_$1" "$TMP/repo_$1"
  (cd "$TMP/repo_$1" && pwd -P)
}

parked_refs() { git -C "$1" for-each-ref --format='%(refname)' 'refs/parked/*'; }

# --- committed-but-unlanded work survives clear_path --------------------------
R1="$(mkfix committed)"
bash "$SCRIPT" create "$R1" work-101 >/dev/null
printf 'reviewed work\n' > "$R1.wt/work-101/feature.txt"
git -C "$R1.wt/work-101" add feature.txt
git -C "$R1.wt/work-101" commit -q -m "the escalated worker's committed work"
lostsha="$(git -C "$R1.wt/work-101" rev-parse HEAD)"

out="$(bash "$SCRIPT" create "$R1" work-101)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] || fail "#1699: re-create not CREATED (got: $out)"
[ "$(jq -r .preserved <<<"$out")" = "true" ] || fail "#1699: committed work not preserved (got: $out)"
pref="$(jq -r .preserved_ref <<<"$out")"
case "$pref" in
  refs/parked/work-101-*) : ;;
  *) fail "#1699: preservation ref not refs/parked/<slug>-<sha8> (got: $pref)" ;;
esac
# The whole point: the destruction DID happen, and the work survived it anyway.
[ "$(git -C "$R1" rev-parse "$pref")" = "$lostsha" ] \
  || fail "#1699: preservation ref does not point at the destroyed commit"
git -C "$R1" cat-file -e "$lostsha^{commit}" \
  || fail "#1699: the committed work was garbage — the ref did not root it"
[ "$(git -C "$R1.wt/work-101" rev-parse HEAD)" = "$(git -C "$R1" rev-parse origin/main)" ] \
  || fail "#1699: the re-created worktree is not on a fresh base"
echo "PASS: clear_path preserves COMMITTED unlanded work to a local-only ref before destroying it (#1699)"

# The ref is outside refs/heads/, so it can never collide with an item whose own
# branch type is `build` (the build/<slug> == <type>/<slug> collision, #1702).
case "$pref" in
  refs/heads/*) fail "#1699: preservation ref lives in refs/heads/ — collides with build/<slug>" ;;
esac
git -C "$R1" show-ref --verify --quiet "refs/heads/${pref#refs/parked/}" \
  && fail "#1699: a refs/heads/ sibling of the preservation ref exists"
# `git push` moves refs/heads and tags only — assert the ref is invisible to the
# two refspecs a caller could plausibly reach for.
git -C "$R1" push -q --dry-run origin --all 2>/dev/null || true
[ -n "$(parked_refs "$R1")" ] || fail "#1699: preservation ref vanished"
echo "PASS: the preservation ref is local-only, outside refs/heads/ (#1699)"

# --- dirty work is captured WITHOUT authoring a semantic commit ---------------
R2="$(mkfix dirty)"
bash "$SCRIPT" create "$R2" work-202 >/dev/null
basetip="$(git -C "$R2.wt/work-202" rev-parse HEAD)"
printf 'uncommitted edit\n' > "$R2.wt/work-202/scratch.txt"
printf 'machinery\n' > "$R2.wt/work-202/.build-verification.md"
out="$(bash "$SCRIPT" create "$R2" work-202)"
[ "$(jq -r .preserved <<<"$out")" = "true" ] || fail "#1699: dirty tree not preserved (got: $out)"
pref2="$(jq -r .preserved_ref <<<"$out")"
psha2="$(git -C "$R2" rev-parse "$pref2")"
[ "$psha2" != "$basetip" ] || fail "#1699: dirty capture is just the tip — the edit was dropped"
[ "$(git -C "$R2" rev-parse "$pref2^")" = "$basetip" ] \
  || fail "#1699: the WIP capture's parent is not the branch tip"
git -C "$R2" show "$pref2:scratch.txt" > "$TMP/snap-scratch.txt" 2>/dev/null \
  || fail "#1699: scratch.txt is absent from the preserved snapshot"
grep -q 'uncommitted edit' "$TMP/snap-scratch.txt" \
  || fail "#1699: the uncommitted edit is not in the preserved snapshot"
# recover-probe's own exclusion pathspec: machinery artifacts are never captured.
git -C "$R2" cat-file -e "$pref2:.build-verification.md" 2>/dev/null \
  && fail "#1699: .build-verification.md was re-committed into the snapshot"
git -C "$R2" cat-file -e "$pref2:.build-guard" 2>/dev/null \
  && fail "#1699: .build-guard was re-committed into the snapshot"
# No semantic commit: the branch pointer never moved before it was destroyed —
# the capture is a detached WIP object, so a failed capture can never leave a
# half-committed branch behind (the false-PUSHED failure path).
[ "$(git -C "$R2" rev-parse "$pref2^{tree}")" != "$(git -C "$R2" rev-parse "$basetip^{tree}")" ] \
  || fail "#1699: the snapshot tree equals the tip tree — nothing was captured"
echo "PASS: dirty state is captured as a detached WIP object, machinery artifacts excluded (#1699)"

# The exclusion must be recover-probe's OWN PATHSPEC, not a lucky info/exclude.
# In this repo both markers are also ignored, which would let a pathspec-less
# `add -A` pass; a CONSUMING repo that never ignored them is the case the
# pathspec exists for (pr.sh's own comment on the same exclusion). Reproduce it
# by clearing the shared info/exclude before the capture runs.
R2B="$(mkfix dirtynoignore)"
bash "$SCRIPT" create "$R2B" work-212 >/dev/null
excl2b="$(cd "$R2B" && cd "$(git rev-parse --git-common-dir)" && pwd -P)/info/exclude"
: > "$excl2b"
printf 'real work\n' > "$R2B.wt/work-212/real.txt"
printf 'machinery\n' > "$R2B.wt/work-212/.build-verification.md"
[ -n "$(git -C "$R2B.wt/work-212" status --porcelain -- .build-guard)" ] \
  || fail "#1699 test setup bug: .build-guard must read as UNtracked here"
out="$(bash "$SCRIPT" create "$R2B" work-212)"
[ "$(jq -r .preserved <<<"$out")" = "true" ] || fail "#1699: un-ignored fixture did not preserve (got: $out)"
pref2b="$(jq -r .preserved_ref <<<"$out")"
git -C "$R2B" cat-file -e "$pref2b:real.txt" 2>/dev/null \
  || fail "#1699: the worker's real file is missing from the snapshot"
git -C "$R2B" cat-file -e "$pref2b:.build-verification.md" 2>/dev/null \
  && fail "#1699: .build-verification.md was captured — the exclusion PATHSPEC is missing"
git -C "$R2B" cat-file -e "$pref2b:.build-guard" 2>/dev/null \
  && fail "#1699: .build-guard was captured — the exclusion PATHSPEC is missing"
echo "PASS: the capture's exclusion is recover-probe's own pathspec, correct even where the markers are not ignored (#1699)"

# --- never a FALSE `preserved` -----------------------------------------------
# (a) nothing to lose → preserved:false with a reason, no ref minted
R3="$(mkfix clean)"
out="$(bash "$SCRIPT" create "$R3" work-303)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] || fail "#1699: a virgin path claimed preservation (got: $out)"
[ "$(jq -r .preserved_detail <<<"$out")" = "no-occupant" ] || fail "#1699: virgin-path detail (got: $out)"
out="$(bash "$SCRIPT" create "$R3" work-303)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] \
  || fail "#1699: a clean zero-commit worktree claimed preservation (got: $out)"
[ -z "$(parked_refs "$R3")" ] || fail "#1699: a ref was minted with nothing to preserve"
echo "PASS: nothing-to-preserve resolves to preserved:false with no ref minted (#1699)"

# (b) a FAILED capture resolves AWAY from claiming preservation
# Force the mint to fail deterministically with a directory/file ref conflict:
# `refs/parked/<slug>-<sha8>` cannot be created while `<...>/x` exists.
R4="$(mkfix mintfail)"
bash "$SCRIPT" create "$R4" work-404 >/dev/null
git -C "$R4.wt/work-404" commit -q --allow-empty -m "work that will fail to preserve"
fsha="$(git -C "$R4.wt/work-404" rev-parse HEAD)"
git -C "$R4" update-ref "refs/parked/work-404-${fsha:0:8}/x" "$fsha"
out="$(bash "$SCRIPT" create "$R4" work-404)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] \
  || fail "#1699: a failed capture must not turn create into a refusal (got: $out)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] \
  || fail "#1699: a failed capture claimed preservation (got: $out)"
case "$(jq -r .preserved_detail <<<"$out")" in
  capture-failed:*) : ;;
  *) fail "#1699: a failed capture must SAY so (got: $(jq -r .preserved_detail <<<"$out"))" ;;
esac
echo "PASS: a failed capture resolves AWAY from preserved, and create still CREATES (#1699)"

# (c) the ref already exists naming a DIFFERENT sha → disambiguate, never clobber
R5="$(mkfix refexists)"
bash "$SCRIPT" create "$R5" work-505 >/dev/null
git -C "$R5.wt/work-505" commit -q --allow-empty -m "work to preserve twice"
csha="$(git -C "$R5.wt/work-505" rev-parse HEAD)"
squatter="$(git -C "$R5" rev-parse origin/main)"
git -C "$R5" update-ref "refs/parked/work-505-${csha:0:8}" "$squatter"
out="$(bash "$SCRIPT" create "$R5" work-505)"
[ "$(jq -r .preserved <<<"$out")" = "true" ] || fail "#1699: collision case did not preserve (got: $out)"
[ "$(jq -r .preserved_ref <<<"$out")" = "refs/parked/work-505-${csha:0:8}-2" ] \
  || fail "#1699: collision was not disambiguated with a -2 suffix (got: $out)"
[ "$(git -C "$R5" rev-parse "refs/parked/work-505-${csha:0:8}")" = "$squatter" ] \
  || fail "#1699: the pre-existing ref was CLOBBERED"
[ "$(git -C "$R5" rev-parse "refs/parked/work-505-${csha:0:8}-2")" = "$csha" ] \
  || fail "#1699: the disambiguated ref does not name the preserved commit"
# Re-preserving the SAME sha is idempotent — one ref, not a third.
git -C "$R5" update-ref "refs/heads/build/work-505" "$csha"
out="$(bash "$SCRIPT" create "$R5" work-505)"
[ "$(jq -r .preserved_ref <<<"$out")" = "refs/parked/work-505-${csha:0:8}-2" ] \
  || fail "#1699: re-preserving the same sha minted a new ref (got: $out)"
echo "PASS: a preservation ref that already exists is disambiguated, never clobbered; same-sha is idempotent (#1699)"

# (d) work that ALREADY LANDED needs nothing — merged_detect_is_merged, not a
#     re-derived ancestry test (a squash-merged tip is not an ancestor).
# The SQUASH shape specifically: the tip is NOT an ancestor of origin/main even
# though the work landed, so a re-derived ancestry test would read it as
# unlanded and mint a pointless ref. merged_detect_is_merged is what gets it
# right (its Method-2 patch-id heuristic, offline).
R6="$(mkfix merged)"
bash "$SCRIPT" create "$R6" work-606 >/dev/null
printf 'landed content\n' > "$R6.wt/work-606/landed.txt"
git -C "$R6.wt/work-606" add landed.txt
git -C "$R6.wt/work-606" commit -q -m "work that squash-lands"
printf 'landed content\n' > "$TMP/up_merged/landed.txt"
git -C "$TMP/up_merged" add landed.txt
git -C "$TMP/up_merged" commit -q -m "work-606 (#1) squash-merged"
git -C "$TMP/up_merged" commit -q --allow-empty -m "main advances past the squash"
git -C "$R6" fetch -q origin main
git -C "$R6.wt/work-606" merge-base --is-ancestor HEAD origin/main \
  && fail "#1699 test setup bug: a squash-merged tip must NOT be an ancestor of origin/main"
out="$(bash "$SCRIPT" create "$R6" work-606)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] || fail "#1699: merged work was needlessly preserved (got: $out)"
[ "$(jq -r .preserved_detail <<<"$out")" = "not-needed:merged" ] \
  || fail "#1699: merged detail (got: $out)"
[ -z "$(parked_refs "$R6")" ] || fail "#1699: a ref was minted for already-merged work"
echo "PASS: already-landed work is not preserved (merged_detect ancestry gate, #1699)"

# (e) work already PUSHED needs nothing — recover-probe's RECOVER_PUSHED rung
R7="$(mkfix pushed)"
bash "$SCRIPT" create "$R7" work-707 >/dev/null
git -C "$R7.wt/work-707" commit -q --allow-empty -m "work that was pushed"
git -C "$R7.wt/work-707" push -q origin HEAD:refs/heads/build/work-707
out="$(bash "$SCRIPT" create "$R7" work-707)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] || fail "#1699: pushed work was needlessly preserved (got: $out)"
[ "$(jq -r .preserved_detail <<<"$out")" = "not-needed:pushed" ] \
  || fail "#1699: RECOVER_PUSHED rung not consumed (got: $out)"
echo "PASS: RECOVER_PUSHED / RECOVER_PR_OPEN need nothing — the probe's ladder is composed, not re-derived (#1699)"

# --- `remove` takes the same guard (the /sweep park finale, #1725) ------------
R8="$(mkfix removepark)"
bash "$SCRIPT" create "$R8" sweepitem-808 >/dev/null
printf 'sweep worker output\n' > "$R8.wt/sweepitem-808/out.txt"
git -C "$R8.wt/sweepitem-808" add out.txt
git -C "$R8.wt/sweepitem-808" commit -q -m "unattended sweep work"
sweepsha="$(git -C "$R8.wt/sweepitem-808" rev-parse HEAD)"
out="$(bash "$SCRIPT" remove "$R8" sweepitem-808)"
[ "$(jq -r .outcome <<<"$out")" = "REMOVED" ] || fail "#1725: remove outcome (got: $out)"
[ "$(jq -r .preserved <<<"$out")" = "true" ] || fail "#1725: remove destroyed unlanded work (got: $out)"
[ "$(git -C "$R8" rev-parse "$(jq -r .preserved_ref <<<"$out")")" = "$sweepsha" ] \
  || fail "#1725: remove's preservation ref does not name the destroyed commit"
[ ! -e "$R8.wt/sweepitem-808" ] || fail "#1725: worktree survived remove"
echo "PASS: remove preserves before destroying too — /sweep's unattended park finale (#1725)"

# =============================================================================
# restore: re-apply a preservation ref WITHOUT assuming a fast-forward
# =============================================================================

# (a) the DIVERGED base — origin/<default> advanced while the question sat open.
#     This is the case the superseded prose asserted could not happen.
R9="$(mkfix restore)"
bash "$SCRIPT" create "$R9" item-909 >/dev/null
printf 'worker output\n' > "$R9.wt/item-909/worker.txt"
git -C "$R9.wt/item-909" add worker.txt
git -C "$R9.wt/item-909" commit -q -m "escalated worker's committed work"
wsha="$(git -C "$R9.wt/item-909" rev-parse HEAD)"
out="$(bash "$SCRIPT" remove "$R9" item-909)"
ref909="$(jq -r .preserved_ref <<<"$out")"
[ -n "$ref909" ] && [ "$ref909" != "null" ] || fail "#1699: restore fixture did not preserve (got: $out)"
# main advances underneath the parked work (a sibling item merges).
printf 'someone else landed this\n' > "$TMP/up_restore/other.txt"
git -C "$TMP/up_restore" add other.txt
git -C "$TMP/up_restore" commit -q -m "main advances while the question sits open"
git -C "$R9" fetch -q origin main
git -C "$R9" merge-base --is-ancestor origin/main "$ref909" \
  && fail "#1699 test setup bug: the base must have DIVERGED (fast-forward must be impossible)"

out="$(bash "$SCRIPT" restore "$R9" item-909)"
[ "$(jq -r .outcome <<<"$out")" = "RESTORED" ] || fail "#1699: diverged restore not RESTORED (got: $out)"
[ "$(jq -r .strategy <<<"$out")" = "merge" ] \
  || fail "#1699: a diverged base must restore by MERGE, not fast-forward (got: $out)"
[ -f "$R9.wt/item-909/worker.txt" ] || fail "#1699: the preserved work is not in the restored worktree"
[ -f "$R9.wt/item-909/other.txt" ] || fail "#1699: the advanced base is not in the restored worktree"
git -C "$R9.wt/item-909" merge-base --is-ancestor "$wsha" HEAD \
  || fail "#1699: the preserved commit is not an ancestor of the restored HEAD"
git -C "$R9.wt/item-909" merge-base --is-ancestor origin/main HEAD \
  || fail "#1699: the restored HEAD does not contain the advanced base"
[ -z "$(git -C "$R9.wt/item-909" status --porcelain)" ] \
  || fail "#1699: restore left the worktree dirty"
echo "PASS: restore re-applies a preservation ref onto a DIVERGED base by merge, never assuming a fast-forward (#1699)"

# (b) the fast-forwardable case still fast-forwards (no gratuitous merge commit)
R10="$(mkfix restoreff)"
bash "$SCRIPT" create "$R10" item-1010 >/dev/null
printf 'ff work\n' > "$R10.wt/item-1010/ff.txt"
git -C "$R10.wt/item-1010" add ff.txt
git -C "$R10.wt/item-1010" commit -q -m "ff-able work"
ffsha="$(git -C "$R10.wt/item-1010" rev-parse HEAD)"
bash "$SCRIPT" remove "$R10" item-1010 >/dev/null
out="$(bash "$SCRIPT" restore "$R10" item-1010)"
[ "$(jq -r .outcome <<<"$out")" = "RESTORED" ] || fail "#1699: ff restore not RESTORED (got: $out)"
[ "$(jq -r .strategy <<<"$out")" = "fast-forward" ] || fail "#1699: ff case did not fast-forward (got: $out)"
[ "$(git -C "$R10.wt/item-1010" rev-parse HEAD)" = "$ffsha" ] \
  || fail "#1699: fast-forward did not land exactly on the preserved commit"
echo "PASS: restore fast-forwards when it genuinely can (#1699)"

# (c) a CONFLICT is a named result, never a silent partial merge
R11="$(mkfix restoreconflict)"
printf 'original\n' > "$TMP/up_restoreconflict/shared.txt"
git -C "$TMP/up_restoreconflict" add shared.txt
git -C "$TMP/up_restoreconflict" commit -q -m "seed shared.txt"
git -C "$R11" fetch -q origin main
bash "$SCRIPT" create "$R11" item-1111 >/dev/null
printf 'worker version\n' > "$R11.wt/item-1111/shared.txt"
git -C "$R11.wt/item-1111" commit -q -am "worker edits shared.txt"
bash "$SCRIPT" remove "$R11" item-1111 >/dev/null
printf 'main version\n' > "$TMP/up_restoreconflict/shared.txt"
git -C "$TMP/up_restoreconflict" commit -q -am "main edits shared.txt too"
git -C "$R11" fetch -q origin main

out="$(bash "$SCRIPT" restore "$R11" item-1111)"
[ "$(jq -r .outcome <<<"$out")" = "RESTORE_CONFLICT" ] \
  || fail "#1699: a conflicting restore is not a named result (got: $out)"
[ "$(jq -r '.conflicts | index("shared.txt")' <<<"$out")" != "null" ] \
  || fail "#1699: RESTORE_CONFLICT must name the conflicted path (got: $out)"
[ "$(jq -r .aborted <<<"$out")" = "true" ] || fail "#1699: conflict was not aborted (got: $out)"
[ -z "$(git -C "$R11.wt/item-1111" status --porcelain)" ] \
  || fail "#1699: a conflicted restore left a partial merge on disk"
grep -q '<<<<<<<' "$R11.wt/item-1111/shared.txt" \
  && fail "#1699: conflict markers were left in the worktree"
# Nothing is lost: the preservation ref still holds the work.
[ -n "$(parked_refs "$R11")" ] || fail "#1699: a conflicting restore consumed the preservation ref"
echo "PASS: a restore conflict is a named result with the merge aborted and the ref intact (#1699)"

# (d) no preservation ref for the slug → RESTORE_NOT_FOUND, not a silent success
R12="$(mkfix restorenone)"
out="$(bash "$SCRIPT" restore "$R12" item-1212)"
[ "$(jq -r .outcome <<<"$out")" = "RESTORE_NOT_FOUND" ] \
  || fail "#1699: a missing preservation ref must be RESTORE_NOT_FOUND (got: $out)"
[ ! -e "$R12.wt/item-1212" ] || fail "#1699: RESTORE_NOT_FOUND must not stand a worktree up"
rc=0; out="$(bash "$SCRIPT" restore "$R12" item-1212 --ref refs/heads/build/item-1212 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "#1699: a refs/heads/ --ref did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "#1699: a refs/heads/ --ref must be a structured ERROR (got: $out)"
echo "PASS: restore reports RESTORE_NOT_FOUND / ERROR rather than a silent success (#1699)"

# =============================================================================
# prune: the preservation ref's named reap owner
# =============================================================================
# Gate 1 (ancestry): the preserved commit reached the merged tip → reap.
R13="$(mkfix reapland)"
bash "$SCRIPT" create "$R13" reap-1313 >/dev/null
git -C "$R13.wt/reap-1313" commit -q --allow-empty -m "work that will land"
bash "$SCRIPT" remove "$R13" reap-1313 >/dev/null
landref="$(parked_refs "$R13")"
[ -n "$landref" ] || fail "#1699: reap fixture did not preserve"
landsha="$(git -C "$R13" rev-parse "$landref")"
git -C "$TMP/up_reapland" fetch -q "$R13" "$landref:refs/heads/landing"
git -C "$TMP/up_reapland" merge -q --no-edit landing
out="$(bash "$SCRIPT" prune "$R13")"
[ "$(jq -r --arg r "$landref" 'select(.ref==$r).outcome' <<<"$out")" = "PARKED_REF_REAPED" ] \
  || fail "#1699: a landed preservation ref was not reaped (got: $out)"
[ -z "$(parked_refs "$R13")" ] || fail "#1699: the landed ref survived the reap"
git -C "$R13" cat-file -e "$landsha^{commit}" 2>/dev/null || true
echo "PASS: prune reaps a preservation ref whose commit is an ancestor of the merged tip (#1699)"

# Gate 2 (disposition) + the floor: an UNLANDED ref is reaped only once its
# originating issue reaches a terminal state; an OPEN or UNEVALUABLE issue is
# REPORTED and never reaped.
R14="$(mkfix reapissue)"
bash "$SCRIPT" create "$R14" featurework-1699 >/dev/null
git -C "$R14.wt/featurework-1699" commit -q --allow-empty -m "unlanded parked work"
bash "$SCRIPT" remove "$R14" featurework-1699 >/dev/null
iref="$(parked_refs "$R14")"
[ -n "$iref" ] || fail "#1699: issue-gate fixture did not preserve"

# unevaluable (the stub's default: an offline/unauthenticated gh) → FALSE
out="$(bash "$SCRIPT" prune "$R14")"
line="$(jq -c --arg r "$iref" 'select(.ref==$r)' <<<"$out")"
[ "$(jq -r .outcome <<<"$line")" = "PARKED_REF" ] \
  || fail "#1699: an unevaluable issue check must NOT reap (got: $line)"
[ "$(jq -r .issue <<<"$line")" = "1699" ] \
  || fail "#1699: the originating issue was not parsed off the slug (got: $line)"
[ "$(jq -r .issue_state <<<"$line")" = "unknown" ] || fail "#1699: unevaluable issue_state (got: $line)"
[ "$(jq -r .landed <<<"$line")" = "false" ] || fail "#1699: unlanded ref reported landed (got: $line)"
[ -n "$(parked_refs "$R14")" ] || fail "#1699: an unevaluable check reaped the ref"

# OPEN → reported, never reaped
out="$(GH_ISSUE_STATE=OPEN bash "$SCRIPT" prune "$R14")"
line="$(jq -c --arg r "$iref" 'select(.ref==$r)' <<<"$out")"
[ "$(jq -r .outcome <<<"$line")" = "PARKED_REF" ] \
  || fail "#1699: a ref whose originating issue is OPEN was reaped (got: $line)"
[ "$(jq -r .issue_state <<<"$line")" = "open" ] || fail "#1699: OPEN issue_state (got: $line)"
[ -n "$(parked_refs "$R14")" ] || fail "#1699: the open-issue ref was reaped"

# CLOSED → the disposition gate fires. This is the ONLY gate that can ever fire
# for a /sweep-originated ref, which is never restored in place and so never
# becomes an ancestor of the merged tip.
out="$(GH_ISSUE_STATE=CLOSED bash "$SCRIPT" prune "$R14")"
line="$(jq -c --arg r "$iref" 'select(.ref==$r)' <<<"$out")"
[ "$(jq -r .outcome <<<"$line")" = "PARKED_REF_REAPED" ] \
  || fail "#1699: a terminal-disposition ref was not reaped (got: $line)"
[ "$(jq -r .reason <<<"$line")" = "reaped:issue-terminal" ] || fail "#1699: reap reason (got: $line)"
[ -z "$(parked_refs "$R14")" ] || fail "#1699: the terminal-disposition ref survived"
echo "PASS: prune's reap gates — ancestry OR terminal disposition, unevaluable is FALSE, an open issue is reported not reaped (#1699)"

# prune's parked-ref lines must never inflate deploy-mini.sh's PRUNED count.
R15="$(mkfix reapcount)"
bash "$SCRIPT" create "$R15" count-1515 >/dev/null
git -C "$R15.wt/count-1515" commit -q --allow-empty -m "parked"
bash "$SCRIPT" remove "$R15" count-1515 >/dev/null
out="$(bash "$SCRIPT" prune "$R15")"
[ "$(grep -c '"outcome":"PRUNED"' <<<"$out")" = "0" ] \
  || fail "#1699: a parked-ref line was counted as a PRUNED worktree (got: $out)"
echo "PASS: parked-ref outcomes are distinct from PRUNED (deploy-mini's counter is unaffected) (#1699)"

# =============================================================================
# Never destroy what preservation failed to capture (temperloop#1730)
# =============================================================================
# #1699 above proves the HAPPY path: when the capture succeeds, the work
# survives the destruction. These cases prove the FAILURE path — the one the
# `|| true` at both call sites used to swallow, destroying the work with
# nothing captured. The two destroying callers diverge deliberately:
# `remove` REFUSES, `create` SIDELINES and still CREATES.

# ACTIVATION PROOF: the swallow is gone from BOTH destroying primitives.
# `grep -F` deliberately — a plain BRE containing `"$repo"` is mis-handled by
# BSD grep, so a fixed-string match is the only reliable form here.
grep -F -- 'preserve_unlanded "$repo" "$wt_path" "$branch" || true' "$SCRIPT" \
  && fail "#1730: a destroying call site still swallows preserve_unlanded's verdict with || true"
[ "$(grep -F -- 'preserve_unlanded ' "$SCRIPT" | grep -v '^[[:space:]]*#' | grep -c -F -- '|| true')" = "0" ] \
  || fail "#1730: some preserve_unlanded CALL (non-comment line) still carries || true"
echo "PASS: neither destroying path swallows a preserve_unlanded failure — the || true is gone (#1730)"

# --- fixture helpers: force each of the four capture-failure details ----------
#
# Each helper leaves an OCCUPANT at the deterministic path/branch that
# preserve_unlanded is guaranteed to fail to capture, and echoes the detail
# prefix it forces. Together they cover the closed failure set.

# capture-failed:ref-mint — a directory/file ref conflict makes update-ref fail
# for every candidate name (the #1699 mintfail technique).
fx_ref_mint() {
  local repo="$1" slug="$2" sha
  bash "$SCRIPT" create "$repo" "$slug" >/dev/null
  printf 'unpreservable work\n' > "$repo.wt/$slug/work.txt"
  git -C "$repo.wt/$slug" add work.txt
  git -C "$repo.wt/$slug" commit -q -m "work that cannot be preserved"
  sha="$(git -C "$repo.wt/$slug" rev-parse HEAD)"
  git -C "$repo" update-ref "refs/parked/${slug}-${sha:0:8}/x" "$sha"
}

# capture-failed:snapshot — the worktree dir is present (so have_wt=1) but its
# gitdir link is broken, so preserve_capture's own `rev-parse HEAD` fails.
fx_snapshot() {
  local repo="$1" slug="$2"
  bash "$SCRIPT" create "$repo" "$slug" >/dev/null
  git -C "$repo.wt/$slug" commit -q --allow-empty -m "work that cannot be snapshotted"
  printf 'gitdir: /nonexistent/broken\n' > "$repo.wt/$slug/.git"
}

# capture-failed:no-commit — no worktree dir at all, and `build/<slug>` names a
# non-commit object, so the branch tip resolves to nothing to preserve.
fx_no_commit() {
  local repo="$1" slug="$2" tree common
  bash "$SCRIPT" create "$repo" "$slug" >/dev/null
  tree="$(git -C "$repo" rev-parse 'origin/main^{tree}')"
  git -C "$repo" worktree remove --force "$repo.wt/$slug"
  common="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  mkdir -p "$common/refs/heads/build"
  printf '%s\n' "$tree" > "$common/refs/heads/build/$slug"
}

# unclassifiable:no-default-branch — an occupant exists but origin's default
# branch cannot be resolved at all.
fx_no_default() {
  local repo="$1" slug="$2"
  bash "$SCRIPT" create "$repo" "$slug" >/dev/null
  git -C "$repo.wt/$slug" commit -q --allow-empty -m "work with no classifiable base"
  git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD
  git -C "$repo" update-ref -d refs/remotes/origin/main
}

# --- `remove` REFUSES on every one of the four failure details ----------------
# A leaked worktree is recoverable by hand; a `git branch -D`'d branch is not.
for case_spec in \
  "refmint:fx_ref_mint:capture-failed:ref-mint" \
  "snapshot:fx_snapshot:capture-failed:snapshot" \
  "nocommit:fx_no_commit:capture-failed:no-commit" \
  "nodefault:fx_no_default:unclassifiable:no-default-branch" ; do
  cname="${case_spec%%:*}"; rest="${case_spec#*:}"
  fx="${rest%%:*}"; want="${rest#*:}"
  RC="$(mkfix "refuse$cname")"
  slug="refuse${cname}-1730"
  "$fx" "$RC" "$slug"
  rc=0
  out="$(bash "$SCRIPT" remove "$RC" "$slug")" || rc=$?
  [ "$rc" -ne 0 ] || fail "#1730[$cname]: remove exited 0 on a capture failure (got: $out)"
  [ "$(jq -r .outcome <<<"$out")" = "REMOVE_REFUSED" ] \
    || fail "#1730[$cname]: refusal is not a named outcome (got: $out)"
  [ "$(jq -r .preserved <<<"$out")" = "false" ] \
    || fail "#1730[$cname]: a refusal claimed preservation (got: $out)"
  # The verbatim detail, not a re-worded summary — the operator needs the
  # machine's own classification to know WHICH failure this was.
  case "$(jq -r .preserved_detail <<<"$out")" in
    "$want"*) : ;;
    *) fail "#1730[$cname]: expected detail '$want*' (got: $(jq -r .preserved_detail <<<"$out"))" ;;
  esac
  # …and the STILL-STANDING path, so the operator can go look at it.
  [ "$(jq -r .path <<<"$out")" = "$RC.wt/$slug" ] \
    || fail "#1730[$cname]: refusal does not report the still-standing path (got: $out)"
  # THE POINT: nothing was destroyed.
  if [ "$cname" != "nocommit" ]; then
    [ -e "$RC.wt/$slug" ] || fail "#1730[$cname]: the worktree was destroyed by a REFUSED remove"
  fi
  git -C "$RC" show-ref --verify --quiet "refs/heads/build/$slug" \
    || fail "#1730[$cname]: build/$slug was force-deleted by a REFUSED remove"
done
echo "PASS: remove REFUSES (non-zero + REMOVE_REFUSED + verbatim detail + standing path) on all four capture failures, destroying nothing (#1730)"

# --- `create` SIDELINES and still CREATES ------------------------------------
# create can never refuse — a refusing create turns /build's prelude batch from
# 'created' into 'escalated' — so the un-preservable occupant is MOVED ASIDE.
R16="$(mkfix sideline)"
fx_ref_mint "$R16" sideitem-1730
sidesha="$(git -C "$R16.wt/sideitem-1730" rev-parse HEAD)"
out="$(bash "$SCRIPT" create "$R16" sideitem-1730)"
[ "$(jq -r .outcome <<<"$out")" = "CREATED" ] \
  || fail "#1730: a capture failure turned create into a refusal (got: $out)"
[ "$(jq -r .preserved <<<"$out")" = "false" ] || fail "#1730: sideline case claimed preservation (got: $out)"
[ "$(jq -r .sidelined <<<"$out")" = "true" ] || fail "#1730: create did not report the sideline (got: $out)"
sidepath="$(jq -r .sidelined_path <<<"$out")"
sidebranch="$(jq -r .sidelined_branch <<<"$out")"
case "$sidepath" in
  "$R16.wt/sideitem-1730.unpreserved-"*) : ;;
  *) fail "#1730: sidelined path is not <path>.unpreserved-<sha8> (got: $sidepath)" ;;
esac
# The work is RECOVERABLE: both halves moved aside, neither destroyed.
[ -d "$sidepath" ] || fail "#1730: the sidelined worktree does not exist"
[ -f "$sidepath/work.txt" ] || fail "#1730: the worker's file is missing from the sidelined worktree"
git -C "$R16" show-ref --verify --quiet "refs/heads/$sidebranch" \
  || fail "#1730: the sidelined branch was not preserved (got: $sidebranch)"
[ "$(git -C "$R16" rev-parse "$sidebranch")" = "$sidesha" ] \
  || fail "#1730: the sidelined branch does not name the un-preservable commit"
# …and create genuinely CREATED: a fresh worktree on a fresh base at the
# deterministic path, on the deterministic branch.
[ -d "$R16.wt/sideitem-1730" ] || fail "#1730: create did not stand a fresh worktree up"
[ "$(git -C "$R16.wt/sideitem-1730" rev-parse --abbrev-ref HEAD)" = "build/sideitem-1730" ] \
  || fail "#1730: the fresh worktree is not on build/sideitem-1730"
[ "$(git -C "$R16.wt/sideitem-1730" rev-parse HEAD)" = "$(git -C "$R16" rev-parse origin/main)" ] \
  || fail "#1730: the fresh worktree is not based on origin/main"
echo "PASS: a capture failure SIDELINES the prior work (worktree + branch moved aside, recoverable) and create still returns CREATED (#1730)"

# --- prune reports a sidelined worktree the way it reports a PARKED_REF -------
# Same two gates, same conservative floor: an unevaluable check is FALSE.
out="$(bash "$SCRIPT" prune "$R16")"
sline="$(jq -c --arg p "$sidepath" 'select(.path==$p)' <<<"$out")"
[ "$(jq -r .outcome <<<"$sline")" = "SIDELINED_WT" ] \
  || fail "#1730: an unevaluable sidelined worktree was not REPORTED (got: $out)"
[ "$(jq -r .slug <<<"$sline")" = "sideitem-1730" ] \
  || fail "#1730: the originating slug was not parsed off the sidelined path (got: $sline)"
[ "$(jq -r .issue <<<"$sline")" = "1730" ] \
  || fail "#1730: the originating issue was not parsed off the slug (got: $sline)"
[ "$(jq -r .issue_state <<<"$sline")" = "unknown" ] || fail "#1730: unevaluable issue_state (got: $sline)"
[ "$(jq -r .landed <<<"$sline")" = "false" ] || fail "#1730: unlanded sidelined wt reported landed (got: $sline)"
[ -d "$sidepath" ] || fail "#1730: an unevaluable check REAPED the sidelined worktree"
# A parked/sidelined line must never inflate deploy-mini.sh's PRUNED counter.
[ "$(jq -r --arg p "$sidepath" 'select(.path==$p).outcome' <<<"$out" | grep -c '^PRUNED$')" = "0" ] \
  || fail "#1730: a sidelined worktree was counted as PRUNED (got: $out)"

# OPEN issue → reported, never reaped. And --force does NOT reach this path:
# it overrides prune_one's dirty/fresh heuristics, not a conservative gate.
out="$(GH_ISSUE_STATE=OPEN bash "$SCRIPT" prune "$R16" --force)"
sline="$(jq -c --arg p "$sidepath" 'select(.path==$p)' <<<"$out")"
[ "$(jq -r .outcome <<<"$sline")" = "SIDELINED_WT" ] \
  || fail "#1730: a sidelined worktree whose issue is OPEN was reaped (got: $sline)"
[ "$(jq -r .issue_state <<<"$sline")" = "open" ] || fail "#1730: OPEN issue_state (got: $sline)"
[ -d "$sidepath" ] || fail "#1730: --force reaped an open-issue sidelined worktree"

# CLOSED issue → the disposition gate fires; worktree AND branch reclaimed.
out="$(GH_ISSUE_STATE=CLOSED bash "$SCRIPT" prune "$R16")"
sline="$(jq -c --arg p "$sidepath" 'select(.path==$p)' <<<"$out")"
[ "$(jq -r .outcome <<<"$sline")" = "SIDELINED_WT_REAPED" ] \
  || fail "#1730: a terminal-disposition sidelined worktree was not reaped (got: $sline)"
[ "$(jq -r .reason <<<"$sline")" = "reaped:issue-terminal" ] || fail "#1730: reap reason (got: $sline)"
[ ! -e "$sidepath" ] || fail "#1730: the reaped sidelined worktree survived"
git -C "$R16" show-ref --verify --quiet "refs/heads/$sidebranch" \
  && fail "#1730: the reaped sidelined branch survived"
echo "PASS: prune reports sidelined worktrees like PARKED_REF — unevaluable is FALSE, an open issue is never reaped, --force does not override (#1730)"
