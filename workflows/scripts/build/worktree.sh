#!/usr/bin/env bash
#
# build worktree lifecycle — the deterministic-spine script that owns the
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
# Output contract — CLOSED outcome set, one structured JSON line per outcome,
# no prose (the orchestrator branches on `.outcome`, never parses prose):
#   create →  {"outcome":"CREATED","path":…,"branch":…,"base":…}
#   remove →  {"outcome":"REMOVED"|"NOT_FOUND","path":…,"branch":…}
#   prune  →  one line per <repo>.wt/* worktree:
#             {"outcome":"PRUNED"|"SKIPPED_DIRTY"|"SKIPPED_UNMERGED","path":…,"branch":…}
#   deps-merged → {"outcome":"DEPS_MERGED"} | {"outcome":"DEPS_UNMERGED","unmerged":[…]}
#   error  →  {"outcome":"ERROR","error":…} + non-zero exit
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }

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
  # not spine git ops, so it does not interfere.
  git -C "$wt_path" rm -q --cached --ignore-unmatch .build-verification.md 2>/dev/null || true
  if ! git -C "$wt_path" diff --cached --quiet; then
    git -C "$wt_path" commit -q \
      -m "chore: untrack dev-local build-verification artifact (#529)" \
      -m "info/exclude can't untrack an already-committed file; do it once here so /build serial-merge stops conflicting on it." \
      || die "self-heal untrack-commit failed in '$wt_path'"
  fi

  jq -cn --arg path "$wt_path" --arg branch "$branch" --arg base "origin/$default" \
    '{outcome:"CREATED", path:$path, branch:$branch, base:$base}'
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
  local repo="$1" wt_path="$2" branch="$3" default="$4" force="$5" head
  head="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)" || head=""

  # Conservative gate 1: only a branch fully merged into origin/<default> is
  # removable — an unmerged worktree holds unlanded work, --force or not.
  if [ -z "$head" ] || ! git -C "$repo" merge-base --is-ancestor "$head" "origin/$default" 2>/dev/null; then
    jq -cn --arg path "$wt_path" --arg branch "$branch" '{outcome:"SKIPPED_UNMERGED", path:$path, branch:$branch}'
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
