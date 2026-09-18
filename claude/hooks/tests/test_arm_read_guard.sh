#!/usr/bin/env bash
# DENY/ALLOW corpus for claude/hooks/arm-read-guard.sh (temperloop#2077).
#
# The guard's whole value is a verdict boundary, so this suite is two corpora,
# not one. The DENY corpus proves a cross-arm read is blocked; the ALLOW corpus
# is equally load-bearing — a guard that denied everything would pass every DENY
# case while making a dual-build arm unable to read its OWN files, which is a
# worse failure than the contamination it prevents. Both are run against the
# same armed fixture, plus an INERT corpus run against an UNARMED worktree: with
# no `.dual-build-arm` marker the guard must be silent, because it ships in a
# kernel every adopter installs and must cost a non-dual-build session nothing.
#
# A canary runs before the ALLOW corpus: an ALLOW result only means anything
# against a guard that is actually armed and firing. Without it, a hook that
# exited 0 at line 1 (a bad marker parse, a missing jq) would sweep the ALLOW
# and INERT corpora clean and report green over a guard protecting nothing.
#
# shellcheck disable=SC2016
# The Bash DENY corpus deliberately feeds UNEXPANDED command text; the fixture
# paths it interpolates use double quotes explicitly where expansion is wanted.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../arm-read-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
# Claude Code invokes the hook's command path directly, with no interpreter
# prefix: a 0644 hook exits 126 on every tool call and is silently inert.
[ -x "$HOOK" ] || { echo "FATAL: hook is not executable (chmod +x) — Claude Code runs the command path directly" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# --- fixture root ------------------------------------------------------------
TMP=$(mktemp -d "${HOME:?HOME must be set}/.arm-read-guard-test.XXXXXX") || {
  echo "FATAL: could not create a fixture root under \$HOME" >&2; exit 1; }
TMP=$(cd "$TMP" && pwd -P)   # realpath: the guard compares against `pwd -P` roots
trap 'rm -rf "$TMP"' EXIT

# The guard walks up from the tool cwd with `git rev-parse --show-toplevel`. If
# $HOME itself is a git checkout (dotfiles — common), the "not a repo" INERT
# case would resolve to $HOME's toplevel instead. Cap the walk at the fixture.
export GIT_CEILING_DIRECTORIES="$TMP"

# Isolate the hook's log away from the real one.
export XDG_STATE_HOME="$TMP/state"
# The guard's state dir ends in a legacy product-name component predating the
# kernel rename. DERIVE it from the guard's own declaration rather than
# restating the literal (which would plant an unreviewed pre-rename identifier
# and would rot the day that path moves).
GUARD_STATE_LEAF=$(sed -n 's|^XDG_STATE_DIR=.*/\([A-Za-z0-9._-][A-Za-z0-9._-]*\)"[[:space:]]*$|\1|p' "$HOOK" | head -1)
[ -n "$GUARD_STATE_LEAF" ] || {
  echo "FATAL: could not derive the guard's state-dir leaf from its XDG_STATE_DIR= line in $HOOK" >&2; exit 1; }
LOG="$XDG_STATE_HOME/$GUARD_STATE_LEAF/arm-read-guard.log"
mkdir -p "$XDG_STATE_HOME/$GUARD_STATE_LEAF"

# --- fixtures ----------------------------------------------------------------
REPO="$TMP/repo"
git init -q --initial-branch=main "$REPO"
echo seed >"$REPO/seed.txt"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q -m init

WTPARENT="$TMP/repo.wt"; mkdir -p "$WTPARENT"
SLUG="dual-item"
A="$WTPARENT/$SLUG@candidate"        # the armed arm under test
B="$WTPARENT/$SLUG@baseline"         # its sibling
A_BRANCH="build/$SLUG@candidate"
B_BRANCH="build/$SLUG@baseline"
git -C "$REPO" worktree add -q "$A" -b "$A_BRANCH" >/dev/null 2>&1
git -C "$REPO" worktree add -q "$B" -b "$B_BRANCH" >/dev/null 2>&1
mkdir -p "$A/src" "$B/src"
echo 'mine'    >"$A/src/x.ts"
echo 'sibling' >"$B/src/x.ts"

MARKER="$A/.dual-build-arm"
ATTEMPTS="$A/.dual-build-cross-read-attempts.jsonl"
jq -cn --arg wt "$B" --arg br "$B_BRANCH" \
  '{arm:"candidate", sibling_worktree:$wt, sibling_branch:$br}' >"$MARKER"

UNARMED="$WTPARENT/$SLUG@unarmed"    # a worktree with NO marker
git -C "$REPO" worktree add -q "$UNARMED" -b "build/$SLUG@unarmed" >/dev/null 2>&1

NONREPO="$TMP/nonrepo"; mkdir -p "$NONREPO"

BADMARK="$WTPARENT/$SLUG@badmark"    # armed with an unparseable marker
git -C "$REPO" worktree add -q "$BADMARK" -b "build/$SLUG@badmark" >/dev/null 2>&1
printf 'not json at all\n' >"$BADMARK/.dual-build-arm"

SIBLESS="$WTPARENT/$SLUG@sibless"    # valid JSON, no sibling fields
git -C "$REPO" worktree add -q "$SIBLESS" -b "build/$SLUG@sibless" >/dev/null 2>&1
printf '{"arm":"candidate"}\n' >"$SIBLESS/.dual-build-arm"

# Fixture shape assertions — every DENY below is meaningless if the marker or
# the sibling tree is not where the guard looks for it.
[ -f "$MARKER" ] || { echo "FATAL: fixture marker missing at $MARKER" >&2; exit 1; }
[ -d "$B/src" ]  || { echo "FATAL: fixture sibling worktree missing at $B" >&2; exit 1; }

# --- harness -----------------------------------------------------------------
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \xe2\x9c\x97 %s\n     %s\n' "$1" "$2"; }

verdict() { # <hook stdout> -> deny|silent
  if grep -q '"permissionDecision":"deny"' <<<"$1"; then printf 'deny'; else printf 'silent'; fi
}

run_bash() { # <cwd> <command>
  local cwd="$1" cmd="$2" json
  json=$(jq -cn --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')
  ( cd "$cwd" && bash "$HOOK" <<<"$json" )
}
run_tool() { # <cwd> <tool> <field> <value>
  local cwd="$1" tool="$2" field="$3" value="$4" json
  json=$(jq -cn --arg t "$tool" --arg f "$field" --arg v "$value" --arg cwd "$cwd" \
    '{tool_name:$t, tool_input:{($f):$v}, cwd:$cwd}')
  ( cd "$cwd" && bash "$HOOK" <<<"$json" )
}
expect() { # <want> <label> <output>
  local want="$1" label="$2" out="$3" got
  got=$(verdict "$out")
  if [ "$got" = "$want" ]; then ok "$label"
  else bad "$label" "want $want, got $got${out:+ :: $out}"; fi
}

# --- canary: the armed guard fires -------------------------------------------
echo "== canary: armed guard denies =="
canary=$(run_tool "$A" Read file_path "$B/src/x.ts")
if [ "$(verdict "$canary")" = "deny" ]; then
  ok "armed guard denies a sibling Read (ALLOW/INERT corpora below are meaningful)"
else
  bad "armed guard denies a sibling Read" "guard did not fire at all — every ALLOW/INERT result below would be vacuous"
  printf '\nFAILED — canary\n'; exit 1
fi

# --- DENY corpus -------------------------------------------------------------
echo
echo "== DENY: cross-arm reads =="
expect deny "Read absolute sibling file"           "$(run_tool "$A" Read file_path "$B/src/x.ts")"
expect deny "Read relative ../<slug>@baseline file" "$(run_tool "$A" Read file_path "../$SLUG@baseline/src/x.ts")"
expect deny "Read the sibling's own arm marker"    "$(run_tool "$A" Read file_path "$B/.dual-build-arm")"
expect deny "Glob pattern rooted in the sibling"   "$(run_tool "$A" Glob pattern "$B/**/*.ts")"
expect deny "Glob path rooted in the sibling"      "$(run_tool "$A" Glob path "$B")"
expect deny "Grep path rooted in the sibling"      "$(run_tool "$A" Grep path "$B/src")"
expect deny "Bash cat of an absolute sibling path" "$(run_bash "$A" "cat $B/src/x.ts")"
expect deny "Bash cd into the sibling worktree"    "$(run_bash "$A" "cd ../$SLUG@baseline && ls")"
expect deny "Bash git -C the sibling worktree"     "$(run_bash "$A" "git -C $B diff")"
expect deny "Bash git log of the sibling branch"   "$(run_bash "$A" "git log --oneline $B_BRANCH")"
expect deny "Bash git show <sibling-branch>:<file>" "$(run_bash "$A" "git show $B_BRANCH:src/x.ts")"
expect deny "Bash git diff against the sibling branch" "$(run_bash "$A" "git diff main..$B_BRANCH")"
expect deny "Bash sibling path inside a pipeline, not the leading word" \
  "$(run_bash "$A" "echo start; find . -type f | head -5; grep -r foo $B/src")"

# --- ALLOW corpus ------------------------------------------------------------
echo
echo "== ALLOW: this arm's own work =="
expect silent "Read own file (absolute)"        "$(run_tool "$A" Read file_path "$A/src/x.ts")"
expect silent "Read own file (relative)"        "$(run_tool "$A" Read file_path "src/x.ts")"
expect silent "Read own arm marker"             "$(run_tool "$A" Read file_path "$MARKER")"
expect silent "Glob own tree"                   "$(run_tool "$A" Glob pattern "src/**/*.ts")"
expect silent "Grep own tree"                   "$(run_tool "$A" Grep path "$A/src")"
expect silent "Bash git log of OWN branch"      "$(run_bash "$A" "git log --oneline $A_BRANCH")"
expect silent "Bash git log of main"            "$(run_bash "$A" "git log --oneline main")"
expect silent "Bash ordinary command"           "$(run_bash "$A" "ls -la && bash scripts/quality-gates.sh --scoped")"
expect silent "Bash reads the shared repo root" "$(run_bash "$A" "git -C $REPO status --short")"
expect silent "non-read tool (Write) at a sibling path" \
  "$(run_tool "$A" Write file_path "$B/src/x.ts")"

# --- INERT corpus ------------------------------------------------------------
echo
echo "== INERT: unarmed, malformed, or outside a repo =="
expect silent "unarmed worktree: sibling Read"     "$(run_tool "$UNARMED" Read file_path "$B/src/x.ts")"
expect silent "unarmed worktree: sibling git log"  "$(run_bash "$UNARMED" "git log $B_BRANCH")"
expect silent "parent checkout (no marker)"        "$(run_tool "$REPO" Read file_path "$B/src/x.ts")"
expect silent "unparseable marker fails open"      "$(run_tool "$BADMARK" Read file_path "$B/src/x.ts")"
expect silent "marker naming no sibling fails open" "$(run_tool "$SIBLESS" Read file_path "$B/src/x.ts")"
expect silent "cwd outside any git repo"           "$(run_tool "$NONREPO" Read file_path "$B/src/x.ts")"
expect silent "empty stdin"                        "$( ( cd "$A" && bash "$HOOK" </dev/null ) )"
expect silent "unparseable stdin"                  "$( ( cd "$A" && bash "$HOOK" <<<'not json' ) )"

# Every INERT case must also leave no attempt record in the unarmed trees.
for d in "$UNARMED" "$BADMARK" "$SIBLESS" "$REPO"; do
  if [ -e "$d/.dual-build-cross-read-attempts.jsonl" ]; then
    bad "no attempt record in an unarmed tree" "found one at $d"
  fi
done
ok "no attempt record written in any unarmed/malformed tree"

# --- attempt marker ----------------------------------------------------------
echo
echo "== attempt marker (the driver's cross_read_attempted signal) =="
if [ -f "$ATTEMPTS" ]; then
  ok "attempt file exists"
else
  bad "attempt file exists" "expected $ATTEMPTS after the DENY corpus"
fi

# It must sit NEXT TO the arm marker — the driver looks for it beside
# .dual-build-arm in the arm's worktree root, not in a state dir.
if [ "$(dirname "$ATTEMPTS")" = "$(dirname "$MARKER")" ]; then
  ok "attempt file sits next to .dual-build-arm"
else
  bad "attempt file sits next to .dual-build-arm" "$(dirname "$ATTEMPTS") != $(dirname "$MARKER")"
fi

if [ -f "$ATTEMPTS" ] && jq -e . "$ATTEMPTS" >/dev/null 2>&1; then
  ok "every attempt line is valid JSON"
else
  bad "every attempt line is valid JSON" "$(cat "$ATTEMPTS" 2>/dev/null)"
fi

# One line per denial, carrying the fields the ledger row is folded from.
attempt_lines=$(grep -c '' "$ATTEMPTS" 2>/dev/null || printf 0)
if [ "$attempt_lines" -ge 13 ]; then
  ok "one line per denial ($attempt_lines recorded)"
else
  bad "one line per denial" "only $attempt_lines lines for 13 DENY cases + canary"
fi

for field in ts arm tool kind target; do
  if jq -e --arg f "$field" 'select(has($f) | not) | .' "$ATTEMPTS" >/dev/null 2>&1; then
    bad "every attempt line carries .$field" "a line is missing it"
  else
    ok "every attempt line carries .$field"
  fi
done

# All three detection kinds must appear: an absolute path, a relative reach
# (`../<slug>@baseline`), and a git ref read. A record that collapsed them into
# one kind would still block, but would lose the distinction a reviewer reads —
# whether the arm reached for the sibling's files or for its history.
for k in path path-basename branch; do
  if jq -sre --arg k "$k" 'map(select(.kind == $k)) | length > 0' "$ATTEMPTS" >/dev/null 2>&1; then
    ok "a '$k' attempt kind was recorded"
  else
    bad "a '$k' attempt kind was recorded" "$(cat "$ATTEMPTS")"
  fi
done

# A fresh armed arm that never cross-reads must leave NO attempt file: the
# driver reads the file's existence as cross_read_attempted, so a file created
# eagerly at arm time would report every clean arm as contaminated.
CLEAN="$WTPARENT/$SLUG@clean"
git -C "$REPO" worktree add -q "$CLEAN" -b "build/$SLUG@clean" >/dev/null 2>&1
jq -cn --arg wt "$B" --arg br "$B_BRANCH" \
  '{arm:"clean", sibling_worktree:$wt, sibling_branch:$br}' >"$CLEAN/.dual-build-arm"
run_tool "$CLEAN" Read file_path "$CLEAN/src/x.ts" >/dev/null 2>&1
run_bash "$CLEAN" "git log --oneline main" >/dev/null 2>&1
if [ -e "$CLEAN/.dual-build-cross-read-attempts.jsonl" ]; then
  bad "a clean arm leaves no attempt file" "found one at $CLEAN"
else
  ok "a clean arm leaves no attempt file"
fi

# --- log surface -------------------------------------------------------------
if grep -q 'DENY' "$LOG" 2>/dev/null; then
  ok "denials are logged to the XDG state log"
else
  bad "denials are logged to the XDG state log" "no DENY line in $LOG"
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d arm-read-guard checks passed\n' "$pass"
