#!/usr/bin/env bash
#
# project-agents.sh — deploy the kernel's claude/agents/* and claude/commands/*
# into a live PROJECT-SCOPED .claude/ so Claude Code's capability probe can
# resolve them (temperloop#290).
#
# THE GAP THIS CLOSES. A fresh standalone-kernel clone ships the review-agent
# and command definitions as SOURCE under claude/agents/ and claude/commands/
# — but Claude Code discovers project agents/commands from a project-scoped
# .claude/agents/ and .claude/commands/, NOT from claude/*. The kernel Makefile
# ships no install-prefixed target (install targets are overlay-only, per
# seed-kernel-repo.sh), and `temperloop install` deploys the MACHINE surface
# (~/.claude, via links.sh) — neither wires the agents into a live in-repo
# .claude/. So on a fresh clone the capability-probe predicate (an agent is
# available iff declared in `CLAUDE.md § Subagents` or present under
# `.claude/agents/` — see docs/features/review-agents.md § "The capability
# probe") evaluates FALSE for every review lens, and every /design, /assess,
# and /triage review degrades to all-skipped. This script is the missing
# install path: run it once in a fresh clone and the probe resolves.
#
# WHAT IT DOES, AND NOTHING ELSE. For each of the two categories it deploys
# one entry per source file into the project's .claude/<category>/:
#
#   claude/agents/*.md    ->  <project>/.claude/agents/*.md
#   claude/commands/*.md  ->  <project>/.claude/commands/*.md
#
# By default each entry is a SYMLINK back to the tracked source, so the source
# under claude/ stays the single source of truth and a later `git pull` needs
# no re-run to pick up an edited agent/command. When the project IS the kernel
# checkout itself (the common case), the symlink is RELATIVE (../../claude/...)
# so it survives the whole repo being moved; for an out-of-tree adopter
# (--project-dir elsewhere) it is an absolute path back to this kernel
# checkout. Pass --copy to materialize detached real-file copies instead (for
# a project that must not depend on the kernel checkout staying on disk).
#
# It is PROJECT-SCOPED — it never writes under ~ or ~/.claude, so it cannot
# collide with a machine-surface `temperloop install`. The two are
# complementary: this one makes the review agents discoverable to a session
# running IN this repo; `temperloop install` wires the machine surface for a
# user who has opted into the full overlay.
#
# IDEMPOTENT BY CONSTRUCTION. An already-correct entry is left untouched. A
# pre-existing NON-managed file at a target (a real file, or a symlink to
# something else) is never clobbered — it is reported and skipped, so the
# script can never destroy a user's own project-scoped agent/command.
#
# Usage:
#   project-agents.sh [--project-dir DIR] [--copy] [--dry-run] [-h|--help]
#
#   --project-dir DIR   Deploy into DIR/.claude/ instead of this kernel
#                       checkout's own .claude/ (for adopting the kernel's
#                       agents into a different working repo). Default: the
#                       kernel checkout this script lives in.
#   --copy              Deploy real-file copies instead of symlinks.
#   --dry-run           Print the plan; write nothing.
#   -h, --help          Show usage.
#
# Exit codes: 0 = ran to completion (a dry run is a legible no-op, not a
# failure). 1 = a fatal usage/environment error, or one or more entries could
# not be deployed. Skipping a pre-existing non-managed target is NOT a failure.
#
# Dependencies: bash (3.2+), coreutils. No network, no gh, no jq.
#
# shellcheck shell=bash

set -uo pipefail

# ---------------------------------------------------------------------------
# Locate the kernel checkout this script lives in (workflows/scripts/install/
# -> repo root), following the same self-locating idiom as the sibling
# install scripts. Read-only; no symlink chasing needed (this file is invoked
# by path, not via a PATH shim).
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The two deployed categories. Source is claude/<cat>; target is
# <project>/.claude/<cat>.
CATEGORIES=(agents commands)

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

project_dir="$KERNEL_ROOT"
mode="symlink"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir)
      [ $# -ge 2 ] || { echo "project-agents.sh: --project-dir needs a value" >&2; exit 1; }
      project_dir="$2"; shift 2 ;;
    --project-dir=*)
      project_dir="${1#*=}"; shift ;;
    --copy) mode="copy"; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "project-agents.sh: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$project_dir" ]; then
  echo "project-agents.sh: --project-dir does not exist: $project_dir" >&2
  exit 1
fi
project_dir="$(cd "$project_dir" && pwd)"

echo "== temperloop install-agents (project-scoped) =="
echo "  kernel source : $KERNEL_ROOT/claude/{agents,commands}"
echo "  project target: $project_dir/.claude/{agents,commands}"
echo "  mode          : $mode$([ "$dry_run" -eq 1 ] && echo '  (dry run)')"
echo

# same_file A B — true iff A and B are the same file (inode), tolerating
# different path spellings. Used to decide relative-vs-absolute symlink target.
same_file() { [ "$1" -ef "$2" ] 2>/dev/null; }

deployed=0
skipped=0
failures=0

deploy_one() {
  local cat="$1" src="$2" name target link_target
  name="$(basename "$src")"
  target="$project_dir/.claude/$cat/$name"

  if [ "$mode" = "symlink" ]; then
    # Relative link when the project IS this kernel checkout (survives a repo
    # move); absolute otherwise (an out-of-tree adopter pointing back here).
    if same_file "$project_dir" "$KERNEL_ROOT"; then
      link_target="../../claude/$cat/$name"
    else
      link_target="$src"
    fi

    if [ -L "$target" ] && [ "$(readlink "$target")" = "$link_target" ]; then
      echo "  = $cat/$name (already linked)"
      return 0
    fi
    if [ -e "$target" ] || [ -L "$target" ]; then
      echo "  ! $cat/$name exists and is not a managed link — skipping (remove it to re-deploy)"
      skipped=$((skipped + 1))
      return 0
    fi
    if [ "$dry_run" -eq 1 ]; then
      echo "  → $cat/$name (would link -> $link_target)"
      deployed=$((deployed + 1))
      return 0
    fi
    if ln -s "$link_target" "$target"; then
      echo "  → linked $cat/$name"
      deployed=$((deployed + 1))
    else
      echo "  ! failed to link $cat/$name" >&2
      failures=$((failures + 1))
    fi
    return 0
  fi

  # --- copy mode ---
  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$src" "$target"; then
    echo "  = $cat/$name (already up to date)"
    return 0
  fi
  if { [ -e "$target" ] || [ -L "$target" ]; } && ! { [ -f "$target" ] && [ ! -L "$target" ]; }; then
    # A symlink or non-regular file sits where a managed copy would go — do
    # not clobber something we didn't create.
    echo "  ! $cat/$name exists and is not a managed copy — skipping (remove it to re-deploy)"
    skipped=$((skipped + 1))
    return 0
  fi
  if [ "$dry_run" -eq 1 ]; then
    echo "  → $cat/$name (would copy)"
    deployed=$((deployed + 1))
    return 0
  fi
  if cp "$src" "$target"; then
    echo "  → copied $cat/$name"
    deployed=$((deployed + 1))
  else
    echo "  ! failed to copy $cat/$name" >&2
    failures=$((failures + 1))
  fi
}

for cat in "${CATEGORIES[@]}"; do
  src_dir="$KERNEL_ROOT/claude/$cat"
  if [ ! -d "$src_dir" ]; then
    echo "-- $cat: no source directory ($src_dir) — skipping category"
    continue
  fi

  # Any *.md at all? A category with only a .gitkeep is a legitimately-empty
  # category, not an error.
  shopt -s nullglob
  src_files=("$src_dir"/*.md)
  shopt -u nullglob
  if [ "${#src_files[@]}" -eq 0 ]; then
    echo "-- $cat: no *.md source files — skipping category"
    continue
  fi

  echo "-- $cat (${#src_files[@]} source file(s)) --"
  if [ "$dry_run" -ne 1 ]; then
    if ! mkdir -p "$project_dir/.claude/$cat"; then
      echo "  ! could not create $project_dir/.claude/$cat" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  for src in "${src_files[@]}"; do
    deploy_one "$cat" "$src"
  done
  echo
done

echo "-- Summary --"
echo "  deployed: $deployed   skipped (pre-existing, untouched): $skipped   failures: $failures"
if [ "$dry_run" -eq 1 ]; then
  echo
  echo "project-agents.sh: done (dry run — nothing written)"
  exit 0
fi
echo "  The capability probe now resolves these agents/commands for a Claude"
echo "  Code session running in: $project_dir"

if [ "$failures" -gt 0 ]; then
  echo
  echo "project-agents.sh: incomplete ($failures failure(s))"
  exit 1
fi

echo
echo "project-agents.sh: done"
exit 0
