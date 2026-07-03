#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash) — git stale-branch guard (foundation #590,
# the unbuilt mechanical half of #49).
#
# WHY: "branch off a stale local main" is the single most frequent and most
# expensive friction class in the session ledger — a session creates a branch
# from a local default branch that is behind origin, then discovers the
# divergence only at `git push` time (DIRTY PR -> rebase/rebuild/renumber).
# #49 established the prose rule "fetch ground truth before building" and
# explicitly proposed a hook to surface behind-by-N; that hook was never built.
# This is it.
#
# WHAT: on a branch-CREATION command (git checkout -b/-B, git switch -c/-C/
# --create) whose base is the LOCAL default branch, fetch the default branch
# from origin and — if local default is behind — return an `ask` decision
# naming behind-by-N and the fix. Branching off origin/<default>, a SHA, or any
# non-default ref is left silent: that base is already correct/intentional. So
# is an up-to-date local default. The fetch is read-only on the working tree
# and, as a side effect, CURES the stale remote-tracking refs the warning is
# about.
#
# WHY ask-not-deny, fail-open: same philosophy as board-adapter-guard.sh — make
# the risky case a conscious choice, never block legitimate work. ANY internal
# error (no jq, not a git repo, fetch failure/timeout, unparsed command) exits 0
# silently and lets the command proceed.
#
# KNOWN LIMITATION: a PreToolUse Bash hook runs in the session CWD and sees only
# the top-level command string. A command that `cd`s elsewhere first, or uses
# `git -C <dir>`, is checked against the session CWD's repo — at worst a missed
# or spurious warning, never a block (fail-open). `git branch <name>` (create
# without checkout) is intentionally not matched; the friction is always
# checkout -b / switch -c.
#
# EVAL_RUN: exits 0 silently — an unanswerable interactive `ask` would hang a
# headless eval run, and a stale branch is not a scored finding.
set -uo pipefail

[ -n "${EVAL_RUN:-}" ] && exit 0           # no interactive prompt under eval

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0    # fail open: no jq, no guard

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool" = "Bash" ] || exit 0             # matcher scopes this; double-check

cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Is this a branch-CREATION, and what are its <name> and optional <start-point>?
# Emits "<name>\t<start-or-empty>" for the first `git … checkout/switch` with a
# create flag, else nothing. Skips git global options (`-C dir`, `-c k=v`, other
# `-…`) before the subcommand, and skips per-flag options (e.g. --track) when
# locating the branch name and start-point. Branch names / start-points never
# start with `-`, so flag-skipping is safe.
create_info=$(printf '%s' "$cmd" | awk '
  {
    n = split($0, tok, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (tok[i] != "git") continue
      j = i + 1
      while (j <= n) {
        if (tok[j] == "-C" || tok[j] == "-c") { j += 2; continue }
        if (tok[j] ~ /^-/) { j++; continue }
        break
      }
      subcmd = tok[j]
      if (subcmd != "checkout" && subcmd != "switch") continue
      for (k = j + 1; k <= n; k++) {
        t = tok[k]
        if (t == "-b" || t == "-B" || t == "-c" || t == "-C" || t == "--create") {
          name = ""; start = ""
          k++
          while (k <= n && tok[k] ~ /^-/) k++
          if (k <= n) { name = tok[k]; k++ }
          while (k <= n && tok[k] ~ /^-/) k++
          if (k <= n) start = tok[k]
          print name "\t" start
          exit
        }
      }
    }
  }
')

[ -n "$create_info" ] || exit 0            # not a branch-creation command

name=${create_info%%$'\t'*}
start=${create_info#*$'\t'}
[ -n "$name" ] || exit 0                   # unparsed name -> fail open

git rev-parse --git-dir >/dev/null 2>&1 || exit 0   # not a git repo -> fail open

# Resolve the repo's default branch (origin/HEAD -> e.g. "main"). Fallback: main.
ref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)
default=${ref##*/}
[ -n "$default" ] || default="main"

# The base the new branch is created from: explicit start-point, else current HEAD.
if [ -n "$start" ]; then
  base="$start"
else
  base=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

# Only act when the base is the LOCAL default branch. origin/<default>, a SHA, or
# another branch is an intentional/correct base -> stay silent.
[ "$base" = "$default" ] || exit 0

# Bounded fetch of the default branch (macOS has no `timeout`: background PID +
# watchdog kill). Read-only on the working tree. Fail open on error/timeout.
_bounded() {
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watcher=$!
  disown "$watcher" 2>/dev/null || true   # suppress the job-control "Terminated" notice on kill
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -TERM "$watcher" 2>/dev/null || true
  return "$rc"
}
_bounded 5 git fetch --quiet origin "$default" || exit 0

behind=$(git rev-list --count "${default}..origin/${default}" 2>/dev/null)
case "$behind" in ''|*[!0-9]*) exit 0;; esac   # non-numeric -> fail open
[ "$behind" -gt 0 ] || exit 0                  # up to date -> silent, proceed

reason="Local '${default}' is ${behind} commit(s) behind 'origin/${default}'. Creating branch '${name}' from it will likely produce a DIRTY PR (stale-base conflicts/reversions) discovered only at push time — the most frequent friction class in the session ledger (foundation #590, follow-up to #49). origin/${default} has just been fetched, so the refs are now current. Before branching, rebase onto it (git rebase origin/${default}) or branch directly from it (git checkout -b ${name} origin/${default}). Approve only if you intend to branch from the stale base anyway."

jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
  2>/dev/null || true
exit 0
