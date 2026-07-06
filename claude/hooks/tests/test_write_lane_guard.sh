#!/usr/bin/env bash
# Tests for write-lane-guard.sh — the session write-lane guard.
#
# Synthetic fixtures (mktemp, zero network):
#   home        — the session's launch dir (CLAUDE_PROJECT_DIR), a git repo
#   foreign     — a DIFFERENT repo's canonical checkout (a peer session's tree)
#   foreign-wt  — a linked worktree off `foreign` (its .git is a gitfile)
#   plain-dir   — a non-repo directory (stands in for the vault / /tmp / scratch)
#
# Covers, for both the file tools (Edit/Write/…) and the Bash path:
#   - write/mutate inside home                     -> silent (in-lane)
#   - write/mutate inside a foreign canonical repo -> ask
#   - write/mutate inside a linked worktree        -> silent (in-lane)
#   - write into a non-repo path                   -> silent
#   - read-only git against a foreign repo         -> silent
#   - `git worktree add` off a foreign repo        -> silent (escape hatch)
#   - EVAL_RUN, non-matching tool, malformed input, missing jq -> fail open
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../write-lane-guard.sh"
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

# --- fixtures ----------------------------------------------------------------
HOME_REPO="$TMP/home";    git init -q --initial-branch=main "$HOME_REPO"
git -C "$HOME_REPO" commit -q --allow-empty -m init
FOREIGN="$TMP/foreign";   git init -q --initial-branch=main "$FOREIGN"
git -C "$FOREIGN" commit -q --allow-empty -m init
WT="$TMP/foreign-wt";     git -C "$FOREIGN" worktree add -q "$WT" -b wt
PLAIN="$TMP/plain-dir";   mkdir -p "$PLAIN"
echo x >"$HOME_REPO/f.txt"; echo x >"$FOREIGN/f.txt"; echo x >"$WT/f.txt"; echo x >"$PLAIN/f.txt"

HOME_RP="$(cd "$HOME_REPO" && pwd -P)"
FOREIGN_RP="$(cd "$FOREIGN" && pwd -P)"

# run a file-tool call; CLAUDE_PROJECT_DIR is always the home repo.
run_file() { # <cwd> <tool> <file_path> [env NAME=VAL...]
  local cwd="$1" tool="$2" fp="$3"; shift 3
  local json
  json=$(jq -cn --arg t "$tool" --arg fp "$fp" --arg cwd "$cwd" \
    '{tool_name:$t, tool_input:{file_path:$fp}, cwd:$cwd}')
  ( cd "$cwd" && env CLAUDE_PROJECT_DIR="$HOME_REPO" "$@" bash "$HOOK" <<<"$json" )
}
# run a Bash-tool call.
run_bash() { # <cwd> <command> [env NAME=VAL...]
  local cwd="$1" cmd="$2"; shift 2
  local json
  json=$(jq -cn --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')
  ( cd "$cwd" && env CLAUDE_PROJECT_DIR="$HOME_REPO" "$@" bash "$HOOK" <<<"$json" )
}

echo "== file tools =="
check "Write inside home -> silent"                 silent "$(run_file "$HOME_REPO" Write "$HOME_REPO/new.txt")"
check "Write inside home (nested new dirs) -> silent" silent "$(run_file "$HOME_REPO" Write "$HOME_REPO/a/b/c.txt")"
out="$(run_file "$HOME_REPO" Write "$FOREIGN/new.txt")"
check "Write inside FOREIGN checkout -> ask"        ask    "$out"
grep -q "$FOREIGN_RP" <<<"$out" || { fail=$((fail+1)); printf '  ✗ ask reason does not name the foreign root\n'; }
grep -q "$HOME_RP"    <<<"$out" || { fail=$((fail+1)); printf '  ✗ ask reason does not name home\n'; }
check "Write inside FOREIGN (nested new dirs) -> ask" ask   "$(run_file "$HOME_REPO" Write "$FOREIGN/x/y/z.txt")"
check "Edit inside FOREIGN existing file -> ask"    ask    "$(run_file "$HOME_REPO" Edit "$FOREIGN/f.txt")"
check "Write inside a linked worktree -> silent"    silent "$(run_file "$HOME_REPO" Write "$WT/new.txt")"
check "Write into a non-repo dir -> silent"         silent "$(run_file "$HOME_REPO" Write "$PLAIN/new.txt")"

# MultiEdit shape (edits[].file_path)
mej=$(jq -cn --arg cwd "$HOME_REPO" --arg fp "$FOREIGN/f.txt" \
  '{tool_name:"MultiEdit", tool_input:{edits:[{file_path:$fp}]}, cwd:$cwd}')
check "MultiEdit edits[] into FOREIGN -> ask" ask \
  "$( cd "$HOME_REPO" && env CLAUDE_PROJECT_DIR="$HOME_REPO" bash "$HOOK" <<<"$mej" )"

echo "== bash =="
check "git commit in home -> silent"                silent "$(run_bash "$HOME_REPO" "git commit -m x")"
check "git status against FOREIGN (read-only) -> silent" silent "$(run_bash "$HOME_REPO" "git -C $FOREIGN status")"
check "git log against FOREIGN (read-only) -> silent"    silent "$(run_bash "$HOME_REPO" "git -C $FOREIGN log --oneline")"
out="$(run_bash "$HOME_REPO" "git -C $FOREIGN commit -m x")"
check "git -C FOREIGN commit -> ask"                ask    "$out"
grep -q "$FOREIGN_RP" <<<"$out" || { fail=$((fail+1)); printf '  ✗ bash ask reason does not name the foreign root\n'; }
check "cd FOREIGN && git checkout -b x -> ask"      ask    "$(run_bash "$HOME_REPO" "cd $FOREIGN && git checkout -b x")"
check "cd FOREIGN && make install -> ask"           ask    "$(run_bash "$HOME_REPO" "cd $FOREIGN && make install")"
check "make install in home -> silent"              silent "$(run_bash "$HOME_REPO" "make install")"
check "git -C FOREIGN worktree add (escape hatch) -> silent" silent "$(run_bash "$HOME_REPO" "git -C $FOREIGN worktree add /tmp/zz -b zz")"
check "cd into a linked worktree && git commit -> silent"   silent "$(run_bash "$HOME_REPO" "cd $WT && git commit -m x")"
check "non-mutating bash (ls FOREIGN) -> silent"    silent "$(run_bash "$HOME_REPO" "ls $FOREIGN")"
check "git push against FOREIGN -> ask"             ask    "$(run_bash "$HOME_REPO" "git -C $FOREIGN push")"

echo "== fail-open / scoping =="
check "EVAL_RUN=1 suppresses a foreign write -> silent" silent "$(run_file "$HOME_REPO" Write "$FOREIGN/new.txt" EVAL_RUN=1)"
check "non-matching tool (Read) -> silent"          silent \
  "$( cd "$HOME_REPO" && env CLAUDE_PROJECT_DIR="$HOME_REPO" bash "$HOOK" \
      <<<"$(jq -cn --arg cwd "$HOME_REPO" '{tool_name:"Read", tool_input:{file_path:"whatever"}, cwd:$cwd}')" )"

# malformed input -> exit 0, no output
out="$(cd "$HOME_REPO" && printf 'not json' | CLAUDE_PROJECT_DIR="$HOME_REPO" bash "$HOOK")"; rc=$?
[ "$rc" -eq 0 ] || { fail=$((fail+1)); printf '  ✗ malformed input: exit=%s (want 0)\n' "$rc"; }
[ -z "$out" ]   || { fail=$((fail+1)); printf '  ✗ malformed input produced output: %s\n' "$out"; }
echo "  ✓ malformed input fails open (exit 0, no output)"

# jq missing -> exit 0, no output
BASH_BIN="$(command -v bash)"; NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for b in cat git dirname basename readlink mkdir date awk; do
  bp="$(command -v "$b")"; [ -n "$bp" ] && ln -sf "$bp" "$NOJQ/$b"
done
mej=$(jq -cn --arg cwd "$HOME_REPO" --arg fp "$FOREIGN/f.txt" '{tool_name:"Write", tool_input:{file_path:$fp}, cwd:$cwd}')
out="$(cd "$HOME_REPO" && printf '%s' "$mej" | CLAUDE_PROJECT_DIR="$HOME_REPO" PATH="$NOJQ" "$BASH_BIN" "$HOOK")"; rc=$?
[ "$rc" -eq 0 ] || { fail=$((fail+1)); printf '  ✗ jq-missing: exit=%s (want 0)\n' "$rc"; }
[ -z "$out" ]   || { fail=$((fail+1)); printf '  ✗ jq-missing produced output: %s\n' "$out"; }
echo "  ✓ jq missing fails open (exit 0, no output)"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d write-lane-guard checks passed\n' "$pass"
