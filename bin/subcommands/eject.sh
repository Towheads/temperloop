#!/usr/bin/env bash
# description: manifest-driven clean exit — reverts every temperloop-init side effect and removes .temperloop/ (or a pre-rename .foundation/)
#
# eject.sh — `temperloop eject`: the clean-exit counterpart to `temperloop
# init` (foundation #765 Epic D "newcomer experience", item foundation-eject
# / #855).
#
# LEGACY PER-REPO DIR (temperloop#165, v0.15.0): the per-repo dir is
# `.temperloop/`; a pre-rename adoption used `.foundation/`. Every read
# below prefers the new dir and falls back to the legacy one, and eject
# removes BOTH — cleaning legacy residue stays supported now that the
# v0.19.0 window has closed (it is exactly this subcommand's job). Comments
# below name only `.temperloop/` for brevity.
#
# `temperloop init` (kernel/bin/subcommands/init.sh) is documented as the
# SOLE WRITER of `.temperloop/config`, and records what it produces in that
# file's `installs[]` array. This script is the ONLY reader of that manifest
# for the purpose of reverting it — it inspects `.temperloop/config`, undoes
# exactly the recorded set, and removes `.temperloop/` itself. Nothing here
# is inferred by namespace grep (e.g. scanning for `fnd:`-prefixed labels) —
# a label the user created independently, with no matching `installs[]`
# entry, is never touched.
#
# WHAT IS ACTUALLY IN THAT MANIFEST, post-scope-down (temperloop#796):
#   - What init STILL produces: a proposal branch/PR. That is the whole set
#     for a repo adopted on or after the scope-down, because `init` no
#     longer applies API state at all.
#   - What a PRE-SCOPE-DOWN init produced, still revertible: a label, a
#     required-check setting, a provisioned board. Those handlers are kept
#     as READ-COMPAT (see the dispatch near the bottom of this file) so an
#     adopter who ran an older `init` can still eject cleanly. They mint
#     nothing new. Removal window: **v0.20.0**, the pre-scope-down compat
#     window — the same release that drops init.sh's deprecated
#     `--yes/--no-required-check`, `--yes/--no-labels`, `--yes/--no-board`
#     flags, because both halves serve exactly that one cohort (see
#     init.sh's "DEPRECATED FLAGS" header note).
#
# WHAT THIS SCRIPT DOES NOT REVERT, and cannot: the substrate the FIRST
# EPIC applies (branch protection, head-branch auto-delete, the merge-queue
# disposition, a scaffolded CI workflow, the recorded `§ Principles`
# disposition). That is API state and adopter-repo content applied by
# `/assess --epic N` -> `/build`, not by `init` — and `/build` deliberately
# has no write channel into `.temperloop/config` (that would break init's
# sole-writer contract), so none of it is ever recorded here for this
# script to find. It is scope (e) in kernel/bin/README.md § Uninstall, it
# is undone by hand, and print_uninstall_bullet() below says so on every
# run rather than letting a clean `all N install(s) reverted` imply
# otherwise. Undo steps: docs/features/engineering-principles.md
# § "Uninstall / removal".
#
# NOT part of that revertible set: the first-epic issue (accept path) and
# its decline re-offer pointer (decline path) init.sh's first-epic offer
# files. Neither is a revertible API-state side effect — eject must never
# close/edit an epic issue an adopter may already be working — so as of
# temperloop#794 init.sh no longer writes either into `installs[]` at all.
# See revert_first_epic_marker() below for the read-compat handling of a
# config an OLDER init already wrote one of these types into.
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
# PRICING.JSON IS NEVER REMOVED (temperloop#985): a hand-authored
# `.temperloop/pricing.json` (the operator's own $/Mtok price table, read by
# `temperloop report` -- see report.sh) is operator data, not a temperloop
# artifact -- nothing in `installs[]` ever produces it, so nothing in this
# script's revert model removes it either. `eject_remove_dirs()` below is
# the ONE place `.temperloop/` (+ legacy `.foundation/`) is actually
# removed, at all three call sites (partial-init residue, an empty install
# manifest, and a fully resolved revert) -- it stashes pricing.json before
# the `rm -rf`, restores it after, and gates its one-line "kept" notice on
# the file actually being back (never on stash bookkeeping) -- and arms an
# interrupt handler across the window so a Ctrl-C/SIGTERM/SIGHUP puts it
# back and EXITS (never resumes into a false "done" over a partially
# removed tree), rather than leaving it under an undiscoverable stash name
# once .temperloop/ is already gone. A failed stash, or `rm -rf` itself
# exiting non-zero, aborts/fails the whole removal instead of proceeding
# over or claiming success on a state it can't guarantee -- callers check
# eject_remove_dirs's return value. Silent (a bare `rm -rf`, same as before
# this change) when no pricing.json is present. The interrupt handler and
# any value it needs are named functions / script-scoped variables, NEVER
# data interpolated into a trap string -- a second review pass found that
# pattern was a command-injection hole (a repo path can contain shell
# metacharacters). See `eject_remove_dirs()`'s own header for the full
# contract.
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
# recorded original branch, deletes the stray LOCAL branch, and (temperloop
# #967) makes a best-effort attempt to delete the same branch on the REMOTE
# too — proposal-pr.sh pushes BEFORE it opens the PR, so a run that dies at
# or after the push (a failed `gh pr create`, a killed process) can leave
# the branch sitting on the remote with no PR ever opened to record it in
# `installs[]`. That remote attempt is unconditional and best-effort (there
# is no way to tell from the marker alone whether the push landed), gated by
# the same --no-network/gh-availability checks as every other API-state
# action, and never itself treated as fatal — see restore_original_branch()
# below. All of this rides the same consented revert this script already
# gates everything else behind (never on `--dry-run`, never without --yes/an
# interactive confirm) — so ejecting a partial run leaves the repo exactly
# as it was: no `.temperloop/` residue, original branch restored, no stray
# unmerged branch either locally or on the remote.
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
# init.sh / testbed.sh's own header comments.
# ---------------------------------------------------------------------------
SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
LIB_DIR="$BIN_DIR/lib"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

command -v jq >/dev/null 2>&1 || { echo "eject.sh: jq not found on PATH" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "eject.sh: git not found on PATH" >&2; exit 1; }

# Test-double seam (mirrors init.sh's INIT_GH_BIN / baseline-snapshot.sh's
# BASELINE_SNAPSHOT_GH_BIN convention) — never overridden in production use.
: "${EJECT_GH_BIN:=gh}"

usage() {
  cat <<'EOF'
usage: eject.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
                [--yes] [--dry-run]
EOF
}

print_uninstall_bullet() {
  cat <<EOF
Five separate removal scopes — this subcommand only handles (c); see
  kernel/bin/README.md § Uninstall for the full table:
  (a) Bootstrap footprint (predates any manifest — manual removal):
        rm -f "$TEMPERLOOP_CLI_BIN_DEFAULT" "${TEMPERLOOP_CLI_BIN_DEFAULT%/*}/foundation"
        rm -rf "$TEMPERLOOP_CLI_HOME_DEFAULT"
  (b) Machine-surface install manifest (settings/config/symlinks a
      'temperloop install' wrote under \$HOME — a separate concern from
      (a) and (c)):
        temperloop uninstall
  (c) THIS repo's .temperloop/config side effects (a proposal PR, including
      the local AND remote 'foundation-init/*' branch it opened — whether
      the PR merged, is still open, was closed unmerged, or the run never
      reached a PR at all (a killed process, a failed push, a failed
      'gh pr create') and only left the branch behind, restored via the
      .temperloop/.recovery.json marker; plus the labels, required checks
      and board a PRE-SCOPE-DOWN init recorded — a pre-v0.15.0 init
      recorded them in .foundation/config)
      — what 'temperloop eject' just did.
  (d) Issue-cache store root (regenerable cache, deliberately untracked —
      manual, optional):
        rm -rf "\${CACHE_STORE_ROOT:-\${XDG_CACHE_HOME:-\$HOME/.cache}/temperloop}"
  (e) FIRST-EPIC SUBSTRATE — branch protection, head-branch auto-delete,
      the merge-queue disposition, any scaffolded CI workflow, and the
      recorded principles disposition. Applied by the first epic via
      /assess -> /build, NOT by init, so it is not in the manifest above
      and 'temperloop eject' does NOT revert it. Undo by hand in your
      repo's Settings -> Branches (and delete the workflow file); the
      step-by-step list is in docs/features/engineering-principles.md
      § "Uninstall / removal".
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

# temperloop#165 rename: `.temperloop/` is the canonical per-repo dir
# (written by v0.15.0+ inits); a pre-rename adoption left `.foundation/`.
# Eject CLEANS EITHER — deliberately still in force now that the v0.19.0
# window has closed, because removing legacy residue is exactly this
# subcommand's job (the window governed which dir the CLI reads and writes
# in normal operation, never which residue this cleanup can reach). Reads
# (config, recovery marker) prefer the new dir and fall back to the legacy
# one; the partial-failure rewrite goes back to whichever file was read.
tl_dir="$repo_dir/.temperloop"
legacy_dir="$repo_dir/.foundation"
config_rel=".temperloop/config"
config_path="$repo_dir/$config_rel"
if [ ! -f "$config_path" ] && [ -f "$legacy_dir/config" ]; then
  config_rel=".foundation/config"
  config_path="$legacy_dir/config"
  echo "NOTE: reading legacy $config_rel (renamed .temperloop/config in v0.15.0; 'temperloop eject' cleans either dir)."
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
# idempotency path FOR A REPO WITH NO PRESERVED pricing.json: a fully
# successful revert removes both dirs entirely as its last step, so a
# re-run finds nothing here and no-ops. When pricing.json WAS preserved,
# `.temperloop/` is NOT empty after that revert (eject_remove_dirs
# recreates it solely to hold that one file back) — Step 0b immediately
# below is what recognizes THAT state as the equivalent no-op.
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
# Step 0b — the ONLY thing left under .temperloop/ is the pricing.json a
# prior 'eject' run deliberately preserved (temperloop#985 review finding):
# no legacy .foundation/, no .temperloop/config (of either name), and
# .temperloop/'s sole entry is pricing.json. This IS the second-run
# idempotency state for a repo that has one — recreating .temperloop/ to
# hold pricing.json back means "nothing under .temperloop/ at all" is no
# longer reachable for such a repo, so this widens Step 0's no-op
# recognition to match rather than letting a re-run fall through to the
# partial-init-residue branch below and "remove" a file that was never
# residue in the first place. Anything else present (a config, a
# report.d/, a .recovery.json) still falls through to the normal handling
# unchanged.
# ---------------------------------------------------------------------------
if [ -d "$tl_dir" ] && [ ! -d "$legacy_dir" ] && [ ! -f "$config_path" ]; then
  tl_only_entry="$(find "$tl_dir" -mindepth 1 -maxdepth 1 2>/dev/null)"
  if [ "$tl_only_entry" = "$tl_dir/pricing.json" ]; then
    echo "Already ejected — .temperloop/ holds only the preserved pricing.json"
    echo "  (kept: .temperloop/pricing.json); nothing else to remove."
    echo
    print_uninstall_bullet
    echo
    echo "temperloop eject: done (no-op)"
    exit 0
  fi
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
    echo "branch: deleted stray '$recovery_proposal_branch' (local)"
  else
    echo "branch: FAILED to delete stray '$recovery_proposal_branch' (local)"
    return 1
  fi

  # --- best-effort REMOTE cleanup (temperloop#967) --------------------------
  # proposal-pr.sh commits, THEN pushes, THEN opens the PR — a run that dies
  # at or after the push (a failed `gh pr create`, a killed process) can
  # leave $recovery_proposal_branch sitting on the remote with no PR ever
  # opened to surface it in installs[] (a `proposal_pr` entry is only folded
  # in once PR_OPENED/EXISTS is known — see init.sh's "BOOTSTRAP ORDERING
  # NOTE"). The recovery marker alone can't tell us whether the push actually
  # landed before the run died, so this attempt is UNCONDITIONAL and silently
  # no-ops when there is nothing there to delete — the same best-effort shape
  # the CLOSED-state cleanup in revert_proposal_pr below already uses for an
  # unmerged PR's branch. Gated exactly like every other API-state action in
  # this script (a legible skip under --no-network / no resolved gh_repo / no
  # gh binary) but never treated as fatal on its own — a skip or a "nothing
  # there" here is the expected, common case (the push itself failed, so
  # nothing was ever pushed), not a sign the revert is incomplete.
  local remote_repo="${gh_repo:-}"
  if [ "$no_network" -eq 1 ]; then
    echo "branch: remote cleanup of '$recovery_proposal_branch' skipped (--no-network)"
  elif [ -z "$remote_repo" ]; then
    echo "branch: remote cleanup of '$recovery_proposal_branch' skipped (no resolved gh_repo — pass --gh-repo)"
  elif ! command -v "$EJECT_GH_BIN" >/dev/null 2>&1; then
    echo "branch: remote cleanup of '$recovery_proposal_branch' skipped (gh CLI not found on PATH)"
  elif "$EJECT_GH_BIN" api --method DELETE \
      "repos/$remote_repo/git/refs/heads/$recovery_proposal_branch" >/dev/null 2>&1; then
    echo "branch: deleted stray '$recovery_proposal_branch' (remote, $remote_repo — in case the push landed before the run died)"
  else
    echo "branch: remote '$recovery_proposal_branch' ($remote_repo) already absent, or could not be deleted — skipped (harmless if the push never landed)"
  fi
  return 0
}

# _eject_restore_pricing_stash STASH DEST DIR_MODE — moves STASH back to
# DEST, recreating DEST's parent dir if needed and best-effort restoring
# its captured mode. Used both by eject_remove_dirs's own normal-path
# restore below AND by the interrupt handler it arms across the removal
# window, so it must be IDEMPOTENT: a no-op once STASH no longer exists,
# which is true both after a successful normal-path restore already moved
# it away, and for a handler firing when nothing was ever stashed. Never
# fails loudly — `mv` errors are swallowed here because the caller
# determines success by checking the OBSERVED end state (does DEST exist
# now?), never by this function's return value (temperloop#985 review
# finding: reporting "kept" from stash bookkeeping rather than the file's
# actual presence is exactly how an operator was told a file survived when
# it hadn't).
#
# `[ -e ]` alone FOLLOWS a symlink and is false for a broken one — a
# second review pass caught that this defeated eject_remove_dirs's own
# `-L` support for an intentionally broken pricing.json symlink: the
# stash (itself a broken symlink in that case) would never be recognized
# as present, so it was silently never moved back, 100% of the time, no
# interrupt required. `[ -e ] || [ -L ]` below matches the `-f`/`-L`
# pairing used everywhere else in this file.
_eject_restore_pricing_stash() {
  local stash="$1" dest="$2" dir_mode="$3"
  [ -n "$stash" ] && { [ -e "$stash" ] || [ -L "$stash" ]; } || return 0
  mkdir -p "$(dirname "$dest")" 2>/dev/null
  [ -z "$dir_mode" ] || chmod "$dir_mode" "$(dirname "$dest")" 2>/dev/null
  mv "$stash" "$dest" 2>/dev/null
}

# _eject_interrupted — the INT/TERM/HUP handler armed across the removal
# window below. A signal handler in bash RESUMES normal script execution
# once it returns unless it exits itself — so this must call `exit`, and
# did not in an earlier version of this fix (review finding, second pass):
# a real Ctrl-C reaches the whole foreground process group, including a
# running `rm -rf` (unlike `kill -TERM $pid` aimed only at the script,
# which is what the first live verification used and which is why it
# didn't catch this) — the child died mid-tree, the handler restored
# pricing.json, and execution CONTINUED past the interrupted `rm -rf`,
# printing "kept" and then "done" over a `.temperloop/` still holding
# thousands of un-removed entries. Exiting here instead of resuming closes
# that: an interrupt now ends the run immediately, after restoring
# pricing.json, with a message naming what state the removal was left in
# — never a resumed "done".
# shellcheck disable=SC2329  # invoked indirectly, by name, via `trap '_eject_interrupted' INT TERM HUP` below -- shellcheck can't see a trap-string call
_eject_interrupted() {
  _eject_restore_pricing_stash "$pricing_stash" "$pricing_src" "$tl_mode"
  if [ -f "$pricing_src" ] || [ -L "$pricing_src" ]; then
    echo "eject: interrupted -- .temperloop/pricing.json restored; .temperloop/ removal may be incomplete, re-run 'temperloop eject' to finish" >&2
  else
    echo "eject: interrupted -- .temperloop/pricing.json could not be confirmed restored; check for a stray $pricing_stash" >&2
  fi
  exit 130
}

# eject_remove_dirs REPO_DIR — the ONE place `.temperloop/` (+ legacy
# `.foundation/`) is actually removed; every removal site below (there are
# three: partial-init residue, an empty install manifest, and a fully
# resolved revert) calls this instead of a bare `rm -rf` (temperloop#985).
#
# A hand-authored `.temperloop/pricing.json` (the operator's own $/Mtok
# price table `temperloop report` reads — see report.sh) is operator data,
# not temperloop state: nothing in this script's install-manifest model
# ever produced it, so nothing in the revert model should delete it either,
# regardless of WHICH of the three removal sites fires. When present (a
# plain file OR a symlink — `-L` so an intentionally broken symlink is
# preserved too, not silently dropped by a `-f` check that only follows
# live links), it is stashed beside `.temperloop/` (same filesystem, so the
# `mv`s are plain renames — no copy, so content is trivially byte-identical
# afterward) BEFORE the `rm -rf` runs, never after — a failed stash aborts
# the whole removal rather than proceeding over a file we couldn't
# guarantee is safe. With no pricing.json present this is silent: a bare
# `rm -rf`, same as before this change, so the common case is unaffected.
#
# TRAP STRINGS ARE SINGLE-QUOTED, NEVER INTERPOLATED (review finding,
# second pass). An earlier version of this function built the trap command
# by interpolating `$pricing_stash`/`$pricing_src`/`$tl_mode` into a
# DOUBLE-quoted trap string, reasoning that their values needed capturing
# "now" rather than looked up later against out-of-scope locals. That
# reasoning was right; the mechanism was a command-injection hole —
# `trap`'s argument is RE-PARSED as shell source when it fires, so those
# values (derived from a repo PATH, via `git rev-parse --show-toplevel`)
# were being spliced into source code, not safely quoted data. A path
# containing `'$(...)'` executed on interrupt; a path containing a plain
# apostrophe silently mis-paired the quotes across arguments and produced
# a no-op restore — the exact stranded-data failure this mechanism exists
# to prevent. Fixed two ways together: (1) the three variables below are
# SCRIPT-scoped (no `local`), so a bare, single-quoted trap string can
# name them and have the shell look them up SAFELY at fire time (real
# double-quoted expansion, not source splicing); (2) the INT/TERM/HUP
# handler is a named function (_eject_interrupted above) referencing them
# directly, so its trap string carries zero data at all — just a function
# name.
#
# Returns 0 on a clean end state: pricing.json (if any) actually restored
# and reported AND `rm -rf` itself exited 0. Returns 1 if the file could
# not be safely stashed (nothing was removed — .temperloop/ is untouched),
# could not be restored after removal (a WARNING names the stash), or
# `rm -rf` exited non-zero (a partial removal — e.g. a non-signal error —
# reported rather than silently claimed complete; a SIGNAL-caused partial
# removal instead exits immediately via _eject_interrupted above, never
# reaching this return at all) — callers must check this and report
# failure rather than the normal success message.
eject_remove_dirs() {
  local dir="$1"
  local rm_rc=0

  # SCRIPT-scoped (no `local`): the interrupt handler above and the trap
  # below both look these up by NAME when they actually fire, never via
  # interpolated values baked into a trap string — see the header note.
  pricing_src="$dir/.temperloop/pricing.json"
  pricing_stash=""
  tl_mode=""

  if [ -f "$pricing_src" ] || [ -L "$pricing_src" ]; then
    # GNU (`-c`) tried FIRST: CI's primary/majority-adopter platform is
    # Linux (.github/workflows/ci.yml pins ubuntu-latest), and BSD-first
    # regressed silently there (review finding, second pass) — GNU's `-f`
    # means `--file-system` and takes no format operand, so `%Lp` lands as
    # a second FILE argument; GNU still exits non-zero (the `||` fires)
    # but only AFTER writing a multi-line filesystem report to stdout,
    # which the command substitution had ALREADY captured, so `tl_mode`
    # ended up holding that report instead of a mode string, and the
    # guarded `chmod` below failed silently on every Linux eject. GNU
    # first degrades cleanly the other direction: BSD `stat` rejects an
    # unrecognized `-c` outright, with no stdout. The `case` guard is a
    # second, independent backstop regardless of order: keep `tl_mode`
    # only if it actually looks like an octal mode (3 or 4 digits, each
    # 0-7); anything else (a garbled report, empty output, a future
    # platform's own quirk) is discarded rather than handed to `chmod`.
    tl_mode="$(stat -c '%a' "$dir/.temperloop" 2>/dev/null)" \
      || tl_mode="$(stat -f '%Lp' "$dir/.temperloop" 2>/dev/null)" \
      || tl_mode=""
    case "$tl_mode" in
      [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) : ;;
      *) tl_mode="" ;;
    esac

    if ! pricing_stash="$(mktemp "$dir/.eject-pricing.XXXXXX" 2>/dev/null)"; then
      echo "eject: FAILED to create a stash location for .temperloop/pricing.json -- aborting, .temperloop/ left untouched" >&2
      pricing_stash=""
      return 1
    fi
    if ! mv "$pricing_src" "$pricing_stash" 2>/dev/null; then
      echo "eject: FAILED to stash .temperloop/pricing.json -- aborting, .temperloop/ left untouched" >&2
      rm -f "$pricing_stash"
      pricing_stash=""
      return 1
    fi
    # Covers an interrupt anywhere between the stash above and the
    # restore below. EXIT alone re-runs the (idempotent) restore on any
    # non-signal exit from this window; INT/TERM/HUP additionally exit
    # (via the named handler above) so a real interrupt can never resume
    # into a false "done" — see both header notes above for why each
    # half is shaped the way it is.
    trap '_eject_restore_pricing_stash "$pricing_stash" "$pricing_src" "$tl_mode"' EXIT
    trap '_eject_interrupted' INT TERM HUP
  fi

  rm -rf "${dir:?}/.temperloop" "${dir:?}/.foundation" || rm_rc=1

  if [ -z "$pricing_stash" ]; then
    if [ "$rm_rc" -ne 0 ]; then
      echo "eject: FAILED to fully remove .temperloop/ (rm -rf exited non-zero) -- see above" >&2
      return 1
    fi
    return 0
  fi

  _eject_restore_pricing_stash "$pricing_stash" "$pricing_src" "$tl_mode"
  # This is the only restore attempt eject makes, whether or not it
  # actually landed — clear every trap here, on EVERY path, not only
  # success, so a later, unrelated interrupt elsewhere in the script can
  # never silently re-fire a stale handler. A failed restore is reported
  # once, definitively, by the WARNING below; there is no silent
  # last-resort retry left armed to disagree with that report.
  trap - EXIT INT TERM HUP

  if { [ -f "$pricing_src" ] || [ -L "$pricing_src" ]; } && [ "$rm_rc" -eq 0 ]; then
    echo "kept: .temperloop/pricing.json (hand-authored pricing table -- not a temperloop-managed file, eject never removes it)"
    return 0
  fi

  if ! { [ -f "$pricing_src" ] || [ -L "$pricing_src" ]; }; then
    echo "eject: WARNING -- .temperloop/pricing.json could not be restored after removal; check for a stray $pricing_stash" >&2
  fi
  if [ "$rm_rc" -ne 0 ]; then
    echo "eject: FAILED to fully remove .temperloop/ (rm -rf exited non-zero) -- see above" >&2
  fi
  return 1
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
  dirs_failed=0
  eject_remove_dirs "$repo_dir" || dirs_failed=1
  if [ "$dirs_failed" -eq 1 ]; then
    echo "partial init residue removal did NOT complete cleanly — see above"
  else
    echo "partial init residue removed ($tl_dirs_desc)"
  fi
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ] && [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore AND pricing.json handling both failed — see above)"
    exit 1
  elif [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  elif [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (pricing.json handling failed — see above)"
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
  dirs_failed=0
  eject_remove_dirs "$repo_dir" || dirs_failed=1
  if [ "$dirs_failed" -eq 1 ]; then
    echo "nothing recorded to revert, but removal did NOT complete cleanly — see above"
  else
    echo "nothing recorded to revert — $config_rel removed"
  fi
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ] && [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore AND pricing.json handling both failed — see above)"
    exit 1
  elif [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  elif [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (pricing.json handling failed — see above)"
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
  elif ! "$EJECT_GH_BIN" label list -R "$repo" --json name -q '.[].name' 2>/dev/null | grep -Fx "$name" >/dev/null; then
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

# --- first_epic / first_epic_decline_pointer: {type,repo,issue,url} --------
# READ-COMPAT ONLY (temperloop#794). A pre-fix `temperloop init` mistakenly
# treated "filed the pre-designed first-epic issue" (accept path) and
# "filed the durable re-offer pointer issue" (decline path) as revertible
# installs — they never were: filing a GitHub issue that names ongoing
# adopter-facing work is not something eject can safely undo (an adopter may
# already be actively working the epic the issue tracks), and there is no
# API-state action for eject to take on either type. init.sh (as of this
# fix) no longer writes either type into installs[] at all — see its own
# add_install call sites — but a config generated by an OLDER init still on
# disk may already carry one, so this handler stays purely for that
# read-compat case. It is a deliberate NO-OP: no `gh` call, ever, and never
# mark_unresolved (there's nothing to retry — the entry is simply dropped
# from the manifest, exactly like an already-reverted entry would be).
revert_first_epic_marker() {
  local entry="$1" type url
  type="$(jq -r '.type' <<<"$entry")"
  url="$(jq -r '.url // empty' <<<"$entry")"
  echo "$type ($url): informational only — not reverted (eject never modifies epic-issue state; legacy manifest entry dropped)"
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
    first_epic|first_epic_decline_pointer) revert_first_epic_marker "$entry" ;;
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
  dirs_failed=0
  eject_remove_dirs "$repo_dir" || dirs_failed=1
  if [ "$dirs_failed" -eq 1 ]; then
    echo "all $n_installs install(s) reverted, but removal did NOT complete cleanly — see above."
    echo "  $config_rel is left in place, still naming the installs already reverted above; a re-run"
    echo "  will safely re-verify each (every revert_* handler already treats 'already absent' as a"
    echo "  no-op skip, never an error) rather than double-applying anything."
  else
    echo "all $n_installs install(s) reverted; $config_rel removed"
  fi
  echo
  print_uninstall_bullet
  echo
  if [ "$recovery_failed" -eq 1 ] && [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore AND pricing.json handling both failed — see above)"
    exit 1
  elif [ "$recovery_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (branch restore failed — see above)"
    exit 1
  elif [ "$dirs_failed" -eq 1 ]; then
    echo "temperloop eject: incomplete (pricing.json handling failed — see above)"
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
