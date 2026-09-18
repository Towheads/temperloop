#!/usr/bin/env bash
# PreToolUse hook (matcher: Read|Glob|Grep|Bash) — dual-build arm read isolation.
#
# WHY (temperloop#2077, epic #2065 "new-work dual-build harness"). A dual-build
# level builds the SAME plan item twice, under two models, in two isolated
# worktrees off one base SHA. The comparison is only evidence if the two arms
# are INDEPENDENT: the moment the candidate arm reads the baseline arm's
# worktree, branch, or diff, its work is no longer its own and every downstream
# number — the judge preference, the item win, the level pick — measures
# contamination instead of capability. Nothing about that contamination is
# visible after the fact: two independent diffs and one copied diff look
# identical in the ledger. So the isolation has to be enforced at read time,
# structurally, rather than asked of the worker model's discretion.
#
# ARMING — marker-scoped, inert by default. The hook does nothing at all unless
# the git worktree the tool call runs in carries a `.dual-build-arm` marker at
# its root, written by `worktree.sh create --arm` (epic #2065's shared seam):
#
#     {"arm":"candidate",
#      "sibling_worktree":"/abs/path/to/<repo>.wt/<slug>@baseline",
#      "sibling_branch":"build/<slug>@baseline"}
#
# No marker, no effect: an ordinary interactive session, an ordinary /build
# worker, and every non-dual-build repo on the machine never see this guard.
# That inertness is the property that lets a deny-verdict guard ship in a
# kernel every adopter installs (ADR 0027 § Consequences carries the amendment).
#
# DETECTION, per tool:
#   - Read/Glob/Grep — every path-shaped field of the tool input (`file_path`,
#     `path`, `notebook_path`, `paths[]`, and Glob's `pattern`, which may itself
#     be an absolute path glob) is resolved against the tool's cwd and tested
#     for containment under the sibling worktree root.
#   - Bash — the WHOLE command text is scanned (not just the leading command
#     word) for the sibling worktree path, the sibling worktree's own basename
#     (`<slug>@<arm>`, which is what a relative `../<slug>@baseline/...` read
#     carries), or the sibling branch name. That covers the git read surface —
#     `git log`, `git show <branch>:<file>`, `git diff`, `git -C <sibling>` —
#     without enumerating git subcommands, which is the enumeration a new git
#     verb silently escapes.
#
# VERDICT: deny (not `ask`, the posture every other guard in this directory
# takes) — deliberately, and for two reasons stated together because either
# alone would be weaker. (1) There is no operator: a dual-build arm is a
# headless worker, so an `ask` has nobody to answer it and would either hang
# the arm or be auto-approved by the harness. (2) There is no legitimate
# cross-read: unlike a kernel/ edit or a foreign-checkout write, which are
# sometimes exactly what the operator wants, an arm reading its sibling has no
# sanctioned form — the isolation IS the experiment. The inertness above is
# what keeps that stricter posture scoped to the one situation it belongs in.
#
# ATTEMPT MARKER. A denial also appends one JSON line to
# `.dual-build-cross-read-attempts.jsonl`, NEXT TO the `.dual-build-arm` marker
# in the arm's own worktree root: {ts, arm, tool, kind, target}. The file's mere
# existence is the signal the level driver folds into the arm's ledger row as
# `cross_read_attempted`; its lines are the detail a reviewer reads. Recording
# the attempt matters as much as blocking it — an arm that TRIED to read its
# sibling is a fact about that arm's run, and a blocked attempt that left no
# trace would be indistinguishable from a clean one.
#
# EVAL_RUN is deliberately NOT honoured here, unlike the interactive `ask`
# guards (git-stale-branch-guard.sh, write-lane-guard.sh, subtree-edit-guard.sh)
# and like the other deny-verdict guard (build-worktree-guard.sh). Those exit
# early under EVAL_RUN because an unanswerable prompt would hang a headless run;
# this hook never prompts, so there is nothing to hang — and suppressing it
# would silently void the isolation the comparison's validity rests on, which is
# the failure mode an eval run is least able to notice.
#
# KNOWN GAPS (stated, not implied). The Bash scan reads the command text it is
# handed: a sibling path assembled at run time out of shell variables, or a read
# performed by an already-committed script invoked by path, is not visible here.
# The path axis is the one a worker actually reaches for; the residue is carried
# by the ledger's `cross_read_attempted` field being a floor, never a proof of
# absence.
#
# FAILS OPEN: any internal error — missing jq, unparseable input, no git, an
# unreadable or malformed marker, a marker with no sibling fields — exits 0
# immediately. A guard bug must never be the reason a legitimate read fails.
set -uo pipefail

# Hook logs live in the XDG state dir, not beside the hook — runtime state,
# not config (foundation #773).
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/arm-read-guard.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq, no guard

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$tool" in
  Read|Glob|Grep|Bash) ;;
  *) exit 0 ;;   # the matcher should scope this; double-check anyway
esac

# The tool's working directory (where relative paths resolve). Falls back to
# PWD if the harness omits it.
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# --- arming gate --------------------------------------------------------
# Inert unless the tool call runs inside a worktree carrying the per-arm
# marker at its root.
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$root" ] || exit 0
if rp=$(cd "$root" 2>/dev/null && pwd -P); then root="$rp"; fi
root="${root%/}"
MARKER="$root/.dual-build-arm"
[ -f "$MARKER" ] || exit 0

marker_json=$(cat "$MARKER" 2>/dev/null) || exit 0
arm=$(printf '%s' "$marker_json" | jq -r '.arm // empty' 2>/dev/null) || exit 0
sib_wt=$(printf '%s' "$marker_json" | jq -r '.sibling_worktree // empty' 2>/dev/null)
sib_br=$(printf '%s' "$marker_json" | jq -r '.sibling_branch // empty' 2>/dev/null)
if [ -z "$sib_wt" ] && [ -z "$sib_br" ]; then
  # Malformed or sibling-less marker — nothing to protect against, and
  # guessing would be worse than staying silent.
  log "INERT: marker at $MARKER names no sibling worktree or branch"
  exit 0
fi

sib_wt="${sib_wt%/}"
sib_wt_rp=""
if [ -n "$sib_wt" ] && [ -d "$sib_wt" ]; then
  sib_wt_rp=$(cd "$sib_wt" 2>/dev/null && pwd -P) || sib_wt_rp=""
  sib_wt_rp="${sib_wt_rp%/}"
fi
sib_base=""
[ -n "$sib_wt" ] && sib_base=$(basename -- "$sib_wt")

# resolve <path> — the target's physical absolute location. Follows symlinks
# in the directory components (cd -P) without ever `cd`-ing the leaf, and
# tolerates a path whose tail does not exist yet. Portable: no GNU
# `realpath -f`. Same shape as subtree-edit-guard.sh's resolver.
resolve() {
  local p="$1" dir base cur suffix rcur
  case "$p" in
    /*) ;;
    *) p="$cwd/$p" ;;
  esac
  dir=$(dirname -- "$p")
  base=$(basename -- "$p")
  cur="$dir"; suffix=""
  while [ ! -d "$cur" ] && [ "$cur" != "/" ] && [ "$cur" != "." ]; do
    suffix="/$(basename -- "$cur")$suffix"
    cur=$(dirname -- "$cur")
  done
  if rcur=$(cd "$cur" 2>/dev/null && pwd -P); then
    printf '%s\n' "${rcur%/}$suffix/$base"
  else
    printf '%s\n' "$p"
  fi
}

# under_sibling <abs-path> — containment under either spelling of the sibling
# worktree root (the literal one the marker names, and its physically
# resolved form when the directory exists).
under_sibling() {
  local p="${1%/}" s
  for s in "$sib_wt" "$sib_wt_rp"; do
    [ -n "$s" ] || continue
    case "$p" in
      "$s"|"$s"/*) return 0 ;;
    esac
  done
  return 1
}

hit=""      # the offending target, for the message and the attempt record
kind=""     # path | path-basename | branch

if [ "$tool" = "Bash" ]; then
  cmd=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  if [ -n "$cmd" ]; then
    for s in "$sib_wt" "$sib_wt_rp"; do
      [ -n "$s" ] || continue
      if printf '%s' "$cmd" | grep -F -- "$s" >/dev/null; then hit="$s"; kind="path"; break; fi
    done
    # Branch BEFORE basename, deliberately: the branch name (`build/<slug>@arm`)
    # CONTAINS the worktree basename (`<slug>@arm`), so testing the basename
    # first would record every git-ref read as a path attempt and the attempt
    # record would lose the one distinction a reviewer wants — whether the arm
    # reached for the sibling's files or for its history.
    if [ -z "$hit" ] && [ -n "$sib_br" ] && printf '%s' "$cmd" | grep -F -- "$sib_br" >/dev/null; then
      hit="$sib_br"; kind="branch"
    fi
    if [ -z "$hit" ] && [ -n "$sib_base" ] && printf '%s' "$cmd" | grep -F -- "$sib_base" >/dev/null; then
      # A relative reach into the sibling (`../<slug>@baseline/...`, `git -C
      # ../<slug>@baseline`). The basename carries the arm suffix, so it is
      # specific to the sibling and cannot match this arm's own paths.
      hit="$sib_base"; kind="path-basename"
    fi
  fi
else
  # Read/Glob/Grep — every path-shaped field of the tool input.
  targets=()
  while IFS= read -r _t; do
    [ -n "$_t" ] && targets+=("$_t")
  done < <(printf '%s' "$INPUT" | jq -r --arg tool "$tool" '
    (.tool_input // {}) as $i
    | [ $i.file_path?, $i.path?, $i.notebook_path?,
        (if $tool == "Glob" then $i.pattern? else empty end),
        ($i.paths // [])[]? ]
    | map(select(type == "string" and . != ""))
    | .[]' 2>/dev/null)
  for t in "${targets[@]:-}"; do
    [ -n "$t" ] || continue
    ap=$(resolve "$t")
    if under_sibling "$ap"; then hit="$ap"; kind="path"; break; fi
  done
fi

[ -n "$hit" ] || exit 0

# --- attempt record (next to the arm marker) ----------------------------
ATTEMPTS="$root/.dual-build-cross-read-attempts.jsonl"
if line=$(jq -cn \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg arm "$arm" --arg tool "$tool" --arg kind "$kind" --arg target "$hit" \
    '{ts:$ts, arm:$arm, tool:$tool, kind:$kind, target:$target}' 2>/dev/null); then
  printf '%s\n' "$line" >>"$ATTEMPTS" 2>/dev/null || true
fi

case "$kind" in
  branch) noun="branch" ;;
  *)      noun="worktree" ;;
esac
reason="Dual-build arm isolation: this ${tool} call reaches the SIBLING arm's ${noun} ('$hit'). This worktree is arm '$arm' of a two-arm dual build (marker: $MARKER); the sibling arm is building the same item under a different model, and the comparison is only evidence while the arms stay independent. Work from this worktree alone — its own files, its own branch, the issue and the acceptance criteria. The attempt has been recorded in $ATTEMPTS and rides the arm's ledger row as cross_read_attempted."
log "DENY ($kind) arm=$arm tool=$tool :: $hit"
jq -cn --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
  2>/dev/null || true
exit 0
