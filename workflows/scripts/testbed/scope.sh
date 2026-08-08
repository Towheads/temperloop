#!/usr/bin/env bash
# scope.sh — the `delete_repo` OAuth-scope check `temperloop testbed
# --teardown` gates on (temperloop#1117, item testbed-teardown / #1231).
#
# LIBRARY ONLY, ONE PUBLIC FUNCTION. Deleting a testbed repository needs the
# `delete_repo` scope, which `gh auth login`'s default scope set does NOT
# include — a testbed created with an ordinary `gh` login can therefore
# exist with no way to tear it down until the operator explicitly grants
# that scope. Teardown must detect this and degrade LEGIBLY (print the exact
# remedy, exit 0) rather than fail opaquely on the `gh repo delete` call
# it can never make. This file exists so that check is written ONCE and
# reused everywhere it is needed — `bin/subcommands/testbed.sh`'s
# `--teardown` mode is the first caller, and a future CI step (the
# `ci-round-trip-rescope` workflow leg the epic's record.sh header already
# names — see its "WHY NOT `.temperloop/testbed.json`" note) is meant to
# source this file too, rather than re-typing the same `gh auth status`
# scope parse inline in YAML.
#
# WHY A SEPARATE FILE FROM record.sh OR source.sh: a third, orthogonal
# concern — record.sh is the machine-scoped artifact record, source.sh is
# the source-provider seam, and this is neither: it is a capability check on
# the CURRENTLY AUTHENTICATED gh account, unrelated to which testbed or
# which provider is in play. Same granularity source.sh's own header uses to
# justify not folding provider logic into record.sh.
#
# ── Public function ──────────────────────────────────────────────────────
#   testbed_teardown_has_delete_repo_scope   -> exit 0 if the active gh
#     account carries the delete_repo OAuth scope, exit 1 otherwise
#     (including "gh missing", "jq missing", "not authenticated", or any
#     other read failure). Prints nothing to stdout/stderr — a pure
#     predicate; callers own their own messaging (teardown prints the
#     `gh auth refresh -s delete_repo` remedy; a future CI step decides
#     whether to fail the job or skip the round trip).
#
# Reads `gh auth status --json hosts` (the documented machine-readable
# surface) first, and falls back to scanning the plain-text `gh auth
# status` output's "Token scopes: '...'" line only when the JSON path
# yields nothing (an older gh with no --json support, or any other read
# failure) — never fails outright just because a caller's gh predates that
# flag. Both shapes are normalized the same way: split on commas, trim
# quotes/whitespace, then an exact per-scope match — so `delete_repo` never
# partial-matches something like `delete_repository_hook` or similar.
#
# Usage (sourced, not executed):
#
#   source "$(dirname "$0")/scope.sh"
#   if testbed_teardown_has_delete_repo_scope; then
#     gh repo delete "$slug" --yes
#   else
#     echo "skipped — gh account lacks the delete_repo scope; run: gh auth refresh -s delete_repo"
#   fi
#
# Dependencies: gh (required — no scope to check without it), jq (used for
# the primary JSON path; its absence alone does not fail the check, since
# the plain-text fallback needs no jq). No network beyond what `gh auth
# status` itself already does (a local token read, not a testbed-affecting
# call). No global shell-option changes (no `set -e`/`set -u` at file
# scope) — same sourced-library posture as record.sh/source.sh.
#
# shellcheck shell=bash

# Guard against double-sourcing (mirrors record.sh/source.sh's own guard
# convention — record.sh's is the more direct precedent, source.sh sets
# none since it declares no file-scoped state to guard).
if [[ "${_TEMPERLOOP_TESTBED_SCOPE_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_TESTBED_SCOPE_SH_LOADED=1

# ---------------------------------------------------------------------------
# testbed_teardown_has_delete_repo_scope
# ---------------------------------------------------------------------------
testbed_teardown_has_delete_repo_scope() {
  command -v gh >/dev/null 2>&1 || return 1

  local raw=""
  if command -v jq >/dev/null 2>&1; then
    raw="$(gh auth status --json hosts 2>/dev/null \
      | jq -r '[.hosts[][] | select(.active) | .scopes][0] // empty' 2>/dev/null || true)"
  fi

  if [ -z "$raw" ]; then
    # Fallback: plain-text `gh auth status` — the "Token scopes: 'a', 'b',
    # ..." line every gh release has printed, JSON support or not.
    raw="$(gh auth status 2>&1 | grep -i 'token scopes' | head -n1 || true)"
  fi
  [ -n "$raw" ] || return 1

  local normalized
  normalized="$(printf '%s' "$raw" | tr -d "'" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\n' "$normalized" | grep -x 'delete_repo' >/dev/null
}
