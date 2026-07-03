#!/usr/bin/env bash
# Shared link enumeration and apply helper for make install-* and make doctor.
#
# SINGLE SOURCE OF TRUTH for every managed symlink (and the one managed real
# file) that the install-* targets create.  Both the apply side (install-*) and
# the verify side (make doctor) source this file to obtain the same enumeration
# — changing it changes both, so apply and verify can never drift.
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/links.sh"
#   links_enumerate                     # emits one record per managed path
#   links_apply_symlink <target> <src>  # idempotent apply (for kind=symlink)
#
# Output of links_enumerate — one record per line, 3 tab-separated fields:
#
#   <target>  <kind>  <expected_source>
#
#   target          absolute path that should exist after install
#   kind            symlink | real | gh-shim
#   expected_source absolute source path a symlink should point at
#                   (empty for kind=real and kind=gh-shim)
#
# NOTE: kind is the SECOND field (not third) so that expected_source, which
# can be empty for kind=real and kind=gh-shim, falls at the END of the line.
# Shell `read` with IFS=tab collapses consecutive tab chars (treating `\t\t`
# as a single delimiter), so an empty middle field would be silently lost.
# With kind in field 2 and expected_source trailing, `read -r target kind src`
# reads correctly even when src is empty.
#
# kind=real       — settings.json (#292): generated as a real file by
#                   install-settings.sh, not a symlink.  Doctor: OK iff a
#                   plain (non-symlink) file exists.
# kind=gh-shim    — ~/.local/bin/gh: a banner-stamped real copy recognised by
#                   a 'call-logger' marker.  Doctor: OK iff the file exists,
#                   is NOT a symlink, and contains the marker.
#
# Callers MUST set FOUNDATION to the repo root before sourcing, or pass it as
# an argument to links_enumerate:
#
#   links_enumerate [<foundation-root>]
#
# If omitted, FOUNDATION must already be in the environment.
#
# shellcheck shell=bash

# Guard against double-sourcing.
if [[ "${_FOUNDATION_LINKS_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_FOUNDATION_LINKS_SH_LOADED=1

# ---------------------------------------------------------------------------
# links_enumerate [<foundation-root>]
#
# Emits one tab-delimited record per managed path to stdout.  Safe to pipe or
# read into an array; produces no side-effects.
#
# Output format (3 tab-separated fields):  target \t kind \t expected_source
# expected_source is empty for kind=real and kind=gh-shim (trailing empty is
# safe with shell `read`; empty middle field is not, hence kind in field 2).
# ---------------------------------------------------------------------------
links_enumerate() {
  local foundation="${1:-${FOUNDATION:-}}"
  if [[ -z "$foundation" ]]; then
    echo "links_enumerate: FOUNDATION is not set" >&2
    return 1
  fi

  local home="${HOME:-$(eval echo ~)}"
  local claude_dir="${home}/.claude"
  local local_bin="${home}/.local/bin"
  local board_src="${foundation}/workflows/scripts/board"

  # ---- 1. env/ dotfiles -> ~ -------------------------------------------------
  # Mirrors install-env: loops env/.* (excluding . .. .gitkeep).
  local f name target src
  for f in "${foundation}"/env/.*; do
    name="$(basename "$f")"
    [[ "$name" == "." || "$name" == ".." || "$name" == ".gitkeep" ]] && continue
    target="${home}/${name}"
    src="${foundation}/env/${name}"
    printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
  done

  # ---- 2. claude/* entries -> ~/.claude/ ------------------------------------
  # Mirrors install-claude: loops claude/*.
  # Exception: settings.json is a managed real file (kind=real, no src).
  # Exception: CLAUDE.kernel.md / CLAUDE.overlay.md are COMPOSE SOURCES for
  # the generated ~/.claude/CLAUDE.md (kind=claude-md, emitted once below,
  # not per-source-file) — not deployed under their own names (foundation
  # Epic B "layered CLAUDE.md").
  for f in "${foundation}"/claude/*; do
    name="$(basename "$f")"
    [[ "$name" == ".gitkeep" ]] && continue
    case "$name" in
      CLAUDE.kernel.md|CLAUDE.overlay.md) continue ;;
    esac
    target="${claude_dir}/${name}"
    if [[ "$name" == "settings.json" ]]; then
      # #292: generated as a real file by install-settings.sh, not a symlink.
      # Trailing tab keeps field count at 3 (expected_source is empty for real).
      printf '%s\t%s\t\n' "$target" "real"
    else
      src="${foundation}/claude/${name}"
      printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
    fi
  done

  # ---- 2b. composed CLAUDE.md (kernel + overlay + rendered knowledge-store
  # routing) -> ~/.claude/CLAUDE.md ------------------------------------------
  # Generated real file (kind=claude-md, doctor/install treat it like
  # kind=real) via workflows/scripts/install-claude-md.sh — a symlink can't
  # compose two source files. Only emitted when both sources exist, so a
  # fixture/older tree without the split simply gets no entry here.
  if [[ -f "${foundation}/claude/CLAUDE.kernel.md" && -f "${foundation}/claude/CLAUDE.overlay.md" ]]; then
    printf '%s\t%s\t\n' "${claude_dir}/CLAUDE.md" "claude-md"
  fi

  # ---- 3. board toolkit commands -> ~/.local/bin ----------------------------
  # Mirrors install-board: BOARD_CMDS = claim release worklist reconcile capture milestone
  local cmd
  for cmd in claim release worklist reconcile capture milestone; do
    target="${local_bin}/${cmd}"
    src="${board_src}/${cmd}.sh"
    printf '%s\t%s\t%s\n' "$target" "symlink" "$src"
  done

  # ---- 4. gh call-logger shim -> ~/.local/bin/gh ----------------------------
  # Mirrors install-gh-logger: a managed REAL (banner-stamped) copy, not a symlink.
  # doctor checks for the 'call-logger' marker to identify it as our shim.
  # Trailing tab keeps field count at 3 (expected_source is empty for gh-shim).
  target="${local_bin}/gh"
  printf '%s\t%s\t\n' "$target" "gh-shim"
}

# ---------------------------------------------------------------------------
# links_apply_symlink <target> <expected_source>
#
# Idempotent symlink creation with the canonical install-* semantics:
#   - already correctly linked  -> print "✓ <name> already linked"
#   - exists but not our symlink -> print "! <name> exists and is not a
#     symlink — skipping (backup manually)"
#   - absent -> create symlink, print "→ linked <name>"
#
# Used by install-env, install-claude, and install-board recipes that have been
# refactored to source this helper.
#
# Callers are responsible for mkdir -p on the parent directory of <target>
# before calling this function.
# ---------------------------------------------------------------------------
links_apply_symlink() {
  local target="$1"
  local src="$2"
  local name
  name="$(basename "$target")"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
    echo "  ✓ ${name} already linked"
  elif [ -e "$target" ]; then
    echo "  ! ${name} exists and is not a symlink — skipping (backup manually)"
  else
    ln -s "$src" "$target" && echo "  → linked ${name}"
  fi
}
