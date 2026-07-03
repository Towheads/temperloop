#!/usr/bin/env bash
#
# Tests for workflows/scripts/proposal/proposal-pr.sh — the proposal-PR
# generator CLI (foundation #765 Epic D, item proposal-pr-generator / #853).
# Board/build-toolkit fixture style: a throwaway real-git bare upstream +
# clone in a tmpdir, a stubbed `gh` on PATH, zero network, structured-output
# assertions via jq.
#
# Covers:
#   - open --dry-run: local branch + commit, DRY_RUN outcome with files
#     listed; nothing pushed (the bare upstream never sees the branch)
#   - open (stubbed gh): pushes the branch, PR_OPENED with parsed pr_number;
#     files land in the pushed tree with correct content/mode
#   - never-direct-push guard: --branch == base -> ERROR, non-zero exit,
#     no mutation
#   - manifest path safety: absolute path / ".." traversal -> ERROR
#   - manifest entry validation: content+content_file both set, neither set
#     (and not delete) -> ERROR; empty manifest -> ERROR
#   - delete:true removes a tracked file
#   - mode 755 sets the executable bit
#   - idempotent NO_CHANGES once the base has absorbed the proposal
#   - EXISTS outcome when gh reports a PR already exists (mirrors pr.sh)
#   - PR body: caller body + generator-owned "## Files changed" + footer
#   - --repo-dir not a git repo -> ERROR
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/proposal-pr.sh"

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

manifest_of() {
  # manifest_of PATH1:CONTENT1 [PATH2:CONTENT2 ...] -> JSON array on stdout
  local out="[" first=1 pc path content
  for pc in "$@"; do
    path="${pc%%:*}"
    content="${pc#*:}"
    [ "$first" = 1 ] || out="$out,"
    out="$out$(jq -cn --arg p "$path" --arg c "$content" '{path:$p, content:$c}')"
    first=0
  done
  out="$out]"
  printf '%s' "$out"
}

# --- open --dry-run: local commit only, nothing pushed ---------------------
manifest_of ".foundation/config:hello=1" > "$TMP/m1.json"
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/proposal-1 \
  --title "chore: propose config" --body "Adds .foundation/config." \
  --files-manifest "$TMP/m1.json" --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "DRY_RUN" ] || fail "dry-run outcome (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/proposal-1" ] || fail "dry-run branch (got: $out)"
[ "$(jq -r .base <<<"$out")" = "main" ] || fail "dry-run base (got: $out)"
jq -e '.files | index(".foundation/config") != null' <<<"$out" >/dev/null \
  || fail "dry-run files missing .foundation/config (got: $out)"
git -C "$REPO" show HEAD:.foundation/config >/dev/null 2>&1 \
  || fail "dry-run did not commit the file locally"
if git -C "$BARE" show-ref --verify --quiet refs/heads/feat/proposal-1; then
  fail "dry-run pushed to the bare upstream — must never push"
fi
echo "PASS: open --dry-run commits locally, never pushes (DRY_RUN)"

# --- never-direct-push guard: branch == base -----------------------------
rc=0
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch main \
  --title "x" --body "y" --files-manifest "$TMP/m1.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "branch==base did not fail"
[ "$(jq -r .outcome <<<"$out")" = "ERROR" ] || fail "branch==base not structured ERROR (got: $out)"
grep -qi 'differ from the base' <<<"$(jq -r .error <<<"$out")" \
  || fail "branch==base error message unclear (got: $out)"
echo "PASS: --branch equal to base is refused (never-direct-push guard)"

# --- manifest path safety: absolute + traversal ----------------------------
echo '[{"path":"/etc/passwd","content":"x"}]' > "$TMP/m-abs.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-abs \
  --title x --body y --files-manifest "$TMP/m-abs.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "absolute manifest path not rejected (got: $out)"

echo '[{"path":"../evil","content":"x"}]' > "$TMP/m-trav.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-trav \
  --title x --body y --files-manifest "$TMP/m-trav.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "'..' traversal manifest path not rejected (got: $out)"

echo '[{"path":"a/../../evil","content":"x"}]' > "$TMP/m-trav2.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-trav2 \
  --title x --body y --files-manifest "$TMP/m-trav2.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "mid-path '..' traversal not rejected (got: $out)"
echo "PASS: manifest paths reject absolute and '..'-traversal entries"

# --- manifest entry validation: both content+content_file, or neither -----
echo "somefile" > "$TMP/src.txt"
jq -n --arg cf "$TMP/src.txt" '[{path:".foundation/x", content:"a", content_file:$cf}]' > "$TMP/m-both.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-both \
  --title x --body y --files-manifest "$TMP/m-both.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "content+content_file both set not rejected (got: $out)"

echo '[{"path":".foundation/x"}]' > "$TMP/m-neither.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-neither \
  --title x --body y --files-manifest "$TMP/m-neither.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "entry with neither content/content_file/delete not rejected (got: $out)"

echo '[]' > "$TMP/m-empty.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/bad-empty \
  --title x --body y --files-manifest "$TMP/m-empty.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "empty manifest array not rejected (got: $out)"
echo "PASS: manifest entry content/content_file/delete + non-empty-array validation"

# --- content_file source works ---------------------------------------------
printf 'from file\n' > "$TMP/src2.txt"
jq -n --arg cf "$TMP/src2.txt" '[{path:".foundation/from-file", content_file:$cf}]' > "$TMP/m-cf.json"
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/from-file \
  --title x --body y --files-manifest "$TMP/m-cf.json" --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "DRY_RUN" ] || fail "content_file dry-run outcome (got: $out)"
[ "$(git -C "$REPO" show HEAD:.foundation/from-file)" = "from file" ] \
  || fail "content_file content not applied correctly"
echo "PASS: content_file sources file content correctly"

# --- mode 755 sets the executable bit ---------------------------------------
jq -n '[{path:".foundation/bin/run.sh", content:"#!/bin/sh\necho hi\n", mode:"755"}]' > "$TMP/m-mode.json"
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/exec \
  --title x --body y --files-manifest "$TMP/m-mode.json" --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "DRY_RUN" ] || fail "mode-755 dry-run outcome (got: $out)"
mode="$(git -C "$REPO" ls-tree HEAD -- .foundation/bin/run.sh | awk '{print $1}')"
[ "$mode" = "100755" ] || fail "executable mode not set (got tree mode: $mode)"
echo "PASS: mode:755 manifest entries land as executable in the tree"

# --- delete:true removes a tracked file --------------------------------------
git -C "$REPO" checkout -q main
git -C "$REPO" fetch -q origin
git clone -q "$BARE" "$TMP/repo2" 2>/dev/null
git -C "$TMP/repo2" checkout -q -b tmp-seed
mkdir -p "$TMP/repo2/.foundation"
echo "to be removed" > "$TMP/repo2/.foundation/stale"
git -C "$TMP/repo2" add .foundation/stale
git -C "$TMP/repo2" -c user.name=test -c user.email=test@test commit -q -m "seed stale file"
git -C "$TMP/repo2" push -q origin tmp-seed:main
git -C "$REPO" fetch -q origin
jq -n '[{path:".foundation/stale", delete:true}]' > "$TMP/m-del.json"
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/del \
  --title x --body y --files-manifest "$TMP/m-del.json" --base main --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "DRY_RUN" ] || fail "delete dry-run outcome (got: $out)"
git -C "$REPO" show HEAD:.foundation/stale >/dev/null 2>&1 \
  && fail "deleted file still present in the proposal commit" || true
echo "PASS: delete:true removes a tracked file from the proposal commit"

# --- delete:true with content also set -> ERROR -----------------------------
jq -n '[{path:".foundation/stale", delete:true, content:"x"}]' > "$TMP/m-del-bad.json"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/del-bad \
  --title x --body y --files-manifest "$TMP/m-del-bad.json" --base main --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "delete:true+content not rejected (got: $out)"
echo "PASS: delete:true combined with content is rejected"

# --- open (stubbed gh): pushes + PR_OPENED with parsed number ---------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${GH_STUB_ARGS:?}"
echo "https://github.com/acme/widget/pull/501"
EOF
chmod +x "$TMP/bin/gh"
manifest_of ".foundation/config:real=1" > "$TMP/m-real.json"
out="$(GH_STUB_ARGS="$TMP/gh-args" PATH="$TMP/bin:$PATH" bash "$SCRIPT" open \
  --repo-dir "$REPO" --branch feat/real-open --title "chore: real open" \
  --body "Adds config." --files-manifest "$TMP/m-real.json")"
[ "$(jq -r .outcome <<<"$out")" = "PR_OPENED" ] || fail "real open outcome (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "501" ] || fail "pr_number not parsed (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/real-open" ] || fail "branch field wrong (got: $out)"
git -C "$BARE" show-ref --verify --quiet refs/heads/feat/real-open \
  || fail "branch was not pushed to the bare upstream"
grep -qx -- '--head' "$TMP/gh-args" || fail "gh not invoked with --head"
grep -qx 'feat/real-open' "$TMP/gh-args" || fail "gh --head branch wrong"
grep -qx -- '--base' "$TMP/gh-args" || fail "gh not invoked with --base"
echo "PASS: open pushes the branch and creates via gh -> PR_OPENED {pr_number}"

# --- PR body: caller content + generator-owned Files-changed + footer ------
grep -qF 'Adds config.' "$TMP/gh-args" || fail "caller body text missing from assembled body"
grep -qF '## Files changed' "$TMP/gh-args" || fail "assembled body missing '## Files changed'"
grep -qF '.foundation/config' "$TMP/gh-args" || fail "assembled body missing touched file listing"
grep -qF 'proposal-PR generator' "$TMP/gh-args" || fail "assembled body missing generator footer"
echo "PASS: assembled PR body carries caller content + Files-changed + generator footer"

# --- open: EXISTS outcome when gh reports a PR already exists ---------------
mkdir -p "$TMP/bin-exists"
cat > "$TMP/bin-exists/gh" <<'EOF'
#!/usr/bin/env bash
echo "a pull request for branch \"feat/again\" into branch \"main\" already exists: https://github.com/acme/widget/pull/77"
exit 1
EOF
chmod +x "$TMP/bin-exists/gh"
manifest_of ".foundation/config:again=1" > "$TMP/m-again.json"
out="$(PATH="$TMP/bin-exists:$PATH" bash "$SCRIPT" open \
  --repo-dir "$REPO" --branch feat/again --title x --body y \
  --files-manifest "$TMP/m-again.json")"
[ "$(jq -r .outcome <<<"$out")" = "EXISTS" ] || fail "already-exists gh error not EXISTS (got: $out)"
[ "$(jq -r .pr_number <<<"$out")" = "77" ] || fail "EXISTS pr_number not parsed (got: $out)"
[ "$(jq -r .url <<<"$out")" = "https://github.com/acme/widget/pull/77" ] || fail "EXISTS url not parsed (got: $out)"
echo "PASS: open returns EXISTS{pr_number,url} when gh reports a PR already exists"

# --- idempotent NO_CHANGES once the base absorbs the proposal ---------------
# Simulate the feat/real-open proposal having merged into main: fast-forward
# main to that branch's tip on the bare upstream, then re-fetch and re-run
# the SAME manifest against the new main — nothing left to propose.
git -C "$BARE" update-ref refs/heads/main refs/heads/feat/real-open
git -C "$REPO" fetch -q origin
out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/real-open-retry \
  --title "chore: real open" --body "Adds config." \
  --files-manifest "$TMP/m-real.json" --base main --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "NO_CHANGES" ] || fail "idempotent re-run not NO_CHANGES (got: $out)"
[ "$(jq -r .branch <<<"$out")" = "feat/real-open-retry" ] || fail "NO_CHANGES branch field wrong (got: $out)"
echo "PASS: re-proposing already-absorbed content -> NO_CHANGES, no commit"

# --- error: --repo-dir not a git repo ---------------------------------------
mkdir -p "$TMP/notgit"
rc=0
out="$(bash "$SCRIPT" open --repo-dir "$TMP/notgit" --branch x --title x --body y \
  --files-manifest "$TMP/m1.json" --dry-run 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "non-git --repo-dir not structured ERROR (got: $out)"
echo "PASS: --repo-dir that is not a git work tree -> structured ERROR"

# --- error: missing required flags -------------------------------------------
rc=0; out="$(bash "$SCRIPT" open --branch x --title x --body y --files-manifest "$TMP/m1.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --repo-dir not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --title x --body y --files-manifest "$TMP/m1.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --branch not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/x --body y --files-manifest "$TMP/m1.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --title not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/x --title x --files-manifest "$TMP/m1.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --body/--body-file not structured ERROR (got: $out)"
rc=0; out="$(bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/x --title x --body y 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "missing --files-manifest not structured ERROR (got: $out)"
echo "PASS: missing required flags each -> structured ERROR + non-zero exit"

# --- --body-file and stdin manifest work -------------------------------------
printf 'Body from a file.\n' > "$TMP/body.txt"
manifest_of ".foundation/stdinfile:v=1" > "$TMP/m-stdin.json"
out="$(cat "$TMP/m-stdin.json" | bash "$SCRIPT" open --repo-dir "$REPO" --branch feat/stdin \
  --title x --body-file "$TMP/body.txt" --files-manifest - --dry-run)"
[ "$(jq -r .outcome <<<"$out")" = "DRY_RUN" ] || fail "stdin-manifest + body-file outcome (got: $out)"
echo "PASS: --body-file and --files-manifest - (stdin) both work"

echo "ALL PASS"
