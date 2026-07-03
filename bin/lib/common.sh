#!/usr/bin/env bash
# kernel/bin/lib/common.sh — shared helpers + constants for the `temperloop`
# CLI and its subcommands (foundation #765 Epic D, item
# cli-entrypoint-bootstrap / #849). Renamed from `foundation` to `temperloop`
# in foundation #893 — kernel/bin/foundation remains a compat shim.
#
# This is the PINNED location for shared CLI lib/constants (see the epic's
# plan note, "## Repo targeting"): a future item (e.g. foundation-try) drops
# its own file here (kernel/bin/lib/cost-estimates.conf) with zero collision
# risk against this one. This item ships only the prereq-check helper; it
# does not speak for what a later item adds alongside it.
#
# Sourced, not executed — by the dispatcher (kernel/bin/temperloop) directly,
# or by an individual subcommand script IN ITS OWN PROCESS if it wants these
# helpers too. That is an ordinary library import, not the "shared shell
# namespace" the dispatcher's own discovery mechanism deliberately avoids
# (see kernel/bin/temperloop's header comment for that distinction):
#   source "$LIB_DIR/common.sh"

# Machine-level install locations the curl bootstrap (bin/bootstrap.sh) uses.
# Echoed back here (rather than re-typed) so the dispatcher's help text and
# any future `foundation eject` uninstall doc all state the SAME path.
# bootstrap.sh runs BEFORE any of this repo exists on disk, so it cannot
# source this file — its own copy of these two defaults must be kept
# byte-identical by hand; see bootstrap.sh's header note.
# A PUBLIC surface for the sourcing scripts (kernel/bin/temperloop today, a
# future eject subcommand later) — shellcheck can't see cross-file use when
# linting this file in isolation, hence the disable, mirroring the
# workflows/scripts/board/lib/board.sh BOARD_OWNER precedent.
# shellcheck disable=SC2034
FOUNDATION_CLI_HOME_DEFAULT="$HOME/.local/share/temperloop"
# shellcheck disable=SC2034
FOUNDATION_CLI_BIN_DEFAULT="$HOME/.local/bin/temperloop"

# foundation_check_prereqs
#   Verifies the two external tools every live subcommand needs:
#     - the Claude Code CLI (`claude`) — drives the actual work
#     - an authenticated `gh` — talks to GitHub
#   Prints one specific, actionable line per missing/failing prerequisite to
#   stderr (never a bare failure or a downstream stack trace) and returns
#   non-zero if anything is missing. Read-only: zero side effects.
foundation_check_prereqs() {
  local problems=0

  if ! command -v claude >/dev/null 2>&1; then
    echo "temperloop: 'claude' (Claude Code CLI) not found on PATH." >&2
    echo "  Install: https://docs.claude.com/en/docs/claude-code/quickstart" >&2
    problems=$((problems + 1))
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "temperloop: 'gh' (GitHub CLI) not found on PATH." >&2
    echo "  Install: https://cli.github.com" >&2
    problems=$((problems + 1))
  elif ! gh auth status >/dev/null 2>&1; then
    echo "temperloop: 'gh' is installed but not authenticated." >&2
    echo "  Run: gh auth login" >&2
    problems=$((problems + 1))
  fi

  if [[ "$problems" -gt 0 ]]; then
    return 1
  fi
  return 0
}
