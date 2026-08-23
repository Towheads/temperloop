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

# ABSENT INPUT IS NOT AUTOMATICALLY A PASS (epic temperloop#1409, "a check that
# could not run reports success"). A bare `exit 0` here would mean this gate goes
# GREEN in the one situation it is least entitled to: the kernel's own checkout
# with its charter directory missing. That is breakage, not "nothing to check".
#
# But an absent dir IS legitimately nothing to check for a VENDORING CONSUMER,
# which may adopt the kernel's build machinery without adopting its review
# agents. The repo already has a discriminator for exactly that distinction — a
# repo-root `.kernel-pin`, the same signal quality-gates.sh uses to class-gate
# kernel-content gates — so use it rather than inventing a second one:
#
#   .kernel-pin PRESENT (a vendoring consumer)  -> no-op, exit 0, and SAY so
#   .kernel-pin ABSENT  (the kernel itself)     -> exit 2, this is breakage
if [[ ! -d "$AGENTS_DIR" ]]; then
  if [[ -f "$ROOT/.kernel-pin" ]]; then
    echo "validate-agent-charter-links: no claude/agents/ dir under $ROOT and a repo-root .kernel-pin is present — a vendoring consumer that did not adopt the review agents; nothing to check." >&2
    exit 0
  fi
  echo "validate-agent-charter-links: no claude/agents/ dir under $ROOT, and no repo-root .kernel-pin — this is the kernel's own checkout, where the charter directory is expected to exist. Refusing to report success on an input this gate could not evaluate (epic temperloop#1409)." >&2
  exit 2
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
  # UNREADABLE IS NOT CLEAN (epic temperloop#1409). `grep` on a file it cannot
  # open returns no matches, which is byte-identical to "this charter has no
  # wikilinks" — so without this guard an unreadable charter passes the gate
  # while never having been examined. Refuse instead: an input this gate could
  # not read is a failure, not a pass.
  if [[ ! -r "$file" ]]; then
    violations=$((violations + 1))
    echo "FAIL  $file — UNREADABLE: this gate could not examine the charter, so it cannot report it clean (epic temperloop#1409)."
    continue
  fi
  matches="$(grep -nE '\[\[[^][ ]' "$file" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    violations=$((violations + 1))
    echo "FAIL  $file — unresolvable wikilink (charter tools: Read/Grep/Glob/Bash, no MCP, cannot reach a vault note):"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "        $line"
    done <<<"$matches"
  fi
# -L, not a bare walk (temperloop#1737). In a COMPOSED OVERLAY `claude/agents`
# is a compat symlink into the vendored kernel subtree, and `find` does not
# descend a symlinked START POINT without it — so the walk yielded zero files
# on a correctly-wired tree. The `[[ -d ]]` guard above DOES follow the
# symlink, so the two disagreed and the script took its "no charters" error
# path instead of its consumer no-op path. `-L` also covers a symlinked
# individual charter, which a trailing slash would not.
done < <(find -L "$AGENTS_DIR" -type f -name '*.md' -print0)

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
