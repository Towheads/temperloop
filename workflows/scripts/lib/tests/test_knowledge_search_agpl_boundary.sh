#!/usr/bin/env bash
#
# AGPL boundary lint (foundation #776, Epic A #762): the knowledge_search
# basic-memory backend must talk to basic-memory (AGPL-3.0) ONLY as an
# external CLI subprocess (`uvx --from basic-memory==<pin> basic-memory ...`)
# — never a vendored copy of its source, never a Python import, never a bare
# invocation of the `basic-memory` binary that bypasses the pinned `uvx`
# wrapper. This repo holds no AGPL-3.0 code and must not start now.
#
# Greps the tracked-or-would-be-tracked tree: `git ls-files --cached
# --others --exclude-standard` and `git grep --untracked` so a change that
# hasn't been `git add`ed yet is still caught (not just what's already
# committed), while `.git` internals and anything gitignored (a local
# basic-memory install cache, this test's own throwaway tmpdir fixtures)
# stay out of scope.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
THIS_TEST_REL="workflows/scripts/lib/tests/test_knowledge_search_agpl_boundary.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cd "$REPO_ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "SKIP: not inside a git work tree"; exit 0; }

# --- 1. no vendored basic-memory / basic_memory path anywhere in-scope ------
vendored="$(git ls-files --cached --others --exclude-standard | grep -iE '(^|/)(basic[_-]memory)(/|$)' || true)"
[ -z "$vendored" ] || fail "vendored basic-memory path(s) found in the tree (must be a CLI subprocess only): $vendored"
echo "PASS: 1 no vendored basic-memory/basic_memory path in the tree"

# --- 2. no Python import of basic_memory anywhere in-scope -------------------
imports="$(git grep --untracked -nE '(^|[^.[:alnum:]_])(import[[:space:]]+basic_memory|from[[:space:]]+basic_memory[[:space:]]+import)' -- . 2>/dev/null || true)"
[ -z "$imports" ] || fail "a Python import of basic_memory was found (must stay a CLI subprocess): $imports"
echo "PASS: 2 no Python import of basic_memory anywhere in the tree"

# --- 3. `basic-memory` is never invoked as a COMMAND outside the uvx wrapper -
#        Distinguishes "basic-memory" as a *command word* (start of a shell
#        command: line start, or right after `;`/`&`/`|`/`$(`) from every
#        other mention of the string (doc prose, `.basic-memory` config-dir
#        paths, log/error messages, env-var names/defaults) -- those are all
#        fine and expected throughout the adapter and its tests/docs. Only a
#        line where "basic-memory" sits in command position AND does not
#        also carry "uvx" is a real boundary violation (a bypass of the
#        pinned subprocess wrapper).
invocations="$(git grep --untracked -nE '(^|[;&|]|\$\()[[:space:]]*basic-memory[[:space:]]' -- '*.sh' 2>/dev/null | grep -v "^${THIS_TEST_REL}:" || true)"
bad=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *uvx*) continue ;;
  esac
  bad="${bad}${bad:+$'\n'}${hit}"
done <<<"$invocations"
[ -z "$bad" ] || fail "found 'basic-memory' invoked as a command outside the uvx subprocess wrapper: $bad"
echo "PASS: 3 every command-position invocation of basic-memory goes through the uvx subprocess boundary"

# --- 4. the adapter never runs the mcp subcommand (sidesteps upstream #1017) -
mcp_calls="$(git grep --untracked -nE 'basic-memory[^|&;]* mcp( |$)' -- '*.sh' 2>/dev/null | grep -v "^${THIS_TEST_REL}:" || true)"
[ -z "$mcp_calls" ] || fail "found a 'basic-memory ... mcp' invocation in tracked source (adapter must be CLI-only, never the MCP server): $mcp_calls"
echo "PASS: 4 no tracked shell script invokes 'basic-memory mcp'"

echo "ALL PASS: AGPL boundary held -- basic-memory is referenced only in docs/tests and invoked only through the pinned uvx subprocess"
