#!/usr/bin/env bash
#
# build worktree lifecycle — the deterministic-machinery script that owns the
# per-item worktree create / remove / prune steps of /build (3b / 3h / 0.5).
# Epic #253 (spike #245): these steps are pure functions of observable git
# state with a closed outcome set, so they move from prose in build.md to
# code here. The LLM orchestrator invokes this script; it never hand-rolls
# `git worktree` for build items.
#
#   worktree.sh create <repo-root> <slug>        # add worktree + drop guard marker
#   worktree.sh remove <repo-root> <slug>        # remove worktree + branch + marker
#   worktree.sh prune  <repo-root> [--force]     # sweep merged <repo>.wt/* worktrees
#   worktree.sh deps-merged <repo-root> <shas>   # gate: all comma-sep SHAs merged?
#
# Deterministic layout (pure function of the slug — never reported back by a
# worker): path `<repo-root>.wt/<slug>`, branch `build/<slug>`, based on
# `origin/<default>`.
#
# Guard marker (#171/#212): `create` drops a `.build-guard` marker file in
# the new worktree root. The PreToolUse write-jail hook
# (claude/hooks/build-worktree-guard.sh) arms itself by reading that marker
# — per-worktree state, so N concurrent sessions on one host arm independently
# (the env-var arming this replaces was never settable per-Agent-spawn and a
# host-wide value would mis-target across sessions). `remove` and `prune`
# clean the marker up with the worktree.
#
# Arming self-test (foundation#1352): dropping the marker only ARMS a hook that
# is actually REACHED, so `create` immediately PROVES the jail rather than
# assuming it — see § Write-jail arming self-test below. The verdict rides the
# CREATED line as `guard`/`guard_detail`; anything but ARMED also prints a loud
# stderr banner. The probe never blocks a create.
#
# Output contract — CLOSED outcome set, one structured JSON line per outcome,
# no prose (the orchestrator branches on `.outcome`, never parses prose):
#   create →  {"outcome":"CREATED","path":…,"branch":…,"base":…,
#              "guard":"ARMED"|"UNARMED"|"UNKNOWN","guard_detail":…}
#   remove →  {"outcome":"REMOVED"|"NOT_FOUND","path":…,"branch":…}
#   prune  →  one line per <repo>.wt/* worktree:
#             {"outcome":"PRUNED"|"SKIPPED_FRESH"|"SKIPPED_DIRTY"|"SKIPPED_UNMERGED","path":…,"branch":…}
#   deps-merged → {"outcome":"DEPS_MERGED"} | {"outcome":"DEPS_UNMERGED","unmerged":[…]}
#   error  →  {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

# merged_detect_is_merged (#171/#173) — merge-queue-safe merged-detection
# (gh pr view state, falling back to a squash-safe cherry heuristic) used by
# prune_one below to reclaim a squash/rebase-merged branch whose tip is NOT an
# ancestor of origin/<default> even though it landed. Sourced by repo-relative
# path from this script's own location so it resolves regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/merged-detect.sh
source "$SCRIPT_DIR/lib/merged-detect.sh"

# fd 3 = the script's real stdout. Helpers like resolve_repo run inside
# command substitutions, where a die()'s ERROR line would be captured by the
# caller instead of reaching the orchestrator — emitting via fd 3 keeps the
# structured error on the real stdout regardless of call context.
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: worktree.sh create <repo-root> <slug> | remove <repo-root> <slug> | prune <repo-root> [--force] | deps-merged <repo-root> <sha,sha,...>"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate the repo root: must exist, be a git work tree, and BE the
# toplevel (not a subdir) — the deterministic `<repo-root>.wt/<slug>` path is
# derived from it, so a subdir would silently scatter worktrees.
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || die "repo-root '$arg' does not exist"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "repo-root '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || die "repo-root '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$repo"
}

# Validate the slug (plan-schema shape). It feeds rm -rf'able paths and branch
# names, so reject anything outside the closed character set.
validate_slug() {
  local slug="$1"
  case "$slug" in
    *[!a-z0-9-]*|"") die "slug '$slug' invalid — must match [a-z0-9-]+" ;;
  esac
}

# The repo's default branch, from origin's HEAD (falling back to main/master).
default_branch() {
  local repo="$1" ref b
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for b in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s\n' "$b"
      return 0
    fi
  done
  return 1
}

# Append the build tooling markers to the shared info/exclude (idempotent)
# so they never show up as untracked files in any worktree's `git status` — a
# worker's `git add -A` must not be able to commit them. Covers the write-jail
# marker (`.build-guard`, #171/#212) and the verification-surface artifact
# (`.build-verification.md`, #418 — the worker writes its PR verification
# surface there and returns only the path; pr.sh reads it directly).
exclude_marker() {
  local repo="$1" common f
  common="$(git -C "$repo" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$repo/$common" ;; esac
  mkdir -p "$common/info"
  for f in .build-guard .build-verification.md; do
    grep -qxF "$f" "$common/info/exclude" 2>/dev/null \
      || echo "$f" >> "$common/info/exclude"
  done
}

# Tear down whatever occupies the deterministic path (registered worktree,
# stale dir, stale registration, stale branch) so create can always re-add.
clear_path() {
  local repo="$1" wt_path="$2" branch="$3"
  if [ -e "$wt_path" ]; then
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null \
      || rm -rf "$wt_path"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" branch -D "$branch" >/dev/null 2>&1 \
      || die "could not delete stale branch '$branch' (checked out elsewhere?)"
  fi
}

# --- Write-jail arming self-test (foundation#1352; the F#932 incident) -------
#
# `create` drops the `.build-guard` marker — but a marker only arms a hook that
# is actually REACHED. Every real failure of this jail has been a REACHABILITY
# failure, not a logic failure: a stale vendored hook body, a settings.json
# matcher still reading `Edit|Write|MultiEdit` (which runs the file-tool jail
# but leaves worker Bash UN-jailed — the exact F#932 shape, where a worker's
# `rm -rf "$(dirname "$(pwd)")"` resolved to ~/dev and wiped every checkout and
# the local knowledge store), a consuming repo that never registered the hook,
# a non-executable hook file, a missing `jq` on the hook's PATH. Every one of
# those exits 0 SILENTLY and is individually invisible. One probe, at the one
# moment it matters — right after arming, right before a worker is handed this
# worktree — collapses them all into a single per-run signal.
#
# Two halves, because either alone is insufficient:
#   1. REGISTRATION — a PreToolUse entry whose matcher covers `Bash` must point
#      at an EXISTING, runnable build-worktree-guard hook file. A perfectly
#      correct hook can still be unwired, and the matcher half is precisely the
#      F#932 gap.
#   2. BEHAVIOR — a synthetic deny-shaped payload is piped at THE REGISTERED
#      HOOK FILE (never at this repo's own source copy — the point is to test
#      the file the harness would actually reach, which may be a stale vendored
#      one) and the verdict asserted to be `permissionDecision:"deny"`. One
#      payload per arm.
#
# NEVER a false ARMED. Asserting safety that isn't there is strictly worse than
# reporting UNKNOWN, so every ambiguity resolves AWAY from ARMED: an
# unresolvable hook path, a hook that hangs, and a registration this probe
# cannot prove the worker actually loads (see `parent-only` below) all report
# UNKNOWN. Only an observed deny from a registration on an unambiguously-loaded
# surface earns ARMED.
#
# NOT an arbitrary-command runner. The probe extracts the HOOK FILE PATH out of
# the registration string and runs that file directly; it never `sh -c`s the
# registration text. `worktree.sh create` must not become a way for repo-tracked
# settings content to execute in the orchestrator's process, outside the very
# jail it is testing. The cost is small: a `bash <hook>` vs bare-path
# registration difference is instead checked explicitly (`hook-not-executable`).
#
# FAIL-OPEN, ALWAYS. The probe never blocks a create, and this is enforced
# rather than emergent: the call site is `|| true`, every arm is bounded by a
# wall-clock tick budget, and the bounded child is launched in its OWN PROCESS
# GROUP with fd 3 CLOSED. Both of those matter — worktree.sh holds the script's
# real stdout on fd 3 (see `exec 3>&1` above), and the orchestrator reads the
# CREATED line by capturing stdout, so a hung hook inheriting fd 3 would hold
# that capture pipe open and wedge `create` for the hook's full duration no
# matter what this tick budget said. A probe that can wedge a build is worse
# than the gap it closes (the same posture the guard family itself takes).
GUARD_STATUS="UNKNOWN"
GUARD_DETAIL="probe-not-run"

# The two synthetic payload targets. Both are only ever READ by the hook —
# never executed, never created:
#   * the Bash target is the verbatim F#932 command. Its operand is NON-LITERAL,
#     which an armed hook denies before it resolves anything — so this probe is
#     immune to the hook's /tmp//$TMPDIR allow-list and gives the same verdict
#     for a worktree in a tmpdir fixture as for one under $HOME.
#   * the Write target is a nonexistent root-level sentinel: outside every
#     worktree AND outside that allow-list, for the same reason.
# shellcheck disable=SC2016  # the $(…) is the literal incident text, not an expansion
GUARD_PROBE_BASH_CMD='rm -rf "$(dirname "$(pwd)")"'
GUARD_PROBE_WRITE_PATH='/build-worktree-guard-probe/never-written'
# Per-arm wall-clock bound, in 0.1s ticks. An internal robustness bound, not an
# operator knob: it exists only so a wedged hook cannot wedge a build. Sized
# well above the real hook's cost (which shells out to git/jq/awk per call, and
# measures ~0.2s) so a loaded runner does not produce a crying-wolf UNKNOWN —
# a banner operators learn to scroll past converts straight back into the
# silent un-armed state F#932 shipped in.
GUARD_PROBE_TICKS=100

# guard_matcher_covers_bash <matcher> — does a settings.json PreToolUse matcher
# select the Bash tool? Deliberately CONSERVATIVE, and deliberately not a
# re-implementation of the harness's regex engine: the wildcards below, or an
# exact `Bash` alternative in a `|`-separated list. A cleverer matcher that this
# says no to costs a spurious UNARMED banner; one it wrongly says yes to costs a
# false ARMED, which is the outcome this whole probe exists to prevent.
guard_matcher_covers_bash() {
  local m="$1" alt rest
  case "$m" in
    ""|"*"|".*"|"^.*$") return 0 ;;
  esac
  rest="$m"
  while [ -n "$rest" ]; do
    alt="${rest%%|*}"
    if [ "$alt" = "Bash" ]; then
      return 0
    fi
    case "$rest" in
      *"|"*) rest="${rest#*|}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

# guard_hook_file <registration-command> <wt> — pull the hook FILE out of a
# registration string and print "<bare>\t<abs-path>", where <bare> is 1 when the
# hook is invoked directly (so its exec bit is load-bearing) and 0 when it runs
# under an interpreter (`bash <hook>`). Prints nothing when no hook token can be
# resolved. Expands only the variables Claude Code itself substitutes into a
# hook command; anything still carrying a `$` is unresolvable by design.
guard_hook_file() {
  local cmd="$1" wt="$2" i=0 t
  local -a toks=()
  IFS=' ' read -r -a toks <<<"$cmd"
  while [ "$i" -lt "${#toks[@]}" ]; do
    t="${toks[$i]}"
    t="${t#[\"\']}"; t="${t%[\"\']}"   # a quoted path compares as a bare one
    case "$t" in
      *build-worktree-guard*.sh)
        t="${t//\$\{CLAUDE_PROJECT_DIR\}/$wt}"
        t="${t//\$CLAUDE_PROJECT_DIR/$wt}"
        t="${t//\$\{HOME\}/$HOME}"
        t="${t//\$HOME/$HOME}"
        # shellcheck disable=SC2088  # matching a literal ~ in the registration TEXT, not expanding one
        case "$t" in "~/"*) t="$HOME/${t#\~/}" ;; esac
        case "$t" in *'$'*|*'`'*) return 0 ;; esac   # unresolvable → no verdict
        case "$t" in /*) ;; *) t="$wt/$t" ;; esac
        if [ "$i" -eq 0 ]; then printf '1\t%s' "$t"; else printf '0\t%s' "$t"; fi
        return 0
        ;;
    esac
    i=$((i + 1))
  done
}

# guard_run_hook <hook-file> <payload> <wt> — run the REGISTERED hook file the
# way Claude Code would (cwd = the worktree, CLAUDE_PROJECT_DIR exported) and
# print its stdout. Bounded; on timeout it prints the timeout sentinel instead.
guard_run_hook() {
  local hook="$1" payload="$2" wt="$3" out pid ticks=0 timedout=0
  out="$(mktemp "${TMPDIR:-/tmp}/wt-guard-probe.XXXXXX")" || return 0
  # `set -m` puts the child in its own process group so the whole tree can be
  # signalled below; `3>&-` closes the inherited real-stdout fd so an abandoned
  # hook can never hold the caller's stdout-capture pipe open.
  set -m
  (
    cd "$wt" 2>/dev/null || exit 0
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$wt" bash "$hook" 2>/dev/null
  ) 3>&- >"$out" 2>/dev/null &
  pid=$!
  set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$GUARD_PROBE_TICKS" ]; then
      # Signal the GROUP, not just the subshell: the hook itself is a
      # grandchild and would otherwise be orphaned, still running. TERM first
      # so it can flush, then KILL.
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      timedout=1
      break
    fi
    ticks=$((ticks + 1))
    sleep 0.1 || true
  done
  wait "$pid" 2>/dev/null || true
  if [ "$timedout" -eq 1 ]; then
    printf '__GUARD_PROBE_TIMEOUT__' || true
  else
    cat "$out" 2>/dev/null || true
  fi
  rm -f "$out" || true
}

# guard_probe_arm <hook-file> <payload> <wt> — prints deny | allow | timeout.
# NOTE that "no output at all" is `allow`, not an error: a hook that exits 0
# silently IS the dominant silent-pass failure (missing jq, stale inert body,
# wrong file) this probe exists to catch.
guard_probe_arm() {
  local out
  out="$(guard_run_hook "$1" "$2" "$3")"
  case "$out" in
    *'__GUARD_PROBE_TIMEOUT__'*) printf 'timeout' ;;
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'allow' ;;
  esac
}

# guard_probe <wt_path> <repo> — sets GUARD_STATUS + GUARD_DETAIL. Never fails.
guard_probe() {
  local wt="$1" repo="$2" f matcher cmd bash_payload write_payload hookinfo
  local reg_cmd="" reg_src="" reg_matcher="" saw_any=0 saw_matcher="none"
  local bash_arm="n/a" write_arm="n/a" hook_file="" hook_bare=0 ambiguous=0
  GUARD_STATUS="UNKNOWN"
  GUARD_DETAIL="probe-error"

  # Both registration surfaces (#72), plus their .local siblings: Claude Code
  # MERGES hook entries across settings files rather than overriding, so every
  # file is scanned and the FIRST Bash-covering registration wins. The order is
  # load-bearing — unambiguously-loaded surfaces first, so the parent-checkout
  # fallback below is only ever reached when nothing better armed the jail.
  for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
           "$wt/.claude/settings.json" "$wt/.claude/settings.local.json" \
           "$repo/.claude/settings.json" "$repo/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r matcher cmd; do
      [ -n "$cmd" ] || continue
      case "$cmd" in *build-worktree-guard*) ;; *) continue ;; esac
      matcher="${matcher#M}"   # jq prefixes every matcher so "" survives the read
      saw_any=1
      if [ "$saw_matcher" = "none" ]; then saw_matcher="${matcher:-<empty>}"; fi
      if guard_matcher_covers_bash "$matcher"; then
        if [ -z "$reg_cmd" ]; then
          reg_cmd="$cmd"; reg_src="$f"; reg_matcher="${matcher:-<empty>}"
        fi
      fi
    done < <(jq -r '
      (.hooks.PreToolUse // [])[]
      | ("M" + (.matcher // "")) as $m
      | (.hooks // [])[]
      | select((.type // "command") == "command")
      | [$m, (.command // "")] | @tsv' "$f" 2>/dev/null || true)
  done

  if [ -z "$reg_cmd" ]; then
    GUARD_STATUS="UNARMED"
    if [ "$saw_any" -eq 1 ]; then
      # The F#932 shape: the file-tool jail runs, worker Bash does not.
      GUARD_DETAIL="registration=matcher-lacks-bash matcher=$saw_matcher bash_arm=n/a write_arm=n/a"
    else
      GUARD_DETAIL="registration=missing matcher=n/a bash_arm=n/a write_arm=n/a"
    fi
    return 0
  fi

  # A project-level registration found ONLY in the parent checkout is not proof.
  # `.claude/settings.local.json` is gitignored and `.claude/settings.json` may
  # be untracked, so either can exist in the parent and be ABSENT from a fresh
  # worktree — and which project dir a spawned worker resolves settings against
  # is not something this script can observe. Probe it anyway (the hook body is
  # still worth testing) but cap the verdict at UNKNOWN rather than claim ARMED.
  case "$reg_src" in
    "$repo/.claude/"*)
      if [ ! -f "$wt/.claude/${reg_src##*/}" ]; then ambiguous=1; fi
      ;;
  esac

  hookinfo="$(guard_hook_file "$reg_cmd" "$wt")"
  IFS=$'\t' read -r hook_bare hook_file <<<"$hookinfo" || true
  if [ -z "$hookinfo" ] || [ -z "$hook_file" ]; then
    GUARD_STATUS="UNKNOWN"
    GUARD_DETAIL="registration=hook-path-unresolvable source=$reg_src matcher=$reg_matcher bash_arm=n/a write_arm=n/a"
    return 0
  fi
  if [ ! -f "$hook_file" ]; then
    GUARD_STATUS="UNARMED"
    GUARD_DETAIL="registration=hook-file-missing source=$reg_src hook=$hook_file bash_arm=n/a write_arm=n/a"
    return 0
  fi
  # A bare-path registration is exec'd by the harness, so a 100644 hook file
  # simply never runs — one of the named silent-failure modes.
  if [ "$hook_bare" = "1" ] && [ ! -x "$hook_file" ]; then
    GUARD_STATUS="UNARMED"
    GUARD_DETAIL="registration=hook-not-executable source=$reg_src hook=$hook_file bash_arm=n/a write_arm=n/a"
    return 0
  fi

  bash_payload="$(jq -cn --arg cwd "$wt" --arg c "$GUARD_PROBE_BASH_CMD" \
    '{tool_name:"Bash", tool_input:{command:$c}, cwd:$cwd}')" || return 0
  write_payload="$(jq -cn --arg cwd "$wt" --arg p "$GUARD_PROBE_WRITE_PATH" \
    '{tool_name:"Write", tool_input:{file_path:$p}, cwd:$cwd}')" || return 0

  bash_arm="$(guard_probe_arm "$hook_file" "$bash_payload" "$wt")"
  write_arm="$(guard_probe_arm "$hook_file" "$write_payload" "$wt")"

  if [ "$bash_arm" = "timeout" ] || [ "$write_arm" = "timeout" ]; then
    GUARD_STATUS="UNKNOWN"
  elif [ "$bash_arm" = "deny" ] && [ "$write_arm" = "deny" ]; then
    if [ "$ambiguous" -eq 1 ]; then GUARD_STATUS="UNKNOWN"; else GUARD_STATUS="ARMED"; fi
  else
    GUARD_STATUS="UNARMED"
  fi
  if [ "$ambiguous" -eq 1 ]; then
    GUARD_DETAIL="registration=parent-only source=$reg_src matcher=$reg_matcher bash_arm=$bash_arm write_arm=$write_arm"
  else
    GUARD_DETAIL="registration=ok source=$reg_src matcher=$reg_matcher bash_arm=$bash_arm write_arm=$write_arm"
  fi
}

# guard_report <wt_path> <repo> — surface the verdict in the run output. ARMED
# is one quiet line; anything else is a LOUD banner, because a silently
# un-armed jail is exactly the state F#932 shipped in.
guard_report() {
  local wt="$1" repo="$2"
  if [ "$GUARD_STATUS" = "ARMED" ]; then
    printf 'build-worktree-guard: ARMED for %s (%s)\n' "$wt" "$GUARD_DETAIL" >&2
    return 0
  fi
  {
    printf '\n'
    printf '!! ==========================================================================\n'
    printf '!! WRITE-JAIL %s — %s\n' "$GUARD_STATUS" "$wt"
    printf '!! probe: %s\n' "$GUARD_DETAIL"
    printf '!!\n'
    printf '!! A worker handed this worktree may NOT be structurally prevented from\n'
    printf '!! writing or DELETING outside it. This is the F#932 state: a worker ran\n'
    printf '!!   %s\n' "$GUARD_PROBE_BASH_CMD"
    printf '!! which resolved to a parent directory and wiped every checkout under it.\n'
    printf '!!\n'
    printf '!! The build CONTINUES (this probe fails open). To arm the jail, register\n'
    printf '!! claude/hooks/build-worktree-guard.sh as a PreToolUse hook in either:\n'
    printf '!!   user-global    %s\n' "$HOME/.claude/settings.json"
    printf '!!   consuming repo %s\n' "$repo/.claude/settings.json"
    printf '!! and make sure its matcher includes Bash — an Edit|Write|MultiEdit matcher\n'
    printf '!! runs the file-tool jail but leaves worker Bash un-jailed.\n'
    case "$GUARD_DETAIL" in
      *registration=parent-only*)
        printf '!!\n'
        printf '!! parent-only: the registration was found ONLY in the parent checkout,\n'
        printf '!! in a file this worktree does not carry (untracked or gitignored), so\n'
        printf '!! it cannot be proven to apply to a worker running here. TRACK\n'
        printf '!! .claude/settings.json in the repo, or register it user-global.\n'
        ;;
    esac
    printf '!! ==========================================================================\n'
    printf '\n'
  } >&2
}

cmd_create() {
  local repo slug wt_path branch default out
  repo="$(resolve_repo "$1")"
  slug="$2"
  validate_slug "$slug"
  wt_path="${repo}.wt/${slug}"
  branch="build/${slug}"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"

  # The path is a pure function of the slug — anything already there is debris
  # from an aborted run; force-remove and re-add.
  clear_path "$repo" "$wt_path" "$branch"

  # Freshen the base before branching off it. `worktree add` bases the new branch
  # on the LOCAL origin/<default> ref, which goes stale between runs — branching
  # off a stale base silently builds the item on an old main (two stale-base
  # incidents in the workflow-evals run, #337). Best-effort, mirroring cmd_prune:
  # offline (tests/planes) is fine — the local ref is then the conservative basis.
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true

  mkdir -p "${repo}.wt"
  if ! out="$(git -C "$repo" worktree add -b "$branch" "$wt_path" "origin/$default" 2>&1)"; then
    die "git worktree add failed: $out"
  fi

  # Drop the guard marker — this is what arms the PreToolUse write-jail for
  # any worker running in this worktree (per-worktree, concurrency-safe).
  jq -cn --arg slug "$slug" --arg branch "$branch" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{slug:$slug, branch:$branch, created:$created}' > "$wt_path/.build-guard"
  exclude_marker "$repo"

  # PROVE the jail is armed before this worktree is handed to a worker — the
  # marker is now in place, so the hook (if it is reached at all) must deny.
  # `|| true` is load-bearing, not decorative: without it a future edit that
  # leaves guard_probe returning non-zero would abort cmd_create mid-flight
  # under `set -e` and suppress the CREATED line entirely — a broken output
  # contract rather than a degraded verdict. Fail-open, enforced not emergent.
  guard_probe "$wt_path" "$repo" || true
  guard_report "$wt_path" "$repo" || true

  # Self-heal (#529): the verification-surface artifact must stay a dev-local,
  # uncommitted file — exclude_marker handles that for UNtracked files, but
  # info/exclude is powerless against a file that was committed before the exclude
  # existed. In consuming repos where `.build-verification.md` is tracked, every
  # item re-commits its own copy, so a multi-item level's serial-merge hits a
  # content conflict on it. Untrack it here as its OWN commit (keeps the worker's
  # feature diff clean); all branches at a level make the identical removal, which
  # merges delete-vs-delete cleanly, and once the repo's main is clean this is a
  # no-op. Targets only the surface artifact — .build-guard is never committed
  # (jq-written above + excluded). The guard hook gates the worker's Edit/Write,
  # not machinery git ops, so it does not interfere.
  git -C "$wt_path" rm -q --cached --ignore-unmatch .build-verification.md 2>/dev/null || true
  if ! git -C "$wt_path" diff --cached --quiet; then
    git -C "$wt_path" commit -q \
      -m "chore: untrack dev-local build-verification artifact (#529)" \
      -m "info/exclude can't untrack an already-committed file; do it once here so /build serial-merge stops conflicting on it." \
      || die "self-heal untrack-commit failed in '$wt_path'"
  fi

  jq -cn --arg path "$wt_path" --arg branch "$branch" --arg base "origin/$default" \
         --arg guard "$GUARD_STATUS" --arg guard_detail "$GUARD_DETAIL" \
    '{outcome:"CREATED", path:$path, branch:$branch, base:$base,
      guard:$guard, guard_detail:$guard_detail}'
}

cmd_remove() {
  local repo slug wt_path branch existed=0 out
  repo="$(resolve_repo "$1")"
  slug="$2"
  validate_slug "$slug"
  wt_path="${repo}.wt/${slug}"
  branch="build/${slug}"

  if [ -e "$wt_path" ]; then
    existed=1
    rm -f "$wt_path/.build-guard"
    git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null \
      || rm -rf "$wt_path"
  fi
  git -C "$repo" worktree prune 2>/dev/null || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    existed=1
    if ! out="$(git -C "$repo" branch -D "$branch" 2>&1)"; then
      die "git branch -D $branch failed: $out"
    fi
  fi

  if [ "$existed" -eq 1 ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"REMOVED", path:$path, branch:$branch}'
  else
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"NOT_FOUND", path:$path, branch:$branch}'
  fi
}

cmd_prune() {
  local repo force="$1" default prefix line wt_path branch
  repo="$(resolve_repo "$2")"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"
  # Best-effort freshen of the merge target; offline (tests, planes) is fine —
  # the local origin/<default> is then the basis, which is conservative.
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true
  git -C "$repo" worktree prune 2>/dev/null || true

  prefix="${repo}.wt/"
  wt_path=""
  branch=""
  # `git worktree list --porcelain` blocks: worktree <path> / HEAD … / branch …
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        branch=""
        ;;
      "branch refs/heads/"*)
        branch="${line#branch refs/heads/}"
        ;;
      "")
        case "$wt_path" in
          "$prefix"*) prune_one "$repo" "$wt_path" "$branch" "$default" "$force" ;;
        esac
        wt_path=""
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain; echo)
}

prune_one() {
  local repo="$1" wt_path="$2" branch="$3" default="$4" force="$5" head merged
  local base_tip head_is_base="false"
  head="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || head=""

  # Conservative gate 1: only a branch whose PR actually merged is removable —
  # an unmerged worktree holds unlanded work, --force or not. Try the cheap,
  # network-free ancestor test first (covers the ordinary case); only fall
  # through to the merge-queue-safe helper (#171) when the tip is NOT an
  # ancestor — the squash/rebase-merge case the ancestor-only test misreads as
  # unmerged. Never weakens the floor: a genuinely-unmerged branch still fails
  # both checks and reports SKIPPED_UNMERGED.
  if [ -z "$head" ]; then
    merged="false"
  elif git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    merged="true"
    # …but ZERO COMMITS AHEAD is evidence of NO WORK YET, not of a merge
    # (#891). `create` bases the new branch on origin/<default>, so from
    # `create` until the worker's first commit a LIVE build worktree is
    # ancestor-identical to a finished, merged one — and a concurrent prune
    # from another session (prune is host-wide, not scoped to its caller's own
    # worktrees) force-removed the directory and deleted build/<slug> out from
    # under a running worker. A genuinely merged branch has commits of its own
    # that are ancestors of origin/<default>, so its tip is NOT equal to it;
    # `head == origin/<default>` cleanly separates "did work, then merged" from
    # "has not started". Stateless — no marker file or timestamp heuristic
    # (.build-guard is present in a live AND an abandoned worktree, so it does
    # not discriminate; the commit test does).
    base_tip="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" || base_tip=""
    if [ -n "$base_tip" ] && [ "$head" = "$base_tip" ]; then
      head_is_base="true"
    fi
  else
    # `|| merged="false"` guards the caller-misuse return (2, e.g. an empty
    # branch name for a detached-HEAD worktree) from tripping `set -e` — the
    # safe default either way is NOT merged, never an abort mid-sweep.
    merged="$(merged_detect_is_merged "$repo" "$branch" "$default")" || merged="false"
  fi
  if [ "$merged" != "true" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_UNMERGED", path:$path, branch:$branch}'
    return 0
  fi
  # Conservative gate 1b (#891): a zero-commit worktree is spared on the
  # DEFAULT path only. --force bypasses it exactly as it bypasses the dirty
  # gate below, because an aborted `worktree.sh create` leaves a legitimate
  # zero-commit worktree that must stay reapable — the guard protects the
  # default path without making stale fresh worktrees immortal.
  if [ "$head_is_base" = "true" ] && [ -z "$force" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_FRESH", path:$path, branch:$branch}'
    return 0
  fi
  # Conservative gate 2: never touch uncommitted changes unless --force (the
  # guard marker is excluded via info/exclude, so it never reads as dirt).
  if [ -z "$force" ] && [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_DIRTY", path:$path, branch:$branch}'
    return 0
  fi

  rm -f "$wt_path/.build-guard"
  git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  git -C "$repo" worktree prune 2>/dev/null || true
  case "$branch" in
    build/*)
      git -C "$repo" branch -D "$branch" >/dev/null 2>&1 || true
      ;;
  esac
  jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"PRUNED", path:$path, branch:$branch}'
}

# deps-merged — the dep-merge precondition gate for /build's 3b-0 (#108). Given a
# comma-separated list of commit SHAs (each the merged head of a `depends-on`
# target), report whether EVERY one is already an ancestor of origin/<default> —
# i.e. the depended-on PR has landed in the default branch. worktree.sh create
# bases a new item's branch on origin/<default>; gating create on this means the
# worker builds and self-verifies against MERGED dependency code, not a pre-merge
# base. An unknown/unfetched SHA (git errors) counts as UNMERGED (conservative).
cmd_deps_merged() {
  local repo default shas_csv sha
  repo="$(resolve_repo "$1")"
  shas_csv="$2"
  [ -n "$shas_csv" ] || die "deps-merged requires a non-empty comma-separated SHA list"
  default="$(default_branch "$repo")" || die "cannot resolve origin's default branch in '$repo'"
  # Freshen the merge target before the ancestry test — mirrors cmd_create /
  # cmd_prune. Offline (tests/planes) is fine: the local origin/<default> is then
  # the conservative basis (a not-yet-fetched merge simply reads as unmerged).
  git -C "$repo" fetch --quiet origin "$default" 2>/dev/null || true

  local unmerged=()
  local IFS=','
  for sha in $shas_csv; do
    [ -n "$sha" ] || continue
    if ! git -C "$repo" merge-base --is-ancestor "$sha" "origin/$default" 2>/dev/null; then
      unmerged+=("$sha")
    fi
  done

  if [ "${#unmerged[@]}" -eq 0 ]; then
    jq -cn '{outcome:"DEPS_MERGED"}'
  else
    printf '%s\n' "${unmerged[@]}" | jq -R . | jq -cs '{outcome:"DEPS_UNMERGED", unmerged:.}'
  fi
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  create)
    [ $# -eq 2 ] || usage
    cmd_create "$1" "$2"
    ;;
  remove)
    [ $# -eq 2 ] || usage
    cmd_remove "$1" "$2"
    ;;
  deps-merged)
    [ $# -eq 2 ] || usage
    cmd_deps_merged "$1" "$2"
    ;;
  prune)
    [ $# -ge 1 ] || usage
    repo_arg="$1"; shift
    force=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) force=1 ;;
        *) usage ;;
      esac
      shift
    done
    cmd_prune "$force" "$repo_arg"
    ;;
  *) usage ;;
esac
