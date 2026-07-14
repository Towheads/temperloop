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
#   - push: push-by-SHA places the branch on a local bare remote → PUSHED;
#     non-fast-forward → PUSH_REJECTED + non-zero; --force recovers
#   - open --body-only: per-entry bare `Closes` emission (gh_issue=278 +
#     also_closes=[171] → exactly `Closes #278` and `Closes #171`, own lines,
#     never combined, never backticked); acceptance recap; ## Verification;
#     backlinks + footer; fallback-to-recap when verification_surface absent
#   - open (stubbed gh): PR_OPENED with parsed pr_number; body/head passed to gh
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
echo "PASS: rebase → REBASED no-op when the worker's base is already current"

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

# Restore to a clean detached-from-conflict state for the push tests below, which
# expect clean-br checked out on the (now twice-advanced) main lineage.
git -C "$REPO" checkout -q clean-br

# --- push: push-by-SHA places the branch on the bare remote ----------------------
sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(bash "$SCRIPT" push "$REPO" feat/widget)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "push outcome (got: $out)"
[ "$(jq -r .sha <<<"$out")" = "$sha" ] || fail "push sha mismatch (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/widget" ] || fail "push branch (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/widget)" = "$sha" ] \
  || fail "remote branch feat/widget not at pushed sha"
echo "PASS: push places HEAD by SHA on the remote plan branch (PUSHED)"

# --- push: non-fast-forward rejected without --force; --force recovers -----------
git -C "$REPO" commit -q --amend --allow-empty -m "reworded widget commit"
newsha="$(git -C "$REPO" rev-parse HEAD)"
rc=0; out="$(bash "$SCRIPT" push "$REPO" feat/widget)" || rc=$?
[ "$rc" -ne 0 ] || fail "non-FF push did not exit non-zero"
[ "$(jq -r .outcome <<<"$out")" = "PUSH_REJECTED" ] || fail "collision not PUSH_REJECTED (got: $out)"
out="$(bash "$SCRIPT" push "$REPO" feat/widget --force)"
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
out="$(bash "$SCRIPT" push "$REPO" feat/widget --force)"
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
out="$(bash "$SCRIPT" push "$REPO" feat/plainpush)"
[ "$(jq -r .outcome <<<"$out")" = "PUSHED" ] || fail "plain push outcome (got: $out)"
[ "$(jq -r .forced <<<"$out")" = "false" ] || fail "plain push must report forced=false (got: $out)"
[ "$(git -C "$BARE" rev-parse refs/heads/feat/plainpush)" = "$plainsha" ] \
  || fail "plain push did not land the branch"
echo "PASS: plain push (no --force requested) reports forced=false"

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
  --plan-link "Plans/2026-06-09 foundation - spine#spine-pr-open" \
  --source "epic #253, spike #245 verdict" --body-only)"
# Per-entry bare emission: exactly the two lines, each on its own line.
[ "$(grep -c '^Closes #' <<<"$body")" -eq 2 ] || fail "expected exactly 2 Closes lines (body: $body)"
grep -qx 'Closes #278' <<<"$body" || fail "missing bare 'Closes #278' on its own line"
grep -qx 'Closes #171' <<<"$body" || fail "missing bare 'Closes #171' on its own line"
grep -q 'Closes #278 and' <<<"$body" && fail "Closes lines combined — closes only #278"
grep -q '`Closes' <<<"$body" && fail "backticked Closes — GitHub ignores it (ec8d5fd class)"
# Acceptance recap with passed/evidence.
grep -qF '## Acceptance' <<<"$body" || fail "missing acceptance recap heading"
grep -qF -- '- [x] widget renders — test_widget.py::test_render green' <<<"$body" \
  || fail "missing passed recap line"
grep -qF -- '- [ ] legacy path unchanged — one diff remains' <<<"$body" \
  || fail "missing failed recap line"
# Verification section = the worker's verification_surface.
grep -qF '## Verification' <<<"$body" || fail "missing ## Verification"
grep -qF 'After: 3 widgets rendered.' <<<"$body" || fail "verification_surface not in body"
# Backlinks + footer.
grep -qxF 'Tracked in: [[Plans/2026-06-09 foundation - spine#spine-pr-open]]' <<<"$body" \
  || fail "missing Tracked in backlink"
grep -qxF 'Derived from: epic #253, spike #245 verdict' <<<"$body" \
  || fail "missing Derived from source ref"
grep -qxF '🤖 Generated with [Claude Code](https://claude.com/claude-code)' <<<"$body" \
  || fail "missing Claude Code footer"
echo "PASS: open --body-only emits per-entry bare Closes + recap + Verification + backlinks + footer"

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
[ "$(grep -cF -- '- [x] widget renders — test_widget.py::test_render green' <<<"$body")" -eq 2 ] \
  || fail "fallback did not reuse the acceptance recap under ## Verification (body: $body)"
echo "PASS: open falls back to the acceptance recap only when verification_surface is absent"

# --- open: verification surface by file-ref (#418 inflow-cut) ---------------------
# The worker writes its surface to a file and returns ONLY the path (keeping the
# block out of orchestrator context); the assembled body must be byte-identical
# to the inline-field path. Both the verdict `.verification_surface_path` key and
# the explicit --verification-surface-file flag are exercised.
printf '%s\n' "Before: 0 widgets rendered." "After: 3 widgets rendered." > "$TMP/surface.md"
inline_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - spine#spine-pr-open" --source "epic #253" --body-only)"
# (a) verdict carries .verification_surface_path instead of the inline field
jq --arg p "$TMP/surface.md" 'del(.verification_surface) | .verification_surface_path=$p' \
  "$TMP/verdict.json" > "$TMP/verdict-pathref.json"
pathref_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-pathref.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - spine#spine-pr-open" --source "epic #253" --body-only)"
[ "$pathref_body" = "$inline_body" ] || fail "path-key body not byte-identical to inline body"
# (b) --verification-surface-file flag, verdict has neither surface field
flag_body="$(bash "$SCRIPT" open --verdict "$TMP/verdict-nosurface.json" --gh-issue 278 --also-closes 171 \
  --plan-link "Plans/2026-06-09 foundation - spine#spine-pr-open" --source "epic #253" \
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
  --plan-link "Plans/2026-06-09 foundation - spine#spine-pr-open" \
  --source "epic #253")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "open outcome (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "342" ] || fail "pr_number not parsed (got: $out)"
grep -qx -- '--head' "$TMP/gh-args" || fail "gh not invoked with --head"
grep -qx 'feat/widget' "$TMP/gh-args" || fail "gh --head branch wrong"
grep -qx 'Closes #278' "$TMP/gh-args" || fail "assembled body (with Closes #278) not passed to gh"
grep -qx 'Closes #171' "$TMP/gh-args" || fail "assembled body (with Closes #171) not passed to gh"
echo "PASS: open creates via gh with the assembled body → PR_OPENED {pr_number}"

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

# --- error: closed ERROR outcome + non-zero exit ----------------------------------
rc=0; out="$(bash "$SCRIPT" scan "$TMP/nonexistent" 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "scan on missing path not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --gh-issue 1 --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "open without --verdict not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --verdict "$TMP/verdict.json" --gh-issue 'abc' --body-only 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "non-numeric --gh-issue not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" push "$REPO" 'bad..branch' 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "invalid branch name not structured ERROR (got: $out)"
echo "PASS: failures emit structured ERROR + non-zero exit (closed outcome set)"
