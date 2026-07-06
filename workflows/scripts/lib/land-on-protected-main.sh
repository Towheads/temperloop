#!/usr/bin/env bash
#
# land-on-protected-main.sh — a SOURCED library that lands a caller-supplied set
# of changes durably onto a repo's default branch, transparently handling the
# case where that branch is PROTECTED (branch-protection / merge-queue ruleset)
# and rejects a direct push (GH013).
#
# Extracted from archive-session.sh's #404 fix so the protected-main landing
# kernel is shared, not copy-pasted: both the session-transcript archive
# (archive-session.sh) and the build plan-snapshot archive
# (build/archive-plan.sh, #408) drive it. The next protected-main lander is
# free — define a populate fn + set the LAND_* contract.
#
# Contract — the caller sets these, defines a populate fn, then calls land_run:
#
#   in (env):
#     LAND_ROOT            target repo root (the repo the change lands in — may be
#                          a CONSUMING repo even though this lib is sourced from
#                          foundation; script location != target repo). REQUIRED.
#     LAND_BRANCH          stable branch name for the PR path (reused across runs
#                          so repeated runs converge on ONE PR). REQUIRED.
#     LAND_PATHS           bash ARRAY of repo-relative paths to `git add`. REQUIRED,
#                          non-empty (e.g. LAND_PATHS=("meta/sessions/archive")).
#     LAND_COMMIT_MSG      commit message. REQUIRED.
#     LAND_PR_TITLE        PR title (PR path only). REQUIRED when main is protected.
#     LAND_PR_BODY         PR body  (PR path only). REQUIRED when main is protected.
#     LAND_GH              gh binary override (default: gh).            [test seam]
#     LAND_DEFAULT_BRANCH  default branch (default: main).
#     LAND_REQUIRES_PR     force the protected path when "1".           [test seam]
#
#   fn:
#     <populate_fn> <root>   place the desired tree state under <root> for the
#                            LAND_PATHS it manages. On the PROTECTED path <root>
#                            is a throwaway worktree checked out from
#                            origin/<default> (so LAND_ROOT's checkout is never
#                            touched); on the DIRECT / no-remote path <root> is
#                            LAND_ROOT itself (in place).
#
#   out (vars set by land_run; caller maps to its own vocabulary):
#     LAND_RESULT  committed | pr-queued | uncommitted
#     LAND_REV     short SHA          (committed)
#     LAND_PR      PR number          (pr-queued)
#     LAND_DETAIL  pushed | already on origin | already current | <why> | ""
#
# land_run ALWAYS returns 0 — the outcome is in LAND_RESULT, never the exit code,
# so a `set -e` caller is never aborted by a "rejected push" control-flow branch.
#
# Working-tree guarantee: on the PROTECTED (PR) path the kernel builds the commit in
# a throwaway worktree and NEVER modifies LAND_ROOT's working tree or branch. So a
# caller that dirtied LAND_ROOT *before* calling land_run (e.g. an in-place sweep)
# OWNS reverting it afterward — the kernel won't, because those changes rode the PR
# branch instead. (On the direct path the kernel's own commit/undo leaves LAND_ROOT
# clean, so no caller revert is needed there.)
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).

# Does the target repo have an `origin` remote?
land__has_remote() { git -C "$LAND_ROOT" remote get-url origin >/dev/null 2>&1; }

# Does the default branch require a PR (branch protection / merge-queue ruleset),
# i.e. is a direct push rejected? Probe once, read-only, via the branch's
# effective rules. A probe failure returns false → the direct path runs and
# self-guards (it reports uncommitted, not committed, if the push is rejected).
land__requires_pr() {
  [ "${LAND_REQUIRES_PR:-}" = "1" ] && return 0   # test seam
  land__has_remote || return 1
  local nwo
  nwo="$("$LAND_GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || return 1
  [ -n "$nwo" ] || return 1
  "$LAND_GH" api "repos/$nwo/rules/branches/$LAND_DEFAULT_BRANCH" \
    --jq 'any(.[]; .type=="merge_queue" or .type=="pull_request")' 2>/dev/null \
    | grep -q true
}

# Set the four output vars in one place. (Assigned here, read by the caller in
# another file — hence the SC2034 directive.)
# shellcheck disable=SC2034
land__set() {  # <result> <rev> <pr> <detail>
  LAND_RESULT="$1"; LAND_REV="$2"; LAND_PR="$3"; LAND_DETAIL="$4"
}

# Stage every managed path under <root>. -A captures additions, modifications,
# AND deletions (e.g. a .md -> .md.gz retention rename).
land__add() {  # <root>
  local root="$1" p
  for p in "${LAND_PATHS[@]}"; do
    git -C "$root" add -A -- "$p" >/dev/null 2>&1 || true
  done
}

# Tear down a throwaway worktree + its mktemp parent dir.
land__finish_wt() {  # <wt>
  git -C "$LAND_ROOT" worktree remove --force "$1" >/dev/null 2>&1 || rm -rf "$1"
  rmdir "$(dirname "$1")" 2>/dev/null || true
}

# Protected default branch: build the commit in a throwaway worktree off
# origin/<default> (so LAND_ROOT's checked-out branch is never touched), push a
# stable branch, adopt-or-open a PR, and arm auto-merge so the queue lands it.
# Idempotent across runs: stable branch + force-push + adopt-open-PR +
# the diff-against-origin short-circuit converge repeated runs onto ONE PR, then
# auto-flip to `committed (already on origin)` once it merges.
land__via_pr() {  # <populate_fn>
  local populate_fn="$1" branch wt rev pr create_out
  branch="$LAND_BRANCH"
  git -C "$LAND_ROOT" worktree prune >/dev/null 2>&1 || true
  git -C "$LAND_ROOT" fetch -q origin "$LAND_DEFAULT_BRANCH" 2>/dev/null || true
  wt="$(mktemp -d "${TMPDIR:-/tmp}/land-wt-XXXXXX")/wt"
  if ! git -C "$LAND_ROOT" worktree add -q -B "$branch" "$wt" "origin/$LAND_DEFAULT_BRANCH" 2>/dev/null; then
    rm -rf "$(dirname "$wt")"
    land__set uncommitted "" "" "could not create worktree off origin/$LAND_DEFAULT_BRANCH"
    return 0
  fi
  "$populate_fn" "$wt"
  land__add "$wt"
  if git -C "$wt" diff --cached --quiet -- "${LAND_PATHS[@]}"; then
    rev="$(git -C "$wt" rev-parse --short HEAD)"
    land__finish_wt "$wt"
    land__set committed "$rev" "" "already on origin"
    return 0
  fi
  git -C "$wt" commit -q -m "$LAND_COMMIT_MSG" -- "${LAND_PATHS[@]}"
  # Plain --force, not --force-with-lease: $branch is disposable and orchestrator-owned,
  # rebuilt off origin/$LAND_DEFAULT_BRANCH every run (line ~109 above), so there is no
  # local work to protect. A no-value --force-with-lease uses the local
  # refs/remotes/origin/$branch tracking ref as its lease, which goes stale the moment a
  # prior run's PR merges and the remote head auto-deletes on a checkout that never
  # prunes — rejecting every subsequent push with "stale info" (#658).
  if ! git -C "$wt" push -q -u origin "$branch" --force 2>/dev/null; then
    land__finish_wt "$wt"
    land__set uncommitted "" "" "push of branch '$branch' failed"
    return 0
  fi
  # Adopt the stable branch's open PR, else open one — and CONVERGE even when the
  # adopt-or-open step trips over its own idempotency (#27). A reused branch means a
  # prior run's PR is the common case, so a momentary failure to see it must never
  # strand the run as "could not find the PR":
  #   - `gh pr list --head` is a SEARCH-index query that lags a fresh force-push, so
  #     an empty result is not proof no PR exists.
  #   - `gh pr create` REFUSES to make a duplicate and prints the existing PR's URL
  #     in its "a pull request ... already exists: <url>" message — capture BOTH
  #     streams (2>&1) so that number is recoverable instead of discarded, and match
  #     the `/pull/<n>` URL so a stray digit in the body/title can't be mistaken for it.
  #   - `gh pr view <branch>` resolves the branch's PR by head ref (no search index) —
  #     the authoritative fallback that adopts a PR the list query hadn't indexed yet.
  pr="$("$LAND_GH" pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || true)"
  if [ -z "$pr" ]; then
    create_out="$("$LAND_GH" pr create --base "$LAND_DEFAULT_BRANCH" --head "$branch" \
                    --title "$LAND_PR_TITLE" --body "$LAND_PR_BODY" 2>&1 || true)"
    pr="$(printf '%s\n' "$create_out" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+$' | tail -1 || true)"
  fi
  if [ -z "$pr" ]; then
    pr="$("$LAND_GH" pr view "$branch" --json number -q .number 2>/dev/null || true)"
  fi
  land__finish_wt "$wt"
  if [ -z "$pr" ]; then
    land__set uncommitted "" "" "could not open or find the PR for branch '$branch'"
    return 0
  fi
  "$LAND_GH" pr merge "$pr" --auto >/dev/null 2>&1 || true   # queue-ON incantation (queue owns strategy + branch)
  land__set pr-queued "" "$pr" "enqueued"
  return 0
}

# Unprotected branch or no remote (fresh-local / tests): commit in place on
# LAND_ROOT, then push when a remote exists. A rejected push (protection the
# probe missed) undoes its own commit + the managed-path changes and reports
# uncommitted — so a false "committed" can never be reported for a stranded commit.
land__direct() {  # <populate_fn>
  local populate_fn="$1" rev
  "$populate_fn" "$LAND_ROOT"
  land__add "$LAND_ROOT"
  if git -C "$LAND_ROOT" diff --cached --quiet -- "${LAND_PATHS[@]}"; then
    rev="$(git -C "$LAND_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
    land__set committed "$rev" "" "already current"
    return 0
  fi
  git -C "$LAND_ROOT" commit -q -m "$LAND_COMMIT_MSG" -- "${LAND_PATHS[@]}"
  rev="$(git -C "$LAND_ROOT" rev-parse --short HEAD)"
  if land__has_remote; then
    if git -C "$LAND_ROOT" push -q origin "$LAND_DEFAULT_BRANCH" 2>/dev/null; then
      land__set committed "$rev" "" "pushed"
      return 0
    fi
    # Push rejected: undo just this commit + the managed-path changes so LAND_ROOT
    # stays at origin, and report uncommitted. The guard that makes the #404
    # false-durability signal impossible even on a bad probe.
    git -C "$LAND_ROOT" reset -q --soft HEAD~1 2>/dev/null || true
    git -C "$LAND_ROOT" restore --staged --worktree -- "${LAND_PATHS[@]}" >/dev/null 2>&1 || true
    git -C "$LAND_ROOT" clean -fdq -- "${LAND_PATHS[@]}" >/dev/null 2>&1 || true
    land__set uncommitted "" "" "direct push to $LAND_DEFAULT_BRANCH rejected (branch likely protected)"
    return 0
  fi
  # No remote: a local commit is the durable end state available here.
  land__set committed "$rev" "" ""
  return 0
}

# Entry point. Routes to the protected (PR) or direct path and sets LAND_RESULT.
land_run() {  # <populate_fn>
  local populate_fn="$1"
  : "${LAND_GH:=gh}"
  : "${LAND_DEFAULT_BRANCH:=main}"
  # The output contract (LAND_RESULT/REV/PR/DETAIL) is set by land__set, which every
  # path below calls before returning — so no explicit reset is needed here.
  if land__requires_pr; then
    land__via_pr "$populate_fn"
  else
    land__direct "$populate_fn"
  fi
  return 0
}
