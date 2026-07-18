#!/usr/bin/env bash
# description: manifest-driven clean exit — reverts every temperloop-init side effect and removes .temperloop/ (or a pre-rename .foundation/)
#
# eject.sh — `temperloop eject`: the clean-exit counterpart to `temperloop
# init` (foundation #765 Epic D "newcomer experience", item foundation-eject
# / #855).
#
# RENAME WINDOW (temperloop#165, v0.14.0): the per-repo dir is
# `.temperloop/`; a pre-rename adoption used `.foundation/`. Every read
# below prefers the new dir and falls back to the legacy one, and eject
# removes BOTH — cleaning legacy residue stays supported even past the
# v0.16.0 window close (it is exactly this subcommand's job). Comments
# below name only `.temperloop/` for brevity.
#
# `temperloop init` (kernel/bin/subcommands/init.sh) is documented as the
# SOLE WRITER of `.temperloop/config`, and records every API-state side
# effect it produces (a label, a required-check setting, a proposal
# branch/PR, a provisioned board) in that file's `installs[]` array. This
# script is the ONLY reader of that manifest for the purpose of reverting
# it — it inspects `.temperloop/config`, undoes exactly the recorded set,
# and removes `.temperloop/` itself. Nothing here is inferred by namespace
# grep (e.g. scanning for `fnd:`-prefixed labels) — a label the user created
# independently, with no matching `installs[]` entry, is never touched.
#
# TREE vs API-STATE, the same split init.sh draws:
#   - `.temperloop/config` itself is a TREE artifact, already present in the
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
# MERGED, its tree changes (`.temperloop/config`, an optional
# `boards.conf` entry) are already part of the target repo's default
# branch — reverting them is explicitly OUT OF SCOPE (see the "acceptance"
# framing in the epic: "byte-identical modulo proposal PRs the user chose
# to merge"). If it was never merged (still OPEN, or CLOSED without
# merging), this script closes it and deletes the branch (local + remote) —
# so an abandoned/declined proposal leaves no trace.
#
# IDEMPOTENT BY CONSTRUCTION: a fully successful revert deletes
# `.temperloop/config` as its last step, so a second run finds nothing and
# no-ops (prints a message, exit 0, zero `gh` calls). A PARTIAL revert (some
# install action failed — e.g. `gh` transiently unreachable) rewrites
# `.temperloop/config` to keep ONLY the unresolved entries, so a re-run
# retries just those, converging without re-doing already-reverted work.
#
# PARTIAL/FAILED INIT RECOVERY (temperloop#414): a run of `temperloop init`
# that dies before ever reaching its own SOLE-WRITER step (init.sh's Step 0
# writes `.temperloop/baseline.jsonl` before `.temperloop/config` exists)
# leaves `.temperloop/` residue with no config to gate on — the "nothing to
# eject" check below therefore keys on `.temperloop/` PRESENCE, not on
# config presence, so this residue is always recognized and cleaned up. A
# run that dies AFTER its branch switch (init.sh's proposal-pr.sh call,
# which does `git checkout -B <branch>`) additionally leaves the checkout on
# that stray branch with an unmerged local commit. init.sh records the
# branch it switched FROM in an untracked `.temperloop/.recovery.json`
# marker immediately before the switch, and deletes it immediately once the
# switch's outcome is known (success either way) — see init.sh's own header
# note. This script is the marker's reader: when it finds the marker AND
# the checkout is still sitting on the branch it names, it restores the
# recorded original branch and deletes the stray one as part of the same
# consented revert this script already gates everything else behind (never
# on `--dry-run`, never without --yes/an interactive confirm) — so ejecting
# a partial run leaves the repo exactly as it was: no `.temperloop/`
# residue, original branch restored, no stray unmerged branch.
#
# Usage:
#   eject.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
#            [--yes] [--dry-run]
#
#   --dir DIR             Git checkout to eject. Default: current dir.
#   --gh-repo OWNER/REPO  Overrides the repo recorded in .temperloop/config's
#                          probe.repo.gh_repo (usually unnecessary — the
#                          manifest already carries it from the init run
#                          that produced it).
#   --no-network           Skip every API-state revert action (label/
#                          required-check/board/proposal_pr) with a legible
#                          skip reason; .temperloop/config is left with
#                          those entries so a later run can retry.
#   --yes                  Pre-confirm the revert instead of an interactive
#                          y/N prompt. Required on a non-interactive stdin —
#                          absent both, the whole run aborts with NOTHING
#                          reverted and .temperloop/config left intact
#                          (the same "nothing lands without explicit
#                          consent" default init.sh uses, mirrored for the
#                          also-mutating uninstall direction).
#   --dry-run               Print what would be reverted; zero `gh` calls,
#                          .temperloop/config left untouched.
#
# Exit codes: 0 = ran to completion (a declined confirmation or an empty
# manifest is a legible no-op, not a failure). 1 = fatal usage/environment
# error, OR a partial revert (some install entries could not be reverted —
# see the rewritten .temperloop/config). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), git, jq. `gh` is optional — its absence
# degrades only the API-state revert step (every install entry reports
# "skipped", .temperloop/config is left in place for a later retry).
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
  (c) THIS repo's .temperloop/config side effects (labels, required
      checks, boards, proposal PRs; a pre-v0.14.0 init recorded them in
      .foundation/config) — what 'temperloop eject' just did.
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

echo "== temperloop eject =="
echo

# temperloop#165 rename window: `.temperloop/` is the canonical per-repo dir
# (written by v0.14.0+ inits); a pre-rename adoption left `.foundation/`.
# Eject CLEANS EITHER — deliberately in force even past the window close
# (removing legacy residue is exactly this subcommand's job), so no
# TEMPERLOOP_LEGACY_WINDOW_CLOSED arm exists here. Reads (config, recovery
# marker) prefer the new dir and fall back to the legacy one; the
# partial-failure rewrite goes back to whichever file was actually read.
tl_dir="$repo_dir/.temperloop"
legacy_dir="$repo_dir/.foundation"
config_rel=".temperloop/config"
config_path="$repo_dir/$config_rel"
if [ ! -f "$config_path" ] && [ -f "$legacy_dir/config" ]; then
  config_rel=".foundation/config"
  config_path="$legacy_dir/config"
  echo "NOTE: reading legacy $config_rel (renamed .temperloop/config in v0.14.0; 'temperloop eject' cleans either dir)."
  echo
fi
# Human-readable name for "what eject removes" in the messages below.
tl_dirs_desc="$tl_dir"
if [ -d "$legacy_dir" ]; then
  if [ -d "$tl_dir" ]; then tl_dirs_desc="$tl_dir + $legacy_dir"; else tl_dirs_desc="$legacy_dir"; fi
fi

# ---------------------------------------------------------------------------
# Step 0 — no .temperloop/ AND no legacy .foundation/ AT ALL, nothing to do.
# Keyed on the DIRECTORIES, not on config_path (temperloop#414): a
# partial/failed 'temperloop init' can leave dir residue (init.sh Step 0's
# baseline.jsonl, written BEFORE the config exists) with no config ever
# written, and that residue must still be recognized as something to eject
# — see the dedicated branch below. This check is also the SECOND-RUN
# idempotency path: a fully successful revert removes both dirs entirely as
# its last step, so a re-run finds nothing here and no-ops.
# ---------------------------------------------------------------------------
if [ ! -d "$tl_dir" ] && [ ! -d "$legacy_dir" ]; then
  echo "No .temperloop/ (or legacy .foundation/) found in $repo_dir — nothing to eject (already ejected, or"
  echo "  'temperloop init' was never run here)."
  echo
  print_uninstall_bullet
  echo
  echo "temperloop eject: done (no-op)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Recovery marker (temperloop#414, written by init.sh — see its own header
# note): present + naming the CURRENT branch means init's own branch switch
# (Step 3's proposal-pr.sh `git checkout -B`) was never followed by a clean
# completion — the checkout is sitting on a stray, unmerged branch.
# recovery_active gates restore_original_branch below, which is only ever
# invoked once the per-repo dir(s) are about to be fully removed (never mid
# a PARTIAL-failure retry, where config_path must stay put on this same
# branch for a later re-run to retry against). Probes the new dir first,
# then the legacy one (a marker left by a pre-rename init).
# ---------------------------------------------------------------------------
recovery_path="$tl_dir/.recovery.json"
[ -f "$recovery_path" ] || recovery_path="$legacy_dir/.recovery.json"
recovery_active=0
recovery_original_branch=""
recovery_proposal_branch=""
if [ -f "$recovery_path" ]; then
  if recovery_json="$(jq -e '.' "$recovery_path" 2>/dev/null)"; then
    recovery_original_branch="$(jq -r '.original_branch // empty' <<<"$recovery_json")"
    recovery_proposal_branch="$(jq -r '.proposal_branch // empty' <<<"$recovery_json")"
    recovery_cur_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [ -n "$recovery_original_branch" ] && [ -n "$recovery_proposal_branch" ] \
        && [ "$recovery_original_branch" != "$recovery_proposal_branch" ] \
        && [ "$recovery_cur_branch" = "$recovery_proposal_branch" ]; then
      recovery_active=1
    fi
  fi
fi

restore_original_branch() {
  [ "$recovery_active" -eq 1 ] || return 0
  if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$recovery_original_branch"; then
    echo "branch: original branch '$recovery_original_branch' no longer exists locally — leaving on '$recovery_proposal_branch'"
    return 1
  fi
  if ! git -C "$repo_dir" checkout -q "$recovery_original_branch" 2>/dev/null; then
    echo "branch: FAILED to check out '$recovery_original_branch' — leaving on '$recovery_proposal_branch'"
    return 1
  fi
  echo "branch: restored '$recovery_original_branch' (was on stray '$recovery_proposal_branch' from an interrupted init run)"
  if git -C "$repo_dir" branch -D "$recovery_proposal_branch" >/dev/null 2>&1; then
    echo "branch: deleted stray '$recovery_proposal_branch'"
  else
    echo "branch: FAILED to delete stray '$recovery_proposal_branch'"
    return 1
  fi
  return 0
}

# _eject_confirm PROMPT — mirrors init.sh's _init_confirm default: nothing
# reverted without explicit consent (--yes, or an interactive y/N). This is
# the revert-direction twin of that same rule; a non-interactive run with
# no --yes returns 1 (decline), leaving everything on disk untouched.
_eject_confirm() {
  local prompt="$1"
  if [ "$do_yes" -eq 1 ]; then
    echo "revert: yes (--yes)"
    return 0
  fi
  if [ -t 0 ]; then
    local ans=""
    printf '%s [y/N] ' "$prompt"
    read -r ans || ans=""
    case "$ans" in
      y|Y|yes|YES) echo "revert: yes (operator confirmed)"; return 0 ;;
      *) echo "revert: no (operator declined)"; return 1 ;;
    esac
  fi
  echo "revert: no (skipped — no explicit consent; non-interactive; pass --yes to opt in)"
  return 1
}

if [ "$recovery_active" -eq 1 ]; then
  echo "-- Recovery (interrupted 'foundation init' run) --"
  echo "  currently on stray branch '$recovery_proposal_branch' — original branch was '$recovery_original_branch'"
  echo
fi

# ---------------------------------------------------------------------------
# Partial-init residue: a per-repo dir exists but no config was ever
# written (or never survived) — nothing was ever recorded to revert via gh,
# so this is a pure local cleanup (+ the recovery restore above, when
# applicable).
# ---------------------------------------------------------------------------
if [ ! -f "$config_path" ]; then
  echo "-- Partial-init residue: $tl_dirs_desc present, no $config_rel (no install manifest was ever recorded) --"
  echo

  extra_msg=""
  [ "$recovery_active" -eq 1 ] && extra_msg=", restore branch '$recovery_original_branch', and delete stray '$recovery_proposal_branch'"

  if [ "$dry_run" -eq 1 ]; then
    echo "-- Dry run: would remove $tl_dirs_desc$extra_msg. Nothing done --"
    echo
    echo "temperloop eject: done (dry run)"
    exit 0
  fi

  if _eject_confirm "Remove $tl_dirs_desc (no install manifest recorded)?"; then
    proceed=1
  else
    proceed=0
  fi
  echo

  if [ "$proceed" -ne 1 ]; then
    echo "temperloop eject: aborted — nothing removed, $tl_dirs_desc left intact"
    exit 0
  fi

  recovery_failed=0
  restore_original_branch || recovery_failed=1
  rm -rf "${repo_dir:?}/.temperloop" "${repo_dir:?}/.foundation"
  echo "partial init residue removed ($tl_dirs_desc)"
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  fi
  echo "temperloop eject: done"
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
  extra_msg=""
  [ "$recovery_active" -eq 1 ] && extra_msg=", restore branch '$recovery_original_branch', and delete stray '$recovery_proposal_branch'"
  echo "-- Dry run: would revert the $n_installs install(s) above, then remove"
  echo "   $config_rel$extra_msg. Nothing done (zero gh calls, config untouched) --"
  echo
  echo "temperloop eject: done (dry run)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Consent gate — see _eject_confirm above.
# ---------------------------------------------------------------------------
if _eject_confirm "Revert the $n_installs install(s) above and remove $config_rel?"; then
  proceed=1
else
  proceed=0
fi
echo

if [ "$proceed" -ne 1 ]; then
  echo "temperloop eject: aborted — nothing reverted, $config_rel left intact"
  exit 0
fi

if [ "$n_installs" -eq 0 ]; then
  recovery_failed=0
  restore_original_branch || recovery_failed=1
  rm -rf "${repo_dir:?}/.temperloop" "${repo_dir:?}/.foundation"
  echo "nothing recorded to revert — $config_rel removed"
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  fi
  echo "temperloop eject: done"
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
  recovery_failed=0
  restore_original_branch || recovery_failed=1
  rm -rf "${repo_dir:?}/.temperloop" "${repo_dir:?}/.foundation"
  echo "all $n_installs install(s) reverted; $config_rel removed"
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  fi
  echo "temperloop eject: done"
  exit 0
else
  new_config_json="$(jq -c --argjson installs "$unresolved_installs" '.installs = $installs' <<<"$config_json")"
  printf '%s\n' "$new_config_json" | jq '.' > "$config_path" 2>/dev/null \
    || printf '%s' "$new_config_json" > "$config_path"
  echo "$n_unresolved of $n_installs install(s) could not be reverted — $config_rel updated to"
  echo "  record only the remainder. Re-run 'temperloop eject' once resolved."
  echo
  echo "temperloop eject: incomplete"
  exit 1
fi
