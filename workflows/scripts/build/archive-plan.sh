#!/usr/bin/env bash
#
# archive-plan.sh — land a done plan note's immutable snapshot into the target
# repo's Plans-archive/ directory at epic close. This is the "machines to git"
# half of the vault/git boundary (epic #252): while an epic is open its plan note
# lives only in the vault as the live cross-session ledger; at epic close
# build copies that done note into the repo so the durable record rides git
# history (diffable, blame-able, survives vault loss).
#
# Driven by build Step 4d-archive (#408). Replaces an inline bare `git commit`
# to the orchestrator's local main that, since the #330 merge-queue ruleset, could
# never reach origin on a protected branch — the same strand #404 fixed for the
# session-transcript archive. Lands via the SHARED protected-main kernel
# (../lib/land-on-protected-main.sh), so the snapshot reaches origin durably (via a
# PR + merge queue when main is protected) instead of stranding local-only.
#
# Usage:
#   archive-plan.sh <plan-src-path> <epic-number> <repo-root>
#     <plan-src-path>  the run's vault Plans/<note>.md (status: done by epic close)
#     <epic-number>    the epic whose close triggered the archive (for the commit msg)
#     <repo-root>      the repo build operates on (where Plans-archive/ lives) —
#                      defaults to the CWD's repo root if omitted
#
# Prints exactly one machine-readable status line. The vocabulary separates LANDED
# from PENDING from FAILED, because the old one did not (#1523): a single
# `plan-archive-pr-queued:` line read as success while the snapshot sat on a branch
# that might never merge — and the next run force-rebuilt that branch off main and
# DESTROYED it. Only the first line below is success:
#
#   plan-archived:         <rev>  -> LANDED. The snapshot is on the default branch
#                                    (pushed, no remote, already on origin/current).
#   plan-archive-pending:  <pr>   -> NOT landed. main is protected; the snapshot is on
#                                    the archive branch, carried by PR <pr> with
#                                    auto-merge armed. It lands only when the queue
#                                    merges that PR — report it pending, never done.
#   plan-archive-failed:   <why>  -> NOT landed and NOT pending: the snapshot never
#                                    reached git, or it reached a PR whose auto-merge
#                                    could not be armed (so nothing will merge it).
#                                    Names what did not land; re-run to retry.
#   plan-archive-skipped:  <why>  -> not attempted (no such note, not a git repo).
#
# Exit stays 0 for every status line (a missing-arg error is the only non-zero exit)
# so a `set -e` caller's epic-close flow is never aborted by an archive miss — the
# LINE is the verdict, and `plan-archive-failed:` is a failure the caller reports
# rather than folds into its summary as success.
#
# NEVER-DESTROY (#1523): the shared kernel bases the archive branch on the PENDING
# branch whenever that branch carries un-merged commits, so a prior run's snapshot
# that has not reached main yet is carried forward, never overwritten. A failed
# archive therefore leaves the source recoverable twice over — the vault note is
# untouched (this script only ever READS it) and any already-pushed snapshot stays
# on the branch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/land-on-protected-main.sh
. "$HERE/../lib/land-on-protected-main.sh"

SRC="${1:-}"
EPIC="${2:-}"
[ -n "$SRC" ]  || { echo "archive-plan: missing <plan-src-path>" >&2; exit 1; }
[ -n "$EPIC" ] || { echo "archive-plan: missing <epic-number>" >&2; exit 1; }

skipped() { echo "plan-archive-skipped: $1"; exit 0; }

[ -f "$SRC" ] || skipped "no such plan note: $SRC"

# Resolve the target repo root: explicit arg, else the CWD's repo root.
REPO_ROOT="${3:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || skipped "no target repo root (not in a git repo)"
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || skipped "$REPO_ROOT is not a git repo"

BASE="$(basename "$SRC")"
REL="Plans-archive/$BASE"

# Set by populate_plan when the snapshot could not be written; read after land_run.
# (Same shell — the kernel is SOURCED and calls the populate fn directly, so this is
# not a subshell assignment.)
POPULATE_ERR=""

# Populate fn (#408 contract): drop the single plan snapshot under the given root.
# (Invoked indirectly by land_run, so the main flow can't see the call — hence
# SC2317 unreachable + SC2329 never-invoked.)
#
# #1523: every step is CHECKED and VERIFIED rather than assumed. A bare `cp` under
# `set -e` aborted the whole script with no status line at all; worse, any write that
# silently produced nothing left an EMPTY staged diff, which the kernel's
# short-circuit then read as "already on origin" — a success verdict for bytes that
# were never written. So the copy reports its own failure, and the written file is
# compared against the source before this run is allowed to claim anything.
# shellcheck disable=SC2317,SC2329
populate_plan() {  # <root>
  local root="$1"
  if ! mkdir -p "$root/Plans-archive" 2>/dev/null; then
    POPULATE_ERR="could not create $root/Plans-archive"; return 0
  fi
  if ! cp -- "$SRC" "$root/$REL" 2>/dev/null; then
    POPULATE_ERR="could not write the snapshot to $REL under $root"; return 0
  fi
  if ! cmp -s -- "$SRC" "$root/$REL"; then
    POPULATE_ERR="the snapshot written to $REL does not match $SRC"; return 0
  fi
  return 0
}

# Drive the shared protected-main landing kernel. The LAND_* contract is consumed by
# the sourced kernel; export the scalars so shellcheck sees them as used-externally.
export LAND_ROOT="$REPO_ROOT"
export LAND_BRANCH="${PLAN_ARCHIVE_BRANCH:-chore/plan-archive}"   # stable -> one reused PR, no per-epic orphans
# shellcheck disable=SC2034  # read by the sourced kernel (arrays can't be exported)
LAND_PATHS=("$REL")
export LAND_COMMIT_MSG="archive(plan): snapshot done plan note for epic #$EPIC at close"
export LAND_PR_TITLE="archive(plan): plan-note snapshots"
# PR body deliberately carries NO `Closes` keyword — the archive tracks no issue
# (the epic is already closed by 4d-epic; this is just the durable snapshot).
export LAND_PR_BODY="Automated plan-note snapshot(s) into Plans-archive/ at epic close (#408, epic #$EPIC).
Routed through a PR because main is protected (merge-queue ruleset). Closes no issue."
export LAND_GH="${PLAN_ARCHIVE_GH:-gh}"
export LAND_REQUIRES_PR="${PLAN_ARCHIVE_REQUIRES_PR:-}"   # this caller owns only its namespaced seam

land_run populate_plan

# The populate verdict OUTRANKS the land verdict (#1523). A snapshot that was never
# written produces no staged diff, and an un-diffed run otherwise reports
# `already on origin` — the false success this check makes unreachable.
if [ -n "$POPULATE_ERR" ]; then
  echo "plan-archive-failed: $BASE did not land — $POPULATE_ERR (the vault note is untouched; re-run to retry)"
  exit 0
fi

case "$LAND_RESULT" in
  committed)   echo "plan-archived: ${LAND_REV}${LAND_DETAIL:+ ($LAND_DETAIL)}" ;;
  pr-queued)   echo "plan-archive-pending: $LAND_PR" ;;
  pr-open)     echo "plan-archive-failed: $BASE is on PR #$LAND_PR but that PR is NOT queued to merge — ${LAND_DETAIL:-auto-merge could not be armed}" ;;  # setting:exempt — LAND_DETAIL is an internal land-result field, not an operator default
  uncommitted) echo "plan-archive-failed: $BASE did not land — ${LAND_DETAIL:-unknown}" ;;  # setting:exempt — as above
  *)           echo "plan-archive-skipped: ${LAND_DETAIL:-unknown}" ;;  # setting:exempt — as above
esac
exit 0
