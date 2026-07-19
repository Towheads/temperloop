#!/usr/bin/env bash
#
# checkout-freshness.sh — the checkout-staleness guard for scripts/quality-gates.sh
# (temperloop#591).
#
# quality-gates.sh runs whatever gate LIST the checked-out tree contains, and its
# diff-scoped gates (the PR leak guard) diff against origin/<default>. A checkout
# that is BEHIND origin/<default> therefore silently runs a SMALLER gate set than
# CI (which checks out the PR's merge with current main) and scans a stale/empty
# leak-guard diff — so a green run in a stale checkout does NOT imply green CI.
# That exact trap cost a 12-item /sweep four post-push CI round-trips: the
# knob-registry / denylist / leak-guard gates the stale local run never exercised.
#
# This guard makes the divergence LEGIBLE rather than blocking it. A stale
# checkout is sometimes legitimate (offline work, deliberately testing an old
# commit), so check_checkout_freshness never fails the run — it prints a loud,
# non-fatal banner and lets the caller decide. build-level.mjs's own worker
# worktrees branch off a freshly-fetched origin/<default> (worktree.sh create),
# so they report 0-behind and the guard stays silent on that hot path.
#
# check_checkout_freshness <repo_root>
#   Sets two globals in the CALLER's shell (source this file, then call):
#     CHECKOUT_BEHIND      — integer commits HEAD is behind its tracking ref (0 if
#                            current, unresolvable, offline, or skipped)
#     CHECKOUT_BEHIND_REF  — the tracking ref compared against (empty if none)
#   Prints a stale-checkout banner to stderr when CHECKOUT_BEHIND > 0. Always
#   returns 0 (advisory, never blocking). Honors QUALITY_GATES_SKIP_FRESHNESS=1.
#
# Best-effort + offline-safe: it does a timeout-bounded `git fetch` of the
# tracking ref so a never-fetched hand checkout can't UNDER-report (the case that
# spawned #591); an unreachable remote just leaves the local ref as-is. Reuses
# the portable-timeout shim (sibling lib) for the fetch bound.

# CHECKOUT_BEHIND / CHECKOUT_BEHIND_REF are set for the CALLER (quality-gates.sh
# reads them after sourcing) — shellcheck can't see that cross-file use.
# shellcheck disable=SC2034

# Guard against double-source (quality-gates.sh + a test may both source this).
[ -n "${_CHECKOUT_FRESHNESS_SH:-}" ] && return 0
_CHECKOUT_FRESHNESS_SH=1

check_checkout_freshness() {
  local repo_root="$1"
  CHECKOUT_BEHIND=0
  CHECKOUT_BEHIND_REF=""

  [ "${QUALITY_GATES_SKIP_FRESHNESS:-0}" = 1 ] && return 0
  [ -n "$repo_root" ] || return 0
  git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # Compare against origin/<default-branch> (main), NOT the branch's own upstream
  # (@{u}). The staleness that diverges a LOCAL gate run from CI is being behind
  # origin/<default>: the gate LIST comes from the checked-out tree and the leak
  # guard diffs against origin/<default>, while CI tests the branch MERGED with
  # current main. A feature branch tracks origin/<feature>, so @{u} would report
  # 0-behind-its-own-remote while its base is far behind main — the exact blind
  # spot #591 is about. Resolve the default via origin/HEAD, falling back to
  # origin/main. Bail quietly if there is no origin remote at all.
  local ref
  ref="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [ -z "$ref" ] && git -C "$repo_root" show-ref --verify --quiet refs/remotes/origin/main; then
    ref="origin/main"
  fi
  [ -n "$ref" ] || return 0

  # Best-effort, timeout-bounded refresh so a STALE local ref can't UNDER-report.
  # Offline / unreachable remote → the fetch fails or is killed and we compare
  # against the ref as-is; the guard is advisory, so a failed fetch is a no-op.
  local remote="${ref%%/*}" branch="${ref#*/}"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$here/portable-timeout.sh" ] && ! command -v run_with_timeout >/dev/null 2>&1; then
    # shellcheck source=workflows/scripts/lib/portable-timeout.sh
    . "$here/portable-timeout.sh"
  fi
  if command -v run_with_timeout >/dev/null 2>&1; then
    run_with_timeout 10 git -C "$repo_root" fetch --quiet "$remote" "$branch" 2>/dev/null || true
  else
    git -C "$repo_root" fetch --quiet "$remote" "$branch" 2>/dev/null || true
  fi

  local behind
  behind="$(git -C "$repo_root" rev-list --count "HEAD..$ref" 2>/dev/null)" || behind=0
  case "$behind" in ''|*[!0-9]*) behind=0 ;; esac
  CHECKOUT_BEHIND="$behind"
  CHECKOUT_BEHIND_REF="$ref"

  if [ "$behind" -gt 0 ]; then
    cat >&2 <<EOF

################################################################################
#  STALE BASE — this gate run may NOT match CI (temperloop#591)
#  Your base is $behind commit(s) behind $ref.
#  The gate LIST comes from the checked-out tree and the leak guard diffs
#  against $ref, but CI tests your branch MERGED with current $ref — so a stale
#  base runs a SMALLER gate set + a stale diff than CI. A green run HERE does
#  not guarantee green in CI. Refresh onto $ref before trusting this result:
#      git -C "$repo_root" fetch && git -C "$repo_root" rebase $ref
#      (or, on the default branch, git -C "$repo_root" pull --ff-only)
#  (set QUALITY_GATES_SKIP_FRESHNESS=1 to silence this check.)
################################################################################
EOF
  fi
  return 0
}
