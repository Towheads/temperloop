#!/usr/bin/env bash
#
# project-agents-prune.sh — the shared, READ-ONLY recognizer + scanner for the
# project-scoped managed link tree that project-agents.sh deploys
# (temperloop#1943).
#
# THE GAP THIS CLOSES. project-agents.sh deploys one entry per source file
# from claude/{agents,commands}/ into a project's .claude/{agents,commands}/,
# in-tree as a RELATIVE SYMLINK back to the tracked source. It had no prune,
# no --sync and no uninstall path, so deleting a source file left its symlink
# behind, now DANGLING. That residue is invisible: .claude/{agents,commands}/
# are gitignored (the script ensures exactly that itself), so `git status`
# never shows it, and doctor.sh classified only the MACHINE surface under
# $HOME/.claude. A dangling entry under .claude/agents/ is not inert — it is
# precisely the surface Claude Code's capability probe reads (an agent is
# available iff declared in CLAUDE.md § Subagents or present under
# .claude/agents/ — docs/features/review-agents.md § "The capability probe"),
# so a deleted reviewer keeps reading as "available" forever.
#
# WHY A SHARED LIB RATHER THAN TWO COPIES. Two callers need the SAME answer to
# the same question ("is this entry a dangling link THIS installer created?"):
# project-agents.sh, which REMOVES what the scan finds, and doctor.sh, which
# REPORTS it. A second hand-rolled recognizer in doctor would be the
# duplicate-mechanism smell — and worse than usual here, because the two
# copies would be a *deletion* predicate and its *audit*, so any drift between
# them makes the audit stop covering the thing that deletes files. One
# recognizer, two callers: the scan is pure (it only reads), and the single
# `rm` lives in project-agents.sh alone.
#
# WHAT COUNTS AS "MANAGED" — deliberately NARROW. Removal is destructive and
# irreversible, so the recognizer matches only link targets this installer
# itself writes, by EXACT STRING, and nothing else:
#
#   ../../claude/<cat>/<name>            the bulk deploy_one() form, cat in
#                                        {agents, commands}
#   ../../claude/agents/<sub>/<name>     the selective deploy_only() form
#                                        (reads a category SUBDIR, writes the
#                                        FLAT .claude/agents/<name>)
#   <kernel_root>/claude/<cat>/<name>    the same two shapes in the ABSOLUTE
#   <kernel_root>/claude/agents/<sub>/<name>
#                                        spelling a pre-temperloop#497 deploy
#                                        could leave behind, and only when the
#                                        caller supplies its own kernel root
#
# Everything else is left strictly alone: a regular file, a directory, a
# symlink whose target string is anything but one of the four forms above, a
# link whose basename does not match the basename it points at, a non-`.md`
# entry, a nested subdirectory (the scan is one level deep, never recursive),
# and any tree other than <project>/.claude/{agents,commands}. A link that
# still RESOLVES is never a candidate either, whatever it points at — only a
# genuinely dangling one is.
#
# Sourced, never executed. It sets no `set` line of its own (it must not
# perturb a caller's shell options) and defines only the three
# `project_agents_`-prefixed names plus PROJECT_AGENTS_CATEGORIES.
#
# shellcheck shell=bash

# The categories project-agents.sh deploys, and therefore the only two
# directories under <project>/.claude/ this scan will look at. Single source
# of truth: project-agents.sh reads its own CATEGORIES from here.
PROJECT_AGENTS_CATEGORIES=(agents commands)

# ---------------------------------------------------------------------------
# project_agents_link_is_managed <link_target> <category> <name> [kernel_root]
#
# True (0) iff <link_target> is EXACTLY one of the four link-target strings
# project-agents.sh writes for an entry named <name> in <category>. Pure
# string comparison — it touches no filesystem, so it is safe to call on a
# dangling link whose target cannot be stat'd.
#
# <kernel_root> is optional: omit it and only the two RELATIVE forms match
# (the conservative default). Pass it and the two absolute spellings a
# pre-#497 deploy could have left are recognized too.
# ---------------------------------------------------------------------------
project_agents_link_is_managed() {
  local link_target="${1:-}" cat="${2:-}" name="${3:-}" kernel_root="${4:-}"
  local mid=""

  [ -n "$link_target" ] || return 1
  [ -n "$name" ] || return 1

  # Only the two deployed categories, and only the .md entries this installer
  # ever writes.
  case "$cat" in
    agents|commands) ;;
    *) return 1 ;;
  esac
  case "$name" in
    *.md) ;;
    *) return 1 ;;
  esac

  # Bulk deploy_one() form.
  if [ "$link_target" = "../../claude/$cat/$name" ]; then
    return 0
  fi
  if [ -n "$kernel_root" ] && [ "$link_target" = "$kernel_root/claude/$cat/$name" ]; then
    return 0
  fi

  # Selective deploy_only() form — one extra path segment (the category
  # subdir it reads from), and only ever under agents/.
  if [ "$cat" = "agents" ]; then
    case "$link_target" in
      "../../claude/agents/"*"/$name")
        mid="${link_target#../../claude/agents/}"
        ;;
    esac
    if [ -z "$mid" ] && [ -n "$kernel_root" ]; then
      case "$link_target" in
        "$kernel_root/claude/agents/"*"/$name")
          mid="${link_target#"$kernel_root"/claude/agents/}"
          ;;
      esac
    fi
    if [ -n "$mid" ]; then
      mid="${mid%/"$name"}"
      # Exactly one segment: no deeper nesting, and not an empty one.
      case "$mid" in
        ""|*/*) return 1 ;;
        *) return 0 ;;
      esac
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# project_agents_dangling_managed_link <path> <category> [kernel_root]
#
# True (0) iff <path> is, RIGHT NOW, a symlink that (a) does not resolve and
# (b) carries a managed link target per the recognizer above. This is the one
# predicate a caller must satisfy before removing anything; project-agents.sh
# re-checks it immediately before its `rm` rather than trusting a scan result
# that could have gone stale.
# ---------------------------------------------------------------------------
project_agents_dangling_managed_link() {
  local path="${1:-}" cat="${2:-}" kernel_root="${3:-}" link_target=""

  [ -n "$path" ] || return 1
  [ -L "$path" ] || return 1
  # -e follows the link: true here means it still resolves, so it is NOT
  # dangling and is never a prune candidate.
  if [ -e "$path" ]; then
    return 1
  fi

  link_target="$(readlink "$path" 2>/dev/null || true)"
  project_agents_link_is_managed "$link_target" "$cat" "$(basename "$path")" "$kernel_root"
}

# ---------------------------------------------------------------------------
# project_agents_scan_dangling <project_dir> [kernel_root]
#
# Prints one TAB-separated row per dangling managed link found directly under
# <project_dir>/.claude/<cat>/ for each managed category:
#
#   <category>/<name><TAB><link target>
#
# Read-only and non-recursive. Prints nothing (and returns 0) when the tree is
# absent or clean — an absent .claude/ is the normal state of a project nobody
# has deployed into, never an error.
# ---------------------------------------------------------------------------
project_agents_scan_dangling() {
  local project_dir="${1:-}" kernel_root="${2:-}"
  local cat dir entry name link_target

  [ -n "$project_dir" ] || return 0

  for cat in "${PROJECT_AGENTS_CATEGORIES[@]}"; do
    dir="$project_dir/.claude/$cat"
    [ -d "$dir" ] || continue
    # One level only. An unmatched glob leaves the literal pattern, which
    # fails the -L test below, so no nullglob is needed (and none is set:
    # this lib must not perturb a caller's shell options).
    for entry in "$dir"/*; do
      if project_agents_dangling_managed_link "$entry" "$cat" "$kernel_root"; then
        name="$(basename "$entry")"
        link_target="$(readlink "$entry" 2>/dev/null || true)"
        printf '%s/%s\t%s\n' "$cat" "$name" "$link_target"
      fi
    done
  done

  return 0
}
