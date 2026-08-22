#!/usr/bin/env bash
#
# validate-agent-charter-links.sh — no-unresolvable-wikilink gate for
# claude/agents/*.md review-agent charters (temperloop, requirements-auditor
# / architecture-reviewer vault-links finding).
#
# THE FAILURE THIS CLOSES. A review-agent charter declares its toolset as
# `tools: Read, Grep, Glob, Bash` (no MCP) — it has no path to the operator's
# private Obsidian vault. A charter that still points the agent at a vault
# note via an Obsidian `[[wikilink]]` — especially in a "read first" /
# "project context" section — silently degrades: the agent cannot open the
# link, so it reviews without the invariant the wikilink promised, and
# nothing in its output distinguishes that from having read it. The fix is
# either to vendor the load-bearing content as short prose directly in the
# charter, or to point at a REPO file the declared toolset can actually
# Read (matching the shape `red-team-lens.md` and the persona agents already
# use: "authored from `docs/whatever.md`", never a vault pointer).
#
# WHAT THIS CHECKS. Every `claude/agents/**/*.md` charter, for any line
# containing an Obsidian-shaped wikilink — `[[` immediately followed by a
# non-space, non-bracket character. That shape is deliberately chosen to
# never match bash `[[ ... ]]` test-syntax examples a shell-focused reviewer
# charter legitimately quotes (`[[ -f "$x" ]]`, `[[ ]]` vs `[ ]`) — those
# always have a space (or nothing) immediately inside the brackets, while a
# real wikilink never does (`[[Decisions/foo - bar]]`).
#
# Usage:
#   workflows/scripts/validate-agent-charter-links.sh
#
# Env seams (tests):
#   AGENT_CHARTER_LINKS_ROOT   repo root to scan (default: this script's repo)
#
# Exit codes: 0 = no charter carries an unresolvable wikilink; 1 = one or
# more violations found (each named file:line + the offending text); 2 =
# usage/internal error (e.g. the charter directory is missing).
#
# BSD/macOS-safe: bash 3.2, POSIX find/grep only — no GNU extensions.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
: "${AGENT_CHARTER_LINKS_ROOT:=$REPO_ROOT}"
ROOT="${AGENT_CHARTER_LINKS_ROOT%/}"

AGENTS_DIR="$ROOT/claude/agents"

if [[ ! -d "$AGENTS_DIR" ]]; then
  echo "validate-agent-charter-links: no claude/agents/ dir under $ROOT — nothing to check" >&2
  exit 0
fi

violations=0
files_checked=0

# Portable (BSD+GNU) recursive file list, NUL-delimited so filenames with
# spaces survive.
while IFS= read -r -d '' file; do
  files_checked=$((files_checked + 1))
  # Extended regex: "[[" then a character that is neither "[", "]", nor a
  # space. That excludes bash's "[[ " / "[[]]" test-syntax shapes while
  # matching a real Obsidian link's "[[Decisions/..." / "[[Patterns/...".
  matches="$(grep -nE '\[\[[^][ ]' "$file" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    violations=$((violations + 1))
    echo "FAIL  $file — unresolvable wikilink (charter tools: Read/Grep/Glob/Bash, no MCP, cannot reach a vault note):"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "        $line"
    done <<<"$matches"
  fi
done < <(find "$AGENTS_DIR" -type f -name '*.md' -print0)

if [[ "$files_checked" -eq 0 ]]; then
  echo "validate-agent-charter-links: no *.md charters found under $AGENTS_DIR" >&2
  exit 2
fi

if [[ "$violations" -gt 0 ]]; then
  echo ""
  echo "validate-agent-charter-links: $violations charter file(s) carry an unresolvable wikilink." >&2
  echo "Vendor the load-bearing content as short prose, or point at a repo file the" >&2
  echo "declared toolset (Read/Grep/Glob/Bash) can actually reach." >&2
  exit 1
fi

echo "validate-agent-charter-links: OK — $files_checked charter(s) checked, no unresolvable wikilinks."
exit 0
