#!/usr/bin/env bash
#
# build combined-tree pre-check — the deterministic-spine script that owns the
# Step-4 level-merge-gate UNION check of /build (temperloop#865). When a level
# parks more than one PR, the orchestrator must know BEFORE it enqueues the set
# whether the parked branches merge together cleanly AND still pass the full
# gate suite as a combined tree — not just pairwise-textually (build.md's
# `git merge-tree` hunk probe already covers that), but SEMANTICALLY: two PRs
# each green alone whose *combination* breaks (a new gate + the files it scans,
# a Makefile target registered only in one branch, a `.PHONY` block, …). Today
# those surface only INSIDE GitHub's native merge queue's `merge_group` trial
# branch — an eject → diagnose → rebase → requeue cycle costing ~1h each (the
# Epic-B retro, F#847). This check moves that discovery LEFT of the enqueue,
# where a collision costs one local gate run instead of a queue round-trip.
#
# This is a LOCAL-GIT script by necessity — it materializes the merged union in
# a throwaway worktree and runs the real gate suite against it. That is a
# deliberate departure from gate.sh's no-local-git invariant (temperloop#242):
# gate.sh reads mergeability through the GitHub API precisely so a PR head ref
# never needs to be reachable locally, whereas running the gate SUITE against
# the merged files is impossible without a local tree. Keeping the two apart —
# gate.sh network-pure, this script local-git — preserves gate.sh's invariant
# rather than smuggling local git into it. This script is a sibling of
# worktree.sh (also local-git), not a gate.sh subcommand.
#
#   combined-tree-precheck.sh <repo-root> <branch> <branch> [<branch> ...] [--base <ref>]
#       → build a throwaway detached worktree at <ref> (default origin/main),
#         `git merge --no-ff` each branch into it in the given order, then run
#         the gate suite (scripts/quality-gates.sh) against the merged tree.
#         Fewer than two branches → SKIP (single-PR levels need no union check).
#
# The gate-suite runner is a fixture seam (COMBINED_TREE_SUITE_CMD, default
# `bash scripts/quality-gates.sh`) so a test can inject a synthetic gate with
# zero dependence on the real suite — the same single-seam-per-dependency shape
# gate.sh uses for `_gate_gh`.
#
# Output contract — CLOSED outcome set, one structured JSON line (the
# orchestrator branches on `.outcome`, never parses prose):
#   {"outcome":"CLEAN","branches":[…]}                                exit 0
#   {"outcome":"SKIP","reason":"fewer-than-two-branches","branches":N} exit 0
#   {"outcome":"CONFLICT","branch":"<ref>","branches":[…]}            exit 3
#   {"outcome":"GATE_FAILED","exit_code":N,"output":"<tail>","branches":[…]} exit 4
#   {"outcome":"ERROR","error":…}                                     exit 1
# Exit codes: 0 CLEAN/SKIP; 1 ERROR (bad input / setup failure); 3 CONFLICT (a
# branch would not merge into the accumulating union — a textual conflict); 4
# GATE_FAILED (the union merged cleanly but the gate suite failed on it — a
# semantic collision, the class this check exists to catch pre-queue). CONFLICT
# names the FIRST branch that failed to merge; a batched union means a later
# branch's conflict may be attributable to any earlier one, so the name is the
# offending merge, not a root-cause claim.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"jq not found"}'; exit 1; }
command -v git >/dev/null 2>&1 || { echo '{"outcome":"ERROR","error":"git not found"}'; exit 1; }

# --- fixture seam ------------------------------------------------------------
# The gate-suite command run against the merged worktree. Default = the repo's
# single-source-of-truth static gate set (== CI's `checks` job). Tests override
# it with a synthetic gate. It is a TRUSTED config string (never user input),
# eval'd exactly as quality-gates.sh eval's its own gate command lines.
: "${COMBINED_TREE_SUITE_CMD:=bash scripts/quality-gates.sh}"

# fd 3 = the script's real stdout, so a die() inside a command substitution
# still reaches the orchestrator (same seam as gate.sh / worktree.sh).
exec 3>&1
die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}' >&3
  exit 1
}

usage() {
  die "usage: combined-tree-precheck.sh <repo-root> <branch> <branch> [<branch> ...] [--base <ref>]"
}

# Physical-path resolve for an EXISTING dir (portable — no GNU readlink -f).
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# Resolve + validate the repo root: must exist, be a git work tree, and BE the
# toplevel (the worktree is added relative to it). Mirrors worktree.sh.
resolve_repo() {
  local arg="$1" repo top
  repo="$(abs_dir "$arg")" || die "repo-root '$arg' does not exist"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "repo-root '$arg' is not inside a git work tree"
  top="$(abs_dir "$top")"
  [ "$repo" = "$top" ] || die "repo-root '$arg' is not a git toplevel (toplevel is '$top')"
  printf '%s\n' "$repo"
}

# Build a JSON array of the branch list once, reused across every outcome line.
_branches_json() { printf '%s\n' "$@" | jq -R . | jq -cs .; }

# Throwaway-worktree teardown. The paths live at SCRIPT scope (not as
# cmd_precheck locals) so the EXIT trap — which fires AFTER cmd_precheck has
# returned and its locals are gone — can still reach them under `set -u`. Always
# torn down: on CLEAN, CONFLICT, GATE_FAILED, or a die() (exit 1 fires the trap).
_CTP_WT=""
_CTP_REPO=""
# shellcheck disable=SC2317
_ctp_cleanup() {
  [ -n "$_CTP_WT" ] || return 0
  git -C "$_CTP_REPO" worktree remove --force "$_CTP_WT" >/dev/null 2>&1 || rm -rf "$_CTP_WT"
  git -C "$_CTP_REPO" worktree prune >/dev/null 2>&1 || true
}

cmd_precheck() {
  local repo="$1" base="$2"; shift 2
  local branches=("$@") brs_json
  brs_json="$(_branches_json "${branches[@]}")"

  # Fewer than two branches → nothing to combine. A single-PR level skips the
  # whole check (acceptance #3); the orchestrator may also just not call us, but
  # a defensive SKIP lets it invoke unconditionally.
  if [ "${#branches[@]}" -lt 2 ]; then
    jq -cn --argjson n "${#branches[@]}" '{outcome:"SKIP", reason:"fewer-than-two-branches", branches:$n}'
    return 0
  fi

  # The base and every branch must resolve to a commit before we touch a
  # worktree — a bad ref should be a clean ERROR, not a half-built worktree.
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || die "base ref '$base' not found in $repo"
  local b
  for b in "${branches[@]}"; do
    git -C "$repo" rev-parse --verify --quiet "$b^{commit}" >/dev/null 2>&1 \
      || die "branch ref '$b' not found in $repo"
  done

  # Throwaway detached worktree at the base. It shares the repo's object store
  # (a linked worktree), so every branch ref above is reachable from it.
  local wt
  wt="$(mktemp -d "${TMPDIR:-/tmp}/combined-tree.XXXXXX")" || die "mktemp failed"
  # rmdir the empty mktemp dir so `git worktree add` (which wants to create it)
  # does not error on an existing path; keep the name for the add.
  rmdir "$wt" 2>/dev/null || true

  # Register the worktree with the script-scope teardown before adding it, so a
  # die() between here and the add still triggers cleanup.
  _CTP_WT="$wt"; _CTP_REPO="$repo"
  trap _ctp_cleanup EXIT

  git -C "$repo" worktree add --detach "$wt" "$base" >/dev/null 2>&1 \
    || die "worktree add at base '$base' failed"

  # Merge each branch into the accumulating union. A non-zero merge is a textual
  # conflict — abort it and report the offending branch. --no-ff keeps each a
  # real merge (so conflicts surface exactly as they would in the queue's
  # merge_group trial branch).
  for b in "${branches[@]}"; do
    if ! git -C "$wt" merge --no-ff --no-edit "$b" >/dev/null 2>&1; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      jq -cn --arg branch "$b" --argjson brs "$brs_json" \
        '{outcome:"CONFLICT", branch:$branch, branches:$brs}'
      return 3
    fi
  done

  # The union merged cleanly. Run the FULL gate suite against it — this is where
  # a semantic collision (green-alone, red-combined) surfaces. Run with cwd =
  # the merged worktree; quality-gates.sh resolves its own repo root, so every
  # `make` target still resolves from the worktree (its own design promise).
  local suiteout rc
  set +e
  suiteout="$(cd "$wt" && eval "$COMBINED_TREE_SUITE_CMD" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    local tail_out
    tail_out="$(printf '%s' "$suiteout" | tail -40)"
    jq -cn --arg out "$tail_out" --argjson code "$rc" --argjson brs "$brs_json" \
      '{outcome:"GATE_FAILED", exit_code:$code, output:$out, branches:$brs}'
    return 4
  fi

  jq -cn --argjson brs "$brs_json" '{outcome:"CLEAN", branches:$brs}'
  return 0
}

# --- dispatch ----------------------------------------------------------------
# Source-guard: when sourced by a test (BASH_SOURCE != $0) skip dispatch so the
# cmd_* functions and the seam are callable directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -ge 1 ] || usage
  repo_arg="$1"; shift
  base="origin/main"
  branch_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)
        [ $# -ge 2 ] || usage
        base="$2"; shift 2 ;;
      --base=*)
        base="${1#--base=}"; shift ;;
      --*) usage ;;
      *) branch_args+=("$1"); shift ;;
    esac
  done
  repo="$(resolve_repo "$repo_arg")"
  cmd_precheck "$repo" "$base" "${branch_args[@]}"
fi
