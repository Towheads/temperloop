#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash|Edit|Write|MultiEdit|NotebookEdit) —
# write-lane guard (temperloop kernel; session write-lane discipline).
#
# WHY: multiple Claude sessions share one machine's filesystem. A git working
# tree has exactly one HEAD, and (by the operator invariant "never more than one
# session per repo directory") a repo's CANONICAL checkout is where a peer
# session lives. A session that reaches OUT of its own launch dir and mutates
# another repo's canonical checkout in place — `git checkout -b`, commits, a
# merge, `make install` — moves that peer's HEAD/branch pointer underneath it,
# leaving the peer's on-disk state inconsistent with its in-memory view. That is
# exactly how epic #86 stepped on a concurrent session working in dev/foundation.
#
# WHAT: the session's LANE = its home dir (`$CLAUDE_PROJECT_DIR`, the launch dir)
# PLUS any linked git worktree (a linked worktree is ephemeral task scratch with
# its own HEAD — never a session's launch dir, so writing one steps on nobody).
# A state-mutating tool call whose target resolves to the MAIN working tree of a
# git repo OTHER than home — a peer's canonical checkout — returns an `ask`.
# Silent/allowed: home, any linked worktree, non-repo paths (the Obsidian vault,
# /tmp, scratchpads — anything not inside a git repo), and every read-only op.
#
# The sanctioned way to do legitimate cross-repo work is therefore a dedicated
# `git worktree add` off the foreign repo, worked in its own dir — which this
# guard leaves silent.
#
# VERDICT: ask, never deny — a deliberate cross-repo action is one confirmation
# away, never hard-blocked (same philosophy as board-adapter-guard.sh /
# git-stale-branch-guard.sh / subtree-edit-guard.sh).
#
# EVAL_RUN: exits 0 silently — an unanswerable interactive `ask` would hang a
# headless eval run, and a lane crossing is not a scored finding.
#
# FAILS OPEN: any internal error (no jq, unparseable input, no git, an
# unresolvable path) exits 0 immediately — a guard bug must never block a
# legitimate write.
#
# KNOWN LIMITATIONS (fail-open by design, documented like the sibling guards):
#   - Bash detection is scoped to `git <mutating-subcommand>` and `make install`,
#     with the target dir resolved from `git -C <dir>` / `make -C <dir>` / a
#     leading `cd <dir> &&` / else the session cwd. Shell redirections
#     (`> foreign`, `sed -i`, `mv`/`cp`/`tee` into a foreign repo) are NOT parsed
#     — but file mutations through the Edit/Write/MultiEdit/NotebookEdit tools ARE
#     covered, which is the dominant vector. A command chaining several `cd`s is
#     checked against the FIRST mutation's context only.
#   - `git worktree add` is intentionally NOT a gated verb: creating a worktree
#     off a foreign repo is the sanctioned isolation escape hatch and only writes
#     that repo's worktree-admin dir — it never moves the peer's HEAD or working
#     tree. Gating it would prompt on the very move we steer toward.
#   - A foreign git SUBMODULE working tree (its `.git` is a gitfile, like a linked
#     worktree) is treated as in-lane. Rare and low-risk; accepted.
set -uo pipefail

[ -n "${EVAL_RUN:-}" ] && exit 0            # no interactive prompt under eval

XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/write-lane-guard.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0     # fail open: no jq, no guard

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Bash|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;                              # matcher should scope this; double-check
esac

# Where relative paths resolve. The hook `cwd` is the session's project dir and
# is not moved by a Bash `cd`; fall back to PWD if the harness omits it.
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# HOME = the session's launch dir. CLAUDE_PROJECT_DIR is Claude Code's canonical
# anchor for it; fall back to the tool cwd. Resolve physically so string-prefix
# containment tests below are apples-to-apples.
home="${CLAUDE_PROJECT_DIR:-$cwd}"
home_real=$(cd "$home" 2>/dev/null && pwd -P) || exit 0   # unresolvable home -> fail open
home_real="${home_real%/}"

# --- physical path resolver (mirrors subtree-edit-guard.sh's resolve) --------
# Fully follow symlinks in every directory component (cd -P) AND a symlinked leaf,
# iteratively; walk to the nearest EXISTING ancestor for a not-yet-created path.
# Portable — no GNU `realpath -f`.
resolve() {
  local p="$1" dir base cur suffix rcur target hops=0
  case "$p" in
    /*) ;;
    *) p="$cwd/$p" ;;
  esac
  while [ "$hops" -lt 40 ]; do
    hops=$((hops + 1))
    dir=$(dirname -- "$p")
    base=$(basename -- "$p")
    cur="$dir"; suffix=""
    while [ ! -d "$cur" ] && [ "$cur" != "/" ]; do
      suffix="/$(basename -- "$cur")$suffix"
      cur=$(dirname -- "$cur")
    done
    if rcur=$(cd "$cur" 2>/dev/null && pwd -P); then
      p="$rcur$suffix/$base"
    else
      printf '%s\n' "$p"; return 0
    fi
    if [ -n "$suffix" ]; then
      printf '%s\n' "$p"; return 0        # a parent dir doesn't exist yet
    fi
    if [ -L "$p" ]; then
      target=$(readlink -- "$p") || { printf '%s\n' "$p"; return 0; }
      case "$target" in
        /*) p="$target" ;;
        *)  p="$rcur/$target" ;;
      esac
      continue
    fi
    printf '%s\n' "$p"; return 0
  done
  printf '%s\n' "$p"                       # symlink-loop guard — best effort
}

# --- foreign-main-checkout test ----------------------------------------------
# echoes the foreign repo root iff the resolved path P is inside the MAIN working
# tree of a git repo that is NOT home (and not a linked worktree); else nothing.
foreign_checkout_root() {
  local p="$1" dir root root_real
  case "$p" in "$home_real"/*|"$home_real") return 0 ;; esac   # under home -> in-lane
  dir="$p"
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do dir=$(dirname -- "$dir"); done
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$root" ] || return 0                                   # not in a git repo -> in-lane
  root_real=$(cd "$root" 2>/dev/null && pwd -P) || return 0
  root_real="${root_real%/}"
  [ "$root_real" = "$home_real" ] && return 0                  # home's own repo
  case "$root_real" in "$home_real"/*) return 0 ;; esac        # nested under home
  # A linked worktree carries a `.git` FILE (gitfile); a canonical checkout a
  # `.git` DIRECTORY. Only the latter is a place a peer session lives.
  [ -d "$root_real/.git" ] || return 0                         # linked worktree / submodule -> in-lane
  printf '%s\n' "$root_real"                                   # foreign canonical checkout
}

# --- gather target paths ------------------------------------------------------
hit=""; hit_target=""
if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || exit 0
  # Detect a mutating git subcommand or `make install`, and the target dir
  # (git -C / make -C / a leading `cd <dir>`; empty => session cwd). Output is
  # "MUT:<dir>" IFF a mutation was found — non-empty output means "mutation", so
  # an empty <dir> (operate in cwd) stays distinguishable from "no match".
  info=$(printf '%s' "$cmd" | awk '
    function isMut(s){
      return s=="commit"||s=="checkout"||s=="switch"||s=="merge"||s=="rebase"|| \
             s=="reset"||s=="push"||s=="stash"||s=="pull"||s=="cherry-pick"|| \
             s=="revert"||s=="am"||s=="apply"||s=="clean"||s=="restore"|| \
             s=="rm"||s=="mv"
    }
    {
      n=split($0,t,/[[:space:]]+/)
      cdDir=""; cDir=""; mut=0
      for(i=1;i<=n;i++){ if(t[i]==""){continue} if(t[i]=="cd" && i+1<=n){cdDir=t[i+1]} break }
      for(i=1;i<=n;i++){
        if(t[i]=="git"){
          j=i+1
          while(j<=n){
            if(t[j]=="-C" && j+1<=n){ cDir=t[j+1]; j+=2; continue }
            if(t[j]=="-c" && j+1<=n){ j+=2; continue }
            if(t[j]~/^-/){ j++; continue }
            break
          }
          if(j<=n && isMut(t[j])){ mut=1; break }
        }
        if(t[i]=="make"){
          hasInstall=0
          for(k=i+1;k<=n;k++){
            if(t[k]=="-C" && k+1<=n){ cDir=t[k+1]; k++; continue }
            if(t[k]=="install"){ hasInstall=1 }
          }
          if(hasInstall){ mut=1; break }
        }
      }
      if(mut){ print "MUT:" (cDir!=""?cDir:cdDir) }
    }')
  [ -n "$info" ] || exit 0                  # no mutating verb -> allow
  dir=${info#MUT:}                          # strip sentinel; may be empty (=cwd)
  [ -n "$dir" ] || dir="$cwd"
  case "$dir" in /*) ;; *) dir="$cwd/$dir" ;; esac
  if rp=$(cd "$dir" 2>/dev/null && pwd -P); then dir="$rp"; fi
  r=$(foreign_checkout_root "$dir") || true
  if [ -n "$r" ]; then hit="$r"; hit_target="$dir"; fi
else
  # Edit/Write/MultiEdit/NotebookEdit — one or more file paths in tool_input.
  targets=()
  while IFS= read -r _t; do
    [ -n "$_t" ] && targets+=("$_t")
  done < <(printf '%s' "$INPUT" | jq -r '
    (.tool_input // {}) as $i
    | [ $i.file_path?, $i.path?, $i.notebook_path?, ($i.edits // [])[].file_path? ]
    | map(select(. != null and . != ""))
    | .[]' 2>/dev/null)
  [ "${#targets[@]}" -gt 0 ] || exit 0
  for t in "${targets[@]}"; do
    ap=$(resolve "$t")
    r=$(foreign_checkout_root "$ap") || true
    if [ -n "$r" ]; then hit="$r"; hit_target="$ap"; break; fi
  done
fi

[ -n "$hit" ] || exit 0                     # in-lane -> silent, proceed

reason="This ${tool} targets '${hit_target}', inside the canonical checkout of a DIFFERENT repo ('${hit}') than this session's home ('${home_real}'). Under the one-session-per-repo-directory invariant that other checkout is very likely a concurrent Claude session's live working tree — mutating it in place (moving its HEAD/branch, committing, merging, make install) leaves that peer's on-disk state inconsistent with what it thinks it has (exactly the epic #86 dev/foundation incident). If you need to change that repo, do it in an ISOLATED worktree instead: 'git -C ${hit} worktree add <path> -b <branch>' and work under <path> (worktrees are in-lane, never prompt). Approve only if you are certain no other session holds '${hit}'."
log "ASK :: tool=${tool} target=${hit_target} foreign_root=${hit} home=${home_real}"
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
  2>/dev/null || true
exit 0
