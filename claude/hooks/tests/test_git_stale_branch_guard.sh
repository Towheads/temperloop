#!/usr/bin/env bash
# Tests for git-stale-branch-guard.sh (foundation #590).
#
# Real-git fixtures with file:// remotes — zero network. Builds an origin whose
# default branch is one commit ahead of a "stale" local clone, then feeds the
# hook crafted PreToolUse JSON and asserts the decision:
#   - checkout -b / switch -c off a stale local default  -> ask (behind-by-N)
#   - branch off origin/<default>, a SHA, or up-to-date   -> silent
#   - non-branch-creation command                         -> silent
#   - EVAL_RUN set                                         -> silent
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../git-stale-branch-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <expected: ask|silent> <actual-stdout>
  local desc="$1" want="$2" out="$3" got
  if printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then got=ask; else got=silent; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want=%s got=%s)\n     out=%s\n' "$desc" "$want" "$got" "$out"
  fi
}

run_hook() { # <repo-cwd> <command-string> [EVAL_RUN]
  local repo="$1" command="$2" evalrun="${3:-}" json
  json=$(jq -cn --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  ( cd "$repo" && printf '%s' "$json" | EVAL_RUN="$evalrun" bash "$HOOK" )
}

# --- Build origin (bare, default branch main) with commit A, then advance to B.
git init -q --bare -b main "$TMP/origin.git" 2>/dev/null \
  || git init -q --bare "$TMP/origin.git"   # older git: -b unsupported, set below

git init -q -b main "$TMP/seed" 2>/dev/null || { git init -q "$TMP/seed"; git -C "$TMP/seed" symbolic-ref HEAD refs/heads/main; }
echo A > "$TMP/seed/f"; git -C "$TMP/seed" add f; git -C "$TMP/seed" commit -qm A
git -C "$TMP/seed" remote add origin "$TMP/origin.git"
git -C "$TMP/seed" push -q -u origin main
# Ensure the bare repo's HEAD names main so clones set origin/HEAD -> origin/main.
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

# Stale clone: has A; origin/main will become B after the hook's fetch.
git clone -q "$TMP/origin.git" "$TMP/work_stale"

# Advance origin to B via a separate clone.
git clone -q "$TMP/origin.git" "$TMP/pusher"
echo B > "$TMP/pusher/f"; git -C "$TMP/pusher" commit -qam B; git -C "$TMP/pusher" push -q origin main

# Up-to-date clone: cloned after B, so local main == origin/main.
git clone -q "$TMP/origin.git" "$TMP/work_fresh"

sha_a=$(git -C "$TMP/work_stale" rev-parse HEAD)

# --- Assertions
check "checkout -b off stale main -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git checkout -b feat/x')"

check "switch -c off stale main -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git switch -c feat/x')"

check "checkout -b with explicit origin/main base -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git checkout -b feat/x origin/main')"

check "checkout -b with explicit SHA base -> silent" silent \
  "$(run_hook "$TMP/work_stale" "git checkout -b feat/x $sha_a")"

check "checkout -b off up-to-date main -> silent" silent \
  "$(run_hook "$TMP/work_fresh" 'git checkout -b feat/x')"

check "non-branch command (git status) -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git status')"

check "plain checkout (no create) -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git checkout main')"

check "git -C prefix + create off stale -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git -C . checkout -b feat/x')"

check "compound: fetch && checkout -b off stale -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git fetch && git checkout -b feat/x')"

check "EVAL_RUN suppresses the prompt -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git checkout -b feat/x' 1)"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d git-stale-branch-guard checks passed\n' "$pass"
