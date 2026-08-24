#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/pr.sh — the build push + PR-open
# mechanics CLI (epic #253, spike #245). Board-toolkit fixture style: a
# throwaway real-git bare upstream + clone in a tmpdir, a stubbed `gh` on
# PATH, zero network, structured-output assertions via jq.
#
# Covers:
#   - scan: clean commit messages → SCAN_CLEAN; a `Closes #153` commit (the
#     ec8d5fd class) → SCAN_BLOCKED + offending line + non-zero exit
#   - base-check: BASE_CURRENT on a current base; BASE_STALE once upstream advances
#   - rebase (temperloop#735): the dirty-vs-conflict split — a genuine content
#     clash is REBASE_CONFLICT, an uncommitted tracked-file edit is DIRTY_WORKTREE
#     (edit preserved, HEAD unmoved, `rebase_needed` telling base==tip from a real
#     stale base), untracked files are not dirt, and the SAME conflicting fixture
#     flips between the two outcomes purely on whether the tree is clean
#   - push: push-by-SHA places the branch on a local bare remote → PUSHED;
#     non-fast-forward → PUSH_REJECTED + non-zero; --force recovers
#   - push (temperloop#1688): the open-PR survey — a push onto a ref no open PR
#     references while a sibling PR sits on a DIFFERENT ref for the same slug is
#     PUSHED_UNWATCHED + non-zero, naming both refs and `stale_head_cause`; the
#     benign neighbours it must NOT fire on are all pinned as controls (a PR
#     whose head ref MATCHES but whose head sha trails — genuine GitHub lag; the
#     ordinary first push with no PR anywhere; an unrelated PR on a different
#     slug; a bounded-listing miss the --head confirm resolves; an erroring gh)
#   - open --body-only: per-entry bare `Closes` emission (gh_issue=278 +
#     also_closes=[171] → exactly `Closes #278` and `Closes #171`, own lines,
#     never combined, never backticked); acceptance recap; ## Verification;
#     backlinks + footer; fallback-to-recap when verification_surface absent
#   - acceptance-extract (temperloop#1267): the recap round-trips BYTE-EXACTLY
#     when ` — ` appears inside the criterion AND inside the evidence (evidence
#     now rides its own nested line, so the split is positional, not a
#     first-vs-last-em-dash guess); multi-line criteria, an evidence-less entry,
#     a decoy `## Acceptance` inside the worker's own surface, `-` stdin, an
#     empty result for a recap-less body, and a structured ERROR on a bad path
#   - open (temperloop#1023): a worker surface carrying its OWN copy of the
#     linkage block is stripped down to one block, a surface with no honored
#     closing-keyword line (mid-sentence / backticked / indented / fenced) is
#     passed through byte-for-byte, and the count rides `surface_closes_stripped`
#   - open (stubbed gh): PR_OPENED with parsed pr_number; body/head passed to gh
#   - recover-probe (temperloop#939): the staged lost-return ladder — RECOVER_NONE
#     / _COMMITTED / _PUSHED / _PR_OPEN across the four real fixture states, plus
#     the fail-soft degradation when `gh` errors
#   - recover-probe (temperloop#993): the RECOVER_DIRTY rung — a dirty worktree
#     with ZERO commits (the backgrounded-gate stall) is distinguished from a
#     clean RECOVER_NONE, and dirty/dirty_files ride every outcome
#   - error: structured ERROR + non-zero exit on bad inputs
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fixture: a BARE upstream (push-able) + a clone with main pushed, so
# origin/main exists — the same shape a real checkout has.
git init -q --bare --initial-branch=main "$TMP/upstream.git"
git clone -q "$TMP/upstream.git" "$TMP/repo" 2>/dev/null
git -C "$TMP/repo" commit -q --allow-empty -m init
git -C "$TMP/repo" push -q origin main 2>/dev/null
git -C "$TMP/repo" fetch -q origin
REPO="$(cd "$TMP/repo" && pwd -P)"
BARE="$TMP/upstream.git"

# --- scan: clean messages pass -------------------------------------------------
git -C "$REPO" checkout -q -b clean-br origin/main
git -C "$REPO" commit -q --allow-empty -m "add widget renderer" \
  -m "Plain description; mentions issue #153 without a closing keyword."
out="$(bash "$SCRIPT" scan "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "SCAN_CLEAN" ] || fail "clean scan not SCAN_CLEAN (got: $out)"
echo "PASS: scan → SCAN_CLEAN on closing-keyword-free commit messages"

# --- scan: a Closes #153 commit message blocks (the ec8d5fd class) --------------
git -C "$REPO" checkout -q -b bad-br origin/main
git -C "$REPO" commit -q --allow-empty -m "implement widget" -m "Closes #153"
rc=0; out="$(bash "$SCRIPT" scan "$REPO")" || rc=$?
[ "$rc" -ne 0 ] || fail "SCAN_BLOCKED did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "SCAN_BLOCKED" ] || fail "bad scan not SCAN_BLOCKED (got: $out)"
jq -e '.matches | index("Closes #153")' <<<"$out" >/dev/null \
  || fail "offending line not surfaced in .matches (got: $out)"
# Case-insensitive + other keywords: `fixes #12` blocks too.
git -C "$REPO" checkout -q -b bad-br2 origin/main
git -C "$REPO" commit -q --allow-empty -m "tweak widget" -m "this fixes #12 for good"
rc=0; out="$(bash "$SCRIPT" scan "$REPO")" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "SCAN_BLOCKED" ] \
  || fail "lowercase 'fixes #12' not blocked (got: $out)"
echo "PASS: scan → SCAN_BLOCKED + offending lines + non-zero exit on closing keywords"

# --- base-check: current base ----------------------------------------------------
git -C "$REPO" checkout -q clean-br
out="$(bash "$SCRIPT" base-check "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "BASE_CURRENT" ] || fail "base-check not BASE_CURRENT (got: $out)"
[ "$(jq -r .merge_base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "BASE_CURRENT but merge_base != tip (got: $out)"
echo "PASS: base-check → BASE_CURRENT when merge-base == origin/<default> tip"

# --- base-check: stale base after upstream advances ------------------------------
git clone -q "$BARE" "$TMP/advancer" 2>/dev/null
git -C "$TMP/advancer" -c user.name=test -c user.email=test@test \
  commit -q --allow-empty -m "level-k merge advances main"
git -C "$TMP/advancer" push -q origin main 2>/dev/null
out="$(bash "$SCRIPT" base-check "$REPO")"   # clean-br branched from the OLD tip
[ "$(jq -r .outcome <<<"$out")" = "BASE_STALE" ] || fail "base-check not BASE_STALE (got: $out)"
[ "$(jq -r .merge_base <<<"$out")" != "$(jq -r .tip <<<"$out")" ] \
  || fail "BASE_STALE but merge_base == tip (got: $out)"
echo "PASS: base-check → BASE_STALE once origin/<default> advances past the base"

# --- rebase: stale, non-conflicting base → REBASED onto the advanced tip ----------
# clean-br carries its own commit branched off the OLD tip; origin/main has since
# advanced (the advancer pushed an empty commit above). The worker's commit
# touches no file the advance touched, so the rebase replays cleanly. The PR diff
# vs the NEW tip must then contain ONLY the worker's own change — the #525 fix.
new_tip="$(git -C "$REPO" rev-parse origin/main)"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "rebase not REBASED (got: $out)"
# HEAD is now a descendant of the advanced origin/main tip (base brought current).
[ "$(git -C "$REPO" merge-base HEAD origin/main)" = "$new_tip" ] \
  || fail "rebase did not bring HEAD's base onto the advanced origin/main tip"
[ "$(jq -r .sha <<<"$out")" = "$(git -C "$REPO" rev-parse HEAD)" ] \
  || fail "REBASED .sha != post-rebase HEAD (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "true" ] \
  || fail "a stale base did not report rebase_needed:true (got: $out)"
# The cumulative diff vs the new tip is ONLY the worker's own commit (no revert of
# the intervening merge): exactly one commit ahead of origin/main.
[ "$(git -C "$REPO" rev-list --count origin/main..HEAD)" -eq 1 ] \
  || fail "rebased branch not exactly 1 commit ahead of advanced origin/main"
echo "PASS: rebase → REBASED replays the worker commit onto the advanced origin/<default> tip"

# --- rebase: already-current base → REBASED (no-op) --------------------------------
# A branch whose base is already the origin/main tip rebases to a no-op and still
# reports REBASED — the unconditional guard never errors on a current worker.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b current-br origin/main
git -C "$REPO" commit -q --allow-empty -m "on current tip"
cur_sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] || fail "current-base rebase not REBASED (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$cur_sha" ] || fail "no-op rebase changed HEAD (got: $out)"
# temperloop#735: base == tip is reported as such — the rebase is SKIPPED, not run.
[ "$(jq -r .rebase_needed <<<"$out")" = "false" ] \
  || fail "current-base REBASED did not report rebase_needed:false (got: $out)"
[ "$(jq -r .base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "rebase_needed:false but base != tip (got: $out)"
echo "PASS: rebase → REBASED no-op (rebase_needed:false) when the worker's base is already current"

# --- rebase: untracked files are NOT dirt ------------------------------------------
# git rebases straight past untracked files, and every build worktree carries at
# least the untracked `.build-guard` marker — so an untracked file must never be
# read as a dirty worktree (temperloop#735).
printf 'scratch\n' > "$REPO/untracked-scratch.txt"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] \
  || fail "untracked file read as dirt (got: $out)"
rm -f "$REPO/untracked-scratch.txt"
echo "PASS: rebase → REBASED with an untracked file present (untracked ≠ dirty)"

# --- rebase: dirty worktree, base already current → DIRTY_WORKTREE -----------------
# The temperloop#735 case, verbatim: a FINISHED worker (commit made) that left one
# tracked file unstaged, on a base that is already current — so no rebase was ever
# needed and no conflict exists anywhere. git refuses to start the rebase; that
# refusal must NOT be reported as REBASE_CONFLICT, and the worker's uncommitted
# edit must be left exactly where it is (this run would otherwise be discarded).
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b dirty-current origin/main
printf 'committed\n' > "$REPO/worker.txt"
git -C "$REPO" add worker.txt
git -C "$REPO" commit -q -m "worker commits worker.txt"
dirty_sha="$(git -C "$REPO" rev-parse HEAD)"
printf 'forgotten unstaged edit\n' >> "$REPO/worker.txt"     # the load-bearing leftover
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "DIRTY_WORKTREE did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "DIRTY_WORKTREE" ] \
  || fail "unstaged-changes refusal not DIRTY_WORKTREE (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "false" ] \
  || fail "DIRTY_WORKTREE on a current base did not report rebase_needed:false (got: $out)"
[ "$(jq -r .base <<<"$out")" = "$(jq -r .tip <<<"$out")" ] \
  || fail "the #735 base==tip fact is not visible in the payload (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "1" ] || fail "dirty_files != 1 (got: $out)"
jq -e '.dirty_paths | join(" ") | test("worker[.]txt")' <<<"$out" >/dev/null \
  || fail "the offending path is not named in .dirty_paths (got: $out)"
# Nothing was attempted, so nothing was aborted: HEAD intact AND the edit intact.
[ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ] \
  || fail "DIRTY_WORKTREE left a rebase in progress"
[ "$(git -C "$REPO" rev-parse HEAD)" = "$dirty_sha" ] \
  || fail "DIRTY_WORKTREE moved HEAD"
grep -q 'forgotten unstaged edit' "$REPO/worker.txt" \
  || fail "DIRTY_WORKTREE destroyed the worker's uncommitted edit"
# Committing the leftover is all it takes: the same tree then rebases clean.
git -C "$REPO" add worker.txt
git -C "$REPO" commit -q -m "amend in the leftover"
out="$(bash "$SCRIPT" rebase "$REPO")"
[ "$(jq -r .outcome <<<"$out")" = "REBASED" ] \
  || fail "committing the leftover did not clear DIRTY_WORKTREE (got: $out)"
echo "PASS: rebase → DIRTY_WORKTREE (rebase_needed:false, edit preserved) on an unstaged-changes refusal"

# --- rebase: conflicting base → REBASE_CONFLICT + abort (worktree left clean) ------
# A worker that edits the SAME line the intervening merge edited conflicts on
# rebase. The script must ABORT (leave the worktree clean — no half-applied
# rebase, no rebase-in-progress, never a silent revert) and emit REBASE_CONFLICT
# + non-zero exit so the orchestrator escalates a rebase conflict.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b conflict-base origin/main
printf 'worker line\n' > "$REPO/shared.txt"
git -C "$REPO" add shared.txt
git -C "$REPO" commit -q -m "worker edits shared.txt"
# Advance origin/main with a CONFLICTING edit to the same file/line.
git clone -q "$BARE" "$TMP/advancer2" 2>/dev/null
git -C "$TMP/advancer2" -c user.name=test -c user.email=test@test checkout -q main
printf 'main line\n' > "$TMP/advancer2/shared.txt"
git -C "$TMP/advancer2" add shared.txt
git -C "$TMP/advancer2" -c user.name=test -c user.email=test@test commit -q -m "main edits shared.txt"
git -C "$TMP/advancer2" push -q origin main 2>/dev/null
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "REBASE_CONFLICT did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "REBASE_CONFLICT" ] || fail "conflict not REBASE_CONFLICT (got: $out)"
# Aborted: no rebase-in-progress, working tree clean, HEAD back at the worker commit.
[ ! -d "$REPO/.git/rebase-merge" ] && [ ! -d "$REPO/.git/rebase-apply" ] \
  || fail "rebase left in progress — not aborted (silent-revert risk)"
[ -z "$(git -C "$REPO" status --porcelain)" ] || fail "worktree not clean after conflict abort"
[ "$(cat "$REPO/shared.txt")" = "worker line" ] \
  || fail "conflict abort did not restore the worker's content (silent revert)"
echo "PASS: rebase → REBASE_CONFLICT aborts the rebase (clean worktree, no silent revert) + non-zero exit"

# --- rebase: the discriminating twin — SAME conflicting base, but dirty -----------
# Identical repo state to the case just above (a genuine content conflict is
# waiting), plus an uncommitted tracked-file edit. git refuses BEFORE it can ever
# reach the conflict, so the honest answer is DIRTY_WORKTREE — even though a real
# conflict does exist here. Without this pair, a pre-check that simply relabelled
# every rebase failure would pass the case above just as happily (temperloop#735).
printf 'worker line\nuncommitted tail\n' > "$REPO/shared.txt"
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] || fail "dirty-over-conflict did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "DIRTY_WORKTREE" ] \
  || fail "dirty tree over a conflicting base not DIRTY_WORKTREE (got: $out)"
[ "$(jq -r .rebase_needed <<<"$out")" = "true" ] \
  || fail "DIRTY_WORKTREE on a STALE base did not report rebase_needed:true (got: $out)"
grep -q 'uncommitted tail' "$REPO/shared.txt" \
  || fail "dirty-over-conflict destroyed the uncommitted edit"
# Drop the dirt and the SAME tree reports the genuine conflict again — the
# conflict path is narrowed, not disabled.
git -C "$REPO" checkout -q -- shared.txt
rc=0; out="$(bash "$SCRIPT" rebase "$REPO" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "REBASE_CONFLICT" ] \
  || fail "genuine conflict no longer reports REBASE_CONFLICT once the tree is clean (got: $out)"
echo "PASS: rebase → dirty-over-a-conflicting-base is DIRTY_WORKTREE; clean the tree and it is REBASE_CONFLICT again"

# Restore to a clean detached-from-conflict state for the push tests below, which
# expect clean-br checked out on the (now twice-advanced) main lineage.
git -C "$REPO" checkout -q clean-br

# `pr.sh push` now surveys open PRs (temperloop#1688), so every push below runs
# with an erroring `gh` on PATH — deterministic and network-free (kernel
# principle 3), and the fail-soft arm the survey must degrade through. The
# survey's own outcomes get real stubs in the #1688 block further down.
NOGH="$TMP/bin-nogh"
mkdir -p "$NOGH"
cat > "$NOGH/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: could not determine repository" >&2
exit 1
EOF
chmod +x "$NOGH/gh"

# --- push: push-by-SHA places the branch on the bare remote ----------------------
sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "push outcome (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$sha" ] || fail "push sha mismatch (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/widget" ] || fail "push branch (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$sha" ] \
  || fail "remote branch feat/widget not at pushed sha"
echo "PASS: push places HEAD by SHA on the remote plan branch (PUSHED)"

# --- push: non-fast-forward rejected without --force; --force recovers -----------
git -C "$REPO" commit -q --amend --allow-empty -m "reworded widget commit"
newsha="$(git -C "$REPO" rev-parse HEAD)"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-FF push did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] || fail "collision not PUSH_REJECTED (got: $out)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "push --force outcome (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$newsha" ] \
  || fail "remote branch not at force-pushed sha"
# #335: the amended HEAD does NOT descend from the remote tip (a genuine
# history rewrite), so --force is really used — forced=true.
[ "$(jq -r .forced <<<"$out")" = "true" ] \
  || fail "genuine rewrite must report forced=true (got: $out)"
echo "PASS: push collision → PUSH_REJECTED + non-zero; --force re-push lands (PUSHED, forced=true)"

# --- push: --force on a fast-forward descendant DOWNGRADES to a plain push (#335) ---
# A CI-retry commit is a fast-forward descendant of the already-pushed head: the
# CI-fix worker resets to the remote tip and commits on top. build-level.mjs
# still *requests* --force (pr.sh push … --force), but because the local head
# descends from the current remote tip the push needs no history rewrite — pr.sh
# must DOWNGRADE to a plain (non-force) push (forced=false) so the git-destructive
# safety classifier is never engaged. The remote must still advance to the new sha.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -B ff-retry refs/remotes/origin/feat/widget
ff_base="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" commit -q --allow-empty -m "CI-retry fix commit (ff descendant)"
ff_sha="$(git -C "$REPO" rev-parse HEAD)"
[ "$ff_sha" != "$ff_base" ] || fail "fixture error: ff-retry commit did not advance HEAD"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/widget --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "ff --force push outcome (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] \
  || fail "fast-forward --force must DOWNGRADE to a plain push (forced=false) (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$ff_sha" ] \
  || fail "remote branch did not advance to the fast-forward retry sha"
echo "PASS: push --force on a fast-forward descendant downgrades to a plain push (PUSHED, forced=false)"

# --- push: a plain (non-force) push reports forced=false --------------------------
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b plainpush origin/main
git -C "$REPO" commit -q --allow-empty -m "fresh branch commit"
plainsha="$(git -C "$REPO" rev-parse HEAD)"
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/plainpush)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "plain push outcome (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] || fail "plain push must report forced=false (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/plainpush)" = "$plainsha" ] \
  || fail "plain push did not land the branch"
echo "PASS: plain push (no --force requested) reports forced=false"

# --- push: the open-PR survey (temperloop#1688) -----------------------------------
# The live 2026-08-21 shape: the worktree's local branch is `build/<slug>` while
# the PR was opened on `fix/<slug>`, so a rebase-and-re-push aimed at the obvious
# `build/<slug>` lands a SECOND remote ref that no PR watches. The push is
# truthful and useless; the only downstream symptom is a PR head that looks
# "stale", which reads as GitHub's post-force-push lag. Every case below is
# stubbed at `gh` — no network, deterministic listings.
#
# Stub grammar: $GH_SURVEY_JSON is the `gh pr list --state open` listing; a call
# carrying `--head` (pr.sh's authoritative confirm) answers from that same
# listing filtered to the requested ref, so the stub can never disagree with
# itself the way two hand-written fixtures could.
mkdir -p "$TMP/bin-survey"
cat > "$TMP/bin-survey/gh" <<'EOF'
#!/usr/bin/env bash
head_ref=""; want_head=0
for a in "$@"; do
  if [ "$want_head" = 1 ]; then head_ref="$a"; want_head=0; continue; fi
  [ "$a" = "--head" ] && want_head=1
done
if [ -n "$head_ref" ]; then
  jq -c --arg h "$head_ref" 'map(select(.headRefName == $h))' <<<"${GH_SURVEY_JSON:?}"
else
  printf '%s\n' "${GH_SURVEY_JSON:?}"
fi
EOF
chmod +x "$TMP/bin-survey/gh"

git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b "build/env-reconcile-1404" origin/main
git -C "$REPO" commit -q --allow-empty -m "rebased worker commit"
wt_sha="$(git -C "$REPO" rev-parse HEAD)"

# THE REGRESSION CASE. PR #1404 is open on fix/env-reconcile-1404; the re-push
# aims at build/env-reconcile-1404. Must REPORT, not proceed.
PR_ON_FIX='[{"number":1404,"url":"https://github.com/Towheads/temperloop/pull/1404","headRefName":"fix/env-reconcile-1404"}]'
rc=0
out="$(GH_SURVEY_JSON="$PR_ON_FIX" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)" || rc=$?
[ "$rc" -ne 0 ] || fail "a push onto a ref no open PR watches must exit non-zero (got: $out)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED_UNWATCHED" ] \
  || fail "build/<slug> push while the PR is on fix/<slug> must be PUSHED_UNWATCHED (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "build/env-reconcile-1404" ] \
  || fail "PUSHED_UNWATCHED must name the ref actually pushed (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1404" ] \
  || fail "PUSHED_UNWATCHED must name the PR that is NOT watching (got: $out)"
[ "$(jq -r .pr_head_ref <<<"$out")" = "fix/env-reconcile-1404" ] \
  || fail "PUSHED_UNWATCHED must name the ref the PR DOES track (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$wt_sha" ] || fail "PUSHED_UNWATCHED sha mismatch (got: $out)"
# The push still LANDED — this is a report about where it landed, not a failure
# to land, and a caller must not re-push believing nothing happened.
[ "$(git -C "$BARE" rev-parse refs/heads/build/env-reconcile-1404)" = "$wt_sha" ] \
  || fail "PUSHED_UNWATCHED must still have placed the branch (the push DID succeed)"
# Criterion 2 — the two meanings must be TOLD APART, not merely flagged. The
# machine-readable cause says which one this is, and the message names both refs
# plus the discriminating fact (lag keeps the SAME ref).
[ "$(jq -r .stale_head_cause <<<"$out")" = "branch-mismatch" ] \
  || fail "PUSHED_UNWATCHED must classify the stale-head cause as branch-mismatch (got: $out)"
msg="$(jq -r .error <<<"$out")"
grep -q 'build/env-reconcile-1404' <<<"$msg" || fail "message omits the pushed ref (got: $msg)"
grep -q 'fix/env-reconcile-1404'   <<<"$msg" || fail "message omits the PR's ref (got: $msg)"
grep -qi 'not GitHub'              <<<"$msg" || fail "message does not rule out the GitHub lag (got: $msg)"
grep -qi 'SAME ref'                <<<"$msg" || fail "message does not state what lag looks like instead (got: $msg)"
echo "PASS: push onto a ref no open PR watches → PUSHED_UNWATCHED + non-zero, both refs named, cause classified"

# CONTROL — genuine GitHub post-force-push head lag. Same visible symptom (the
# PR's head looks stale), but the PR's head REF *is* the ref just pushed, so the
# push reached it and the lag converges on its own. Must stay a plain PUSHED:
# this is the case a naive "PR head looks stale" warning would collapse into the
# one above, reproducing the original misdiagnosis.
PR_ON_SAME='[{"number":1404,"url":"https://github.com/Towheads/temperloop/pull/1404","headRefName":"build/env-reconcile-1404"}]'
out="$(GH_SURVEY_JSON="$PR_ON_SAME" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "a PR whose head REF matches the pushed ref is GitHub lag at worst — must stay PUSHED (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1404" ] \
  || fail "PUSHED must still name the PR watching the ref (got: $out)"
[ "$(jq -r .stale_head_cause <<<"$out")" = "null" ] \
  || fail "the benign lag case must carry no stale_head_cause (got: $out)"
echo "PASS: a PR on the SAME head ref (genuine GitHub head lag) stays PUSHED — the two causes are not collapsed"

# CONTROL — the ordinary build-level.mjs first push: 3f-1 pushes, 3f-2 opens the
# PR, so no PR references the ref yet and none exists elsewhere for the slug.
# This is the path the check must never break.
out="$(GH_SURVEY_JSON='[]' PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "fix/first-push-1688")"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "the normal pre-PR first push must stay PUSHED (got: $out)"
[ "$(jq -r .pr_lookup <<<"$out")" = "ok" ] || fail "first push should report a successful lookup (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "null" ] || fail "first push has no PR yet (got: $out)"
echo "PASS: the normal push-then-open-PR path (no PR anywhere yet) stays PUSHED"

# CONTROL — an unrelated open PR on a different slug is not a sibling.
PR_OTHER='[{"number":99,"url":"u","headRefName":"fix/some-other-slug-1"}]'
out="$(GH_SURVEY_JSON="$PR_OTHER" PATH="$TMP/bin-survey:$PATH" \
       bash "$SCRIPT" push "$REPO" "fix/first-push-1688" --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "an unrelated PR on another slug must not trip the survey (got: $out)"
echo "PASS: an open PR on an unrelated slug does not trip the survey"

# CONTROL — fail-soft. An erroring `gh` cannot OBSERVE the split, and a push that
# already succeeded must never be turned into a failure by an inability to look.
out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "an erroring gh must degrade to PUSHED, not fail the push (got: $out)"
[ "$(jq -r .pr_lookup <<<"$out")" = "unavailable" ] \
  || fail "an erroring gh must be reported as pr_lookup:unavailable (got: $out)"
echo "PASS: push survey degrades fail-soft when gh errors (PUSHED, pr_lookup:unavailable)"

# CONTROL — a match outside the bounded listing. The survey lists at most 100
# open PRs, so on a busy repo the real match can fall outside the window while a
# sibling sits inside it. The authoritative `--head` confirm resolves it, and no
# split is reported. Stub: the listing shows only the sibling; the --head lookup
# is answered from a listing that DOES contain the match.
cat > "$TMP/bin-survey/gh" <<'EOF'
#!/usr/bin/env bash
head_ref=""; want_head=0
for a in "$@"; do
  if [ "$want_head" = 1 ]; then head_ref="$a"; want_head=0; continue; fi
  [ "$a" = "--head" ] && want_head=1
done
if [ -n "$head_ref" ]; then
  jq -c --arg h "$head_ref" 'map(select(.headRefName == $h))' <<<"${GH_HEAD_JSON:?}"
else
  printf '%s\n' "${GH_SURVEY_JSON:?}"
fi
EOF
chmod +x "$TMP/bin-survey/gh"
out="$(GH_SURVEY_JSON="$PR_ON_FIX" \
       GH_HEAD_JSON='[{"number":1500,"url":"u","headRefName":"build/env-reconcile-1404"}]' \
       PATH="$TMP/bin-survey:$PATH" bash "$SCRIPT" push "$REPO" "build/env-reconcile-1404" --force)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] \
  || fail "a match found only by the --head confirm must NOT be reported as a split (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "1500" ] \
  || fail "the confirm's PR number must be adopted (got: $out)"
echo "PASS: a real match outside the bounded listing is recovered by the --head confirm, not reported"

# --- open --body-only: per-entry bare Closes + full 3f body shape ----------------
cat > "$TMP/verdict.json" <<'EOF'
{
  "status": "done",
  "summary": "Implements the widget renderer behind the existing seam.",
  "acceptance_results": [
    {"criterion": "widget renders", "passed": true, "evidence": "test_widget.py::test_render green"},
    {"criterion": "legacy path unchanged", "passed": false, "evidence": "one diff remains"}
  ],
  "verification_surface": "Before: 0 widgets rendered.\nAfter: 3 widgets rendered."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" \
  --source "epic #253, spike #245 verdict" --body-only)"
# Per-entry bare emission: exactly the two lines, each on its own line.
[ "$(grep -c '^Closes #' <<<"$body")" -eq 2 ] || fail "expected exactly 2 Closes lines (body: $body)"
grep -qx 'Closes #278' <<<"$body" || fail "missing bare 'Closes #278' on its own line"
grep -qx 'Closes #171' <<<"$body" || fail "missing bare 'Closes #171' on its own line"
grep -q 'Closes #278 and' <<<"$body" && fail "Closes lines combined — closes only #278"
grep -q '`Closes' <<<"$body" && fail "backticked Closes — GitHub ignores it (ec8d5fd class)"
# Acceptance recap with passed/evidence.
grep -qF '## Acceptance' <<<"$body" || fail "missing acceptance recap heading"
# temperloop#1267: evidence rides its OWN nested line, never an inline ` — `.
grep -qxF -- '- [x] widget renders' <<<"$body" \
  || fail "missing passed recap line"
grep -qxF -- '      — test_widget.py::test_render green' <<<"$body" \
  || fail "passed entry's evidence is not on its own nested line (body: $body)"
grep -qxF -- '- [ ] legacy path unchanged' <<<"$body" \
  || fail "missing failed recap line"
grep -qxF -- '      — one diff remains' <<<"$body" \
  || fail "failed entry's evidence is not on its own nested line (body: $body)"
grep -q -- '] widget renders — ' <<<"$body" \
  && fail "evidence re-inlined after a bare em-dash — the temperloop#1267 defect (body: $body)"
# No .discrimination_evidence on either entry above → no stray "discrimination:" line.
grep -q 'discrimination:' <<<"$body" \
  && fail "recap emitted a stray discrimination: line for entries with no .discrimination_evidence (body: $body)"
# Verification section = the worker's verification_surface.
grep -qF '## Verification' <<<"$body" || fail "missing ## Verification"
grep -qF 'After: 3 widgets rendered.' <<<"$body" || fail "verification_surface not in body"
# Backlinks + footer.
grep -qxF 'Tracked in: [[Plans/2026-06-09 foundation - machinery#machinery-pr-open]]' <<<"$body" \
  || fail "missing Tracked in backlink"
grep -qxF 'Derived from: epic #253, spike #245 verdict' <<<"$body" \
  || fail "missing Derived from source ref"
grep -qxF '🤖 Generated with [Claude Code](https://claude.com/claude-code)' <<<"$body" \
  || fail "missing Claude Code footer"
echo "PASS: open --body-only emits per-entry bare Closes + recap + Verification + backlinks + footer"

# --- open --body-only: .discrimination_evidence reaches the recap (temperloop#1319) ---
# The whole point of #1319: a jq filter that reads only .passed/.criterion/.evidence
# would silently DROP a worker-reported .discrimination_evidence field instead of
# surfacing it to the PR's human reviewer. This proves it survives end to end.
cat > "$TMP/verdict-discrim.json" <<'EOF'
{
  "status": "done",
  "summary": "Adds a guard that rejects an out-of-worktree write.",
  "acceptance_results": [
    {"criterion": "guard rejects out-of-worktree writes", "passed": true, "evidence": "test_guard.sh::test_reject green", "discrimination_evidence": "Removed the path-prefix check at build-worktree-guard.sh:42 -> test_guard.sh RED (1 failed); restored -> GREEN (12 passed)."}
  ],
  "verification_surface": "Before: guard allowed any path.\nAfter: guard rejects paths outside the worktree."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-discrim.json" --gh-issue 1319 --body-only)"
grep -qF '## Acceptance' <<<"$body" || fail "discrimination-evidence fixture missing ## Acceptance heading"
grep -qxF -- '- [x] guard rejects out-of-worktree writes' <<<"$body" \
  || fail "discrimination-evidence fixture missing the base recap line (body: $body)"
grep -qxF -- '      — test_guard.sh::test_reject green' <<<"$body" \
  || fail "discrimination-evidence fixture: evidence not on its own nested line (body: $body)"
grep -qF 'discrimination: Removed the path-prefix check at build-worktree-guard.sh:42 -> test_guard.sh RED (1 failed); restored -> GREEN (12 passed).' <<<"$body" \
  || fail "recap dropped .discrimination_evidence — a jq filter reading only .passed/.criterion/.evidence silently drops this field (body: $body)"
echo "PASS: open --body-only surfaces .discrimination_evidence in the acceptance recap (temperloop#1319)"

# --- open --body-only: .deferred_host_config reaches the recap (temperloop#1182) ---
# A host-config deferral rides `passed: false` (the worker did NOT confirm it) plus
# the `deferred_host_config` marker. Read only .passed and the recap renders it as a
# bare unchecked box — visually identical to "the worker failed this criterion", the
# exact misreading this field exists to prevent. The DEFERRED line must survive.
cat > "$TMP/verdict-hostcfg.json" <<'EOF'
{
  "status": "done",
  "summary": "Wires the retro-judge spawn to the host credential seam.",
  "acceptance_results": [
    {"criterion": "pipeline-retro-judge-spawn.sh --dry-run reports credential_present", "passed": false, "evidence": "not observable from a worktree", "deferred_host_config": "workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)"},
    {"criterion": "the spawn script reads the credential from config", "passed": true, "evidence": "test_pipeline_retro_judge_spawn.sh green"}
  ],
  "verification_surface": "Before: no credential seam.\nAfter: the spawn sources build.config.local.sh."
}
EOF
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-hostcfg.json" --gh-issue 1182 --body-only)"
grep -qF -- '- [ ] pipeline-retro-judge-spawn.sh --dry-run reports credential_present' <<<"$body" \
  || fail "host-config fixture missing the base recap line for the deferred criterion (body: $body)"
grep -qF 'DEFERRED — host-config `workflows/scripts/build/build.config.local.sh (SENTRY_AUTH_TOKEN)` is invisible from a worktree; verified parent-side (temperloop#1182)' <<<"$body" \
  || fail "recap dropped .deferred_host_config — an unchecked box then reads as a worker FAILURE rather than a criterion nobody could check worktree-side (body: $body)"
# A non-deferred entry must not pick up a stray DEFERRED line.
[ "$(grep -c 'DEFERRED — host-config' <<<"$body")" -eq 1 ] \
  || fail "expected exactly one DEFERRED line — the marker leaked onto an entry with no .deferred_host_config (body: $body)"
echo "PASS: open --body-only surfaces .deferred_host_config in the acceptance recap (temperloop#1182)"

# --- acceptance recap round-trips through ` — ` (temperloop#1267) ----------------
# The PR body is the ONLY durable verbatim record of the acceptance bullets a
# worker was handed. With evidence appended inline after a bare ` — ` that record
# was not parseable: ` — ` occurs inside real criteria (a first-occurrence split
# silently TRUNCATES the criterion — the live #1201 bullet-3 case, where the
# dropped clause was the anti-over-exclusion guard) and inside real evidence (a
# last-occurrence split then eats the evidence tail). Neither rule is right, and
# nothing picks between them. Evidence on its OWN nested line makes the split
# positional, and `pr.sh acceptance-extract` is the heuristic-free inverse.
#
# The fixture below is deliberately the hard shape: BOTH fields carry ` — `,
# one criterion spans several lines, and one entry has no evidence at all.
cat > "$TMP/verdict-emdash.json" <<'EOF'
{
  "status": "done",
  "summary": "Round-trip fixture.",
  "acceptance_results": [
    {"criterion": "A genuine user turn that merely FOLLOWS a command invocation is NOT over-excluded — guard the rule to the single adjacent expansion turn", "passed": true, "evidence": "test_scan_stub.sh 3c(a) — four-turn fixture yields exactly 1 match"},
    {"criterion": "a criterion that spans\nseveral lines — with an em-dash on the last", "passed": false, "evidence": "ev — with — several — dashes", "deferred_host_config": "build.config.local.sh (TOKEN)", "discrimination_evidence": "removed the guard — RED; restored — GREEN"},
    {"criterion": "an entry with no evidence at all — still fine", "passed": true}
  ],
  "verification_surface": "## Acceptance\n- [x] a decoy bullet inside the worker's own surface — must never be re-parsed"
}
EOF
bash "$SCRIPT" open --verdict "$TMP/verdict-emdash.json" --gh-issue 1267 --body-only > "$TMP/body-emdash.md"
# Byte-exact round-trip: extract → compare against the verdict's own entries.
# `passed` plus the four optional fields, nulls dropped so an absent field and a
# null one compare equal.
jq -S '.acceptance_results
       | map({passed, criterion, evidence, deferred_host_config, discrimination_evidence}
             | with_entries(select(.value != null)))' \
   "$TMP/verdict-emdash.json" > "$TMP/rt-want.json"
bash "$SCRIPT" acceptance-extract "$TMP/body-emdash.md" \
  | jq -S 'map(with_entries(select(.value != null)))' > "$TMP/rt-got.json"
diff -u "$TMP/rt-want.json" "$TMP/rt-got.json" \
  || fail "acceptance recap did not round-trip byte-exactly (want/got above)"
# Both halves of the acceptance, named so a regression says which one broke.
jq -e '.[0].criterion | endswith("single adjacent expansion turn")' "$TMP/rt-got.json" >/dev/null \
  || fail "criterion containing ' — ' was TRUNCATED on extract (temperloop#1267 first-occurrence split)"
jq -e '.[1].evidence == "ev — with — several — dashes"' "$TMP/rt-got.json" >/dev/null \
  || fail "evidence containing ' — ' was truncated on extract (last-occurrence split)"
jq -e '.[1].criterion == "a criterion that spans\nseveral lines — with an em-dash on the last"' "$TMP/rt-got.json" >/dev/null \
  || fail "a multi-line criterion lost its continuation lines on extract"
jq -e '.[2].evidence == null' "$TMP/rt-got.json" >/dev/null \
  || fail "an entry with no evidence invented one on extract"
# The worker surface's own `## Acceptance` heading must not re-open the section.
[ "$(jq 'length' "$TMP/rt-got.json")" -eq 3 ] \
  || fail "extract re-parsed a decoy '## Acceptance' inside the verification surface"
# stdin (`-`) is the same extractor.
bash "$SCRIPT" acceptance-extract - < "$TMP/body-emdash.md" \
  | jq -S 'map(with_entries(select(.value != null)))' > "$TMP/rt-stdin.json"
diff -q "$TMP/rt-got.json" "$TMP/rt-stdin.json" >/dev/null \
  || fail "acceptance-extract - (stdin) disagreed with the file path form"
echo "PASS: acceptance recap round-trips byte-exactly with ' — ' in BOTH criterion and evidence (temperloop#1267)"

# A body with no ## Acceptance section extracts to an empty array, not an error.
printf '%s\n' 'just a summary' > "$TMP/body-noacc.md"
[ "$(bash "$SCRIPT" acceptance-extract "$TMP/body-noacc.md")" = "[]" ] \
  || fail "acceptance-extract on a body with no ## Acceptance section did not return []"
rc=0; out="$(bash "$SCRIPT" acceptance-extract "$TMP/nonexistent-body.md" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "acceptance-extract on a missing path not structured ERROR (got: $out)"
echo "PASS: acceptance-extract returns [] for a recap-less body and structured ERROR for a missing path"

# --- open --body-only: multiple also_closes, comma-separated ---------------------
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue 278 --also-closes 171,205 --body-only)"
[ "$(grep -c '^Closes #' <<<"$body")" -eq 3 ] || fail "expected 3 Closes lines (body: $body)"
grep -qx 'Closes #205' <<<"$body" || fail "missing 'Closes #205'"
echo "PASS: open emits one bare Closes line per also_closes entry (comma list)"

# --- open --body-only: cross-repo repo: honor point — owner/repo#N (RED/GREEN) ----
# GREEN: a fully-qualified owner/repo#N gh_issue/also_closes ref is accepted and
# emitted as `Closes owner/repo#N` (not bare `Closes #N` — a bare close is
# same-repo only, plan-schema.md § Optional repo: field).
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" \
  --gh-issue acme/widgets#42 --also-closes acme/widgets#43 --body-only)"
grep -qxF 'Closes acme/widgets#42' <<<"$body" \
  || fail "missing qualified 'Closes acme/widgets#42' (body: $body)"
grep -qxF 'Closes acme/widgets#43' <<<"$body" \
  || fail "missing qualified 'Closes acme/widgets#43' (body: $body)"
grep -q '^Closes #' <<<"$body" && fail "qualified ref must not also emit a bare 'Closes #N' (body: $body)"
echo "PASS: open emits Closes owner/repo#N for a qualified cross-repo gh_issue/also_closes ref"

# RED: a malformed issue ref (neither plain digits nor owner/repo#N) is rejected.
rc=0
out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue not-a-ref --body-only 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "malformed --gh-issue 'not-a-ref' did not exit non-zero (out: $out)"
grep -qi 'invalid' <<<"$out" || fail "malformed --gh-issue error missing 'invalid' (out: $out)"
echo "PASS: open rejects a malformed --gh-issue ref (neither digits nor owner/repo#N)"

# --- open --body-only: no verification_surface → fall back to the recap ----------
jq 'del(.verification_surface)' "$TMP/verdict.json" > "$TMP/verdict-nosurface.json"
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 --body-only)"
grep -qF '## Verification' <<<"$body" || fail "fallback body missing ## Verification"
# The recap appears twice: once under ## Acceptance, once as the fallback surface.
[ "$(grep -cxF -- '- [x] widget renders' <<<"$body")" -eq 2 ] \
  || fail "fallback did not reuse the acceptance recap under ## Verification (body: $body)"
echo "PASS: open falls back to the acceptance recap only when verification_surface is absent"

# --- open: verification surface by file-ref (#418 inflow-cut) ---------------------
# The worker writes its surface to a file and returns ONLY the path (keeping the
# block out of orchestrator context); the assembled body must be byte-identical
# to the inline-field path. Both the verdict `.verification_surface_path` key and
# the explicit --verification-surface-file flag are exercised.
printf '%s\n' "Before: 0 widgets rendered." "After: 3 widgets rendered." > "$TMP/surface.md"
inline_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" --body-only)"
# (a) verdict carries .verification_surface_path instead of the inline field
jq --arg p "$TMP/surface.md" 'del(.verification_surface) | .verification_surface_path=$p' \
  "$TMP/verdict.json" > "$TMP/verdict-pathref.json"
pathref_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-pathref.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" --body-only)"
[ "$pathref_body" = "$inline_body" ] || fail "path-key body not byte-identical to inline body"
# (b) --verification-surface-file flag, verdict has neither surface field
flag_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" --source "epic #253" \
  --verification-surface-file "$TMP/surface.md" --body-only)"
[ "$flag_body" = "$inline_body" ] || fail "--verification-surface-file body not byte-identical to inline body"
echo "PASS: verification surface by file-ref (path key + flag) == inline body, byte-identical"

# --- open: --verification-surface-file precedence over the inline field -----------
printf 'FROM FILE\n' > "$TMP/surface2.md"
out_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 1 \
  --verification-surface-file "$TMP/surface2.md" --body-only)"
grep -qF 'FROM FILE' <<<"$out_body" || fail "flag did not override inline surface"
grep -qF 'After: 3 widgets rendered.' <<<"$out_body" && fail "inline surface leaked when flag given"
echo "PASS: --verification-surface-file takes precedence over the inline verification_surface field"

# --- open: a given-but-missing surface file → structured ERROR --------------------
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 1 \
  --verification-surface-file "$TMP/does-not-exist.md" --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --verification-surface-file not structured ERROR (got: $out)"
jq --arg p "$TMP/nope.md" 'del(.verification_surface) | .verification_surface_path=$p' \
  "$TMP/verdict.json" > "$TMP/verdict-pathref-missing.json"
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict-pathref-missing.json" --gh-issue 1 --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing .verification_surface_path file not structured ERROR (got: $out)"
echo "PASS: a given-but-missing surface file (flag or path key) → structured ERROR + non-zero exit"

# --- open: the worker's own Closes block is stripped from the surface (#1023) ------
# Observed on temperloop PR #1019: the worker copied pr.sh's linkage block into
# its own .build-verification.md, so the assembled body carried it TWICE. Linkage
# lives in pr.sh alone, so `open` strips a bare closing-keyword LINE out of the
# spliced surface. Assertions below compare the ## Verification window byte-for-
# byte against the expected surface, so a strip that mangles anything else fails.
#
# verif_window N — the N lines of $body that follow the '## Verification' heading.
verif_window() {
  local n="$1" ln
  ln="$(grep -n '^## Verification$' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || fail "assembled body has no ## Verification heading"
  sed -n "$((ln + 1)),$((ln + n))p" <<<"$body"
}

cat > "$TMP/surface-dup.md" <<'MD'
Closes #278
Closes Towheads/foundation#171

## What changed
The widget renderer now paints 3 widgets.
MD
cat > "$TMP/surface-dup-expected.md" <<'MD'

## What changed
The widget renderer now paints 3 widgets.
MD
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" \
  --gh-issue 278 --also-closes Towheads/foundation#171 \
  --verification-surface-file "$TMP/surface-dup.md" --body-only)"
[ "$(grep -c '^Closes ' <<<"$body")" -eq 2 ] \
  || fail "duplicate linkage survived — expected exactly 2 Closes lines (body: $body)"
grep -qx 'Closes #278' <<<"$body" || fail "pr.sh's own bare 'Closes #278' missing after strip"
grep -qx 'Closes Towheads/foundation#171' <<<"$body" \
  || fail "pr.sh's own qualified 'Closes Towheads/foundation#171' missing after strip"
[ "$(verif_window "$(wc -l < "$TMP/surface-dup-expected.md")")" = "$(cat "$TMP/surface-dup-expected.md")" ] \
  || fail "stripped surface not byte-identical to expected (body: $body)"
echo "PASS: open strips a worker-copied Closes block from the surface — one linkage block (#1023)"

# --- open: a surface with no HONORED closing-keyword line is untouched (#1023) -----
# The strip is deliberately narrow: only a WHOLE line that is nothing but
# `<keyword> #N` / `<keyword> owner/repo#N` — i.e. only what GitHub itself would
# honor AND what can only be a duplicate of pr.sh's emission. A mid-sentence
# mention, a backticked line, a 4-space-indented line and ANY line inside a
# fenced code block (a surface quoting an assembled body as its evidence) all
# survive byte-for-byte.
cat > "$TMP/surface-clean.md" <<'MD'
Before: 0 widgets rendered.

pr.sh emits Closes #279 near the top of the body, which is the single home.
`Closes #280`
    Closes #281

```text
Closes #282
Fixes Towheads/foundation#283
```
After: 3 widgets rendered.
MD
body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 \
  --verification-surface-file "$TMP/surface-clean.md" --body-only)"
[ "$(verif_window "$(wc -l < "$TMP/surface-clean.md")")" = "$(cat "$TMP/surface-clean.md")" ] \
  || fail "keyword-free surface was modified (body: $body)"
for n in 279 280 281 282; do
  grep -qF "Closes #$n" <<<"$body" || fail "non-honored 'Closes #$n' was stripped (body: $body)"
done
grep -qF 'Fixes Towheads/foundation#283' <<<"$body" \
  || fail "fenced 'Fixes Towheads/foundation#283' was stripped (body: $body)"
# Two line-start `Closes ` lines: pr.sh's own, plus the one INSIDE the fenced
# block — which is exactly the proof the fence guard fired (a fence-blind strip
# would have eaten it and left 1).
[ "$(grep -c '^Closes ' <<<"$body")" -eq 2 ] \
  || fail "expected pr.sh's own Closes line + the fenced one (body: $body)"
echo "PASS: open leaves a surface with no honored closing-keyword line byte-identical (#1023)"

# --- open: stubbed gh → PR_OPENED with parsed number ------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GH_STUB_ARGS:?}"
echo "https://github.com/Towheads/foundation/pull/342"
EOF
chmod +x "$TMP/bin/gh"
out="$(GH_STUB_ARGS="$TMP/gh-args" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - machinery#machinery-pr-open" \
  --source "epic #253")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "open outcome (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "342" ] || fail "pr_number not parsed (got: $out)"
grep -qx -- '--head' "$TMP/gh-args" || fail "gh not invoked with --head"
grep -qx 'feat/widget' "$TMP/gh-args" || fail "gh --head branch wrong"
grep -qx 'Closes #278' "$TMP/gh-args" || fail "assembled body (with Closes #278) not passed to gh"
grep -qx 'Closes #171' "$TMP/gh-args" || fail "assembled body (with Closes #171) not passed to gh"
[ "$(jq -r .surface_closes_stripped <<<"$out")" = "0" ] \
  || fail "surface_closes_stripped not 0 for a clean surface (got: $out)"
echo "PASS: open creates via gh with the assembled body → PR_OPENED {pr_number}"

# --- open: surface_closes_stripped reports the strip on the real outcome (#1023) ---
# The strip is otherwise invisible (it deletes worker-authored lines), so the
# count rides the structured outcome the .mjs logs — SPINE_OUTCOME_SCHEMA is
# `additionalProperties: true`, so this is a passthrough field, not a new outcome.
out="$(GH_STUB_ARGS="$TMP/gh-args-dup" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict-nosurface.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278 --also-closes Towheads/foundation#171 \
  --verification-surface-file "$TMP/surface-dup.md")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "dup-surface open outcome (got: $out)"
[ "$(jq -r .surface_closes_stripped <<<"$out")" = "2" ] \
  || fail "surface_closes_stripped did not report the 2 stripped lines (got: $out)"
[ "$(grep -c '^Closes ' "$TMP/gh-args-dup")" -eq 2 ] \
  || fail "body passed to gh still carries a duplicate linkage block"
echo "PASS: open reports surface_closes_stripped on PR_OPENED (#1023)"

# --- open: verdict on stdin -------------------------------------------------------
body="$(bash "$SCRIPT" open --verdict - --gh-issue 9 --body-only < "$TMP/verdict.json")"
grep -qx 'Closes #9' <<<"$body" || fail "stdin verdict not consumed"
echo "PASS: open accepts the verdict JSON on stdin (--verdict -)"

# --- open: EXISTS outcome when gh reports a PR already exists (#544) ---------------
# gh returns a non-zero exit with the "already exists" message — pr.sh must parse
# the PR number and URL and return {outcome:"EXISTS",...} (NOT ERROR/pr-open-failed).
mkdir -p "$TMP/bin-exists"
cat > "$TMP/bin-exists/gh" <<'EOF'
#!/usr/bin/env bash
# Simulate: gh pr create fails because a PR already exists
echo "a pull request for branch \"feat/widget\" into branch \"main\" already exists: https://github.com/Towheads/foundation/pull/163"
exit 1
EOF
chmod +x "$TMP/bin-exists/gh"
out="$(PATH="$TMP/bin-exists:$PATH" bash "$SCRIPT" open \
  --verdict "$TMP/verdict.json" --repo "$REPO" --branch feat/widget \
  --title "feat: widget renderer" --gh-issue 278)"
[ "$(jq -r .outcome <<<"$out")" = "EXISTS" ] \
  || fail "already-exists gh error not EXISTS (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "163" ] \
  || fail "pr_number not parsed from already-exists message (got: $out)"
[ "$(jq -r .url <<<"$out")" = "https://github.com/Towheads/foundation/pull/163" ] \
  || fail "url not parsed from already-exists message (got: $out)"
echo "PASS: open returns EXISTS{pr_number,url} when gh reports a PR already exists (#544)"

# --- recover-probe: the staged lost-return side-effect ladder (temperloop#939) ----
# Drives all four stages against the real fixture, bottom to top, on a branch of
# its own so the earlier push tests' remote state cannot mask a stage transition.
git -C "$REPO" fetch -q origin
git -C "$REPO" checkout -q -b build/recov origin/main
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_NONE" ] \
  || fail "no commits + no PR must be RECOVER_NONE (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "0" ] || fail "commits_ahead should be 0 (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "false" ] || fail "pushed should be false (got: $out)"
jq -e 'has("pr_number") | not' <<<"$out" >/dev/null || fail "pr_number must be absent with no PR (got: $out)"
[ "$(jq -r .dirty <<<"$out")" = "false" ] || fail "a clean worktree must report dirty:false (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "0" ] || fail "a clean worktree must report dirty_files:0 (got: $out)"
echo "PASS: recover-probe → RECOVER_NONE when nothing observable landed (the genuine-failure case)"

# --- recover-probe: the DIRTY rung (temperloop#993) -------------------------------
# Same zero-commit, no-PR state as RECOVER_NONE above — but with real work left on
# disk. That is the backgrounded-gate stall (#982: 8 modified files / 0 commits;
# #983: 3 / 0), and it must NOT read as "nothing happened": the caller resumes the
# worker on THIS worktree instead of escalating. Both index-staged and untracked
# paths count toward the porcelain tally.
printf 'staged work\n' > "$REPO/staged-work.txt"
git -C "$REPO" add staged-work.txt
printf 'untracked work\n' > "$REPO/untracked-work.txt"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_DIRTY" ] \
  || fail "a dirty worktree with 0 commits must be RECOVER_DIRTY, not RECOVER_NONE (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "0" ] \
  || fail "RECOVER_DIRTY must still report commits_ahead 0 (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "false" ] || fail "RECOVER_DIRTY must report pushed:false (got: $out)"
[ "$(jq -r .dirty <<<"$out")" = "true" ] || fail "dirty must be true on a dirty worktree (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "2" ] \
  || fail "dirty_files must count BOTH the staged and the untracked path (got: $out)"
echo "PASS: recover-probe → RECOVER_DIRTY on uncommitted work with zero commits (the #993 stall shape)"
git -C "$REPO" rm -q --cached staged-work.txt >/dev/null
rm -f "$REPO/staged-work.txt" "$REPO/untracked-work.txt"

# `.build-guard` is worktree.sh's OWN marker, not worker work: it must not count
# toward the dirty tally, or every freshly-created worktree would read
# RECOVER_DIRTY in a consuming repo that has not gitignored it.
printf '{"slug":"x"}\n' > "$REPO/.build-guard"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_NONE" ] \
  || fail "the .build-guard marker alone must not make a worktree read dirty (got: $out)"
[ "$(jq -r .dirty_files <<<"$out")" = "0" ] \
  || fail ".build-guard must be excluded from the dirty tally (got: $out)"
echo "PASS: recover-probe excludes worktree.sh's own .build-guard marker from the dirty tally (#993)"
rm -f "$REPO/.build-guard"

git -C "$REPO" commit -q --allow-empty -m "worker work that never returned a verdict"
recov_sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_COMMITTED" ] \
  || fail "a commit ahead of base with no push must be RECOVER_COMMITTED (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$recov_sha" ] || fail "probe sha mismatch (got: $out)"
[ "$(jq -r .commits_ahead <<<"$out")" = "1" ] || fail "commits_ahead should be 1 (got: $out)"
[ "$(jq -r .verification_surface_present <<<"$out")" = "false" ] \
  || fail "verification_surface_present should be false (got: $out)"
echo "PASS: recover-probe → RECOVER_COMMITTED on an unpushed worktree commit (the #939 L1 shape)"

PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" feat/recov >/dev/null
: > "$REPO/.build-verification.md"
out="$(bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PUSHED" ] \
  || fail "a pushed branch with no PR must be RECOVER_PUSHED (got: $out)"
[ "$(jq -r .pushed <<<"$out")" = "true" ] || fail "pushed should be true (got: $out)"
[ "$(jq -r .remote_sha <<<"$out")" = "$recov_sha" ] || fail "remote_sha mismatch (got: $out)"
[ "$(jq -r .verification_surface_present <<<"$out")" = "true" ] \
  || fail "verification_surface_present must report the worker's .build-verification.md (got: $out)"
echo "PASS: recover-probe → RECOVER_PUSHED once the branch is on origin (+ surface-file presence)"

mkdir -p "$TMP/bin-prlist"
cat > "$TMP/bin-prlist/gh" <<'EOF'
#!/usr/bin/env bash
echo '[{"number":936,"url":"https://github.com/Towheads/temperloop/pull/936"}]'
EOF
chmod +x "$TMP/bin-prlist/gh"
out="$(PATH="$TMP/bin-prlist:$PATH" bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PR_OPEN" ] \
  || fail "an open PR for the branch must be RECOVER_PR_OPEN (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "936" ] || fail "pr_number not adopted from gh (got: $out)"
[ "$(jq -r .url <<<"$out")" = "https://github.com/Towheads/temperloop/pull/936" ] \
  || fail "url not adopted from gh (got: $out)"
echo "PASS: recover-probe → RECOVER_PR_OPEN{pr_number,url} when an open PR exists (the #939 L0 shape)"

# Fail-soft: a broken/erroring gh degrades to "no PR observed" rather than
# failing the whole recovery (the caller's `open` then returns EXISTS and adopts).
mkdir -p "$TMP/bin-ghfail"
cat > "$TMP/bin-ghfail/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: could not determine repository" >&2
exit 1
EOF
chmod +x "$TMP/bin-ghfail/gh"
out="$(PATH="$TMP/bin-ghfail:$PATH" bash "$SCRIPT" recover-probe "$REPO" feat/recov)"
[ "$(jq -r .outcome <<<"$out")" = "RECOVER_PUSHED" ] \
  || fail "an erroring gh must degrade to the push-stage answer, not fail (got: $out)"
echo "PASS: recover-probe degrades fail-soft when gh errors (no PR observed, push stage still reported)"
rm -f "$REPO/.build-verification.md"

# --- error: closed ERROR outcome + non-zero exit ----------------------------------
rc=0; out="$(bash "$SCRIPT" recover-probe "$TMP/nonexistent" feat/recov 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "recover-probe on missing path not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" scan "$TMP/nonexistent" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "scan on missing path not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --gh-issue 1 --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "open without --verdict not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 'abc' --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "non-numeric --gh-issue not structured ERROR (got: $out)"
rc=0; out="$(PATH="$NOGH:$PATH" bash "$SCRIPT" push "$REPO" 'bad..branch' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "invalid branch name not structured ERROR (got: $out)"
echo "PASS: failures emit structured ERROR + non-zero exit (closed outcome set)"
