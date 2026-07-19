#!/usr/bin/env bash
#
# reviewer-activate.sh — opt-in activation caller + durable-decline marker
# (temperloop#549, ADR 0007/0008).
#
# WHAT THIS IS. The INTERACTIVE half of the reviewer-activation pipeline.
# Sources #548's reviewer-activation-coverage.sh for the gap-set DATA PATH
# (reviewer_coverage_gaps() — never re-implemented here) and invokes #543's
# project-agents.sh for the DEPLOY path (--only NAME --category reviewers).
# This script owns only the OFFER/DECISION/MARKER layer between them:
#
#   1. compute the gap set (sourced from #548, read-only)
#   2. emit ONE BATCHED offer covering the whole gap set (never one prompt
#      per reviewer)
#   3. on accept, invoke #543's --only to deploy each chosen reviewer
#   4. on decline, write a durable per-name marker so that language is never
#      re-offered/re-warned again
#
# A same-name user-defined reviewer is never offered the catalog one and is
# never touched by this script — #548's gap computation already treats ANY
# file present at .claude/agents/<name>.md as "covered" regardless of
# provenance (so a user-defined reviewer never even enters the gap set), and
# #543's --only independently refuses to clobber a non-managed target. This
# script relies on both rather than re-checking either invariant itself.
#
# ON-DISK MARKER FORMAT (owned by this file; #548 already tolerates it and
# reads it read-only; #550's `make doctor` check will also READ it — keep
# this comment authoritative if the format ever changes):
#
#   <project-dir>/.claude/reviewer-state/declined/<reviewer-name>
#
#   One marker FILE per durably-declined reviewer name. Presence of the file
#   is the ENTIRE signal (per #548's _rac_is_declined()) — its content is a
#   human-readable comment only (a declined-on date), never parsed by any
#   reader. The whole .claude/reviewer-state/ tree lives under the project's
#   OWN .claude/ (per-repo install/local state, matching the existing
#   .claude/agents/ + .claude/commands/ precedent) and MUST stay gitignored
#   — see this repo's own .gitignore entry (.claude/reviewer-state/) added
#   alongside this file.
#
# TARGET-REPO GITIGNORE SAFETY (temperloop#560 mitigation, temperloop#569
# extraction). This kernel checkout's OWN .gitignore already carries both
# entries below, but a real adopter repo (foundation/stageFind/ssmobile/
# subsetwiki and any other target this script is pointed at) does NOT — so
# writing activation/decline state straight into an un-ignored .claude/
# would leave it untracked-but-stageable, one `git add -A` away from
# committing a single teammate's personal opt-in (violating ADR 0007's
# "never imposed on teammates" invariant). Before EITHER write path
# (deploying via --only, or writing a decline marker), this script
# therefore verifies — and if missing, APPENDS — both entries in the
# TARGET project's OWN .gitignore:
#   .claude/agents/
#   .claude/reviewer-state/
# Idempotent (checked with `git check-ignore` first; never duplicates a
# line), newline-guarded (never glues onto a target .gitignore's last line
# if it lacks a trailing newline), and refuses to proceed with that write —
# loudly, to stderr — if the target isn't a git repo or its .gitignore
# can't be written, rather than silently leaving state exposed. The actual
# guard logic lives in the shared, sourceable
# gitignore-safety.sh:gitignore_ensure_all() (this file only calls it) —
# see that file's own header for the extraction rationale and the bug it
# fixes.
#
# REVERSING. To deactivate a reviewer, remove its
# .claude/agents/<name>.md; to re-offer a declined one, remove its marker
# under .claude/reviewer-state/declined/<name>.
#
# INTERACTIVITY. The offer/accept prompt below is this script's ONLY
# interactive surface. Two non-interactive paths exist for driving it
# without a TTY (a fixture test, or a future scripted caller like `make
# doctor --fix`):
#   --accept <list>   comma/space-separated reviewer names (or the literal
#                      "all") to activate, no prompting.
#   --decline <list>  comma/space-separated reviewer names (or the literal
#                      "all") to durably decline, no prompting.
#   Both may be combined in one invocation (useful for exercising both paths
#   in one test run). Any gap-set name mentioned in neither list is left
#   untouched — still a gap, still offered next time.
#   With NEITHER flag given, the script prompts ONCE on stdin — a real TTY
#   or a piped/heredoc stdin both work (no `-t 0` check is done), so a test
#   can drive the interactive path too by piping an answer. On EOF (no input
#   available at all, e.g. stdin closed/redirected from /dev/null with no
#   flags given) it makes NO changes rather than guessing a default — a
#   headless invocation that forgot to pass flags must never silently
#   activate or decline anything.
#
# Usage:
#   reviewer-activate.sh [--project-dir DIR] [--dry-run]
#                         [--accept LIST] [--decline LIST]
#                         [-h|--help]
#
#   --project-dir DIR   Repo to scan/activate into (default: DIR's git root
#                        if run inside one, else the cwd) — same default
#                        resolution as reviewer-activation-coverage.sh.
#   --dry-run            Print the plan (gap set + what would happen); write
#                        and deploy nothing.
#   --accept LIST        Non-interactive: activate these gap-set reviewers
#                        ("all" activates the whole gap set).
#   --decline LIST       Non-interactive: durably decline these gap-set
#                        reviewers ("all" declines the whole gap set).
#   -h, --help           Show usage.
#
# Exit codes: 0 = ran to completion (no gaps, a dry run, a fully-handled
# offer, or "no input available — nothing changed" are all a legible
# success). 1 = a fatal usage/environment error, or one or more
# activations/declines failed.
#
# Dependencies: bash (3.2+), coreutils, the sibling
# reviewer-activation-coverage.sh and project-agents.sh scripts in this same
# directory. No network, no gh, no jq.
#
# shellcheck shell=bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RAC_SH="${SCRIPT_DIR}/reviewer-activation-coverage.sh"
PROJECT_AGENTS_SH="${SCRIPT_DIR}/project-agents.sh"
GITIGNORE_SAFETY_SH="${SCRIPT_DIR}/gitignore-safety.sh"

if [ ! -f "$RAC_SH" ]; then
  echo "reviewer-activate.sh: missing sibling script: $RAC_SH" >&2
  exit 1
fi
if [ ! -f "$PROJECT_AGENTS_SH" ]; then
  echo "reviewer-activate.sh: missing sibling script: $PROJECT_AGENTS_SH" >&2
  exit 1
fi
if [ ! -f "$GITIGNORE_SAFETY_SH" ]; then
  echo "reviewer-activate.sh: missing sibling script: $GITIGNORE_SAFETY_SH" >&2
  exit 1
fi

# shellcheck source=reviewer-activation-coverage.sh
source "$RAC_SH"
# shellcheck source=gitignore-safety.sh
source "$GITIGNORE_SAFETY_SH"

usage() {
  sed -n '2,110p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

_ra_default_project_dir() {
  local d
  if d="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$d"
  else
    pwd
  fi
}

# _ra_split_list LIST -> prints one name per line (comma and/or
# whitespace-separated input both tolerated).
_ra_split_list() {
  local list="$1"
  list="${list//,/ }"
  # shellcheck disable=SC2086  # intentional word-splitting to enumerate names
  printf '%s\n' $list
}

# _ra_contains NEEDLE HAYSTACK_NEWLINE_SEPARATED -> 0 iff NEEDLE is one of
# the newline-separated entries in HAYSTACK.
_ra_contains() {
  local needle="$1" hay="$2" line
  while IFS= read -r line; do
    [ "$line" = "$needle" ] && return 0
  done <<<"$hay"
  return 1
}

# _ra_filter_to_gaps LIST GAPS -> prints only the LIST entries that are
# actually present in GAPS (one per line), warning to stderr for any that
# aren't. Never act on a name the coverage scan didn't just report — an
# already-covered, already-declined, or mistyped name is a no-op here.
_ra_filter_to_gaps() {
  local list="$1" gaps="$2" name kept=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if _ra_contains "$name" "$gaps"; then
      kept="${kept}${name}"$'\n'
    else
      echo "  ! '$name' is not in the current gap set — ignoring" >&2
    fi
  done <<<"$list"
  printf '%s' "$kept"
}

# _ra_ensure_state_gitignored PROJECT_DIR -> 0 iff BOTH the activation
# (.claude/agents/) and decline-marker (.claude/reviewer-state/) trees
# resolve ignored in PROJECT_DIR, appending to its .gitignore as needed.
# Called before EITHER write path (accept or decline) — see header comment.
# Thin wrapper over the shared gitignore-safety.sh:gitignore_ensure_all()
# (temperloop#569 extraction) so every call site here keeps its existing
# name/signature.
_ra_ensure_state_gitignored() {
  local project_dir="$1"
  gitignore_ensure_all "$project_dir" \
    ".claude/agents/" ".claude/agents/.reviewer-activate-probe" \
    ".claude/reviewer-state/" ".claude/reviewer-state/.reviewer-activate-probe"
}

# ---------------------------------------------------------------------------
# main — arg parsing + the offer/accept/decline flow. Wrapped so sourcing
# this file (a test, or a future `make doctor --fix` caller) only defines
# functions and never runs the interactive CLI — see the source-guard at
# EOF (temperloop#569).
# ---------------------------------------------------------------------------
main() {
local project_dir=""
local dry_run=0
local accept_list=""
local decline_list=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir)
      [ $# -ge 2 ] || { echo "reviewer-activate.sh: --project-dir needs a value" >&2; exit 1; }
      project_dir="$2"; shift 2 ;;
    --project-dir=*)
      project_dir="${1#*=}"; shift ;;
    --dry-run) dry_run=1; shift ;;
    --accept)
      [ $# -ge 2 ] || { echo "reviewer-activate.sh: --accept needs a value" >&2; exit 1; }
      accept_list="$2"; shift 2 ;;
    --accept=*)
      accept_list="${1#*=}"; shift ;;
    --decline)
      [ $# -ge 2 ] || { echo "reviewer-activate.sh: --decline needs a value" >&2; exit 1; }
      decline_list="$2"; shift 2 ;;
    --decline=*)
      decline_list="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "reviewer-activate.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$project_dir" ]; then
  project_dir="$(_ra_default_project_dir)"
fi
if [ ! -d "$project_dir" ]; then
  echo "reviewer-activate.sh: --project-dir does not exist: $project_dir" >&2
  exit 1
fi
project_dir="$(cd "$project_dir" && pwd)"

local gaps
gaps="$(reviewer_coverage_gaps "$project_dir" "$REVIEWER_ROUTING_TSV")"

if [ -z "$gaps" ]; then
  echo "reviewer-activate: no activation gaps found in $project_dir — nothing to offer"
  exit 0
fi

local gap_count
gap_count="$(printf '%s\n' "$gaps" | grep -c . || true)"

echo "== reviewer activation offer — $project_dir =="
echo "  ${gap_count} catalogued reviewer(s) match this repo's language mix and are not yet active:"
local g
while IFS= read -r g; do
  [ -n "$g" ] && echo "    - $g"
done <<<"$gaps"
echo

# ---------------------------------------------------------------------------
# Resolve the accept-set / decline-set: either from --accept/--decline (no
# prompting) or from a SINGLE batched interactive prompt covering the whole
# gap set (never one prompt per reviewer).
# ---------------------------------------------------------------------------
local accept_set="" decline_set="" answer

if [ -n "$accept_list" ] || [ -n "$decline_list" ]; then
  if [ "$accept_list" = "all" ]; then
    accept_set="$gaps"
  elif [ -n "$accept_list" ]; then
    accept_set="$(_ra_split_list "$accept_list")"
  fi
  if [ "$decline_list" = "all" ]; then
    decline_set="$gaps"
  elif [ -n "$decline_list" ]; then
    decline_set="$(_ra_split_list "$decline_list")"
  fi
else
  echo "Activate all ${gap_count} listed reviewer(s) now? [Y/n, or a"
  echo "comma/space-separated subset of the names above, or 'none']"
  printf '> '
  if IFS= read -r answer; then
    case "$answer" in
      ''|y|Y|yes|YES|Yes|all|ALL)
        accept_set="$gaps" ;;
      n|N|no|NO|No|none|NONE|None)
        decline_set="$gaps" ;;
      *)
        accept_set="$(_ra_split_list "$answer")" ;;
    esac
  else
    echo
    echo "  (no input available — no changes made; use --accept/--decline for non-interactive use)"
  fi
fi

accept_set="$(_ra_filter_to_gaps "$accept_set" "$gaps")"
decline_set="$(_ra_filter_to_gaps "$decline_set" "$gaps")"

local activated=0 declined=0 failures=0 name accept_n decline_n marker_dir

if [ -n "$accept_set" ]; then
  echo "-- activating --"
  accept_n="$(printf '%s\n' "$accept_set" | grep -c . || true)"
  if [ "$dry_run" -eq 1 ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "  → would activate $name"
      activated=$((activated + 1))
    done <<<"$accept_set"
  elif ! _ra_ensure_state_gitignored "$project_dir"; then
    echo "  ! refusing to activate any reviewer here — see gitignore warning(s) above" >&2
    failures=$((failures + accept_n))
  else
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      if bash "$PROJECT_AGENTS_SH" --project-dir "$project_dir" --only "$name" --category reviewers; then
        activated=$((activated + 1))
      else
        echo "  ! failed to activate $name" >&2
        failures=$((failures + 1))
      fi
    done <<<"$accept_set"
  fi
  echo
fi

if [ -n "$decline_set" ]; then
  echo "-- declining (durable — will not be re-offered) --"
  decline_n="$(printf '%s\n' "$decline_set" | grep -c . || true)"
  marker_dir="${project_dir}/.claude/reviewer-state/declined"
  if [ "$dry_run" -eq 1 ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      echo "  → would decline $name (marker: $marker_dir/$name)"
      declined=$((declined + 1))
    done <<<"$decline_set"
  elif ! _ra_ensure_state_gitignored "$project_dir"; then
    echo "  ! refusing to decline any reviewer here — see gitignore warning(s) above" >&2
    failures=$((failures + decline_n))
  else
    if ! mkdir -p "$marker_dir"; then
      echo "  ! could not create $marker_dir" >&2
      exit 1
    fi
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      if printf '# reviewer-activate: declined %s on %s\n' "$name" "$(date +%Y-%m-%d)" >"${marker_dir}/${name}"; then
        echo "  → declined $name"
        declined=$((declined + 1))
      else
        echo "  ! failed to write decline marker for $name" >&2
        failures=$((failures + 1))
      fi
    done <<<"$decline_set"
  fi
  echo
fi

echo "-- Summary --"
echo "  activated: $activated   declined: $declined   failures: $failures"
if [ "$dry_run" -eq 1 ]; then
  echo
  echo "reviewer-activate.sh: done (dry run — nothing written)"
  exit 0
fi

if [ "$failures" -gt 0 ]; then
  echo
  echo "reviewer-activate.sh: incomplete ($failures failure(s))"
  exit 1
fi

echo
echo "reviewer-activate.sh: done"
exit 0
}

# ---------------------------------------------------------------------------
# Source-guard: only run main() when this file is the top-level EXECUTED
# script, never on `source` — so a test (or a future doctor.sh/
# project-agents.sh caller) can source this file to reuse its helper
# functions (_ra_split_list, _ra_contains, _ra_filter_to_gaps,
# _ra_ensure_state_gitignored, _ra_default_project_dir) without triggering
# the interactive offer/accept/decline CLI (temperloop#569).
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
