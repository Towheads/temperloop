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
#
# temperloop#776 (refiled from foundation#1138) additions below the original
# suite: a subsetwiki incident (2026-07-10, Sessions/2026-07-10-1905-subsetwiki-
# f3716c1a) branched 18 commits behind origin/main with no `ask`. Investigation
# (kernel-side, this ticket) found the root cause was a LOGIC gap, not a
# registration gap:
#   - The hook was already registered in foundation's tracked settings.json
#     Bash-matcher PreToolUse array in the SAME commit that added the hook
#     itself (foundation 9115f191, 2026-06-25) — two weeks before the
#     incident, so it was wired into ~/.claude/settings.json well before
#     2026-07-10.
#   - subsetwiki ships its own project-level `.claude/settings.json`
#     declaring a PreToolUse hook for `Edit|Write|MultiEdit` only (that
#     file's own comment: "Global hooks... must NOT be re-declared here
#     (would double-fire)") — correct per Claude Code's documented hook
#     semantics: hook entries merge across user/project/local settings
#     scopes rather than one scope's `hooks` key replacing another's
#     (code.claude.com/docs/en/hooks, "Hook locations"). So a project
#     settings.json with no `Bash` matcher entry cannot shadow the globally
#     registered git-stale-branch-guard.sh — registration was never the gap.
#   - subsetwiki's `.claude/hooks/` ships `build-worktree-guard.sh`,
#     confirming its branch-creation path is `git worktree add -b` (the
#     worktree-based /build flow), not plain `checkout -b`. PRIOR to commit
#     fe86e11 (2026-07-25 — 15 days AFTER the incident), this hook's awk
#     parser recognized only `checkout -b/-B` / `switch -c/-C/--create` and
#     had NO branch-creating-worktree-add case at all, so `git worktree add
#     -b <branch> <path>` slipped through completely unparsed/unguarded
#     regardless of staleness. That is the exact incident shape and date
#     match: the parser gap existed on 2026-07-10, and was closed 15 days
#     later by a commit already merged into this very file — no new parser
#     change is needed by this ticket.
# The remaining gap this ticket closes is *test coverage*, not hook logic:
# an explicit reproduction naming the exact behind-by-N count (previously
# only ask/silent was asserted, never the reason string's count), and a
# "subsetwiki-shaped checkout" fixture — a real project-level
# `.claude/settings.json` mirroring subsetwiki's own shape sitting inside the
# fixture repo — proving the guard still fires there, closing the
# install-verification leg (a guard present-but-unregistered is otherwise
# indistinguishable from one that silently failed to fire).
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

# check_reason: asserts BOTH that the decision is `ask` AND that the reason
# text names the exact behind-by-N count — the "naming behind-by-N" half of
# the acceptance criterion that check()'s ask/silent-only comparison does not
# cover on its own.
check_reason() { # <desc> <expected-substring> <actual-stdout>
  local desc="$1" want_substr="$2" out="$3" reason
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if printf '%s' "$out" | grep -q '"permissionDecision":"ask"' && printf '%s' "$reason" | grep -qF "$want_substr"; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want reason to contain %q)\n     reason=%s\n' "$desc" "$want_substr" "$reason"
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

# --- temperloop#776: 18-commits-behind fixture, matching the subsetwiki
# incident's exact behind-count (Sessions/2026-07-10-1905-subsetwiki-f3716c1a)
# — reproduces the incident shape precisely rather than an arbitrary N. Uses
# its OWN isolated origin18.git/pusher18/seed18 (never the shared
# origin.git/pusher above) so advancing it 18 commits cannot disturb the
# already-established behind-by-1 / up-to-date fixtures those depend on.
git init -q --bare -b main "$TMP/origin18.git" 2>/dev/null \
  || git init -q --bare "$TMP/origin18.git"

git init -q -b main "$TMP/seed18" 2>/dev/null || { git init -q "$TMP/seed18"; git -C "$TMP/seed18" symbolic-ref HEAD refs/heads/main; }
echo A > "$TMP/seed18/f"; git -C "$TMP/seed18" add f; git -C "$TMP/seed18" commit -qm A
git -C "$TMP/seed18" remote add origin "$TMP/origin18.git"
git -C "$TMP/seed18" push -q -u origin main
git -C "$TMP/origin18.git" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

# Stale clone: stays at commit A while origin18 advances 18 commits ahead.
git clone -q "$TMP/origin18.git" "$TMP/work_stale18"

git clone -q "$TMP/origin18.git" "$TMP/pusher18"
n=1
while [ "$n" -le 18 ]; do
  echo "extra$n" > "$TMP/pusher18/f18_$n"
  git -C "$TMP/pusher18" add "f18_$n"
  git -C "$TMP/pusher18" commit -qm "extra $n"
  n=$((n + 1))
done
git -C "$TMP/pusher18" push -q origin main

# subsetwiki-shaped project settings.json (temperloop#776): mirrors the real
# subsetwiki `.claude/settings.json` — a PreToolUse hook for
# `Edit|Write|MultiEdit` (build-worktree-guard.sh) only, no `Bash` matcher —
# placed INSIDE the 18-behind fixture repo to prove the guard's firing does
# not depend on / get shadowed by a co-located project settings.json.
mkdir -p "$TMP/work_stale18/.claude/hooks"
cat >"$TMP/work_stale18/.claude/settings.json" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "_comment": "Repo-local hooks ONLY. Global hooks (session drain/log, board-adapter-guard, git-stale-branch-guard) are inherited from ~/.claude/settings.json and must NOT be re-declared here (would double-fire).",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/build-worktree-guard.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
JSON

# Structural registration check: the subsetwiki-shaped project settings.json
# fixture declares no `Bash` matcher at all, so it has no PreToolUse.Bash key
# to collide with — it cannot possibly shadow the globally-registered
# git-stale-branch-guard.sh regardless of scope-merge semantics.
if [ "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher | test("(^|\\|)Bash($|\\|)"))] | length' "$TMP/work_stale18/.claude/settings.json")" = "0" ]; then
  pass=$((pass + 1)); printf '  ✓ %s\n' "subsetwiki-shaped settings.json declares no Bash-matcher PreToolUse entry (no shadow surface)"
else
  fail=$((fail + 1)); printf '  ✗ %s\n' "subsetwiki-shaped settings.json unexpectedly declares a Bash-matcher PreToolUse entry"
fi

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

# --- foundation #1138: worktree-add-b path + explicit HEAD/@ base
check "worktree add -b off stale main -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git worktree add -b feat/x ../wt')"

check "worktree add -b with explicit origin/main commit-ish -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git worktree add -b feat/x ../wt origin/main')"

check "git -C prefix + worktree add -b off stale -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git -C . worktree add -b feat/x ../wt')"

check "worktree add without -b (checkout existing) -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git worktree add ../wt main')"

check "non-add worktree subcommand (list) -> silent" silent \
  "$(run_hook "$TMP/work_stale" 'git worktree list')"

check "checkout -b with explicit HEAD base off stale -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git checkout -b feat/x HEAD')"

check "switch -c with explicit @ base off stale -> ask" ask \
  "$(run_hook "$TMP/work_stale" 'git switch -c feat/x @')"

# --- temperloop#776: 18-behind reproduction naming the exact count, and the
# "subsetwiki-shaped checkout" install-verification leg (a co-located
# project-level `.claude/settings.json`, mirroring subsetwiki's real one,
# does not suppress the guard). Uses `git worktree add -b` — the exact
# command shape subsetwiki's build-worktree-guard.sh presence implies it
# uses — inside the fixture dir that also carries the project settings.json.
check_reason "18-behind checkout -b names the exact count (subsetwiki-shaped checkout)" \
  "18 commit(s) behind" \
  "$(run_hook "$TMP/work_stale18" 'git checkout -b feat/w223-w226')"

check_reason "18-behind worktree add -b names the exact count (subsetwiki-shaped checkout)" \
  "18 commit(s) behind" \
  "$(run_hook "$TMP/work_stale18" 'git worktree add -b feat/w223-w226 ../wt18')"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d git-stale-branch-guard checks passed\n' "$pass"
