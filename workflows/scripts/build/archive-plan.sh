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
# Prints exactly one machine-readable status line:
#   plan-archived:          <rev>  -> snapshot is on the default branch (pushed, or
#                                     no remote, or already on origin / already current)
#   plan-archive-pr-queued: <pr>   -> main is protected; snapshot landed on a branch +
#                                     PR that is ENQUEUED but not yet merged (lands async)
#   plan-archive-skipped:   <why>  -> not landed (not a repo, custom dir, push rejected) —
#                                     non-fatal; the snapshot can be re-archived next run
#
# Skips never fail (exit 0) — a missing-arg error is the only non-zero exit.
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

# Populate fn (#408 contract): drop the single plan snapshot under the given root.
# (Invoked indirectly by land_run, so the main flow can't see the call — hence
# SC2317 unreachable + SC2329 never-invoked.)
# shellcheck disable=SC2317,SC2329
populate_plan() {  # <root>
  local root="$1"
  mkdir -p "$root/Plans-archive"
  cp -- "$SRC" "$root/$REL"
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

case "$LAND_RESULT" in
  committed)   echo "plan-archived: ${LAND_REV}${LAND_DETAIL:+ ($LAND_DETAIL)}" ;;
  pr-queued)   echo "plan-archive-pr-queued: $LAND_PR" ;;
  *)           echo "plan-archive-skipped: ${LAND_DETAIL:-unknown}" ;;  # knob:exempt — LAND_DETAIL is an internal land-result field, not an operator default
esac
exit 0
