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
# DENIES a DESTRUCTIVE filesystem verb (rm, rmdir, mv, shred, truncate, dd of=,
# rsync --delete, find -delete/-exec rm, git clean -xfd)
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
# BASH ARM — THE VERB → OPERAND-MODEL TABLE (foundation#1354). The walker began
# as a single flat list of destructive verbs, all sharing one grammar ("every
# non-flag token is a path operand"). That shape does not generalize: `rsync` is
# destructive only under `--delete*` and only at its LAST operand; `find` is
# destructive only when its predicate run carries `-delete` / `-exec rm`, and
# only its PRE-predicate paths are targets; `git clean` takes no target operand
# at all and is destructive against the cd-context base itself. So the verb list
# became a TABLE — one row per verb, four data fields, no per-verb control flow:
#
#   MODEL["<verb>"] = "<select>|<arm>|<base>|<words>"
#     select : which operands are containment-checked
#              ALL  every non-flag token   (rm, rmdir, mv, shred, truncate)
#              OF   the `of=` operand only (dd)
#              LAST the last non-flag token — the destination (rsync). Skips an
#                   option's ARGUMENT via the OPTARG table, or a trailing
#                   `--exclude foo` would be mistaken for the destination.
#              PRE  the pre-predicate path operands (find)
#              NONE no operand is a target (git clean)
#     arm    : the predicate deciding whether THIS invocation is destructive
#              ALWAYS      the verb is always destructive
#              RSYNCDEL    an exact member of rsync's delete family — `--del`,
#                          `--delete`, `--delete-*`, `--remove-source-files`. A
#                          prefix test would arm on `--delay-updates`, denying a
#                          plain transfer that deletes nothing.
#              FINDPRED    a `-delete` or `-exec rm`/`-exec rmdir` predicate (find)
#              CLEANFLAG   an `-x`/`-X`/`-d`/`-f` flag LETTER (git clean). Letters,
#                          never substrings: `index(tok,"d")` matched `--dry-run`
#                          and falsely denied a read-only command. An explicit
#                          `-n`/`--dry-run` VETOES arming outright.
#     base   : CWD = the active cd-context base dir is ITSELF an implicit target
#              (empty = the base only resolves relative operands, as before)
#     words  : how many tokens the verb name occupies (2 for `git clean`). READ:
#              the walker derives its key-probe length (MAXW) from this column,
#              so a 3-word verb is a row, not walker surgery.
#
# Two invariants keep the table honest — both are regressions the first cut of
# this refactor shipped, so they are stated as rules, not as commentary:
#
#   1. RESUME AT THE OPERANDS, NEVER PAST THEM. After a row is applied, the walk
#      re-enters at the first operand token, not at the end of the run. Skipping
#      the run discards every token the row's `select` did not pick — which hid a
#      nested `find -exec rm <outside>` argv (the F#932 shape in a find hat) and
#      hid anything sequenced after a non-ALL verb (`rsync -a s/ d/; rm -rf
#      <outside>` — and that rsync is not even destructive, so the ROW ITSELF
#      created the hiding place). Re-scanning costs nothing and makes a nested
#      verb resolve through the table like any other.
#   2. AN ARMED ROW ALWAYS EMITS AT LEAST ONE RECORD. The cd-containment check
#      runs per emitted record, so a row that arms but selects zero targets would
#      slip the check entirely. Zero selections therefore emit a synthetic "."
#      against the active base — covering `base`=CWD verbs by construction and
#      GNU `find -delete`'s implicit path.
#
# The one deliberate exemption is find's `-exec` placeholder: `{}` (and the `\;`
# / `+` terminators) are find's grammar, not operands of the nested verb, and
# `{}` expands to a path under the search root that PRE already judged. It is
# exempted BY NAME inside an -exec context, never by discarding the argv.
#
# Adding a destructive shape that reuses an existing select/arm pair is a pure
# TABLE ROW — no new branch. A shape needing a genuinely NEW operand model (a
# new `select` or `arm` kind) is the signal that enumeration has hit its
# ceiling; see the Decisions note named at the foot of this header.
#
# Coverage regressions in this arm are caught by
# `claude/hooks/tests/differential-guard-vs-ref.sh`, which runs this guard and a
# git ref's copy over the same payloads and fails on any `old=DENY new=allow`.
# The DENY/ALLOW corpus alone provably cannot catch them: a refactor that loses
# coverage tends to arrive with a corpus that ratifies the loss.
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
#
# OBSERVABILITY — every early exit logs `INERT: <reason>`. Because failing open
# is silent, "the guard ran and allowed this" and "the guard never armed" look
# identical from outside, so a regression to always-open is invisible. Each
# early `exit 0` below therefore goes through `inert()`, which names the reason
# in the log. Reading it: an INERT line = no judgment was made; NO INERT line on
# an armed worktree = the guard ran and permitted. `claude/hooks/tests/
# test_build_worktree_guard.sh` asserts both arms against DENY and ALLOW corpora,
# and uses the absence of an INERT line to prove the ALLOW corpus was actually
# judged rather than silently skipped.
set -uo pipefail

# Hook logs live in the XDG state dir (foundation #773), not ~/.claude/hooks/ —
# runtime state, not config.
XDG_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation"
mkdir -p "$XDG_STATE_DIR" 2>/dev/null || true
LOG="$XDG_STATE_DIR/build-worktree-guard.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# Exit WITHOUT having made a containment judgment, recording why.
#
# This guard's normal state is to allow silently, so an "allowed" outcome and a
# "never armed / never reached" outcome are indistinguishable from the outside —
# which is exactly how it could regress to always-open with nothing observable
# changing (the F#932 blast radius). Every early exit therefore names its reason
# in the log: an INERT line means the guard made NO judgment, and its ABSENCE on
# an armed worktree means the guard ran and permitted. Diagnostics only — this
# never writes stdout (the PreToolUse "empty stdout = allow" contract is
# unchanged) and never converts a fail-open into a block.
inert() { log "INERT: $1"; exit 0; }

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
[ -n "$INPUT" ] || inert "empty hook input on stdin"
# fail open: no jq, no enforcement
command -v jq >/dev/null 2>&1 || inert "jq not found on PATH — cannot parse the hook payload"

tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool" in
  Bash|Edit|Write|MultiEdit) ;;
  # matcher should scope this, but double-check. An empty tool also lands here,
  # which is how unparseable (non-JSON) input fails open.
  *) inert "tool '$tool' is not one of Bash/Edit/Write/MultiEdit" ;;
esac

# The tool's working directory (where relative paths resolve, and where we
# compute the worktree root from). Falls back to PWD if the harness omits it.
cwd=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

# Resolve the active worktree root from the tool's cwd. If git can't tell us
# (cwd not in a repo), the hook is inert — we can't make a containment
# judgment, and only build worktrees (always git checkouts) are guarded.
worktree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$worktree_root" ] || inert "cwd '$cwd' is not inside a git working tree"

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
[ -f "$wt/.build-guard" ] || inert "no .build-guard marker at '$wt' — guard unarmed (the normal interactive-session state)"

# Marker present but the toplevel is NOT under a `<repo>.wt/` dir — a stale or
# hand-copied marker outside the build worktree convention. Warn and fail
# OPEN: the convention scopes the guard, the marker alone never arms it.
case "$(dirname "$wt")" in
  *.wt) ;;
  *)
    echo "build-worktree-guard: marker '$wt/.build-guard' present but '$wt' is not under a '<repo>.wt/' worktree dir — stale marker? Failing OPEN (writes allowed). Remove the marker or recreate the worktree via workflows/scripts/build/worktree.sh." >&2
    log "WARN fail-open: marker outside .wt convention at $wt"
    inert "marker '$wt/.build-guard' present but '$wt' is not under a '<repo>.wt/' dir — stale or hand-copied marker, guard NOT armed"
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
    # A top-level path ("/tmp") has dirname "/", and re-appending the separator
    # would yield "//tmp" — which matches NO allow-list root, so `cd /tmp && rm
    # -rf x` was falsely DENIED. Drop the root's own slash before rejoining.
    [ "$rdir" = "/" ] && rdir=""
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
  [ -n "$cmd" ] || inert "Bash tool_input.command is absent or empty — nothing to inspect"

  # Walk the command left-to-right. Track the active `cd`/`pushd` context, and
  # for each ARMED destructive verb emit one tab-delimited record per path
  # operand its table row selects:
  #   <baseKind>\t<baseVal>\t<verb>\t<opndVal>
  # baseKind: CWD (no cd — resolve against the worktree cwd) | LIT <dir> |
  # NONLIT <dir> (a cd whose target the guard cannot resolve). Redirect
  # operators and command separators end an operand run. Which tokens of that
  # run become records is the row's `select`; whether the verb counts as
  # destructive at all is its `arm`. See the operand-model table in the header.
  while IFS=$'\t' read -r bk bv verb op; do
    [ -n "$op" ] || continue

    # Resolve the base dir the operand is relative to (the active cd context).
    basedir="$cwd"
    if [ "$bk" = "NONLIT" ]; then
      deny "build worktree guard (Bash): a destructive command ($verb) runs after 'cd $bv', whose target the guard cannot resolve statically (it contains an expansion, substitution, or glob), so it cannot prove the command stays inside the worktree root '$wt'. cd to a literal path under '$wt' first, or drop the cd. (foundation #1087/#932 — worker Bash must not escape the write-jail.)"
    fi
    if [ "$bk" = "LIT" ]; then
      bdir=$(abspath "$(strip_quotes "$bv")")
      case "$bdir" in
        "$wt"/*|"$wt") basedir="$bdir" ;;
        *) if is_allowlisted "$bdir"; then basedir="$bdir"
           else deny "build worktree guard (Bash): a destructive command ($verb) runs after 'cd $bv' → '$bdir', which is OUTSIDE the active worktree root '$wt'. A build worker must operate only inside its own worktree (or /tmp). (foundation #1087/#932.)"
           fi ;;
      esac
    fi

    # A non-literal operand is unprovable → deny (the exact F#932 shape).
    if is_nonliteral "$op"; then
      deny "build worktree guard (Bash): a destructive command ($verb) targets '$op', a NON-LITERAL path — it contains an expansion, command substitution, or glob whose value the guard cannot resolve, so it cannot prove the target stays inside the worktree root '$wt'. This is the F#932 failure shape ('rm -rf \"\$(dirname \"\$(pwd)\")\"' wiped ~/dev). Re-issue with a literal path typed in full under '$wt' (or /tmp/\$TMPDIR). (foundation #1087/#932.)"
    fi

    ap=$(abspath "$(strip_quotes "$op")" "$basedir")

    # Inside the worktree, or allow-listed, or a gitignored in-tree copy → OK.
    case "$ap" in "$wt"/*|"$wt") continue ;; esac
    is_allowlisted "$ap" && continue
    is_gitignored "$ap" && continue

    deny "build worktree guard (Bash): a destructive command ($verb) targets '$ap', which is OUTSIDE the active worktree root '$wt'. A build worker must delete/move only inside its own pre-created worktree (foundation #1087/#932 — worker Bash wiped ~/dev by escaping the write-jail). Re-issue with a path under '$wt'. Allowed exceptions: /tmp, \$TMPDIR, and gitignored source copies."
  done < <(printf '%s' "$cmd" | awk '
    # --- the verb -> operand-model table (see the hook header for the schema).
    # "<select>|<arm>|<base>|<words>". A new destructive shape reusing an
    # existing select/arm pair is a ROW here and nothing else — the walker below
    # dispatches on the data, never on the verb name.
    BEGIN{
      MODEL["rm"]        = "ALL|ALWAYS||1"
      MODEL["rmdir"]     = "ALL|ALWAYS||1"
      MODEL["mv"]        = "ALL|ALWAYS||1"
      MODEL["shred"]     = "ALL|ALWAYS||1"
      MODEL["truncate"]  = "ALL|ALWAYS||1"
      MODEL["dd"]        = "OF|ALWAYS||1"
      MODEL["rsync"]     = "LAST|RSYNCDEL||1"
      MODEL["find"]      = "PRE|FINDPRED||1"
      MODEL["git clean"] = "NONE|CLEANFLAG|CWD|2"

      # The verb-key probe length is DERIVED from the table`s own `words`
      # column, so a three-word verb (`git submodule deinit`) is a row and not
      # walker surgery. Read here, nowhere else.
      MAXW=1
      for(mk in MODEL){ split(MODEL[mk],mf,"|"); if(mf[4]+0>MAXW) MAXW=mf[4]+0 }

      # Options that consume a FOLLOWING token. The LAST model must skip an
      # option`s argument, or it mistakes that argument for the destination
      # (`rsync --delete src/ DEST --exclude foo` picks `foo`, not DEST).
      split("--exclude --include --exclude-from --include-from --files-from " \
            "--filter -f --rsh -e --rsync-path --compare-dest --copy-dest " \
            "--link-dest --partial-dir --temp-dir -T --backup-dir --suffix " \
            "--chmod --chown --usermap --groupmap --copy-as --block-size -B " \
            "--max-size --min-size --max-delete --bwlimit --timeout " \
            "--contimeout --port --sockopts --address --password-file " \
            "--write-batch --only-write-batch --read-batch --protocol --iconv " \
            "--checksum-seed --log-file --log-file-format --out-format --info " \
            "--debug --stderr --config --modify-window --remote-option -M " \
            "--skip-compress --compress-level --outbuf", OA, " ")
      for(oi in OA){ OPTARG[OA[oi]]=1 }
    }
    function nonlit(s){
      return (index(s,"$")||index(s,"`")||index(s,"*")||index(s,"?")|| \
              index(s,"[")||index(s,"~")||index(s,"{"))
    }
    function isFlag(s){ return substr(s,1,1)=="-" }
    # command separators / redirects end an operand run
    function isSep(s){
      return (s==";"||s=="|"||s=="||"||s=="&"||s=="&&"|| \
              s==">"||s==">>"||s=="<"||s=="2>"||s=="2>>")
    }
    # `find -exec CMD ... {} \;` — the placeholder and the run terminators are
    # find`s own grammar, not path operands of the nested verb. `{}` expands to
    # a path UNDER find`s search root, which the PRE selector already judged,
    # so it is allow-listed EXPLICITLY here rather than by discarding the argv.
    function isExecNoise(s){ return (s=="{}"||s=="+"||s=="\\;"||s==";") }
    # Never emit an empty baseVal field: a tab-delimited shell read collapses
    # empty whitespace-run fields, which would shift op into bv. CWD uses a dash.
    function emit(bk,bv,vb,op){
      if(op==""){ return }
      if(bv==""){ bv="-" }
      emitted++
      print bk "\t" bv "\t" vb "\t" op
    }
    # `arm`: is THIS invocation destructive at all? Reads the operand run o[1..m].
    function armed(arm,   k,tk,armv){
      if(arm=="ALWAYS"){ return 1 }
      if(arm=="RSYNCDEL"){
        # Exact members of the delete family only. A prefix test would catch
        # `--delay-updates` (harmless) and arm a plain transfer, which
        # criterion 2 forbids: no --delete* flag, no inspection.
        for(k=1;k<=m;k++){
          tk=o[k]
          if(tk=="--del"||tk=="--delete"||substr(tk,1,9)=="--delete-") return 1
          if(tk=="--remove-source-files"||tk=="--remove-sent-files") return 1
        }
        return 0
      }
      if(arm=="FINDPRED"){
        for(k=1;k<=m;k++){
          if(o[k]=="-delete"){ return 1 }
          if(o[k]=="-exec"||o[k]=="-execdir"||o[k]=="-ok"||o[k]=="-okdir"){
            if(k<m && (o[k+1]=="rm"||o[k+1]=="rmdir")) return 1
          }
        }
        return 0
      }
      if(arm=="CLEANFLAG"){
        # Match flag LETTERS, never substrings: `index(tk,"d")` armed on
        # `--dry-run`, falsely denying a read-only command — and a false deny is
        # what gets the guard disarmed. An explicit dry run VETOES arming
        # outright, whatever else is present (git honors -n over -f too).
        armv=0
        for(k=1;k<=m;k++){
          tk=o[k]
          if(tk=="--dry-run"){ return 0 }
          if(tk=="--force"||tk=="--directory"){ armv=1; continue }
          if(tk ~ /^-[A-Za-z]+$/){
            if(index(tk,"n")){ return 0 }
            if(index(tk,"x")||index(tk,"X")||index(tk,"d")||index(tk,"f")){ armv=1 }
          }
        }
        return armv
      }
      return 0
    }
    # `select`: which tokens of the operand run o[1..m] are containment targets.
    function targets(sel,   k,last){
      if(sel=="ALL"){
        for(k=1;k<=m;k++){
          if(isFlag(o[k])) continue
          if(execCtx && isExecNoise(o[k])) continue
          emit(baseKind,baseVal,verb,o[k])
        }
        return
      }
      if(sel=="OF"){
        for(k=1;k<=m;k++){ if(substr(o[k],1,3)=="of=") emit(baseKind,baseVal,verb,substr(o[k],4)) }
        return
      }
      if(sel=="LAST"){
        last=""; k=1
        while(k<=m){
          if(isFlag(o[k])){ if(o[k] in OPTARG){ k+=2 } else { k++ } ; continue }
          last=o[k]; k++
        }
        emit(baseKind,baseVal,verb,last)
        return
      }
      if(sel=="PRE"){
        # find [leading-options] [paths...] [predicates...] — the paths are the
        # non-flag run BEFORE the first predicate. The leading options are the
        # only flags allowed to precede a path.
        k=1
        while(k<=m && (o[k]=="-L"||o[k]=="-H"||o[k]=="-P"||o[k]=="-E"|| \
                       o[k]=="-d"||o[k]=="-s"||o[k]=="-x")) k++
        while(k<=m && !isFlag(o[k])){ emit(baseKind,baseVal,verb,o[k]); k++ }
        return
      }
      # NONE: the verb takes no target operand — the caller emits the synthetic
      # "." record that puts its cd-context base through the containment check.
    }
    {
      n=split($0,t,/[[:space:]]+/)
      baseKind="CWD"; baseVal=""; execCtx=0
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
        # `find -exec`/-ok argv context: the nested verb is walked like any
        # other (see the resume rule below), and only find`s own placeholder
        # tokens are exempted from its operand selection.
        if(tok=="-exec"||tok=="-execdir"||tok=="-ok"||tok=="-okdir"){ execCtx=1; i++; continue }
        if(tok==";"||tok=="\\;"||tok=="+"){ execCtx=0; i++; continue }

        # Resolve the verb through the table. The probe grows one word at a time
        # up to MAXW (derived from the `words` column), and the LONGEST declared
        # match wins — so `git clean` beats a bare `git`, and a future 3-word row
        # needs no walker change.
        verb=""; runstart=0; kkey=""; kw=0; kj=i
        while(kw<MAXW && kj<=n){
          if(t[kj]==""){ kj++; continue }
          kkey=(kkey=="") ? t[kj] : (kkey " " t[kj])
          kw++
          if(kkey in MODEL){
            split(MODEL[kkey],f,"|")
            if(f[4]+0==kw){ verb=kkey; runstart=kj+1 }
          }
          kj++
        }
        if(verb==""){ i++; continue }

        # Collect the operand run (flags included — the `arm` predicate reads them).
        m=0; j=runstart
        while(j<=n){
          x=t[j]
          if(x==""){ j++; continue }
          if(isSep(x)) break
          m++; o[m]=x; j++
        }

        split(MODEL[verb],f,"|")
        emitted=0
        if(armed(f[2])){
          targets(f[1])
          # An armed row that selected NO target still has a base to judge:
          # `base`=CWD verbs (git clean) have no target operand by construction,
          # and a path-taking verb can be armed with its path implicit (GNU
          # `find -delete`). Emit a synthetic "." so the cd-context check runs
          # either way — otherwise an armed verb with zero records slips past
          # the containment loop entirely.
          if(emitted==0){ emit(baseKind,baseVal,verb,".") }
        }

        # RESUME AT THE OPERANDS, NOT PAST THEM. Advancing to `j` (the end of
        # the run) discarded every token the row`s `select` did not pick — which
        # hid a nested `find -exec rm <outside>` argv, and hid any command
        # sequenced after a LAST/PRE/NONE/OF verb (`rsync -a s/ d/; rm -rf
        # <outside>`). Re-entering at `runstart` re-scans the run through the
        # same table, so a nested or following verb resolves like any other.
        # Progress is guaranteed: runstart > i always.
        i=runstart
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
[ "${#targets[@]}" -gt 0 ] || inert "no parseable write target in tool_input for tool '$tool'"

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
