#!/usr/bin/env bash
#
# AGPL boundary lint (foundation #776, Epic A #762): the knowledge_search
# basic-memory backend must talk to basic-memory (AGPL-3.0) ONLY as an
# external CLI subprocess — never a vendored copy of its source, never a
# Python import, never a bare invocation of the `basic-memory` binary that
# bypasses the adapter's own pinned wrapper. This repo holds no AGPL-3.0 code
# and must not start now.
#
# THE WRAPPER CHANGED SHAPE IN temperloop#1113, the boundary did not. The
# adapter used to resolve the pin per run (`uvx --from basic-memory==<pin>
# basic-memory ...`); it now installs that same pin as a uv tool into its own
# isolated home and invokes the installed entry point BY ABSOLUTE PATH
# (`_ks_bm_run`). Both are "spawn it as a subprocess and read its stdout" —
# no source vendored, no package imported, no dependency manifest declaring
# it. What check 3 below still forbids is unchanged and is the part that
# matters: a `basic-memory` in COMMAND POSITION, which would resolve through
# PATH to some unpinned install outside the boundary.
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

# --- 3. `basic-memory` is never invoked as a bare COMMAND WORD --------------
#        Distinguishes "basic-memory" as a *command word* (start of a shell
#        command: line start, or right after `;`/`&`/`|`/`$(`) from every
#        other mention of the string (doc prose, `.basic-memory` config-dir
#        paths, log/error messages, env-var names/defaults) -- those are all
#        fine and expected throughout the adapter and its tests/docs. Only a
#        line where "basic-memory" sits in command position is a real
#        boundary violation: the adapter invokes its installed entry point
#        through a PATH-INDEPENDENT variable ("$bm_bin"), so a bare
#        `basic-memory ...` can only mean a PATH lookup that escapes the
#        pinned install. Lines that carry `uvx`/`uv tool` are exempted so the
#        historical-note prose and the fixture stubs that mention the old
#        wrapper do not trip the lint.
invocations="$(git grep --untracked -nE '(^|[;&|]|\$\()[[:space:]]*basic-memory[[:space:]]' -- '*.sh' 2>/dev/null | grep -v "^${THIS_TEST_REL}:" || true)"
bad=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *uvx*|*"uv tool"*) continue ;;
  esac
  bad="${bad}${bad:+$'\n'}${hit}"
done <<<"$invocations"
[ -z "$bad" ] || fail "found 'basic-memory' invoked as a bare command word, bypassing the adapter's pinned installed entry point: $bad"
echo "PASS: 3 no shell line invokes basic-memory as a bare command word (every call goes through the adapter's pinned entry point)"

# --- 4a. the ADAPTER never runs the mcp subcommand (sidesteps upstream #1017) -
mcp_calls="$(git grep --untracked -nE 'basic-memory[^|&;]* mcp( |$)' -- '*.sh' 2>/dev/null | grep -v "^${THIS_TEST_REL}:" || true)"
[ -z "$mcp_calls" ] || fail "found a 'basic-memory ... mcp' invocation in tracked shell source (the adapter must be CLI-only, never the MCP server): $mcp_calls"
echo "PASS: 4a no tracked shell script invokes 'basic-memory mcp'"

# --- 4b. any tracked SUPERVISOR UNIT that launches the MCP server must be
#         explicitly sanctioned (foundation#1019) ----------------------------
#
# 4a alone made this invariant hold by FILE EXTENSION rather than by intent.
# A consuming repo can ship a warm-search daemon — foundation's
# com.foundation.bm-mcp.plist does exactly that, and it genuinely launches
# `basic-memory mcp`, which IS the upstream #1017 exposure 4a proxies for —
# and 4a grepped straight past it twice over: the file is a `.plist` (outside
# the `*.sh` pathspec), and launchd splits argv across SEPARATE <string>
# elements, so `basic-memory` and `mcp` never share a line and NO line-oriented
# regex can see the pair no matter what pathspec it is given.
#
# So assert the property POSITIVELY rather than assuming absence: find every
# tracked unit that launches the MCP server and require each to carry an
# explicit sanction marker. A supervised daemon is a deliberate, reviewed
# decision; a stray future one — a new plist, a systemd unit, a compose file —
# carries no marker and fails here. The marker lives IN the unit rather than in
# an allowlist file this KERNEL test would have to hardcode a consuming repo's
# paths into: self-describing, and it travels with the unit it sanctions.
SANCTION_MARKER='AGPL-SUPERVISOR-SANCTIONED'

# Prints the tracked units that launch the MCP server WITHOUT a sanction
# marker, one per line. Factored out so the fixture self-check below can drive
# it against a scratch tree rather than only ever against the real one.
find_unsanctioned_units() {
  local root="$1" unit
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ -f "$root/$unit" ] || continue
    # TWO independent token tests, never one pattern — see the argv-splitting
    # note above. A unit that names basic-memory AND carries a standalone
    # `mcp` token is an MCP launcher whatever its file format.
    grep -q 'basic-memory' "$root/$unit" 2>/dev/null || continue
    grep -qE '(<string>[[:space:]]*mcp[[:space:]]*</string>|(^|[[:space:]"'"'"'=])mcp([[:space:]"'"'"']|$))' "$root/$unit" 2>/dev/null || continue
    grep -q "$SANCTION_MARKER" "$root/$unit" 2>/dev/null && continue
    printf '%s\n' "$unit"
  done <<EOF
$(cd "$root" && git ls-files --cached --others --exclude-standard -- '*.plist' '*.service' '*.yaml' '*.yml' 2>/dev/null || true)
EOF
}

unsanctioned="$(find_unsanctioned_units "$REPO_ROOT" | tr '\n' ' ' | sed 's/ *$//')"
[ -z "$unsanctioned" ] || fail "a tracked supervisor unit launches 'basic-memory mcp' without the $SANCTION_MARKER marker (a supervised MCP daemon must be a deliberate, marked decision — add the marker with a one-line rationale, or remove the launch): $unsanctioned"
echo "PASS: 4b every tracked supervisor unit that launches 'basic-memory mcp' carries the $SANCTION_MARKER marker"

# --- 4c. the 4b detector actually bites (fixture self-check) ----------------
# Without this, 4b passes vacuously on any tree that ships no unit files at all
# — which is the kernel repo's OWN situation, and is precisely the "an unrun
# gate reads as a pass" shape this whole re-scope exists to close.
_agpl_fixture="$(mktemp -d "${TMPDIR:-/tmp}/agpl-boundary-fixture-XXXXXX")"
trap 'rm -rf "$_agpl_fixture"' EXIT
(
  cd "$_agpl_fixture"
  git init -q .
  mkdir -p units
  # An UNMARKED launcher, argv split across elements exactly as launchd writes it.
  cat > units/unmarked.plist <<'PLIST'
<key>ProgramArguments</key>
<array>
  <string>/opt/bm/bin/basic-memory</string>
  <string>mcp</string>
  <string>--transport</string>
  <string>streamable-http</string>
</array>
PLIST
  # The same launcher, sanctioned.
  sed 's|<array>|<array><!-- AGPL-SUPERVISOR-SANCTIONED: warm search daemon -->|' \
    units/unmarked.plist > units/marked.plist
  # A unit that names basic-memory but launches no MCP server.
  printf '<string>/opt/bm/bin/basic-memory</string>\n<string>sync</string>\n' > units/not-mcp.plist
)
_fx_out="$(find_unsanctioned_units "$_agpl_fixture" | sort | tr '\n' ' ' | sed 's/ *$//')"
[ "$_fx_out" = "units/unmarked.plist" ] \
  || fail "4c: the 4b detector does not discriminate — expected exactly 'units/unmarked.plist', got '$_fx_out' (an unmarked launcher must be caught; a marked one and a non-MCP unit must not be)"
rm -rf "$_agpl_fixture"
trap - EXIT
echo "PASS: 4c the 4b detector catches an unmarked MCP launcher and clears both a marked one and a non-MCP unit (fixture-verified, so 4b cannot pass vacuously)"

echo "ALL PASS: AGPL boundary held -- basic-memory is referenced only in docs/tests, invoked only as a pinned external subprocess, and supervised only by explicitly sanctioned units"
