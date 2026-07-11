#!/usr/bin/env bash
# description: manifest-driven clean exit — reverts every foundation-init side effect and removes .foundation/
#
# eject.sh — `foundation eject`: the clean-exit counterpart to `foundation
# init` (foundation #765 Epic D "newcomer experience", item foundation-eject
# / #855).
#
# `foundation init` (kernel/bin/subcommands/init.sh) is documented as the
# SOLE WRITER of `.foundation/config`, and records every API-state side
# effect it produces (a label, a required-check setting, a proposal
# branch/PR, a provisioned board) in that file's `installs[]` array. This
# script is the ONLY reader of that manifest for the purpose of reverting
# it — it inspects `.foundation/config`, undoes exactly the recorded set,
# and removes `.foundation/` itself. Nothing here is inferred by namespace
# grep (e.g. scanning for `fnd:`-prefixed labels) — a label the user created
# independently, with no matching `installs[]` entry, is never touched.
#
# TREE vs API-STATE, the same split init.sh draws:
#   - `.foundation/config` itself is a TREE artifact, already present in the
#     local working copy (init.sh's proposal-pr.sh call leaves the local
#     checkout ON the proposal branch with the file committed there,
#     regardless of whether that branch's PR ever merged upstream) — so
#     this script reads it straight off disk, no network needed for that
#     part. Removing it at the end is a plain `rm -rf`, not a second
#     proposal PR (subtraction over mechanism — there is no world where
#     "propose a PR to delete the file that undoes everything" is simpler
#     than just deleting it).
#   - Every `installs[]` entry is an API-STATE side effect (or, for
#     `proposal_pr`, a GitHub ref) and is reverted via `gh`, gated exactly
#     like init.sh's consented-apply step: explicit confirmation (--yes or
#     an interactive y/N), and a legible skip when offline / `gh` missing /
#     no resolvable repo — never a silent partial revert.
#
# proposal_pr entries get special handling: a `type":"proposal_pr"` install
# records the branch init.sh's proposal-pr.sh call opened. If that PR was
# MERGED, its tree changes (`.foundation/config`, an optional
# `boards.conf` entry) are already part of the target repo's default
# branch — reverting them is explicitly OUT OF SCOPE (see the "acceptance"
# framing in the epic: "byte-identical modulo proposal PRs the user chose
# to merge"). If it was never merged (still OPEN, or CLOSED without
# merging), this script closes it and deletes the branch (local + remote) —
# so an abandoned/declined proposal leaves no trace.
#
# IDEMPOTENT BY CONSTRUCTION: a fully successful revert deletes
# `.foundation/config` as its last step, so a second run finds nothing and
# no-ops (prints a message, exit 0, zero `gh` calls). A PARTIAL revert (some
# install action failed — e.g. `gh` transiently unreachable) rewrites
# `.foundation/config` to keep ONLY the unresolved entries, so a re-run
# retries just those, converging without re-doing already-reverted work.
#
# Usage:
#   eject.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
#            [--yes] [--dry-run]
#
#   --dir DIR             Git checkout to eject. Default: current dir.
#   --gh-repo OWNER/REPO  Overrides the repo recorded in .foundation/config's
#                          probe.repo.gh_repo (usually unnecessary — the
#                          manifest already carries it from the init run
#                          that produced it).
#   --no-network           Skip every API-state revert action (label/
#                          required-check/board/proposal_pr) with a legible
#                          skip reason; .foundation/config is left with
#                          those entries so a later run can retry.
#   --yes                  Pre-confirm the revert instead of an interactive
#                          y/N prompt. Required on a non-interactive stdin —
#                          absent both, the whole run aborts with NOTHING
#                          reverted and .foundation/config left intact
#                          (the same "nothing lands without explicit
#                          consent" default init.sh uses, mirrored for the
#                          also-mutating uninstall direction).
#   --dry-run               Print what would be reverted; zero `gh` calls,
#                          .foundation/config left untouched.
#
# Exit codes: 0 = ran to completion (a declined confirmation or an empty
# manifest is a legible no-op, not a failure). 1 = fatal usage/environment
# error, OR a partial revert (some install entries could not be reverted —
# see the rewritten .foundation/config). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq. `gh` is optional — its absence
# degrades only the API-state revert step (every install entry reports
# "skipped", .foundation/config is left in place for a later retry).
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate sibling kernel content — same pinned-physical-path idiom as
# init.sh / try.sh's own header comments.
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
LIB_DIR="$BIN_DIR/lib"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

command -v jq >/dev/null 2>&1 || { echo "eject.sh: jq not found on PATH" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "eject.sh: git not found on PATH" >&2; exit 1; }

# Test-double seam (mirrors init.sh's INIT_GH_BIN / try.sh's TRY_GH_BIN
# convention) — never overridden in production use.
: "${EJECT_GH_BIN:=gh}"

usage() {
  cat <<'EOF'
usage: eject.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
                [--yes] [--dry-run]
EOF
}

print_uninstall_bullet() {
  cat <<EOF
Three separate removal scopes — this subcommand only handles (c); see
  kernel/bin/README.md § Uninstall for the full table:
  (a) Bootstrap footprint (predates any manifest — manual removal):
        rm -f "$FOUNDATION_CLI_BIN_DEFAULT" "${FOUNDATION_CLI_BIN_DEFAULT%/*}/foundation"
        rm -rf "$FOUNDATION_CLI_HOME_DEFAULT"
  (b) Machine-surface install manifest (settings/config/symlinks a
      'temperloop install' wrote under \$HOME — a separate concern from
      (a) and (c)):
        temperloop uninstall
  (c) THIS repo's .foundation/config side effects (labels, required
      checks, boards, proposal PRs) — what 'foundation eject' just did.
EOF
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
eject_dir="."
gh_repo_flag=""
no_network=0
do_yes=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) eject_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo_flag="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --yes) do_yes=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "eject.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- resolve --dir to a git toplevel (mirrors init.sh's own resolve) -------
abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
repo_dir="$(abs_dir "$eject_dir")" || { echo "eject.sh: --dir '$eject_dir' does not exist" >&2; exit 1; }
repo_top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "eject.sh: --dir '$eject_dir' is not a git working tree" >&2; exit 1; }
repo_dir="$(abs_dir "$repo_top")"

echo "== foundation eject =="
echo

config_rel=".foundation/config"
config_path="$repo_dir/$config_rel"

# ---------------------------------------------------------------------------
# Step 0 — no manifest, nothing to do. This is the SECOND-RUN idempotency
# path too: a fully successful revert deletes config_path as its last step.
# ---------------------------------------------------------------------------
if [ ! -f "$config_path" ]; then
  echo "No $config_rel found in $repo_dir — nothing to eject (already ejected, or"
  echo "  'foundation init' was never run here)."
  echo
  print_uninstall_bullet
  echo
  echo "foundation eject: done (no-op)"
  exit 0
fi

config_json=""
if ! config_json="$(jq -e '.' "$config_path" 2>/dev/null)" \
    || [ "$(jq -r '.schema // empty' <<<"$config_json")" != "1" ]; then
  echo "eject.sh: $config_rel is not valid schema-1 JSON — cannot safely determine" >&2
  echo "  what to revert. Fix or remove $config_rel by hand, then re-run." >&2
  exit 1
fi

installs="$(jq -c '.installs // []' <<<"$config_json")"
n_installs="$(jq 'length' <<<"$installs")"

gh_repo="$gh_repo_flag"
[ -n "$gh_repo" ] || gh_repo="$(jq -r '.probe.repo.gh_repo // empty' <<<"$config_json")"
default_branch="$(jq -r '.probe.repo.default_branch // empty' <<<"$config_json")"

echo "-- Install manifest ($config_rel) --"
echo "$n_installs install(s) recorded:"
if [ "$n_installs" -gt 0 ]; then
  jq -r '.installs[] | "  - " + .type + ": " + ((.name // .branch // .url // "") | tostring)' <<<"$config_json"
fi
echo

if [ "$dry_run" -eq 1 ]; then
  echo "-- Dry run: would revert the $n_installs install(s) above, then remove"
  echo "   $config_rel. Nothing done (zero gh calls, config untouched) --"
  echo
  echo "foundation eject: done (dry run)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Consent gate — mirrors init.sh's _init_confirm default: nothing reverted
# without explicit consent (--yes, or an interactive y/N). This is the
# revert-direction twin of that same rule; a non-interactive run with no
# --yes aborts entirely, leaving config_path untouched.
# ---------------------------------------------------------------------------
proceed=0
if [ "$do_yes" -eq 1 ]; then
  proceed=1
  echo "revert: yes (--yes)"
elif [ -t 0 ]; then
  printf 'Revert the %s install(s) above and remove %s? [y/N] ' "$n_installs" "$config_rel"
  ans=""
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) proceed=1; echo "revert: yes (operator confirmed)" ;;
    *) echo "revert: no (operator declined)" ;;
  esac
else
  echo "revert: no (skipped — no explicit consent; non-interactive; pass --yes to opt in)"
fi
echo

if [ "$proceed" -ne 1 ]; then
  echo "foundation eject: aborted — nothing reverted, $config_rel left intact"
  exit 0
fi

if [ "$n_installs" -eq 0 ]; then
  rm -rf "${repo_dir:?}/.foundation"
  echo "nothing recorded to revert — $config_rel removed"
  echo
  print_uninstall_bullet
  echo
  echo "foundation eject: done"
  exit 0
fi

# ---------------------------------------------------------------------------
# API-state revert step. Gated exactly like init.sh's consented-apply step:
# offline / no gh_repo / no gh binary all degrade to a legible per-entry
# skip, never a silent partial revert.
# ---------------------------------------------------------------------------
api_state_reason=""
if [ "$no_network" -eq 1 ]; then
  api_state_reason="--no-network"
elif [ -z "$gh_repo" ]; then
  api_state_reason="no resolved gh_repo (pass --gh-repo)"
elif ! command -v "$EJECT_GH_BIN" >/dev/null 2>&1; then
  api_state_reason="gh CLI not found on PATH"
fi

echo "-- Reverting recorded installs --"

unresolved_installs="[]"
mark_unresolved() {
  unresolved_installs="$(jq -c --argjson e "$1" '. + [$e]' <<<"$unresolved_installs")"
}

# --- required_check: {type,repo,branch,name} — DELETE the required-check
# setting init.sh's PATCH added. init.sh's PATCH fully replaces the
# contexts array with just "checks", so the inverse of "add" here is
# "remove the required-status-checks requirement entirely" (mirrors what a
# fresh repo looked like before init.sh's PATCH ever ran). ------------------
revert_required_check() {
  local entry="$1" repo branch name
  repo="$(jq -r '.repo' <<<"$entry")"
  branch="$(jq -r '.branch' <<<"$entry")"
  name="$(jq -r '.name' <<<"$entry")"
  if [ -n "$api_state_reason" ]; then
    echo "required-check '$name' ($repo@$branch): skipped ($api_state_reason)"
    mark_unresolved "$entry"
    return
  fi
  if "$EJECT_GH_BIN" api --method DELETE \
      "repos/$repo/branches/$branch/protection/required_status_checks" >/dev/null 2>&1; then
    echo "required-check '$name' ($repo@$branch): removed"
  elif ! "$EJECT_GH_BIN" api "repos/$repo/branches/$branch/protection/required_status_checks" >/dev/null 2>&1; then
    echo "required-check '$name' ($repo@$branch): already absent — skipped"
  else
    echo "required-check '$name' ($repo@$branch): FAILED to remove"
    mark_unresolved "$entry"
  fi
}

# --- label: {type,repo,name} ------------------------------------------------
revert_label() {
  local entry="$1" repo name
  repo="$(jq -r '.repo' <<<"$entry")"
  name="$(jq -r '.name' <<<"$entry")"
  if [ -n "$api_state_reason" ]; then
    echo "label '$name' ($repo): skipped ($api_state_reason)"
    mark_unresolved "$entry"
    return
  fi
  if "$EJECT_GH_BIN" label delete "$name" -R "$repo" --yes >/dev/null 2>&1; then
    echo "label '$name' ($repo): deleted"
  elif ! "$EJECT_GH_BIN" label list -R "$repo" --json name -q '.[].name' 2>/dev/null | grep -Fxq "$name"; then
    echo "label '$name' ($repo): already absent — skipped"
  else
    echo "label '$name' ($repo): FAILED to delete"
    mark_unresolved "$entry"
  fi
}

# --- board: {type,owner,project_number,url} ---------------------------------
revert_board() {
  local entry="$1" owner project_number url
  owner="$(jq -r '.owner' <<<"$entry")"
  project_number="$(jq -r '.project_number // empty' <<<"$entry")"
  url="$(jq -r '.url // empty' <<<"$entry")"
  if [ -n "$api_state_reason" ]; then
    echo "board #${project_number:-?} ($owner): skipped ($api_state_reason)"
    mark_unresolved "$entry"
    return
  fi
  if [ -z "$project_number" ]; then
    echo "board ($owner, $url): no project_number recorded — remove by hand: $url"
    mark_unresolved "$entry"
    return
  fi
  if "$EJECT_GH_BIN" project delete "$project_number" --owner "$owner" >/dev/null 2>&1; then
    echo "board #$project_number ($owner): deleted"
  elif ! "$EJECT_GH_BIN" project view "$project_number" --owner "$owner" >/dev/null 2>&1; then
    echo "board #$project_number ($owner): already absent — skipped"
  else
    echo "board #$project_number ($owner): FAILED to delete"
    mark_unresolved "$entry"
  fi
}

# --- proposal_pr: {type,branch,pr_number,url} -------------------------------
# MERGED -> left alone (its tree changes stay — "modulo proposal PRs the
#   user chose to merge"). OPEN -> closed + branch deleted (local + remote).
# CLOSED (already, unmerged) -> best-effort branch cleanup only.
revert_proposal_pr() {
  local entry="$1" branch pr_number url pr_repo state cur_branch target
  branch="$(jq -r '.branch' <<<"$entry")"
  pr_number="$(jq -r '.pr_number // empty' <<<"$entry")"
  url="$(jq -r '.url // empty' <<<"$entry")"

  pr_repo="$(printf '%s' "$url" | sed -n 's#https\{0,1\}://github\.com/\([^/]*/[^/]*\)/pull/.*#\1#p')"
  [ -n "$pr_repo" ] || pr_repo="$gh_repo"

  if [ -n "$api_state_reason" ]; then
    echo "proposal_pr branch '$branch': skipped ($api_state_reason)"
    mark_unresolved "$entry"
    return
  fi
  if [ -z "$pr_repo" ] || [ -z "$pr_number" ]; then
    echo "proposal_pr branch '$branch': cannot resolve repo/PR number — leaving as-is"
    mark_unresolved "$entry"
    return
  fi

  state="$("$EJECT_GH_BIN" pr view "$pr_number" -R "$pr_repo" --json state -q '.state' 2>/dev/null)"
  if [ -z "$state" ]; then
    echo "proposal_pr #$pr_number ($pr_repo): could not resolve PR state — leaving branch '$branch' as-is"
    mark_unresolved "$entry"
    return
  fi

  # If the branch is the repo's current checkout, switch off it first — a
  # checked-out branch can't be deleted (locally or via --delete-branch).
  cur_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ "$cur_branch" = "$branch" ]; then
    for target in "$default_branch" main master; do
      [ -n "$target" ] || continue
      git -C "$repo_dir" checkout -q "$target" 2>/dev/null && break
      git -C "$repo_dir" checkout -q -B "$target" "origin/$target" 2>/dev/null && break
    done
  fi

  case "$state" in
    MERGED)
      echo "proposal_pr #$pr_number ($pr_repo): merged — left in tree, not reverted (branch '$branch' kept)"
      ;;
    OPEN)
      if (cd "$repo_dir" && "$EJECT_GH_BIN" pr close "$pr_number" -R "$pr_repo" --delete-branch >/dev/null 2>&1); then
        echo "proposal_pr #$pr_number ($pr_repo): closed, branch '$branch' deleted"
      else
        echo "proposal_pr #$pr_number ($pr_repo): FAILED to close / delete branch '$branch'"
        mark_unresolved "$entry"
      fi
      ;;
    CLOSED)
      git -C "$repo_dir" branch -D "$branch" >/dev/null 2>&1 || true
      "$EJECT_GH_BIN" api --method DELETE "repos/$pr_repo/git/refs/heads/$branch" >/dev/null 2>&1 || true
      echo "proposal_pr #$pr_number ($pr_repo): already closed (unmerged) — branch '$branch' cleanup best-effort"
      ;;
    *)
      echo "proposal_pr #$pr_number ($pr_repo): unexpected state '$state' — leaving as-is"
      mark_unresolved "$entry"
      ;;
  esac
}

n="$(jq 'length' <<<"$installs")"
i=0
while [ "$i" -lt "$n" ]; do
  entry="$(jq -c ".[$i]" <<<"$installs")"
  type="$(jq -r '.type' <<<"$entry")"
  case "$type" in
    required_check) revert_required_check "$entry" ;;
    label) revert_label "$entry" ;;
    board) revert_board "$entry" ;;
    proposal_pr) revert_proposal_pr "$entry" ;;
    *)
      echo "$type: unknown install type — leaving recorded"
      mark_unresolved "$entry"
      ;;
  esac
  i=$((i + 1))
done
echo

# ---------------------------------------------------------------------------
# Summary + config_path fate.
# ---------------------------------------------------------------------------
n_unresolved="$(jq 'length' <<<"$unresolved_installs")"
echo "-- Summary --"
if [ "$n_unresolved" -eq 0 ]; then
  rm -rf "${repo_dir:?}/.foundation"
  echo "all $n_installs install(s) reverted; $config_rel removed"
  echo
  print_uninstall_bullet
  echo
  echo "foundation eject: done"
  exit 0
else
  new_config_json="$(jq -c --argjson installs "$unresolved_installs" '.installs = $installs' <<<"$config_json")"
  printf '%s\n' "$new_config_json" | jq '.' > "$config_path" 2>/dev/null \
    || printf '%s' "$new_config_json" > "$config_path"
  echo "$n_unresolved of $n_installs install(s) could not be reverted — $config_rel updated to"
  echo "  record only the remainder. Re-run 'foundation eject' once resolved."
  echo
  echo "foundation eject: incomplete"
  exit 1
fi
