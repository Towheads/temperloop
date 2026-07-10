#!/usr/bin/env bash
#
# Prune branches already merged into the base ref (default origin/main) for the
# git repo the current directory is in. Repo-agnostic by design: it reads the
# cwd's repo and its `origin/main`, so one file serves every checkout — there is
# no per-repo copy to keep in sync.
#
# Why this exists (F#551): `delete_branch_on_merge=true` is now enabled and
# honored by the merge queue on all four build repos, so newly-merged *remote*
# head branches auto-delete. But two gaps remain that the repo setting never
# covered: (1) merged *local* branches accumulate on a dev machine (ordinary
# `git checkout -b` work leaves them behind); (2) a historical backlog of
# pre-setting stale remote branches still exists. This helper sweeps both.
#
# DRY-RUN BY DEFAULT — it prints what it would delete and changes nothing. Pass
# --apply to actually delete.
#
# Merged-detection (#171/#173): a local branch is a delete candidate if EITHER
# it's a plain ancestor of $base (the ordinary case, `git merge-base
# --is-ancestor`, no network needed) OR the merge-queue-safe helper
# (merged-detect.sh: gh pr view state, falling back to a squash-safe cherry
# heuristic) independently confirms its PR merged even though the branch tip
# is NOT an ancestor — the squash/rebase-merge-queue topology the ancestor-only
# test misses. Deletion still defaults to `git branch -d` (refuses anything not
# fully merged — the safety floor); `-D` is used ONLY as a fallback for a
# branch the helper independently confirmed merged, never for an ordinary `-d`
# failure (e.g. in-use/worktree-bound), so a genuinely-unmerged branch is still
# refused exactly as before.
#
#   prune-merged-branches.sh                 # dry-run: list merged local branches
#   prune-merged-branches.sh --apply         # delete merged local branches
#   prune-merged-branches.sh --remote        # dry-run incl. merged remote heads
#   prune-merged-branches.sh --remote --apply# delete merged local + remote heads
#   prune-merged-branches.sh --base origin/develop --apply
#
set -euo pipefail

# shellcheck source=../workflows/scripts/build/lib/merged-detect.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../workflows/scripts/build/lib/merged-detect.sh"

base="origin/main"
apply=0
do_remote=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)  apply=1; shift ;;
    --remote) do_remote=1; shift ;;
    --base)   base="${2:?--base needs a ref}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "prune-merged-branches: unknown arg '$1'" >&2; usage 1 ;;
  esac
done

# Must be inside a work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "prune-merged-branches: not inside a git work tree" >&2
  exit 1
}

# Refresh remote-tracking refs and drop stale origin/* (the half git fetch --prune
# already handles; local/remote branch deletes below are the part nothing did).
echo "==> git fetch origin --prune"
git fetch origin --prune --quiet

git rev-parse --verify --quiet "$base" >/dev/null || {
  echo "prune-merged-branches: base ref '$base' not found (fetch failed?)" >&2
  exit 1
}

current="$(git symbolic-ref --quiet --short HEAD || true)"
# Strip the leading "origin/" so a remote base ("origin/main") protects the
# matching local/remote "main" from deletion too.
base_branch="${base#origin/}"

# Read newline-delimited stdin into a named array. Portable to bash 3.2 (macOS
# system bash) — `mapfile`/`readarray` are bash 4+ and this is a dev-machine
# local helper that must run under whatever bash is on PATH.
read_into() {
  local __name="$1" __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    eval "$__name+=(\"\$__line\")"
  done
}

# --- Local branches merged into base -----------------------------------------
# Exclude the current branch, main, and the base branch itself, then classify
# EVERY remaining local branch (#171/#173): ancestor-of-base is the fast,
# network-free path; a tip that is NOT an ancestor falls through to the
# merge-queue-safe helper, which catches a squash/rebase-merged branch the
# ancestor test alone would misreport as unmerged. `local_squash` tracks the
# subset confirmed ONLY via the helper — `git branch -d` refuses those (their
# tip genuinely isn't an ancestor), so the apply step below escalates those
# specific branches to `-D`.
all_local=()
read_into all_local < <(
  git branch --format='%(refname:short)' \
    | grep -vxE "main|${base_branch}|${current:-}" || true
)

repo_root="$(git rev-parse --show-toplevel)"
local_merged=()
local_squash=()
if [ "${#all_local[@]}" -gt 0 ]; then
  for b in "${all_local[@]}"; do
    if git merge-base --is-ancestor "$b" "$base" 2>/dev/null; then
      local_merged+=("$b")
    elif [ "$(merged_detect_is_merged "$repo_root" "$b" "$base_branch" 2>/dev/null || echo false)" = "true" ]; then
      local_merged+=("$b")
      local_squash+=("$b")
    fi
  done
fi

# --- Remote heads merged into base (opt-in) ----------------------------------
remote_merged=()
if [ "$do_remote" -eq 1 ]; then
  read_into remote_merged < <(
    git branch -r --merged "$base" --format='%(refname:short)' \
      | sed -n 's#^origin/##p' \
      | grep -vxE "HEAD|main|${base_branch}" || true
  )
fi

echo
if [ "${#local_merged[@]}" -eq 0 ]; then
  echo "Local branches merged into ${base}: none"
else
  echo "Local branches merged into ${base} (${#local_merged[@]}):"
  printf '  %s\n' "${local_merged[@]}"
fi
if [ "$do_remote" -eq 1 ]; then
  if [ "${#remote_merged[@]}" -eq 0 ]; then
    echo "Remote heads merged into ${base}: none"
  else
    echo "Remote heads merged into ${base} (${#remote_merged[@]}):"
    printf '  origin/%s\n' "${remote_merged[@]}"
  fi
fi
echo

if [ "$apply" -ne 1 ]; then
  echo "DRY RUN — nothing deleted. Re-run with --apply to delete."
  exit 0
fi

# --- Apply --------------------------------------------------------------------
# Delete locals ONE AT A TIME with per-branch failure tolerated (F#650). A
# worktree-bound branch ("error: cannot delete branch … used by worktree at …")
# — or any in-use branch — makes `git branch -d` exit non-zero; a single batched
# delete would then trip `set -e` and abort the script BEFORE the remote sweep,
# silently stranding the remote backlog. Looping + an `if` guard keeps one
# undeletable branch from blocking the rest, and the remote step always runs.
deleted_local=0
skipped_local=()
if [ "${#local_merged[@]}" -gt 0 ]; then
  echo "==> Deleting ${#local_merged[@]} local branch(es) (git branch -d, refuses unmerged)"
  for b in "${local_merged[@]}"; do
    # -d (not -D) first — git refuses any branch not fully merged; this is the
    # safety floor and the fast path for the ordinary ancestor-merged case.
    # Suppress git's stderr on failure and print our own one-line skip note.
    if git branch -d "$b" 2>/dev/null; then
      deleted_local=$((deleted_local + 1))
      continue
    fi
    # -d refused (its tip genuinely isn't an ancestor) — escalate to -D ONLY
    # when the merge-queue-safe helper independently confirmed THIS branch
    # merged (local_squash, #171/#173): a squash/rebase-merge queue landed the
    # PR without leaving the tip as an ancestor. Never force-delete a branch
    # -d refused for any OTHER reason (in-use/worktree-bound, genuinely
    # unmerged) — the safety floor stays intact.
    is_squash=0
    for s in "${local_squash[@]:-}"; do
      [ "$s" = "$b" ] && { is_squash=1; break; }
    done
    if [ "$is_squash" -eq 1 ] && git branch -D "$b" 2>/dev/null; then
      deleted_local=$((deleted_local + 1))
    else
      skipped_local+=("$b")
      echo "  skipped (in use / worktree-bound): $b"
    fi
  done
fi

deleted_remote=0
if [ "$do_remote" -eq 1 ] && [ "${#remote_merged[@]}" -gt 0 ]; then
  echo "==> Deleting ${#remote_merged[@]} remote head(s) on origin"
  git push origin --delete "${remote_merged[@]}"
  deleted_remote=${#remote_merged[@]}
fi

summary="Done. deleted ${deleted_local} local"
[ "$do_remote" -eq 1 ] && summary="${summary} / ${deleted_remote} remote"
[ "${#skipped_local[@]}" -gt 0 ] && summary="${summary}; skipped ${#skipped_local[@]} local (in use)"
echo "$summary"
