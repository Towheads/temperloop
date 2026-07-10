#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write|MultiEdit) — build worker write jail.
#
# Structurally enforces /build worker write-isolation (foundation #17, #10):
# a worker spawned by the orchestrator must only edit files inside its OWN
# pre-created worktree. A bare parent-root absolute path resolves against the
# parent checkout and leaks an uncommitted write into the orchestrator's tree
# even when the worker's Bash cwd is the worktree. This hook DENIES any Edit/
# Write/MultiEdit whose resolved absolute target is outside the active worktree
# root, so isolation no longer depends on the worker model's discretion.
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
  Edit|Write|MultiEdit) ;;
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

# Normalize a path to absolute WITHOUT requiring it to exist (a Write target may
# be a new file). Resolves the existing parent dir, then re-attaches the leaf.
abspath() {
  local p="$1" dir base rdir
  case "$p" in
    /*) ;;                       # already absolute
    *)  p="$cwd/$p" ;;           # resolve relative to the tool's cwd
  esac
  dir=$(dirname -- "$p")
  base=$(basename -- "$p")
  if rdir=$(cd "$dir" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "$rdir" "$base"
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
