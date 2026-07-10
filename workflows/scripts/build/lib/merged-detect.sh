#!/usr/bin/env bash
#
# merged-detect.sh — SOURCED helper exposing the merge-queue-safe
# merged-detection function (#171): given a branch name, report whether its
# PR actually MERGED — robust to squash/rebase/merge-queue topology, where
# the branch tip is NOT an ancestor of origin/<default> even though the PR
# landed. This is the shared source of truth that replaces the ancestor-only
# `git merge-base --is-ancestor` fragility at worktree.sh:246 and in
# scripts/prune-merged-branches.sh — but THIS ITEM ONLY ADDS the helper. It
# does not change either caller's prune path — a later item (#173) switches
# worktree.sh's `prune_one` and prune-merged-branches.sh over to call this
# function instead of their own ancestor-only test.
#
# Detection order (first conclusive signal wins):
#
#   1. `gh pr view <branch> --json state` — the ground truth GitHub itself
#      reports for the PR associated with that head branch name. Valid
#      regardless of squash/rebase/merge-queue topology, and even once the
#      head branch/ref has been deleted (auto-delete-on-merge) — gh resolves
#      by the PR's recorded headRefName, not by the git ref still existing.
#      state == MERGED → merged. state == OPEN or CLOSED (closed without
#      merging) → conclusively NOT merged; no reason to fall through to a
#      weaker heuristic.
#
#   2. gh errored (not installed / not authenticated / rate-limited / no
#      network) or returned an unrecognized `state` value — fall back to a
#      local, network-free heuristic: collapse $branch's cumulative diff
#      since its merge-base with origin/<default> into ONE synthetic commit
#      (this is exactly what a squash-merge commit looks like) and ask
#      `git cherry` (patch-id comparison, not tree/ancestor comparison)
#      whether origin/<default> already contains a commit with an equivalent
#      patch. Unlike a plain tree-equality check, this stays correct even
#      after origin/<default> has advanced further past the point the squash
#      landed.
#
#   3. Neither signal is conclusive → NOT merged, the safe/non-destructive
#      default. This is both the correct answer for a genuinely open/
#      unmerged branch AND the fail-open answer for a gh/network error or an
#      inconclusive heuristic — a caller (worktree prune, env-reconcile) must
#      never be told "merged" on uncertain grounds.
#
# Output contract: prints exactly one line — `true` or `false` — to stdout.
# Return code: 0 on every DETERMINATE check, including the gh-error/
# inconclusive-heuristic fail-open `false` — this function must never abort
# a caller running under `set -e` just because gh/network flaked. The only
# non-zero return (2, nothing printed) is caller MISUSE — a missing
# repo-root or branch argument, a real programming bug, not a runtime
# condition callers should treat as "not merged".
#
# This file is SOURCED — it sets no shell options (the caller owns
# `set -euo pipefail`); every function here is written to behave under
# `set -u`. Override seam: _merged_detect_gh (mirrors _gate_gh / _board_gh in
# this same toolkit) — tests redefine it to stand in for the real `gh`
# binary without touching the network.

_merged_detect_gh() { gh "$@"; }

# Best-effort default-branch resolution (mirrors worktree.sh's own
# default_branch()) — used only when the caller doesn't pass one explicitly.
# Prints the branch name (no "origin/" prefix); returns 1 if neither
# origin/HEAD nor a main/master remote ref can be resolved.
_merged_detect_default_branch() {
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

# merged_detect_is_merged <repo-root> <branch> [default-branch]
#
# Prints "true" or "false" to stdout; see the file header for the full
# output/return-code contract.
merged_detect_is_merged() {
  local repo="${1:-}" branch="${2:-}" default="${3:-}"
  local state merge_base tree synth cherry_out

  if [ -z "$repo" ] || [ -z "$branch" ]; then
    return 2
  fi

  if [ -z "$default" ]; then
    default="$(_merged_detect_default_branch "$repo" 2>/dev/null)" || default="main"
  fi

  # --- Method 1: gh pr view <branch> --json state --------------------------
  # Run with cwd inside the repo so gh auto-detects the GitHub repo from the
  # origin remote — no owner/repo parsing needed here. Any gh failure (not
  # installed, not authed, rate-limited, offline) falls through to Method 2
  # rather than propagating — this call is never allowed to abort a caller.
  if state="$(cd "$repo" && _merged_detect_gh pr view "$branch" --json state --jq .state 2>/dev/null)"; then
    case "$state" in
      MERGED)
        printf 'true\n'
        return 0
        ;;
      OPEN | CLOSED)
        printf 'false\n'
        return 0
        ;;
      *)
        # Unrecognized/empty state (gh output-shape drift) — don't trust it,
        # fall through to the local heuristic instead.
        ;;
    esac
  fi

  # --- Method 2: patch-equivalence (squash-safe) heuristic -----------------
  # Collapse $branch's cumulative diff since its merge-base with
  # origin/<default> into one synthetic commit — what a squash-merge commit
  # looks like — then ask `git cherry` (patch-id, not tree/ancestor
  # comparison) whether origin/<default> already carries an equivalent
  # patch. `git cherry <upstream> <head>` prefixes each commit unique to
  # <head> with `-` (equivalent patch found in <upstream>) or `+` (not
  # found); our synthetic commit is the only commit unique to <head> here
  # (its sole parent, merge_base, is common ancestor), so a leading `-`
  # means merged.
  if merge_base="$(git -C "$repo" merge-base "origin/$default" "$branch" 2>/dev/null)" \
    && tree="$(git -C "$repo" rev-parse "${branch}^{tree}" 2>/dev/null)" \
    && synth="$(git -C "$repo" commit-tree "$tree" -p "$merge_base" -m squash-probe 2>/dev/null)"; then
    if cherry_out="$(git -C "$repo" cherry "origin/$default" "$synth" 2>/dev/null)"; then
      case "$cherry_out" in
        -*)
          printf 'true\n'
          return 0
          ;;
      esac
    fi
  fi

  # --- Method 3 / fail-open default: NOT merged ----------------------------
  # Reached by a genuinely open/unmerged branch AND by any gh error or
  # inconclusive heuristic above — the safe default either way (#171).
  printf 'false\n'
  return 0
}
