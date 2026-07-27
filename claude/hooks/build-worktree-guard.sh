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
# BASH ARM — OUTPUT REDIRECTS (foundation#1355). A redirect target is a write
# the shell performs itself, before the verb ever runs: `> /Users/travis/dev/x`
# truncates that file whatever the command is, so leaving it unparsed left an
# uninspected write vector alongside the inspected delete vector. Redirect
# targets are therefore containment-checked on the SAME terms as a destructive
# verb's operand — non-literal is unprovable (deny), resolved-outside is an
# escape (deny), the /tmp//$TMPDIR//gitignored allow-list applies unchanged — and
# they are emitted through the same record stream, so the cd-context check covers
# them for free. Three shape rules, each of them load-bearing:
#   - THREE SPELLINGS, ONE REDIRECT. `> f`, `>f` and `date>f` are the same write.
#     Whitespace splitting alone sees only the first two, because `>` is a bash
#     metacharacter ANYWHERE unquoted in a word — so tokens are re-split at
#     embedded operators first (splitRedirWords), or `date>/etc/passwd` would
#     resolve to no record at all and bypass this check entirely. Of the three,
#     only the BARE form is an isSep() token: it keeps ending the preceding
#     verb's operand run (unchanged, long-standing behavior), while a glued form
#     is skipped from that run WITHOUT ending it, because it does not end the
#     argument list in a real shell either — `rm -rf 2>/dev/null <outside>` does
#     delete <outside>, and terminating the run there would have hidden it.
#   - `>&WORD` is an fd DUPLICATION, naming no file, ONLY when WORD is numeric or
#     `-` (`2>&1`, `>&-`). A non-numeric WORD is bash's both-streams FILE
#     redirect and stays a containment target — otherwise `2>&$FD` would slip
#     through unchecked. `>(cmd)` is process substitution: a word, not a redirect.
#     `>|` is a force-truncate — the same write, and parsing it as operator `>`
#     with target `|` left the real target unjudged.
#   - CHARACTER-DEVICE SINKS (`/dev/null`, `/dev/zero`, `/dev/stdout`,
#     `/dev/stderr`, `/dev/tty`) are allow-listed FOR REDIRECTS ONLY, and an
#     absolute one short-circuits above the cd-context check as well, since its
#     resolution does not involve the base. `2>/dev/null` is the single most
#     routine idiom in a worker command line and it mutates no tree; denying it,
#     or denying `cd <outside> && ls 2>/dev/null`, would have made the guard the
#     thing operators disarm. `rm -rf /dev/null` is still judged as an ordinary
#     destructive operand. `/dev/fd/*` is deliberately excluded — see
#     is_device_sink for the platform-divergence reason.
#
# BASH ARM — REDIRECTS, THE COSTS THIS BUYS (stated, not discovered later):
#   - A NON-LITERAL redirect target is judged by its literal directory PREFIX
#     when it has one (`logs/$(date).log` -> `logs/`), and denied when it does
#     not (`> "$LOG"`, `> "$HOME/x"`, `> ~/x`). Two consequences, both accepted:
#     a bare `> "$VAR"` is ACCEPTED COLLATERAL — it denies, and a worker must
#     re-issue with a literal prefix; and the prefix proves only where the write
#     STARTS, so an expansion evaluating to `../../..` still climbs out. This is
#     a redirect-only relaxation, never extended to a destructive verb, where a
#     computed path is the F#932 incident itself. See redirect_prefix_contained.
#   - `$TMPDIR` is resolved (it is an allow-listed root whose value the guard
#     knows); no other variable is.
#
# BASH ARM — accepted fail-open gaps (documented, like the sibling guards):
#   - Only tree-destructive verbs and output-redirect targets are inspected.
#     `tee` and in-place edits (`sed -i`) are NOT parsed — the dominant
#     catastrophic vector is tree deletion/move, and those two remain a
#     documented gap rather than a silent omission.
#   - A BARE redirect operator still terminates the operand run it sits in, so a
#     verb operand written AFTER one (`rm -rf 2> /dev/null <outside>`) is not
#     collected. Long-standing behavior, deliberately left intact: it fails OPEN
#     on an exotic ordering, never falsely denies.
#   - HEREDOC BODIES are judged as commands, because the walker is line-oriented
#     and has no heredoc state — the same pre-existing property that makes a
#     heredoc'd `rm -rf $VAR` deny. This is BROADER than an out-of-tree redirect
#     and worth stating plainly, since writing a README or a generated script
#     through `cat > f <<EOF` is routine /build output: a markdown BLOCKQUOTE
#     whose first word carries an expansion or glob char (`> **Note:**`) reads as
#     a redirect to a non-literal target and denies, as does any body line
#     redirecting to a variable. Fails CLOSED (a false deny, never a false
#     allow), and the worker`s recourse is a Write tool call, which the file arm
#     judges properly. The likeliest next thing to fix in this arm.
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

# Character-device sinks a REDIRECT may legitimately target. `2>/dev/null` is the
# most routine idiom in a worker command line, and writing a character device
# mutates no tree — judging these "outside the worktree" would deny half of every
# worker's commands, and a guard that falsely denies is a guard that gets
# disarmed. Scoped to redirect targets: `rm -rf /dev/null` is still judged as an
# ordinary destructive operand.
# `/dev/fd/*` is deliberately ABSENT. It is platform-divergent: on macOS it
# resolves to itself, but on Linux `/dev/fd` symlinks to `/proc/self/fd`, so
# abspath turns `/dev/fd/3` into `/proc/<pid>/fd/3` and the literal match here
# would silently stop working — a green-on-macOS/red-on-Linux split with the
# cause three frames away. Nothing is lost: an fd-numbered redirect is the
# `2>&1` form, which isFdDup handles before a target is ever emitted.
is_device_sink() {
  case "$1" in
    /dev/null|/dev/zero|/dev/stdout|/dev/stderr|/dev/tty) return 0 ;;
  esac
  return 1
}

# A redirect target that is NOT fully literal, judged by its LITERAL PREFIX: the
# leading run before the first metacharacter, cut back to the last `/`.
# `logs/$(date +%F).log` -> `logs/` -> in-tree -> allowed. `$HOME/leak`, `~/x`
# and a bare `$LOG` have NO directory-bearing prefix and stay denied.
#
# WHY a redirect gets this and a destructive verb does not: `> "$VAR"` is an
# everyday, benign shell idiom (this repo alone writes ~1,480 of them), while
# `rm -rf $VAR` is rare and is the F#932 incident shape itself. A redirect
# creates or truncates ONE file; a destructive verb at a computed path removes a
# TREE. Denying every variable redirect is exactly the false-positive class that
# gets a guard disarmed, after which coverage is zero. Same reasoning, and same
# redirect-only scope, as the device-sink allow-list above.
#
# HONEST LIMIT: the prefix proves the write STARTS from a contained directory,
# not that it stays there — an expansion evaluating to `../../etc/passwd` still
# climbs out. This is a disclosed, deliberate relaxation of a redirect-only
# check, not a containment proof.
redirect_prefix_contained() {
  local p="$1" base="$2" pre ap
  # Longest leading run with no metacharacter. Applied successively, each strip
  # runs on the already-truncated string, so the result is the prefix before the
  # EARLIEST metacharacter. (Successive `%%` beats one bracket expression, whose
  # quoting is a portability trap for `[` and a backtick.)
  pre="$p"
  pre="${pre%%\$*}"; pre="${pre%%\`*}"; pre="${pre%%\**}"; pre="${pre%%\?*}"
  pre="${pre%%\[*}"; pre="${pre%%\~*}"; pre="${pre%%\{*}"
  # A leaf fragment constrains nothing (`out$X.log` could expand anywhere), so
  # require a directory component and keep only that.
  case "$pre" in
    */*) pre="${pre%/*}/" ;;
    *)   return 1 ;;
  esac
  ap=$(abspath "$pre" "$base")
  case "$ap" in "$wt"/*|"$wt") return 0 ;; esac
  is_allowlisted "$ap" && return 0
  return 1
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
  # operand its table row selects — plus one record per OUTPUT REDIRECT target,
  # which the shell writes on its own account:
  #   <baseKind>\t<baseVal>\t<verb|redirect-operator>\t<opndVal>
  # baseKind: CWD (no cd — resolve against the worktree cwd) | LIT <dir> |
  # NONLIT <dir> (a cd whose target the guard cannot resolve). A verb name never
  # contains `>`, so the operator in the third column is what tells the two
  # record kinds apart downstream. Bare redirect operators and command
  # separators end an operand run. Which tokens of that run become records is
  # the row's `select`; whether the verb counts as destructive at all is its
  # `arm`. See the operand-model table in the header.
  while IFS=$'\t' read -r bk bv verb op; do
    [ -n "$op" ] || continue

    # One record stream, two record kinds. A verb name never contains `>`, so the
    # redirect operator standing in the verb column is self-identifying — no
    # extra field, no second loop. Both kinds run the SAME containment checks;
    # only the wording of the refusal (and the device-sink exemption) differ.
    case "$verb" in
      *'>'*) is_redirect=1; what="an output redirect ('$verb')" ;;
      *)     is_redirect=0; what="a destructive command ($verb)" ;;
    esac

    tgt=$(strip_quotes "$op")

    # $TMPDIR is an ALLOW-LISTED root whose value this guard knows exactly, so
    # resolve it rather than refusing it — denying a write to a root we
    # explicitly allow (`> "$TMPDIR/out.log"`) is incoherent. Redirect-only and
    # anchored at the start; every other expansion stays unresolved.
    if [ "$is_redirect" = 1 ] && [ -n "${TMPDIR:-}" ]; then
      # shellcheck disable=SC2016
      # The single quotes are the POINT: these patterns match the LITERAL text
      # `$TMPDIR` as the worker typed it into the command line. Expanding them
      # would match the resolved path, which the ordinary literal checks already
      # handle and which is not what arrives here.
      case "$tgt" in
        '${TMPDIR}'*) tgt="${TMPDIR%/}${tgt#\$\{TMPDIR\}}" ;;
        '$TMPDIR'*)   tgt="${TMPDIR%/}${tgt#\$TMPDIR}" ;;
      esac
    fi

    # An ABSOLUTE device-sink target resolves entirely on its own — the cd
    # context plays no part in it — so judging it against the base below would
    # deny `cd <outside> && ls 2>/dev/null`, an ordinary worker move whose
    # redirect writes nothing. Short-circuit ABOVE the base checks.
    if [ "$is_redirect" = 1 ] && is_device_sink "$tgt"; then continue; fi

    # Resolve the base dir the operand is relative to (the active cd context).
    basedir="$cwd"
    if [ "$bk" = "NONLIT" ]; then
      deny "build worktree guard (Bash): $what runs after 'cd $bv', whose target the guard cannot resolve statically (it contains an expansion, substitution, or glob), so it cannot prove the command stays inside the worktree root '$wt'. cd to a literal path under '$wt' first, or drop the cd. (foundation #1087/#932 — worker Bash must not escape the write-jail.)"
    fi
    if [ "$bk" = "LIT" ]; then
      bdir=$(abspath "$(strip_quotes "$bv")")
      case "$bdir" in
        "$wt"/*|"$wt") basedir="$bdir" ;;
        *) if is_allowlisted "$bdir"; then basedir="$bdir"
           else deny "build worktree guard (Bash): $what runs after 'cd $bv' → '$bdir', which is OUTSIDE the active worktree root '$wt'. A build worker must operate only inside its own worktree (or /tmp). (foundation #1087/#932.)"
           fi ;;
      esac
    fi

    # A non-literal operand is unprovable → deny (the exact F#932 shape). A
    # redirect gets one relief first: a literal directory prefix it can be
    # judged by (see redirect_prefix_contained for why redirects and not verbs).
    if is_nonliteral "$tgt"; then
      if [ "$is_redirect" = 1 ] && redirect_prefix_contained "$tgt" "$basedir"; then
        continue
      fi
      deny "build worktree guard (Bash): $what targets '$op', a NON-LITERAL path — it contains an expansion, command substitution, or glob whose value the guard cannot resolve, so it cannot prove the target stays inside the worktree root '$wt'. This is the F#932 failure shape ('rm -rf \"\$(dirname \"\$(pwd)\")\"' wiped ~/dev). Re-issue with a literal path typed in full under '$wt' (or /tmp/\$TMPDIR) — or, for a redirect, with a literal directory prefix such as 'logs/\$NAME'. (foundation #1087/#932.)"
    fi

    ap=$(abspath "$tgt" "$basedir")

    # Inside the worktree, or allow-listed, or a gitignored in-tree copy → OK.
    case "$ap" in "$wt"/*|"$wt") continue ;; esac
    is_allowlisted "$ap" && continue
    is_gitignored "$ap" && continue
    # Redirect-only: a character-device sink writes no tree (see is_device_sink).
    [ "$is_redirect" = 1 ] && is_device_sink "$ap" && continue

    if [ "$is_redirect" = 1 ]; then
      deny "build worktree guard (Bash): $what writes '$ap', which is OUTSIDE the active worktree root '$wt'. The shell performs a redirect itself — it truncates/creates that file whatever the command is — so it is contained on the same terms as a destructive operand. Re-issue with a path under '$wt'. Allowed exceptions: /tmp, \$TMPDIR, gitignored source copies, and character-device sinks such as /dev/null. (foundation #1355; #1087/#932.)"
    fi
    deny "build worktree guard (Bash): $what targets '$ap', which is OUTSIDE the active worktree root '$wt'. A build worker must delete/move only inside its own pre-created worktree (foundation #1087/#932 — worker Bash wiped ~/dev by escaping the write-jail). Re-issue with a path under '$wt'. Allowed exceptions: /tmp, \$TMPDIR, and gitignored source copies."
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

      # An apostrophe, built by code point: this whole awk program is a
      # single-quoted shell string, so the character cannot be written literally.
      SQ=sprintf("%c",39)

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
    # --- OUTPUT REDIRECTS (foundation#1355) --------------------------------
    # NB: this awk program is a single-quoted shell string — no apostrophes.
    #
    # Length of the redirect operator at the START of s, or 0 if s does not begin
    # with one. Covers `>`, `>>`, `>&`, `>|` (force-truncate — the SAME write, and
    # missing it left the real target unchecked), each with an optional `[fd]` or
    # `&` prefix. The fd prefix belongs to the operator ONLY when it is entirely
    # digits (or `&`) — that is bash`s own rule, and it is why `echo x2>/f` passes
    # `x2` to echo and redirects to /f rather than treating 2 as a descriptor.
    function redirOpLen(s,   p,c,pre){
      p=index(s,">")
      if(p==0) return 0
      pre=substr(s,1,p-1)
      if(pre!="" && pre!="&" && pre !~ /^[0-9]+$/) return 0
      c=substr(s,p+1,1)
      if(c==">"||c=="&") p=p+1
      if(substr(s,p+1,1)=="|") p=p+1
      return p
    }
    function isRedirTok(s){ return (redirOpLen(s)>0) }
    # Split a redirect token into ROP (operator) and RTGT (glued target, "" when
    # the target is the NEXT token). RAMP=1 marks an operator ENDING in `&` (the
    # `>&` family), whose target may be an fd rather than a file — the caller
    # decides via isFdDup, because for a BARE `>&` the deciding word is the next
    # token. `&>` ends in `>`, so it is correctly NOT an fd form.
    function redirParse(s,   ol){
      ROP=""; RTGT=""; RAMP=0
      ol=redirOpLen(s)
      if(ol==0) return 0
      ROP=substr(s,1,ol); RTGT=substr(s,ol+1)
      if(substr(ROP,length(ROP),1)=="&") RAMP=1
      # `>(cmd)` is process substitution — a WORD belonging to the command line,
      # not a redirect, and never a path this guard can judge.
      if(substr(RTGT,1,1)=="("){ ROP=""; RTGT=""; RAMP=0; return 0 }
      return 1
    }
    # WORD-GLUED REDIRECTS. Bash treats `>` as a metacharacter ANYWHERE unquoted
    # in a word, not only at the start of one: `date>/etc/passwd` really does
    # truncate /etc/passwd, and whitespace splitting alone hides it inside the
    # word `date>/etc/passwd`, which resolves to nothing and is never judged. So
    # re-split every unquoted token at its embedded operators BEFORE the walk.
    # CONSERVATIVE by construction: a token containing any quote — or a `(`, which
    # marks process substitution — is left INTACT, because inside quotes a `>` is
    # data and mis-splitting it would be a FALSE DENY. The residual cost is that a
    # quoted word hiding a real redirect stays unsplit; it still cannot escape,
    # since the whole token remains subject to the ordinary checks.
    function splitRedirWords(count,   si,s,p,ol,rest,q,cnt,guard){
      cnt=0
      for(si=1;si<=count;si++){
        s=t[si]
        if(s=="") continue
        if(index(s,"\"")||index(s,SQ)||index(s,"(")){ cnt++; u[cnt]=s; continue }
        guard=0
        while(s!="" && guard<64){
          guard++
          p=index(s,">")
          if(p==0){ cnt++; u[cnt]=s; s=""; break }
          ol=redirOpLen(s)
          if(ol==0){
            # A non-fd word prefix — bash ends the WORD at the `>`.
            cnt++; u[cnt]=substr(s,1,p-1); s=substr(s,p); continue
          }
          # s starts with the operator: take operator+target, stopping the target
          # at a following operator so `date>/a>/b` splits into both redirects.
          rest=substr(s,ol+1)
          q=index(rest,">")
          if(q>0){ cnt++; u[cnt]=substr(s,1,ol) substr(rest,1,q-1); s=substr(rest,q) }
          else   { cnt++; u[cnt]=substr(s,1,ol) rest; s="" }
        }
      }
      return cnt
    }
    # `>&WORD` names NO file only when WORD is an fd number or `-` (`2>&1`,
    # `>&-`). A NON-numeric WORD is bash`s both-streams FILE redirect and stays a
    # containment target — treating every `>&` as a dup would let `2>&$FD`
    # through unchecked, which the old flat walker did catch (as a non-literal
    # operand). This is the one place the redirect model must NOT relax.
    function isFdDup(w){ return (w ~ /^[0-9]+$/ || w=="-") }
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
      # Re-split words at embedded redirect operators before anything else reads
      # the stream — `date>/etc/passwd` is a redirect, not a word (see
      # splitRedirWords). Every later step sees the corrected tokens.
      n=splitRedirWords(n)
      for(ci=1;ci<=n;ci++) t[ci]=u[ci]
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

        # An output redirect is a write the SHELL performs, independent of the
        # verb — so it is emitted as its own record against the active cd
        # context, and the containment loop judges it on the same terms as an
        # operand. Checked BEFORE the verb probe: a redirect token is never a
        # verb key, and every token is reached here exactly once (the walker`s
        # index only ever moves forward), so no record is emitted twice.
        if(redirParse(tok)){
          rop=ROP; rtgt=RTGT; ramp=RAMP
          if(rtgt==""){
            # Bare operator: the target is the next token — unless that token is
            # a separator or another redirect, in which case the line is
            # malformed and there is nothing to judge.
            rj=i+1
            while(rj<=n && t[rj]=="") rj++
            if(rj<=n && !isSep(t[rj]) && !isRedirTok(t[rj])){ rtgt=t[rj]; i=rj }
          }
          if(rtgt!="" && !(ramp && isFdDup(rtgt))){ emit(baseKind,baseVal,rop,rtgt) }
          i++; continue
        }

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
          # A GLUED redirect (`2>/dev/null`) is not a path operand of this verb —
          # but it does NOT end the argument list either, and terminating the run
          # on it would hide everything after it: `rm -rf 2>/dev/null <outside>`
          # really does delete <outside>. So skip the redirect (and the target of
          # a bare form isSep does not cover, e.g. `&>`, `>&`, `3>`) and KEEP
          # COLLECTING. The BARE `>`/`>>`/`2>`/`2>>` forms still terminate the run
          # via isSep above — long-standing behavior, deliberately unchanged.
          # The main walker re-reaches this token and judges it as a redirect.
          # redirParse (NOT the looser isRedirTok) is the predicate, so the two
          # sites agree on what counts: `>(cmd)` is process substitution, stays
          # an ordinary token here, and does not drop the token after it.
          if(redirParse(x)){
            j++
            if(RTGT==""){
              while(j<=n && t[j]=="") j++
              if(j<=n && !isSep(t[j]) && !isRedirTok(t[j])) j++
            }
            continue
          }
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
