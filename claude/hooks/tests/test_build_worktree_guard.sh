#!/usr/bin/env bash
# Tests for build-worktree-guard.sh — the /build worker write-jail
# (guard: foundation #17/#10 for the file arm, #1087 / F#932 for the Bash arm).
#
# This is the only guard in its family with a CRITICAL incident behind it. On
# 2026-07-04 a /build worker ran `rm -rf "$(dirname "$(pwd)")" 2>/dev/null` from
# a cwd it had assumed wrongly; `dirname` resolved to `~/dev` and every checkout,
# every `.wt` worktree, and the local Obsidian vault were deleted. The guard's
# normal mode is to allow SILENTLY, so a regression to always-open changes
# nothing observable in a session — which is exactly why it needs a harness
# rather than field confidence.
#
# Synthetic fixtures (mktemp, zero network, no real repo touched):
#   repo            — the parent checkout; every path here is OUTSIDE the jail
#   repo.wt/item    — the ARMED build worktree (marker + `<repo>.wt/` convention)
#   repo.wt/nomark  — under `.wt` but carrying no marker            -> inert
#   plain           — a repo WITH a marker but NOT under `.wt`      -> inert
#   nonrepo         — a plain directory, no git                     -> inert
#   tmpdir          — stands in for $TMPDIR (an allow-listed root)
#
# Three corpora:
#   INERT — the guard makes NO containment judgment; must allow silently AND
#           log its reason, so an unreached guard is distinguishable from a
#           permitting one.
#   DENY  — the F#932 shapes: a non-literal operand, or a literal escape.
#   ALLOW — routine in-worktree worker commands, which must NOT be denied.
#
# The ALLOW corpus is load-bearing, not padding: a guard that falsely denies gets
# disarmed by the first operator it blocks, after which coverage is zero — a
# worse outcome than the gap it closed. Every ALLOW case additionally asserts the
# guard logged NO `INERT:` line. That is what separates "ran and permitted" from
# "silently never armed" — without it, a guard that had regressed to always-inert
# would pass the entire ALLOW corpus while protecting nothing.
#
# Extending (plan item L2 redirect containment): add a line to the corpus blocks
# below — `deny_bash`, `allow_bash`, `deny_file`, `allow_file` each take <desc>
# <case> and handle log isolation themselves.
#
# The guard's Bash arm is a verb -> operand-model TABLE (foundation#1354), so a
# new destructive shape arrives as a table ROW plus a DENY/ALLOW pair here. The
# three shapes past the flat rm/mv/dd list each have a DIFFERENT grammar, and
# each needs BOTH polarities pinned — the arm predicate is as load-bearing as the
# operand selector:
#   rsync     destructive only under `--delete*`; only its LAST operand (the
#             destination) is a target. A plain rsync must stay untouched.
#   find      destructive only when the predicate run carries `-delete` or
#             `-exec rm`; only its PRE-predicate paths are targets. Its
#             predicate tokens routinely carry globs (`-name '*.pyc'`) that must
#             NOT be read as non-literal path operands.
#   git clean destructive under -x/-d/-f with NO target operand at all, so it is
#             judged against the cd-context base.
#
# THIS CORPUS IS NOT SUFFICIENT ON ITS OWN. It proves the guard does what the
# corpus says; it cannot prove the guard still does what it USED to do, because
# a refactor that loses coverage tends to arrive with a corpus that ratifies the
# loss. That is not hypothetical here: the first cut of the operand-model table
# un-denied six shapes and pinned one of them (`find ... -exec rm {} \;`) as
# intended ALLOW, so the suite was fully green over a regression. Run
# `claude/hooks/tests/differential-guard-vs-ref.sh` (working copy vs a git ref,
# failing on any `old=DENY new=allow`) alongside this file on any change to the
# guard's Bash arm.
#
# shellcheck disable=SC2016
# SC2016 ("expressions don't expand in single quotes") is disabled file-wide on
# purpose: the DENY corpus feeds the guard command strings containing UNEXPANDED
# `$(...)`, `$HOME`, and backticks. Those are the payload — expanding them here
# would test a completely different (and harmless) command.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../build-worktree-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
# Claude Code runs the hook COMMAND PATH directly, so the file MUST be executable
# — a 0644 hook is silently inert (installed but never runs). Every sibling guard
# is 0755; assert it here so a missing +x can never ship again.
[ -x "$HOOK" ] || { echo "FATAL: hook is not executable (needs chmod +x) — Claude Code runs the command path directly" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# --- fixture root ------------------------------------------------------------
# NOT `mktemp -d`. The guard ALLOW-LISTS /tmp and $TMPDIR, which is where a bare
# mktemp lands (/tmp/... on Linux, /var/folders/... on macOS) — fixtures sited
# there would be inside the allow-list, and every DENY case would be judged
# "allowed" for a reason that has nothing to do with the behavior under test.
# Root the fixtures under $HOME instead, and assert the property below.
TMP=$(mktemp -d "${HOME:?HOME must be set}/.build-worktree-guard-test.XXXXXX") || {
  echo "FATAL: could not create a fixture root under \$HOME" >&2; exit 1; }
TMP=$(cd "$TMP" && pwd -P)   # realpath: the guard compares against `pwd -P` roots
trap 'rm -rf "$TMP"' EXIT

for forbidden in /tmp /private/tmp "${TMPDIR:-/nonexistent}"; do
  case "$TMP/" in
    "${forbidden%/}"/*)
      echo "FATAL: fixture root '$TMP' is under the guard's allow-listed '$forbidden' — DENY cases would be vacuous" >&2
      exit 1 ;;
  esac
done

# The guard walks up from the tool cwd with `git rev-parse --show-toplevel`. If
# $HOME itself is a git repo (a dotfiles checkout — common), the "cwd is not in a
# git repo" INERT case would silently resolve to $HOME's toplevel instead. Cap
# the discovery walk at the fixture root so that case is deterministic anywhere.
export GIT_CEILING_DIRECTORIES="$TMP"

# Isolate the hook's log (it is the assertion surface for the INERT contract) and
# pin $TMPDIR to a fixture dir, so the "$TMPDIR is allow-listed" case is exact.
export XDG_STATE_HOME="$TMP/state"
export TMPDIR="$TMP/tmpdir"

# The guard's state dir ends in a legacy product-name component that predates the
# kernel rename. DERIVE it from the guard's own `XDG_STATE_DIR=` declaration
# rather than restating the literal here: restating it would plant a second,
# unreviewed copy of a pre-rename identifier (the kernel leak gate flags exactly
# that), and would leave this test pointing at a dead path the day the rename
# lands — every INERT assertion would then fail for a reason unrelated to the
# guard's behavior. Exact and deterministic: one parsed value, asserted non-empty.
GUARD_STATE_LEAF=$(sed -n 's|^XDG_STATE_DIR=.*/\([A-Za-z0-9._-][A-Za-z0-9._-]*\)"[[:space:]]*$|\1|p' "$HOOK" | head -1)
[ -n "$GUARD_STATE_LEAF" ] || {
  echo "FATAL: could not derive the guard's state-dir leaf from its XDG_STATE_DIR= line in $HOOK — has that declaration changed shape?" >&2
  exit 1; }
LOG="$XDG_STATE_HOME/$GUARD_STATE_LEAF/build-worktree-guard.log"
mkdir -p "$XDG_STATE_HOME/$GUARD_STATE_LEAF" "$TMPDIR"

# --- fixtures ----------------------------------------------------------------
REPO="$TMP/repo"
git init -q --initial-branch=main "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
mkdir -p "$REPO/parentdir"
echo x >"$REPO/f.txt"

WTPARENT="$TMP/repo.wt"; mkdir -p "$WTPARENT"
WT="$WTPARENT/item"
git -C "$REPO" worktree add -q "$WT" -b jail 2>/dev/null
touch "$WT/.build-guard"                       # <- arms the guard
mkdir -p "$WT/src" "$WT/node_modules" "$WT/build" "$WT/dist"
echo a >"$WT/src/a.ts"; echo k >"$WT/keep.txt"

NOMARK="$WTPARENT/nomark"                      # under .wt, but unarmed
git -C "$REPO" worktree add -q "$NOMARK" -b nomark 2>/dev/null

PLAIN="$TMP/plain"                             # marker OUTSIDE the .wt convention
git init -q --initial-branch=main "$PLAIN"
git -C "$PLAIN" commit -q --allow-empty -m init
touch "$PLAIN/.build-guard"

NONREPO="$TMP/nonrepo"; mkdir -p "$NONREPO"    # not a git working tree at all

WT_RP=$(cd "$WT" && pwd -P)

# Multi-line commands. The guard's awk walker is LINE-oriented and carries no
# heredoc state, so a heredoc BODY is walked as if each line were a command —
# these two pin both sides of that. The markdown one is a DISCLOSED false
# positive (a blockquote reads as a redirect to a non-literal target); pinning
# it means a future change to the walker cannot flip it silently in either
# direction. Built with $'...' so the newlines are real.
HEREDOC_PLAIN=$'cat > README.md <<\'EOF\'\nplain prose line\nanother line\nEOF'
HEREDOC_MARKDOWN=$'cat > README.md <<\'EOF\'\n> **Note:** see the docs\nEOF'

# Assert the fixture's load-bearing shape before trusting a single result: the
# armed worktree must sit under a `<repo>.wt/` parent and carry the marker.
case "$(dirname "$WT_RP")" in
  *.wt) ;;
  *) echo "FATAL: fixture worktree '$WT_RP' is not under a '<repo>.wt/' dir — the arming gate would never fire" >&2; exit 1 ;;
esac
[ -f "$WT_RP/.build-guard" ] || { echo "FATAL: fixture marker missing at $WT_RP/.build-guard" >&2; exit 1; }

# --- harness -----------------------------------------------------------------
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

verdict() { # <hook stdout> -> deny|silent
  if printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; then printf 'deny'; else printf 'silent'; fi
}
log_reset()     { : >"$LOG"; }
log_inert()     { grep -h 'INERT:' "$LOG" 2>/dev/null || true; }

run_bash() { # <cwd> <command> [env NAME=VAL ...]
  local cwd="$1" cmd="$2"; shift 2
  local json
  json=$(jq -cn --arg c "$cmd" --arg cwd "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')
  ( cd "$cwd" && env "$@" bash "$HOOK" <<<"$json" )
}
run_file() { # <cwd> <tool> <file_path> [env NAME=VAL ...]
  local cwd="$1" tool="$2" fp="$3"; shift 3
  local json
  json=$(jq -cn --arg t "$tool" --arg fp "$fp" --arg cwd "$cwd" \
    '{tool_name:$t, tool_input:{file_path:$fp}, cwd:$cwd}')
  ( cd "$cwd" && env "$@" bash "$HOOK" <<<"$json" )
}
run_json() { # <cwd> <raw json> — for shapes the helpers above don't build
  local cwd="$1" json="$2"
  ( cd "$cwd" && bash "$HOOK" <<<"$json" )
}

# Corpus helpers. Each isolates the log, runs from the ARMED worktree, and
# asserts both the stdout verdict and (for ALLOW) that a judgment was made.
deny_bash() { # <desc> <command>
  local desc="$1" out; log_reset; out=$(run_bash "$WT" "$2")
  if [ "$(verdict "$out")" = deny ]; then ok "DENY  $desc"
  else bad "DENY  $desc" "want=deny got=silent  cmd=[$2]"; fi
}
allow_bash() { # <desc> <command>
  local desc="$1" out inert; log_reset; out=$(run_bash "$WT" "$2")
  if [ "$(verdict "$out")" != silent ]; then
    bad "ALLOW $desc" "FALSE DENY — cmd=[$2] out=$out"; return
  fi
  inert=$(log_inert)
  if [ -n "$inert" ]; then
    bad "ALLOW $desc" "guard was INERT, not permitting: $inert"; return
  fi
  ok "ALLOW $desc"
}
deny_file() { # <desc> <tool> <file_path>
  local desc="$1" out; log_reset; out=$(run_file "$WT" "$2" "$3")
  if [ "$(verdict "$out")" = deny ]; then ok "DENY  $desc"
  else bad "DENY  $desc" "want=deny got=silent  tool=$2 path=[$3]"; fi
}
allow_file() { # <desc> <tool> <file_path>
  local desc="$1" out inert; log_reset; out=$(run_file "$WT" "$2" "$3")
  if [ "$(verdict "$out")" != silent ]; then
    bad "ALLOW $desc" "FALSE DENY — tool=$2 path=[$3] out=$out"; return
  fi
  inert=$(log_inert)
  if [ -n "$inert" ]; then
    bad "ALLOW $desc" "guard was INERT, not permitting: $inert"; return
  fi
  ok "ALLOW $desc"
}
# <desc> <expected reason substring> <hook stdout>
check_inert() {
  local desc="$1" want="$2" out="$3" inert
  if [ "$(verdict "$out")" != silent ]; then
    bad "INERT $desc" "guard DENIED where it must be inert: $out"; return
  fi
  inert=$(log_inert)
  if [ -z "$inert" ]; then
    bad "INERT $desc" "no 'INERT:' line logged — an unreached guard is indistinguishable from a permitting one"; return
  fi
  case "$inert" in
    *"$want"*) ok "INERT $desc" ;;
    *) bad "INERT $desc" "INERT reason does not mention '$want': $inert" ;;
  esac
}

# =============================================================================
echo "== INERT: the guard makes no judgment, allows silently, and says why =="
# Each of these is an early `exit 0`. A destructive, escaping command is used
# throughout so that a guard which HAD armed would unambiguously deny — the
# silence therefore proves inertness, not leniency.
ESCAPE="rm -rf $REPO/parentdir"

log_reset
check_inert "no .build-guard marker (under .wt)" "no .build-guard marker" \
  "$(run_bash "$NOMARK" "$ESCAPE")"

log_reset
check_inert "no .build-guard marker (parent checkout)" "no .build-guard marker" \
  "$(run_bash "$REPO" "$ESCAPE")"

# Marker present but outside the `<repo>.wt/` convention: inert AND a stderr warning.
log_reset
err="$TMP/stderr-plain.txt"
out=$(run_bash "$PLAIN" "$ESCAPE" 2>"$err")
check_inert "marker outside the '<repo>.wt/' convention" "not under a '<repo>.wt/' dir" "$out"
if grep -q "stale marker" "$err"; then ok "INERT stale marker also warns on stderr"
else bad "INERT stale marker stderr warning" "stderr=[$(cat "$err")]"; fi

log_reset
check_inert "cwd is not a git working tree" "not inside a git working tree" \
  "$(run_bash "$NONREPO" "$ESCAPE")"

log_reset
check_inert "non-matching tool_name (Read)" "is not one of Bash/Edit/Write/MultiEdit" \
  "$(run_file "$WT" Read "$REPO/f.txt")"

log_reset
check_inert "unparseable (non-JSON) input" "is not one of Bash/Edit/Write/MultiEdit" \
  "$( cd "$WT" && printf 'not json' | bash "$HOOK" )"

log_reset
check_inert "empty stdin" "empty hook input" \
  "$( cd "$WT" && bash "$HOOK" </dev/null )"

log_reset
check_inert "Bash with an empty command" "command is absent or empty" \
  "$(run_json "$WT" "$(jq -cn --arg cwd "$WT" '{tool_name:"Bash",tool_input:{command:""},cwd:$cwd}')")"

log_reset
check_inert "file tool with no parseable target" "no parseable write target" \
  "$(run_json "$WT" "$(jq -cn --arg cwd "$WT" '{tool_name:"Write",tool_input:{},cwd:$cwd}')")"

# jq absent -> inert. BASH_BIN is resolved via the test's normal PATH so only the
# hook's internal `command -v jq` sees the stripped PATH. `date`/`mkdir` must
# survive the strip or the INERT line itself could not be written.
log_reset
BASH_BIN="$(command -v bash)"; NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for b in cat git dirname basename readlink mkdir date awk grep; do
  bp="$(command -v "$b")"; [ -n "$bp" ] && ln -sf "$bp" "$NOJQ/$b"
done
nojq_json=$(jq -cn --arg cwd "$WT" --arg c "$ESCAPE" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
out="$( cd "$WT" && printf '%s' "$nojq_json" | PATH="$NOJQ" "$BASH_BIN" "$HOOK" )"; rc=$?
[ "$rc" -eq 0 ] || bad "INERT jq absent exits 0" "exit=$rc"
check_inert "jq absent" "jq not found on PATH" "$out"

# =============================================================================
echo
echo "== DENY: the F#932 shapes — a non-literal operand, or a literal escape =="
# The incident command itself. Both operand tokens carry a `$(` substitution, so
# the guard cannot prove containment and must refuse rather than assume.
deny_bash "F#932 verbatim: rm -rf \"\$(dirname \"\$(pwd)\")\"" \
  'rm -rf "$(dirname "$(pwd)")"'
deny_bash "F#932 with stderr suppressed (the error-hiding half of the incident)" \
  'rm -rf "$(dirname "$(pwd)")" 2>/dev/null'
deny_bash "non-literal operand: \$HOME expansion"        'rm -rf $HOME/dev'
deny_bash "non-literal operand: backtick substitution"   'rm -rf `pwd`/..'
deny_bash "non-literal operand: tilde"                   'rm -rf ~/dev'
deny_bash "non-literal operand: brace expansion"         'rm -rf /Users/{a,b}'
# A LITERAL operand that resolves outside the worktree root — the other half of
# the contract: containment is judged on the resolved path, not on the spelling.
deny_bash "literal absolute path outside the worktree"   "rm -rf $REPO/parentdir"
deny_bash "literal relative escape via .."               'rm -rf ../../escape'
deny_bash "mv whose DESTINATION escapes"                 "mv keep.txt $REPO/stolen.txt"
deny_bash "rmdir outside the worktree"                   "rmdir $REPO/parentdir"
deny_bash "truncate outside the worktree"                "truncate -s 0 $REPO/f.txt"
deny_bash "dd of= outside the worktree"                  "dd if=/dev/zero of=$REPO/f.txt"
# Pins the top-level-path fix below (`abspath` used to emit "//etc"): collapsing
# the root separator must not accidentally widen the allow-list.
deny_bash "top-level path outside the allow-list"        'rm -rf /etc'
deny_bash "cd to a top-level dir outside the allow-list" 'cd /etc && rm -rf hosts'
# cd context: the operand is innocent, the base dir is not.
deny_bash "cd to a literal dir outside, then rm"         "cd $REPO && rm -rf parentdir"
deny_bash "cd to a NON-LITERAL dir, then rm"             'cd "$(dirname "$PWD")" && rm -rf x'
# Deliberately conservative: a glob is unprovable, so even an in-worktree glob is
# refused. Documented in the guard header as preventive, not a complete sandbox.
deny_bash "in-worktree glob is still unprovable"         'rm -rf node_modules/*'

# --- the three post-flat-list operand models (foundation#1354) ---------------
# rsync: LAST operand only, armed by --delete*.
deny_bash "rsync --delete to a destination outside"      "rsync -a src/ $REPO/dest/ --delete"
deny_bash "rsync --delete before the operands"           "rsync --delete src/ $REPO/dest/"
deny_bash "rsync --delete-after (a --delete* variant)"   "rsync -a --delete-after src/ $REPO/dest/"
deny_bash "rsync --delete to a NON-LITERAL destination"  'rsync -a --delete src/ "$HOME/dev/dest"'
deny_bash "cd outside, then rsync --delete"              "cd $REPO && rsync -a --delete src/ dest/"
# find: PRE-predicate paths only, armed by -delete / -exec rm. `-delete` must
# NOT be swallowed by the leading-`-` flag skip that the flat list applied.
deny_bash "find -delete on a path outside"               "find $REPO/parentdir -delete"
deny_bash "find -exec rm on a path outside"              "find $REPO -name x -exec rm {} \;"
deny_bash "find -exec rmdir on a path outside"           "find $REPO -type d -exec rmdir {} \;"
deny_bash "find -delete on a NON-LITERAL path"           'find "$HOME/dev" -delete'
deny_bash "find -delete after a leading -L option"       "find -L $REPO/parentdir -delete"
deny_bash "cd outside, then find . -delete"              "cd $REPO && find . -name x -delete"
# git clean: NO target operand — judged against the cd-context base. The ALLOW
# twins for these live below ("read-only git clean"): the ARM predicate, not the
# cd check, is what must separate `-xfd` from `--dry-run` at the same cd.
deny_bash "git clean -xfd with a cd-context outside"     "cd $REPO && git clean -xfd"
deny_bash "git clean -f with a cd-context outside"       "cd $REPO && git clean -f"
deny_bash "git clean -X with a cd-context outside"       "cd $REPO && git clean -X"
deny_bash "git clean --force with a cd-context outside"  "cd $REPO && git clean --force"
deny_bash "git clean -xfd after a NON-LITERAL cd"        'cd "$(dirname "$PWD")" && git clean -xfd'

# --- nested-verb + run-resume contracts (foundation#1354, review round 2) -----
# An armed `find -exec rm` proves the guard KNOWS the command deletes; the
# tokens saying WHAT it deletes are the -exec argv. Skipping the walker past the
# consumed run discarded exactly those, re-admitting the F#932 shape in a find
# hat. The nested verb must resolve through the table like any other. (`\;` and
# `+` are never a bare `;`, so no glued-separator trick is needed — this is
# idiomatic find, and :332 above does NOT cover it: that one denies on find's
# own path, never on the rm's.)
deny_bash "F#932 shape wearing a find -exec hat" \
  'find . -name x -exec rm -rf $(dirname $(pwd)) \;'
deny_bash "find -exec rm on an OUTSIDE path (find's own path in-worktree)" \
  "find . -name x -exec rm -rf $REPO/parentdir \\;"
deny_bash "find -exec rmdir on an OUTSIDE path (find's own path in-worktree)" \
  "find . -name x -exec rmdir $REPO/parentdir \\;"
deny_bash "find -exec rm on an OUTSIDE path, + terminator" \
  "find . -name x -exec rm -rf $REPO/parentdir +"
deny_bash "find -execdir rm on an OUTSIDE path" \
  "find . -name x -execdir rm -rf $REPO/parentdir \\;"

# ...and a verb's operand run must not become a hiding place for whatever
# FOLLOWS it. Any select that is not ALL leaves tokens unemitted; consuming the
# run anyway meant a later destructive verb was never reached. Note the rsync
# case: that rsync is not even destructive — adding the ROW created the hiding
# place, so every future row is one too. These pin the mechanism, not the verbs.
deny_bash "an rsync run must not hide a following rm" \
  "rsync -a src/ dist/; rm -rf $REPO/parentdir"
deny_bash "a find run must not hide a following rm" \
  "find . -delete; rm -rf $REPO/parentdir"
deny_bash "a git clean run must not hide a following rm" \
  "git clean -xfd; rm -rf $REPO/parentdir"
deny_bash "a dd run must not hide a following rm" \
  "dd if=/dev/zero of=out.bin; rm -rf $REPO/parentdir"
deny_bash "an rsync run must not hide an && rm" \
  "rsync -a src/ dist/ && rm -rf $REPO/parentdir"

# LAST must survive a trailing option-WITH-ARGUMENT. The valueless trailing flag
# at :324 passes without proving this — the failure is the option's ARGUMENT
# being mistaken for the destination.
deny_bash "rsync --delete with a trailing option-with-argument" \
  "rsync -a --delete src/ $REPO/dest/ --exclude foo"
deny_bash "rsync --delete, trailing --exclude, absolute outside dest" \
  'rsync -a --delete src/ /etc/dest/ --exclude foo'
deny_bash "rsync --del (delete-family alias) to an outside dest" \
  "rsync -a --del src/ $REPO/dest/"
deny_bash "rsync --remove-source-files to an outside dest" \
  "rsync -a --remove-source-files src/ $REPO/dest/"

# An armed row that selects ZERO targets still has a cd context to judge. The
# containment check runs per emitted record, so with no record the cd was never
# examined at all. GNU find's implicit-`.` path is the live instance.
deny_bash "cd outside, then find with an IMPLICIT path -delete" \
  "cd $REPO && find -name x -delete"
# The `{}` relaxation below is scoped to find's placeholder, not to the cd it
# runs in.
deny_bash "cd outside, then find -exec rm {}" \
  "cd $REPO && find . -name core -exec rm {} \\;"

# --- OUTPUT REDIRECTS (foundation#1355) --------------------------------------
# A redirect is a write the SHELL performs before the verb ever runs, so it is
# contained on the same terms as a destructive operand. Both spellings of every
# operator are pinned (BARE `> f` and GLUED `>f`), because only the bare form is
# a token the separator test recognizes — they take different code paths.
deny_bash "redirect > to a literal path outside"         "echo x > $REPO/leak.txt"
deny_bash "redirect > outside, GLUED to the operator"    "echo x >$REPO/leak.txt"
deny_bash "redirect >> (append) to a path outside"       "echo x >> $REPO/append.log"
deny_bash "redirect 2> (stderr) to a path outside"       "echo x 2> $REPO/err.log"
deny_bash "redirect 2>> (stderr append) outside"         "echo x 2>> $REPO/err.log"
deny_bash "redirect > to a top-level path outside"       'echo x > /etc/passwd'
deny_bash "redirect > to a NON-LITERAL target"           'echo x > "$HOME/leak"'
deny_bash "redirect >> to a tilde target"                'echo x >> ~/leak'
deny_bash "redirect 2> to a NON-LITERAL target"          'make test 2> "$LOGDIR/err"'
deny_bash "redirect after a cd-context outside"          "cd $REPO && echo x > out.txt"
# `>&WORD` names no file ONLY when WORD is an fd number. A non-numeric WORD is
# bash's both-streams FILE redirect and must stay contained; a non-literal one is
# unprovable. Treating every `>&` as an fd dup is the tempting wrong shortcut.
deny_bash "redirect >& to a non-numeric (file) target outside" "ls >& $REPO/both.log"
deny_bash "redirect 2>& to a NON-LITERAL fd/file word"   'rm -rf ./dist 2>&$FD'
# Composed with a destructive verb: BOTH halves are judged, neither hides the
# other. The last two are the run-integrity cases — a redirect must not swallow
# what follows it, and (glued) must not end the argument list, or `rm -rf
# 2>/dev/null <outside>` would delete <outside> unseen.
deny_bash "in-worktree rm with a redirect escaping"      "rm -rf ./dist > $REPO/log"
deny_bash "an in-worktree redirect must not hide a following rm" \
  "echo x > out.txt; rm -rf $REPO/parentdir"
deny_bash "a GLUED redirect must not hide the verb's own operand" \
  "rm -rf 2>/dev/null $REPO/parentdir"
# A trailing glued redirect must not be mistaken for rsync's destination — the
# LAST selector used to pick `2>/dev/null` and miss the real (outside) dest.
deny_bash "rsync --delete outside, trailing glued redirect" \
  "rsync -a --delete src/ $REPO/dest/ 2>/dev/null"

deny_file "Write into the parent checkout"    Write     "$REPO/leak.txt"
deny_file "Edit  in the parent checkout"      Edit      "$REPO/f.txt"
deny_file "Write via a relative .. escape"    Write     "../../leak.txt"
deny_file "Write to an absolute path far outside" Write "/etc/leak.txt"

# MultiEdit carries its targets in edits[].file_path, not file_path.
log_reset
out=$(run_json "$WT" "$(jq -cn --arg cwd "$WT" --arg fp "$REPO/f.txt" \
  '{tool_name:"MultiEdit",tool_input:{edits:[{file_path:$fp}]},cwd:$cwd}')")
if [ "$(verdict "$out")" = deny ]; then
  ok "DENY  MultiEdit edits[].file_path into the parent checkout"
else
  bad "DENY  MultiEdit edits[].file_path into the parent checkout" "want=deny out=$out"
fi

# The deny reason must name BOTH the offending target and the jail root — a
# worker that cannot see where it is confined re-issues the same escape.
log_reset
out=$(run_bash "$WT" "rm -rf $REPO/parentdir")
if grep -q "$REPO/parentdir" <<<"$out"; then ok "DENY  reason names the resolved target"
else bad "DENY  reason names the resolved target" "out=$out"; fi
if grep -q "$WT_RP" <<<"$out"; then ok "DENY  reason names the worktree root"
else bad "DENY  reason names the worktree root" "out=$out"; fi
if grep -q '"hookEventName":"PreToolUse"' <<<"$out"; then ok "DENY  emits a well-formed PreToolUse verdict"
else bad "DENY  emits a well-formed PreToolUse verdict" "out=$out"; fi

# =============================================================================
echo
echo "== ALLOW: routine in-worktree worker commands must NOT be denied =="
# A guard that falsely denies gets disarmed, after which coverage is zero. Each
# case also asserts NO 'INERT:' line, proving the guard actually judged it.
#
# Canary first: an ALLOW corpus is only meaningful against an ARMED guard — a
# guard that had regressed to always-open would pass every case below while
# protecting nothing. Prove enforcement is live for this exact fixture and cwd
# before reading a single "allowed" as evidence.
log_reset
if [ "$(verdict "$(run_bash "$WT" "rm -rf $REPO/parentdir")")" = deny ]; then
  ok "ALLOW canary: the guard is armed and enforcing for this fixture"
else
  bad "ALLOW canary: the guard is armed and enforcing for this fixture" \
      "enforcement is NOT live — every ALLOW result below is vacuous"
fi
allow_bash "rm -rf node_modules (relative, in-worktree)" 'rm -rf node_modules'
allow_bash "rm -rf ./dist (dot-slash relative)"          'rm -rf ./dist'
allow_bash "mv src/a.ts src/b.ts (routine rename)"       'mv src/a.ts src/b.ts'
allow_bash "mv into a not-yet-existing nested dir"       'mv src/a.ts src/new/deep/b.ts'
allow_bash "literal absolute path under the worktree root" "rm -rf $WT_RP/build/out"
allow_bash "literal path under /tmp (allow-listed)"      'rm -rf /tmp/build-worktree-guard-scratch'
# $TMPDIR is exercised by its EXPANDED value on purpose: a literal `$TMPDIR`
# token carries a `$`, so the guard cannot resolve it statically and denies it by
# design (see the non-literal DENY cases above). The allow-list is over the
# resolved root, not over the spelling.
allow_bash "literal path under \$TMPDIR (allow-listed)"  "rm -rf $TMPDIR/scratch"
allow_bash "cd to an in-worktree subdir, then rm"        "cd $WT_RP/src && rm -rf tmpwork"
allow_bash "cd into /tmp, then rm"                       'cd /tmp && rm -rf build-guard-scratch'
allow_bash "no destructive verb at all (git status)"     'git status --porcelain && ls -la'
allow_bash "non-destructive read of an outside path"     "cat $REPO/f.txt"
allow_bash "rm of a single in-worktree file"             'rm keep.txt'
allow_bash "rm with flags before the operand"            'rm -r -f -- node_modules'

# --- the three post-flat-list operand models, ALLOW half (foundation#1354) ----
# These are ROUTINE worker commands. A guard that denies them gets disarmed, so
# each polarity of each new row is pinned here as firmly as its DENY twin.
# git clean: no target operand, judged against the cd context — which here is
# the worktree itself, so it must stay silent.
allow_bash "git clean -xfd inside the worktree"          'git clean -xfd'
allow_bash "git clean -xfd after an in-worktree cd"      "cd $WT_RP/src && git clean -xfd"
allow_bash "git clean -n (dry run — not armed)"          'git clean -n'
# Read-only git clean, at the SAME outside cd its -xfd twin is denied at. This
# is the pair that proves the ARM predicate is doing the work: the cd context is
# identical, only the flags differ. It also pins the substring-vs-letter bug —
# `index(tk,"d")` matched the 'd' inside `--dry-run` and denied a command that
# deletes nothing, and a false deny is what gets the guard disarmed for good.
allow_bash "git clean --dry-run at an OUTSIDE cd (read-only)" \
  "cd $REPO && git clean --dry-run"
allow_bash "git clean -n -d at an OUTSIDE cd (read-only)" \
  "cd $REPO && git clean -n -d"
allow_bash "git clean --exclude=build at an outside cd (no delete flag)" \
  "cd $REPO && git clean --exclude=build"
# find: the predicate run's glob is NOT a path operand — the pre-predicate paths
# are, and here they are in-worktree.
allow_bash "find . -name '*.pyc' -delete (in-worktree)"  "find . -name '*.pyc' -delete"
allow_bash "find in-worktree subdir -delete"             "find $WT_RP/build -type f -delete"
# DELIBERATE, and the one place this suite allows something origin/main denied.
# `{}` is find's placeholder: it expands to a path UNDER find's search root, and
# that root is exactly what the PRE selector already judged (in-worktree here).
# The old guard denied this only because `{}` trips the non-literal BRACE test —
# a false deny on a routine worker command. Two things make the relaxation safe,
# and both have DENY twins above: the nested rm's REAL operands are still walked
# through the table ("find -exec rm on an OUTSIDE path"), and `{}` is exempted
# BY NAME rather than by discarding the argv, so the exemption cannot widen to
# the rest of the command. It is also scoped to the placeholder, not to the cd
# it runs in ("cd outside, then find -exec rm {}").
allow_bash "find -exec rm {} inside the worktree (placeholder is exempt)" \
  'find . -name core -exec rm {} \;'
allow_bash "find -exec rm {} + inside the worktree"      'find . -name core -exec rm {} +'
allow_bash "find with no destructive predicate"          "find $REPO -name '*.log' -print"
# rsync: untouched without --delete*; with it, only the destination is checked.
allow_bash "plain rsync (no --delete) to an outside dir" "rsync -a src/ $REPO/dest/"
allow_bash "rsync --delete to an in-worktree destination" 'rsync -a --delete src/ dist/'
allow_bash "rsync --delete to a /tmp destination"        'rsync -a --delete src/ /tmp/build-guard-scratch/'
# --delay-updates shares a prefix with the delete family but deletes nothing. A
# prefix test would arm on it and deny a plain transfer, which criterion 2
# forbids ("a plain rsync with no --delete* is untouched") — hence exact
# membership, pinned here.
allow_bash "rsync --delay-updates (prefix lookalike, not a delete flag)" \
  "rsync -a --delay-updates src/ $REPO/dest/"
allow_bash "rsync --delete, trailing option-with-arg, IN-worktree dest" \
  'rsync -a --delete src/ dist/ --exclude foo'

# --- OUTPUT REDIRECTS, ALLOW half (foundation#1355) --------------------------
# These are the most routine commands a worker issues. Redirect containment is
# the newest tightening in this arm and therefore the likeliest source of a
# false deny — and a false deny is what gets the guard disarmed, after which
# coverage is zero. Every polarity of every operator is pinned here.
allow_bash "redirect > to an in-worktree relative file"  'echo x > out.txt'
allow_bash "redirect > GLUED to an in-worktree file"     'echo x >out.txt'
allow_bash "redirect >> into a not-yet-existing subdir"  'cmd >> logs/run.log'
allow_bash "redirect > to an absolute in-worktree path"  "echo x > $WT_RP/build/out.log"
allow_bash "redirect > under /tmp (allow-listed)"        'echo x > /tmp/build-guard-scratch.log'
allow_bash "redirect > under \$TMPDIR (allow-listed)"    "echo x > $TMPDIR/scratch.log"
allow_bash "redirect after an in-worktree cd"            "cd $WT_RP/src && echo x > out.txt"
# /dev/null is the single most routine idiom in a worker command line and writes
# no tree. Allow-listed for REDIRECTS ONLY — its destructive-operand twin is
# below. Without this the guard would deny half of every worker's commands.
allow_bash "redirect 2> /dev/null (character-device sink)" 'make test 2>/dev/null'
allow_bash "redirect > /dev/null with a 2>&1 fd dup"     'make test > /dev/null 2>&1'
allow_bash "redirect 2>&1 into a pipe (fd dup, no file)" 'ls 2>&1 | tee out.txt'
allow_bash "redirect >&- (fd close, names no file)"      'ls >&- '
# `>(cmd)` is process substitution — a word belonging to the command line, not a
# redirect. Reading it as one would deny a routine diff.
allow_bash "process substitution is not a redirect"      'diff <(sort a) >(sort b)'
# A token carrying a quote is never re-split at an embedded `>`, because inside
# quotes a `>` is data. That covers the GLUED case pinned here. It does NOT
# cover a `>` standing alone inside a quoted phrase (`echo "route to > $X"`),
# where whitespace splitting has already separated the operator — that reads as
# a real redirect and denies. Fails closed; stated so the claim stays accurate.
allow_bash "a quoted '>' is an argument, not a redirect" 'grep ">" src/a.ts'
allow_bash "quoted redirect chars are not re-split"      'grep "a>b" src/a.ts'
allow_bash "redirect >| (force-truncate) to an in-worktree file" 'echo x >| out.txt'
allow_bash "redirect >| GLUED to an in-worktree file"    'echo x >|out.txt'
# Word-GLUED redirects: `>` is a bash metacharacter anywhere unquoted in a word,
# so these are real redirects and their in-worktree half must stay silent.
allow_bash "word-glued redirect to an in-worktree file"  'date>out.txt'
allow_bash "word-glued redirect, arg then operator"      'echo x>out.txt'
# The rest of the operator family the header treats as load-bearing.
allow_bash "redirect &> (both streams) in-worktree"      'ls &> both.log'
allow_bash "redirect &>> (both streams, append)"         'ls &>> both.log'
allow_bash "redirect 1> (explicit stdout fd)"            'ls 1> o.log'
allow_bash "redirect 3> (arbitrary fd)"                  'ls 3> o.log'
allow_bash "redirect > /dev/zero (device sink)"          'echo x > /dev/zero'
allow_bash "redirect > /dev/tty (device sink)"           'echo x > /dev/tty'
allow_bash "redirect > /dev/stderr (device sink)"        'echo x > /dev/stderr'
# A read-only command after an OUTSIDE cd whose only redirect is a device sink.
# An absolute sink resolves without the base, so the cd must not condemn it —
# `cd ../otherrepo && git log 2>/dev/null` is an ordinary worker move.
allow_bash "device-sink redirect survives an OUTSIDE cd" "cd $REPO && ls 2>/dev/null"
allow_bash "device-sink redirect survives an outside cd (git log)" \
  "cd $REPO && git log 2>/dev/null"
# NON-LITERAL redirect targets judged by their literal directory PREFIX. `>
# "$VAR"` is an everyday idiom (~1,480 in this repo alone); denying all of them
# is the false-positive class that gets a guard disarmed. The DENY twins below
# pin exactly where the relief stops.
allow_bash "redirect to \$TMPDIR (an allow-listed root the guard knows)" \
  'echo x > "$TMPDIR/out.log"'
allow_bash "redirect to \${TMPDIR} braced form"          'echo x > ${TMPDIR}/out.log'
allow_bash "redirect to \$TMPDIR with a trailing 2>&1"   'make test > "$TMPDIR/out.log" 2>&1'
allow_bash "redirect with an in-tree literal prefix + \$(...)" \
  'cmd > logs/$(date +%F).log'
allow_bash "redirect with an in-tree literal prefix + \$VAR" 'cmd > src/$X.log'
# A heredoc BODY with no metacharacters is walked harmlessly.
allow_bash "heredoc body with no redirect-looking line"  "$HEREDOC_PLAIN"

# =============================================================================
echo
echo "== DENY: counter-cases to the ALLOW half above =="
# Each of these is the DENY twin of a relief granted just above — the pair is
# what proves a relief is SCOPED rather than a hole. They get their own banner:
# an assertion that something is REFUSED does not belong under one promising
# commands are permitted.
#
# The device-sink allow-list is scoped to redirect TARGETS. A destructive verb
# aimed at the same path is still judged as an ordinary out-of-tree operand.
deny_bash "device sink is redirect-scoped: rm -rf /dev/null is still judged" \
  'rm -rf /dev/null'
# ...and the literal-PREFIX relief is redirect-scoped too. `rm -rf logs/$(date)`
# removes a TREE at a computed path — the F#932 shape — and keeps denying.
deny_bash "literal-prefix relief is redirect-scoped: rm -rf logs/\$(date)" \
  'rm -rf logs/$(date +%F)'
# ACCEPTED COLLATERAL, stated rather than discovered later: a redirect target
# with no literal directory component gives the guard nothing to judge, so it
# denies; a worker re-issues as `logs/$NAME`. This is the cost the prefix rule
# buys, pinned so it stays a decision on the record and not an accident.
deny_bash "ACCEPTED COLLATERAL: a bare \$VAR redirect target denies" \
  'echo x > "$LOG"'
deny_bash "a leaf-only expansion (no directory part) denies" 'echo x > out$X.log'
# The prefix must be a real DIRECTORY that is itself contained.
deny_bash "literal prefix resolving OUTSIDE the worktree"  'echo x > /etc/$USER/x'
deny_bash "literal prefix climbing out via .."             'echo x > ../../$X/f'
# /dev/fd/* is NOT a sink: it is platform-divergent (Linux resolves it through
# /proc/self/fd), so it is excluded by design rather than matched unreliably.
deny_bash "/dev/fd/N is not an allow-listed sink (platform-divergent)" \
  'echo x > /dev/fd/3'
# Word-glued redirects, the escaping half — the bypass this pairing closes.
deny_bash "word-glued redirect to a path outside"        "date>$REPO/passwd"
deny_bash "word-glued redirect, arg then operator, outside" "echo x>$REPO/leak"
deny_bash "word-glued redirect with a space AFTER only"  "echo x> $REPO/leak"
# bash's own fd rule: in `x2>/f` the `2` belongs to the WORD, not the operator.
deny_bash "a non-fd digit prefix is part of the word, not the operator" \
  "echo x2>$REPO/leak"
deny_bash "two redirects glued into one word"            "date>/a>$REPO/b"
# >| is a force-truncate: the same write, and it must not parse as target `|`.
deny_bash "redirect >| (force-truncate) to a path outside" "echo x >| $REPO/passwd"
deny_bash "redirect >| GLUED to a path outside"          "echo x >|$REPO/passwd"
# The remaining operator family, escaping half.
deny_bash "redirect &> to a path outside"                "ls &> $REPO/both"
deny_bash "redirect &>> to a path outside"               "ls &>> $REPO/both"
deny_bash "redirect 1> to a path outside"                "ls 1> $REPO/o"
deny_bash "redirect 3> to a path outside"                "ls 3> $REPO/o"
# DISCLOSED FALSE POSITIVE, pinned so a future change cannot flip it silently:
# the walker is line-oriented and has no heredoc state, so a markdown blockquote
# in a heredoc body reads as a redirect to a non-literal target. Fails CLOSED.
deny_bash "DISCLOSED: a markdown blockquote in a heredoc body reads as a redirect" \
  "$HEREDOC_MARKDOWN"

allow_file "Write a new file at the worktree root"   Write "$WT_RP/new.txt"
allow_file "Write a relative in-worktree path"       Write "newdir/new.txt"
allow_file "Edit  an existing in-worktree file"      Edit  "$WT_RP/src/a.ts"
allow_file "Write under /tmp (allow-listed)"         Write "/tmp/build-worktree-guard-scratch.txt"
allow_file "Write under \$TMPDIR (allow-listed)"     Write "$TMPDIR/scratch.txt"

log_reset
out=$(run_json "$WT" "$(jq -cn --arg cwd "$WT" --arg fp "$WT_RP/src/a.ts" \
  '{tool_name:"MultiEdit",tool_input:{edits:[{file_path:$fp}]},cwd:$cwd}')")
if [ "$(verdict "$out")" = silent ] && [ -z "$(log_inert)" ]; then
  ok "ALLOW MultiEdit edits[].file_path inside the worktree"
else
  bad "ALLOW MultiEdit edits[].file_path inside the worktree" "out=$out inert=$(log_inert)"
fi

# =============================================================================
echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d build-worktree-guard checks passed\n' "$pass"
