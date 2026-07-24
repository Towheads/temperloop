#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash|Edit|Write|MultiEdit) — build worker write jail.
#
# Structurally enforces /build worker write-isolation (foundation #17, #10):
# a worker spawned by the orchestrator must only edit files inside its OWN
# pre-created worktree. A bare parent-root absolute path resolves against the
# parent checkout and leaks an uncommitted write into the orchestrator's tree
# even when the worker's Bash cwd is the worktree. This hook DENIES any Edit/
# Write/MultiEdit whose resolved absolute target is outside the active worktree
# root, so isolation no longer depends on the worker model's discretion.
#
# BASH ARM (foundation #1087 / F#932). File-tool writes were the only jailed
# vector; worker *Bash* was unjailed, so a shell command could delete or write
# anywhere. F#932: a worker ran `rm -rf "$(dirname "$(pwd)")"` from an
# unexpected cwd, which resolved to `/Users/travis/dev` and wiped every checkout
# and the local Obsidian vault. This hook now also inspects Bash commands and
# DENIES a DESTRUCTIVE filesystem verb (rm, rmdir, mv, shred, truncate, dd of=)
# unless it can PROVE every path operand stays inside the worktree (or the
# /tmp//$TMPDIR allow-list). The proof fails — so the command is denied — when an
# operand (or a preceding `cd` target) is NON-LITERAL: it contains a `$`
# expansion, a `\`…\`` / `$(…)` command substitution, a `~`, a `*`/`?`/`[` glob,
# or a `{` brace. That is exactly the F#932 shape ("target is computed, not a
# literal path"), and it enforces the avoidance rule the incident post-mortem
# named: destructive targets must be literal paths under the worktree.
#
# BASH ARM — accepted fail-open gaps (documented, like the sibling guards):
#   - Only tree-destructive verbs are inspected. Output redirections (`> file`,
#     `>> file`), `tee`, and in-place edits (`sed -i`) are NOT parsed — the
#     dominant catastrophic vector is tree deletion/move, and redirect parsing
#     is noisy for little safety gain (write-lane-guard.sh makes the same call).
#   - Operand/cd containment is judged against a LEADING/most-recent `cd` context
#     and whitespace tokenization; an exotic one-liner (verbs glued to `;`/`&&`
#     with no spaces, a mid-pipeline subshell `cd`) may not be modelled — those
#     cases fail OPEN, never falsely deny. Preventive coverage of the common
#     destructive shapes, not a complete shell sandbox.
#
# CRITICAL SAFETY — INERT BY DEFAULT, ARMED BY A PER-WORKTREE MARKER. The
# hook enforces ONLY when BOTH hold for the tool cwd's worktree toplevel
# (`git rev-parse --show-toplevel`):
#   1. a `.build-guard` marker file sits in that toplevel (dropped by
#      `workflows/scripts/build/worktree.sh create`, removed by its
#      remove/prune), AND
#   2. the toplevel sits under a `<repo>.wt/` directory — the deterministic
#      build worktree path convention.
# In any normal interactive session neither holds and this hook exits 0
# immediately, allowing every write. Installing it globally via `make install`
# therefore changes nothing for ordinary use — it arms only inside a guarded
# build worker worktree.
#
# A marker found OUTSIDE the `.wt` convention (condition 1 without 2 — a stale
# or hand-copied marker) makes the hook WARN on stderr and fail OPEN.
#
# Why a marker, not an env var (#171/#212): the prior arming required
# BUILD_WORKTREE_GUARD in the tool-invoking process env, but the Agent tool
# has no per-spawn env parameter — so the guard was never actually armable for
# Agent-tool workers — and a host-wide export would mis-target across a
# machine's concurrent sessions (one global value cannot encode N sessions'
# worktree roots). The marker is per-worktree state: each worktree carries its
# own guard arming, so concurrent sessions are isolated by construction.
#
# Allow-list: writes under /tmp (and $TMPDIR) and gitignored source copies
# (e.g. a `.env` copied in from the parent checkout) are always permitted.
#
# Fails OPEN: any internal error (missing jq, unparseable input, git failure)
# never blocks a write — the guard must never wedge a legitimate session.
# See "Decisions/stageFind - Worker write-isolation guarantee.md" in the
# operator's knowledge store (workflows/scripts/lib/knowledge_store.contract.md).
set -uo pipefail

# Hook logs live in the XDG state dir (foundation #773), not ~/.claude/hooks/ —
# runtime state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/build-worktree-guard.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# Emit a PreToolUse deny verdict and exit. The reason is surfaced to Claude.
deny() {
  reason="$1"
  log "DENY :: $reason"
  jq -cn --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null || true
  exit 0
}

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no enforcement

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Bash|Edit|Write|MultiEdit) ;;
  *) exit 0 ;;   # matcher should scope this, but double-check
esac

# The tool's working directory (where relative paths resolve, and where we
# compute the worktree root from). Falls back to PWD if the harness omits it.
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# Resolve the active worktree root from the tool's cwd. If git can't tell us
# (cwd not in a repo), the hook is inert — we can't make a containment
# judgment, and only build worktrees (always git checkouts) are guarded.
worktree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$worktree_root" ] || exit 0

# Realpath the worktree root, so a symlinked cwd and a pwd -P'd target compare
# on the same basis (and the .wt convention check below sees the real parent).
if wt_rp=$(cd "$worktree_root" 2>/dev/null && pwd -P); then
  worktree_root="$wt_rp"
fi
wt="${worktree_root%/}"

# --- ARMING GATE (marker file + path convention) -----------------------------
# Inert unless the worktree carries the `.build-guard` marker that
# `workflows/scripts/build/worktree.sh create` drops. This is the single
# most important safety property: globally installed, the hook is a no-op for
# every interactive session.
[ -f "$wt/.build-guard" ] || exit 0

# Marker present but the toplevel is NOT under a `<repo>.wt/` dir — a stale or
# hand-copied marker outside the build worktree convention. Warn and fail
# OPEN: the convention scopes the guard, the marker alone never arms it.
case "$(dirname "$wt")" in
  *.wt) ;;
  *)
    echo "build-worktree-guard: marker '$wt/.build-guard' present but '$wt' is not under a '<repo>.wt/' worktree dir — stale marker? Failing OPEN (writes allowed). Remove the marker or recreate the worktree via workflows/scripts/build/worktree.sh." >&2
    log "WARN fail-open: marker outside .wt convention at $wt"
    exit 0
    ;;
esac

# --- shared helpers (used by both the Edit/Write and Bash arms) ---------------

# Normalize a path to absolute WITHOUT requiring it to exist (a Write target may
# be a new file). Resolves the existing parent dir, then re-attaches the leaf.
# Relative paths resolve against $2 (an explicit base dir) or, by default, the
# tool's cwd — the Bash arm passes a `cd`-adjusted base.
abspath() {
  local p="$1" root="${2:-$cwd}" dir leaf rdir
  case "$p" in
    /*) ;;                       # already absolute
    *)  p="$root/$p" ;;          # resolve relative to the base dir
  esac
  dir=$(dirname -- "$p")
  leaf=$(basename -- "$p")
  if rdir=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$rdir" "$leaf"
  else
    # Parent dir doesn't exist yet — return the lexically-joined path as-is.
    printf '%s\n' "$p"
  fi
}

# Allow-listed scratch roots: /tmp and $TMPDIR (macOS hands out per-user temp
# dirs under /var/folders via $TMPDIR; honor both, with their -P realpaths so a
# /tmp -> /private/tmp symlink still matches a pwd -P'd target).
allow_roots=()
for r in "/tmp" "${TMPDIR:-}"; do
  [ -n "$r" ] || continue
  allow_roots+=("${r%/}")
  if rp=$(cd "$r" 2>/dev/null && pwd -P); then
    allow_roots+=("${rp%/}")
  fi
done

is_allowlisted() {
  local p="$1" root
  for root in "${allow_roots[@]}"; do
    case "$p" in
      "$root"/*|"$root") return 0 ;;
    esac
  done
  return 1
}

# Gitignored source copies are allowed: a worker may copy a gitignored file
# (e.g. `.env`) in from the parent checkout. `git check-ignore` answers whether
# the path is ignored relative to the worktree (only meaningful for in-tree
# paths; an out-of-tree path errors and is treated as not-ignored).
is_gitignored() {
  local p="$1"
  git -C "$worktree_root" check-ignore -q -- "$p" 2>/dev/null
}

# True iff a shell token is NON-LITERAL — it carries an expansion, command
# substitution, glob, or brace whose runtime value the guard cannot resolve
# statically. `..` is deliberately NOT here: it is literal and abspath's `pwd -P`
# resolves it, so it stays subject to the ordinary containment check.
is_nonliteral() {
  case "$1" in
    *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'~'*|*'{'*) return 0 ;;
  esac
  return 1
}

# Strip one layer of surrounding single/double quotes from a whitespace-split
# shell token, so a quoted literal path (`"/tmp/x"`) compares as a bare path.
strip_quotes() {
  local s="$1"
  s="${s#[\"\']}"; s="${s%[\"\']}"
  printf '%s' "$s"
}

# --- Bash arm: destructive filesystem verbs (foundation #1087 / F#932) --------
if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$cmd" ] || exit 0

  # Walk the command left-to-right. Track the active `cd`/`pushd` context, and
  # for each destructive verb emit one tab-delimited record per path operand:
  #   <baseKind>\t<baseVal>\t<opndVal>
  # baseKind: CWD (no cd — resolve against the worktree cwd) | LIT <dir> |
  # NONLIT <dir> (a cd whose target the guard cannot resolve). Flags, redirect
  # operators, and command separators end an operand list. For `dd`, only the
  # `of=` operand is a write target.
  while IFS=$'\t' read -r bk bv op; do
    [ -n "$op" ] || continue

    # Resolve the base dir the operand is relative to (the active cd context).
    basedir="$cwd"
    if [ "$bk" = "NONLIT" ]; then
      deny "build worktree guard (Bash): a destructive command runs after 'cd $bv', whose target the guard cannot resolve statically (it contains an expansion, substitution, or glob), so it cannot prove the command stays inside the worktree root '$wt'. cd to a literal path under '$wt' first, or drop the cd. (foundation #1087/#932 — worker Bash must not escape the write-jail.)"
    fi
    if [ "$bk" = "LIT" ]; then
      bdir=$(abspath "$(strip_quotes "$bv")")
      case "$bdir" in
        "$wt"/*|"$wt") basedir="$bdir" ;;
        *) if is_allowlisted "$bdir"; then basedir="$bdir"
           else deny "build worktree guard (Bash): a destructive command runs after 'cd $bv' → '$bdir', which is OUTSIDE the active worktree root '$wt'. A build worker must operate only inside its own worktree (or /tmp). (foundation #1087/#932.)"
           fi ;;
      esac
    fi

    # A non-literal operand is unprovable → deny (the exact F#932 shape).
    if is_nonliteral "$op"; then
      deny "build worktree guard (Bash): a destructive command (rm/rmdir/mv/shred/truncate/dd) targets '$op', a NON-LITERAL path — it contains an expansion, command substitution, or glob whose value the guard cannot resolve, so it cannot prove the target stays inside the worktree root '$wt'. This is the F#932 failure shape ('rm -rf \"\$(dirname \"\$(pwd)\")\"' wiped ~/dev). Re-issue with a literal path typed in full under '$wt' (or /tmp/\$TMPDIR). (foundation #1087/#932.)"
    fi

    ap=$(abspath "$(strip_quotes "$op")" "$basedir")

    # Inside the worktree, or allow-listed, or a gitignored in-tree copy → OK.
    case "$ap" in "$wt"/*|"$wt") continue ;; esac
    is_allowlisted "$ap" && continue
    is_gitignored "$ap" && continue

    deny "build worktree guard (Bash): a destructive command (rm/rmdir/mv/shred/truncate/dd) targets '$ap', which is OUTSIDE the active worktree root '$wt'. A build worker must delete/move only inside its own pre-created worktree (foundation #1087/#932 — worker Bash wiped ~/dev by escaping the write-jail). Re-issue with a path under '$wt'. Allowed exceptions: /tmp, \$TMPDIR, and gitignored source copies."
  done < <(printf '%s' "$cmd" | awk '
    function isDestructive(s){
      return s=="rm"||s=="rmdir"||s=="mv"||s=="shred"||s=="truncate"||s=="dd"
    }
    function nonlit(s){
      return (index(s,"$")||index(s,"`")||index(s,"*")||index(s,"?")|| \
              index(s,"[")||index(s,"~")||index(s,"{"))
    }
    # Never emit an empty baseVal field: a tab-delimited shell read collapses
    # empty whitespace-run fields, which would shift op into bv. CWD uses a dash.
    function emit(bk,bv,op){ if(bv==""){bv="-"} print bk "\t" bv "\t" op }
    {
      n=split($0,t,/[[:space:]]+/)
      baseKind="CWD"; baseVal=""
      i=1
      while(i<=n){
        tok=t[i]
        if(tok==""){ i++; continue }
        # Track the active cd/pushd context (its dir becomes the operand base).
        if(tok=="cd"||tok=="pushd"){
          j=i+1
          while(j<=n && (t[j]==""||substr(t[j],1,1)=="-")) j++
          if(j<=n){
            d=t[j]
            if(nonlit(d)){ baseKind="NONLIT" } else { baseKind="LIT" }
            baseVal=d
            i=j+1; continue
          }
          i++; continue
        }
        if(isDestructive(tok)){
          verb=tok
          j=i+1
          while(j<=n){
            o=t[j]
            if(o==""){ j++; continue }
            # command separators / redirects end this operand list
            if(o==";"||o=="|"||o=="||"||o=="&"||o=="&&"|| \
               o==">"||o==">>"||o=="<"||o=="2>"||o=="2>>"){ break }
            if(substr(o,1,1)=="-"){ j++; continue }   # a flag
            if(verb=="dd"){
              if(substr(o,1,3)=="of="){ emit(baseKind,baseVal,substr(o,4)) }
              j++; continue
            }
            emit(baseKind,baseVal,o)
            j++
          }
          i=j; continue
        }
        i++
      }
    }')
  exit 0
fi

# --- Edit/Write/MultiEdit arm -------------------------------------------------
# Collect every target path the tool would write. Edit/Write/MultiEdit all carry
# a single `file_path` in tool_input; gather defensively in case a variant adds
# more. Newline-delimited read loop (portable to bash 3.2 — no `mapfile`); tool
# paths from the harness never contain embedded newlines.
targets=()
while IFS= read -r _t; do
  [ -n "$_t" ] && targets+=("$_t")
done < <(printf '%s' "$INPUT" | jq -r '
  (.tool_input // {}) as $i
  | [ $i.file_path?, $i.path?, ($i.edits // [])[].file_path? ]
  | map(select(. != null and . != ""))
  | .[]' 2>/dev/null)

# No parseable target → fail open.
[ "${#targets[@]}" -gt 0 ] || exit 0

for t in "${targets[@]}"; do
  ap=$(abspath "$t")

  # Inside the active worktree root → allowed.
  case "$ap" in
    "$wt"/*|"$wt") continue ;;
  esac

  # Outside the worktree, but on an allow-list → permitted.
  is_allowlisted "$ap" && continue
  is_gitignored "$ap" && continue

  # Outside the worktree and not allow-listed → DENY.
  deny "build worktree guard: write to '$ap' is OUTSIDE the active worktree root '$wt'. A build worker must write only inside its own pre-created worktree (foundation #17/#10 — a bare parent-root path leaks an uncommitted edit into the orchestrator's tree). Re-issue the write with a path under '$wt' (relative paths from your Bash cwd are safest). Allowed exceptions: /tmp, \$TMPDIR, and gitignored source copies."
done

exit 0
