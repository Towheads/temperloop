#!/usr/bin/env bash
#
# gitignore-safety.sh — shared, sourceable target-repo .gitignore safety
# helpers (temperloop#569, split from #563; extracted out of
# reviewer-activate.sh's original _ra_ensure_gitignore_entry /
# _ra_ensure_state_gitignored copy, temperloop#560 mitigation).
#
# WHAT THIS IS. A PURE HELPER LIBRARY, no CLI of its own. Any installer
# script that writes per-checkout state into a TARGET project's .claude/
# tree (reviewer-activate.sh today; doctor.sh and project-agents.sh in
# sibling items) needs the SAME guarantee: that state resolves git-ignored
# in the target repo before anything is written there, so a stray `git add
# -A` in that repo can never stage a teammate's personal opt-in/local state.
# This file is the ONE place that guarantee is implemented, so every caller
# gets the same behavior (including the same bug fixes) rather than N
# hand-rolled copies drifting apart.
#
# THE BUG THIS FIXES (temperloop#563/#569). The original copy of this logic
# appended a new .gitignore entry with NO leading-newline guard:
#   printf '%s\n' "$entry" >>"$gi"
# When the target .gitignore existed but had NO trailing newline (e.g. a
# teammate's file ending in `*.pyc` with no final `\n`), this glued the new
# entry onto the file's last line — `*.pyc.claude/reviewer-state/` — which
# both destroyed the pre-existing `*.pyc` rule and failed to add a working
# entry of its own. The fix below: before appending, if the file exists,
# is non-empty, and its last byte is not a newline, first append a bare
# `\n` to close out the existing content on its own line.
#
# Sourceable interface:
#   gitignore_ensure_entry <project_dir> <entry> <sample_path>
#       -> 0 iff, on return, <sample_path> resolves ignored under
#          `git -C <project_dir> check-ignore`. See the function's own
#          header comment below for the full contract (idempotent, prints
#          a console notice on an actual write, re-verifies after writing,
#          refuses loudly without writing on any failure mode).
#   gitignore_ensure_all <project_dir> <entry> <sample_path> [<entry>
#                          <sample_path> ...]
#       -> 0 iff EVERY <entry>/<sample_path> pair ensures ignored (calls
#          gitignore_ensure_entry once per pair; does not short-circuit on
#          the first failure so every pair gets a chance to report its own
#          warning — matches the original _ra_ensure_state_gitignored
#          behavior of trying both entries even if the first fails).
#
# This file has NO side effects at source time (no CLI, no arg parsing) —
# sourcing it only defines the two functions above. Bash 3.2+, coreutils,
# no network, no gh, no jq.
#
# shellcheck shell=bash

# `-u`/`pipefail` are safe to hand to a sourcing caller (matches the
# existing sourced-library convention in this repo — see
# reviewer-activation-coverage.sh's own header comment on why `-e` is never
# set here). This file never sets `-e` since it has no top-level executed
# path of its own to guard.
set -uo pipefail

# ---------------------------------------------------------------------------
# gitignore_ensure_entry PROJECT_DIR ENTRY SAMPLE_PATH -> 0 iff, on return,
# SAMPLE_PATH resolves ignored under `git -C PROJECT_DIR check-ignore` —
# either it already was, or ENTRY was appended to PROJECT_DIR/.gitignore
# (creating the file if absent) to make it so. Prints one line to stdout
# when it actually appends (nothing when already ignored). Returns 1 and
# warns loudly to stderr, WITHOUT writing anything, when PROJECT_DIR isn't a
# git repo, .gitignore can't be written, or the path is somehow still not
# ignored after appending.
#
# Newline-guarded append (temperloop#563/#569 fix): if the file already
# exists and is non-empty and its last byte is not a newline, a bare `\n`
# is appended FIRST so the new entry never glues onto the target's last
# existing line.
# ---------------------------------------------------------------------------
gitignore_ensure_entry() {
  local project_dir="$1" entry="$2" sample_path="$3" gi

  if ! git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "gitignore-safety: ! $project_dir is not a git repository — cannot guarantee '$entry' stays untracked; refusing to write activation/decline state here" >&2
    return 1
  fi

  if git -C "$project_dir" check-ignore -q -- "$sample_path" 2>/dev/null; then
    return 0
  fi

  gi="${project_dir}/.gitignore"
  if [ -f "$gi" ] && grep -qxF "$entry" "$gi" 2>/dev/null; then
    : # entry already literally present; check-ignore above should have
      # caught this — fall through to the post-check below, which will
      # surface a clear failure if it somehow still isn't ignored.
  elif { [ -e "$gi" ] || touch "$gi" 2>/dev/null; }; then
    # Newline guard: if the file has content and doesn't already end in a
    # newline, close out its last existing line before appending ours —
    # otherwise the entry glues onto it (the #563/#569 corruption bug).
    if [ -s "$gi" ] && [ "$(tail -c 1 "$gi" 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
      printf '\n' >>"$gi" 2>/dev/null
    fi
    if printf '%s\n' "$entry" >>"$gi" 2>/dev/null; then
      echo "gitignore-safety: added '$entry' to $gi to keep activation/decline state per-checkout (never committed)"
    else
      echo "gitignore-safety: ! could not write $gi to add '$entry' — refusing to write activation/decline state here" >&2
      return 1
    fi
  else
    echo "gitignore-safety: ! could not write $gi to add '$entry' — refusing to write activation/decline state here" >&2
    return 1
  fi

  if ! git -C "$project_dir" check-ignore -q -- "$sample_path" 2>/dev/null; then
    echo "gitignore-safety: ! $sample_path is still not ignored after updating $gi — refusing to write activation/decline state here" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# gitignore_ensure_all PROJECT_DIR ENTRY SAMPLE_PATH [ENTRY SAMPLE_PATH ...]
# -> 0 iff EVERY given entry/sample_path pair resolves ignored in
# PROJECT_DIR, appending to its .gitignore as needed. Tries every pair
# (does not stop at the first failure) so a caller sees every relevant
# warning in one pass, matching reviewer-activate.sh's original
# _ra_ensure_state_gitignored behavior (which unconditionally checked both
# .claude/agents/ and .claude/reviewer-state/ before reporting).
# ---------------------------------------------------------------------------
gitignore_ensure_all() {
  local project_dir="$1"
  shift
  local ok=0 entry sample_path

  while [ $# -ge 2 ]; do
    entry="$1"
    sample_path="$2"
    shift 2
    gitignore_ensure_entry "$project_dir" "$entry" "$sample_path" || ok=1
  done

  return "$ok"
}
