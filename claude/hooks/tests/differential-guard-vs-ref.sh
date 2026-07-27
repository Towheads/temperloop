#!/usr/bin/env bash
# Differential harness for build-worktree-guard.sh — WORKING COPY vs a git REF.
#
# Why this exists (foundation#1354, review round 2). The DENY/ALLOW corpus in
# test_build_worktree_guard.sh proves the guard does what the corpus says. It
# cannot prove the guard still does what it USED to do, because a refactor that
# loses coverage tends to arrive with a corpus that ratifies the loss — that is
# exactly what happened: restructuring the operand walker into a verb-model
# table silently un-denied six shapes, and the new corpus pinned one of them
# (`find ... -exec rm {} \;`) as intended ALLOW, so 80/80 was green over a
# regression.
#
# So: run BOTH guards over the same payloads and diff the verdicts. The only
# result that matters is `old=DENY new=allow` — a coverage LOSS. `old=allow
# new=DENY` is a tightening and is reported, not failed (the whole point of the
# table is to catch shapes the flat list missed).
#
# NOT named test_*.sh on purpose: `make test-hooks` globs test_*.sh, and this
# needs a fetched git ref, so it must not be a hard CI gate. Run it by hand on
# any change to the guard`s Bash arm:
#
#     bash claude/hooks/tests/differential-guard-vs-ref.sh [ref]     # default origin/main
#
# shellcheck disable=SC2016
# SC2016 is disabled file-wide: the payloads deliberately carry UNEXPANDED
# `$(...)`/`$HOME`/backticks — expanding them here would test a different
# command. Interpolated fixture paths use double quotes explicitly.
set -uo pipefail

# The GATE is this guard vs shipped main. Any other ref is a DIAGNOSTIC run:
# the ratified-relaxation list below is declared relative to the default ref, so
# against an arbitrary ref its entries legitimately do not apply and a
# deliberate fix legitimately reads as a relaxation. Diagnostic runs therefore
# report but do not fail — otherwise the first person to pass a ref gets a red
# result that means nothing, and learns to ignore the harness.
DEFAULT_REF="origin/main"
REF="${1:-$DEFAULT_REF}"
GATING=0; [ "$REF" = "$DEFAULT_REF" ] && GATING=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
NEW_HOOK="$HERE/../build-worktree-guard.sh"
GUARD_REL="claude/hooks/build-worktree-guard.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }
[ -f "$NEW_HOOK" ] || { echo "FATAL: working-copy hook not found at $NEW_HOOK" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Fixture root under $HOME, never /tmp — /tmp is guard-allow-listed, which would
# make every DENY case vacuous (same reasoning as the corpus test`s preamble).
TMP=$(mktemp -d "${HOME:?}/.build-guard-diff.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export GIT_CEILING_DIRECTORIES="$TMP"
export XDG_STATE_HOME="$TMP/state"
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

OLD_HOOK="$TMP/old-build-worktree-guard.sh"
git -C "$REPO_ROOT" show "$REF:$GUARD_REL" >"$OLD_HOOK" 2>/dev/null || {
  echo "FATAL: could not read $GUARD_REL at ref '$REF' (try: git fetch origin)" >&2; exit 1; }
[ -s "$OLD_HOOK" ] || { echo "FATAL: hook at ref '$REF' is empty" >&2; exit 1; }

REPO="$TMP/repo"
git init -q --initial-branch=main "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
mkdir -p "$REPO/parentdir"
echo x >"$REPO/f.txt"
WT="$TMP/repo.wt/item"; mkdir -p "$TMP/repo.wt"
git -C "$REPO" worktree add -q "$WT" -b jail 2>/dev/null
touch "$WT/.build-guard"
mkdir -p "$WT/src" "$WT/dist" "$WT/build"
echo a >"$WT/src/a.ts"; echo k >"$WT/keep.txt"
WT_RP=$(cd "$WT" && pwd -P)

verdict() { # <hook> <cwd> <command> -> deny|allow
  local hook="$1" cwd="$2" cmd="$3" json out
  json=$(jq -cn --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')
  out=$( cd "$cwd" && bash "$hook" <<<"$json" 2>/dev/null )
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then printf 'DENY'; else printf 'allow'; fi
}

regress=0; tighten=0; same=0; ratified=0
probe() { # <desc> <command>
  local desc="$1" cmd="$2" old new
  old=$(verdict "$OLD_HOOK" "$WT" "$cmd")
  new=$(verdict "$NEW_HOOK" "$WT" "$cmd")
  if [ "$old" = DENY ] && [ "$new" = allow ]; then
    regress=$((regress + 1)); printf '  ✗ REGRESSION  old=%s new=%s  %s\n       cmd=[%s]\n' "$old" "$new" "$desc" "$cmd"
  elif [ "$old" = allow ] && [ "$new" = DENY ]; then
    tighten=$((tighten + 1)); printf '  + tightened   old=%s new=%s  %s\n' "$old" "$new" "$desc"
  else
    same=$((same + 1)); printf '  = same        old=%s new=%s  %s\n' "$old" "$new" "$desc"
  fi
}
# A DELIBERATE old=DENY -> new=allow, with its justification recorded inline.
# Every relaxation must come through here, so "we meant that one" is a written
# claim in the diff output rather than an absence — the failure this whole
# harness exists to prevent is a relaxation that nobody declared. Asserts the
# direction really is DENY->allow, so a stale entry cannot sit here unnoticed.
probe_ratified() { # <desc> <justification> <command>
  local desc="$1" why="$2" cmd="$3" old new
  old=$(verdict "$OLD_HOOK" "$WT" "$cmd")
  new=$(verdict "$NEW_HOOK" "$WT" "$cmd")
  if [ "$old" = DENY ] && [ "$new" = allow ]; then
    ratified=$((ratified + 1)); printf '  ~ RATIFIED    old=%s new=%s  %s\n       why: %s\n' "$old" "$new" "$desc" "$why"
  elif [ "$GATING" -eq 1 ]; then
    regress=$((regress + 1))
    printf '  ✗ STALE RATIFICATION  old=%s new=%s  %s\n       this entry claims a DENY->allow relaxation that no longer happens; delete it\n' \
      "$old" "$new" "$desc"
  else
    printf '  . n/a          old=%s new=%s  %s (ratification is %s-relative)\n' \
      "$old" "$new" "$desc" "$DEFAULT_REF"
  fi
}

if [ "$GATING" -eq 1 ]; then
  echo "== differential: working copy vs $REF (GATING) =="
else
  echo "== differential: working copy vs $REF (DIAGNOSTIC — the pass/fail verdict"
  echo "   and the ratified-relaxation list are calibrated to $DEFAULT_REF) =="
fi
echo

echo "-- HIGH-1: find -exec argv must not be discarded --"
probe "F#932 verbatim wearing a find -exec hat" \
  'find . -name x -exec rm -rf $(dirname $(pwd)) \;'
probe "find -exec rm -rf <absolute outside>" \
  'find . -name core -exec rm -rf /Users/travis/dev/mind \;'
probe "find -exec rmdir <absolute outside>" \
  'find . -name x -exec rmdir /Users/travis/dev/mind \;'
probe "find -exec rm -rf <fixture outside>" \
  "find . -name x -exec rm -rf $REPO/parentdir \\;"
probe "find -exec rm with a + terminator" \
  "find . -name x -exec rm -rf $REPO/parentdir +"

echo
echo "-- HIGH-2: a non-ALL run must not hide the next command --"
probe "rsync (not even destructive) then rm" \
  "rsync -a src/ dist/; rm -rf $REPO/parentdir"
probe "find -delete then rm" \
  "find . -delete; rm -rf $REPO/parentdir"
probe "git clean -xfd then rm" \
  "git clean -xfd; rm -rf $REPO/parentdir"
probe "dd (OF select) then rm" \
  "dd if=/dev/zero of=out.bin; rm -rf $REPO/parentdir"
probe "rsync then rm, && separated" \
  "rsync -a src/ dist/ && rm -rf $REPO/parentdir"

echo
echo "-- MEDIUM-3: LAST must survive a trailing option-with-argument --"
probe "rsync --delete DEST --exclude foo" \
  "rsync -a --delete src/ $REPO/dest/ --exclude foo"
probe "rsync --delete DEST --exclude foo (absolute outside)" \
  'rsync -a --delete src/ /Users/travis/dev/mind/ --exclude foo'
probe "rsync --del (delete-family alias)" \
  "rsync -a --del src/ $REPO/dest/"
probe "rsync --remove-source-files to an outside dest" \
  "rsync -a --remove-source-files src/ $REPO/dest/"

echo
echo "-- MEDIUM-5: read-only git clean must NOT be denied --"
probe "cd outside && git clean --dry-run" \
  "cd $REPO && git clean --dry-run"
probe "cd outside && git clean -n -d" \
  "cd $REPO && git clean -n -d"
probe "cd outside && git clean -n" \
  "cd $REPO && git clean -n"

echo
echo "-- LOW-6: an armed row selecting zero targets must still judge the cd --"
probe "cd outside && find -name x -delete (implicit path)" \
  "cd $REPO && find -name x -delete"
probe "cd outside && git clean -xfd" \
  "cd $REPO && git clean -xfd"

echo
echo "-- baseline: the pre-existing flat-list behavior must be unchanged --"
probe "F#932 verbatim"                 'rm -rf "$(dirname "$(pwd)")"'
probe "rm -rf \$HOME/dev"              'rm -rf $HOME/dev'
probe "rm -rf backtick pwd/.."         'rm -rf `pwd`/..'
probe "rm -rf ~/dev"                   'rm -rf ~/dev'
probe "rm -rf /Users/{a,b}"            'rm -rf /Users/{a,b}'
probe "rm -rf <outside>"               "rm -rf $REPO/parentdir"
probe "rm -rf ../../escape"            'rm -rf ../../escape'
probe "mv dest escapes"                "mv keep.txt $REPO/stolen.txt"
probe "rmdir outside"                  "rmdir $REPO/parentdir"
probe "truncate outside"               "truncate -s 0 $REPO/f.txt"
probe "dd of= outside"                 "dd if=/dev/zero of=$REPO/f.txt"
probe "rm -rf /etc"                    'rm -rf /etc'
probe "cd /etc && rm -rf hosts"        'cd /etc && rm -rf hosts'
probe "cd outside && rm"               "cd $REPO && rm -rf parentdir"
probe "cd nonliteral && rm"            'cd "$(dirname "$PWD")" && rm -rf x'
probe "in-worktree glob"               'rm -rf node_modules/*'
probe "rm -rf node_modules"            'rm -rf node_modules'
probe "rm -rf ./dist"                  'rm -rf ./dist'
probe "mv in-worktree rename"          'mv src/a.ts src/b.ts'
probe "mv into a new nested dir"       'mv src/a.ts src/new/deep/b.ts'
probe "rm under the worktree root"     "rm -rf $WT_RP/build/out"
probe "rm under /tmp"                  'rm -rf /tmp/build-worktree-guard-scratch'
probe "rm under \$TMPDIR"              "rm -rf $TMPDIR/scratch"
probe "cd in-worktree && rm"           "cd $WT_RP/src && rm -rf tmpwork"
probe "cd /tmp && rm"                  'cd /tmp && rm -rf build-guard-scratch'
probe "no destructive verb"            'git status --porcelain && ls -la'
probe "cat an outside path"            "cat $REPO/f.txt"
probe "rm a single in-worktree file"   'rm keep.txt'
probe "rm with flags first"            'rm -r -f -- node_modules'

echo
echo "-- deliberate relaxations (declared, not discovered) --"
probe_ratified "find -exec rm {} (bare brace placeholder)" \
  "{} expands to a path UNDER find's search root, and the PRE selector already judged that root. The old guard denied it only because {} trips the non-literal brace test — a FALSE deny on a routine worker command. The nested rm's real operands are still walked (see HIGH-1 above), and {} is exempted by name, not by discarding the argv." \
  'find . -name core -exec rm {} \;'
# The relaxation above is scoped to find's own placeholder, not to the cd
# context it runs in — pin that it still escapes nothing.
probe "cd outside && find -exec rm {} (relaxation stays scoped)" \
  "cd $REPO && find . -name core -exec rm {} \\;"

echo
printf 'differential vs %s: %d same, %d tightened, %d ratified, %d REGRESSIONS\n' \
  "$REF" "$same" "$tighten" "$ratified" "$regress"
if [ "$regress" -gt 0 ]; then
  if [ "$GATING" -eq 1 ]; then
    echo "FAILED — a shape the old guard DENIED is now allowed (coverage loss)"
    exit 1
  fi
  echo "DIAGNOSTIC — $regress DENY->allow difference(s) vs '$REF'. Not a verdict:"
  echo "  only the run against $DEFAULT_REF gates. Re-run with no argument."
  exit 0
fi
echo "OK — no coverage loss vs $REF"
