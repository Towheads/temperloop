#!/usr/bin/env bash
#
# test_validate_agent_charter_links.sh — fixture + real-tree tests for
# workflows/scripts/validate-agent-charter-links.sh (the no-unresolvable-
# wikilink gate over claude/agents/**/*.md review-agent charters).
#
# Covers: the real-tree happy path (the actual repo's charters conform —
# the gate's own green baseline); a fixture wikilink violation in a "read
# first" position; a bash `[[ ]]` test-syntax example that must NOT be
# flagged (the discriminator this gate depends on); a clean fixture tree
# exits 0; a missing claude/agents/ dir is a soft no-op, not a hard error;
# an agents dir with zero *.md files is a usage error.
# Zero network. BSD/macOS-safe.
#
# Usage: bash workflows/scripts/tests/test_validate_agent_charter_links.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-agent-charter-links.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}

assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-charter-links-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Real tree conforms (the gate's own green baseline) ------------------
echo "section 1: real tree"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "real tree exits 0" || fail_test "real tree exits 0" "rc=$rc, output: $out"
assert_has "$out" "validate-agent-charter-links: OK" "real tree reports OK"

# --- 2. Fixture tree: a violation + the bash-syntax non-match ---------------
echo "section 2: fixture violation + discriminator"
R="$TMP/tree"
mkdir -p "$R/claude/agents"

printf -- '---\nname: fixture-bad\ntools: Read, Grep, Glob, Bash\n---\n\n## Project context (read first)\n\nSee [[Decisions/foundation - Some Note]] for the invariant.\n' \
  > "$R/claude/agents/fixture-bad.md"
printf -- '---\nname: fixture-good\ntools: Read, Grep, Glob, Bash\n---\n\nUses bash test syntax like `[[ -f "$x" ]]` and `[[ ]]` vs `[ ]` — not a wikilink.\n' \
  > "$R/claude/agents/fixture-good.md"

out="$(AGENT_CHARTER_LINKS_ROOT="$R" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "fixture tree with a wikilink exits 1" || fail_test "fixture tree with a wikilink exits 1" "rc=$rc, output: $out"
assert_has     "$out" "fixture-bad.md" "the violating charter is named"
assert_has     "$out" "[[Decisions/foundation - Some Note]]" "the offending wikilink text is quoted"
assert_not_has "$out" "fixture-good.md" "the bash [[ ]]-only charter is not flagged"

# --- 3. Fully conforming fixture tree exits 0 -------------------------------
echo "section 3: conforming fixture tree"
R2="$TMP/tree2"
mkdir -p "$R2/claude/agents"
printf -- '---\nname: fixture-good\ntools: Read, Grep, Glob, Bash\n---\n\nNo wikilinks here, just `[[ -f "$x" ]]` bash examples.\n' \
  > "$R2/claude/agents/fixture-good.md"
out="$(AGENT_CHARTER_LINKS_ROOT="$R2" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "conforming fixture exits 0" || fail_test "conforming fixture exits 0" "rc=$rc, output: $out"

# --- 4. Missing claude/agents/ dir is a soft no-op --------------------------
echo "section 4: missing agents dir"
R3="$TMP/tree3"
mkdir -p "$R3"
out="$(AGENT_CHARTER_LINKS_ROOT="$R3" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "missing agents dir exits 0 (nothing to check)" || fail_test "missing agents dir exits 0" "rc=$rc"

# --- 5. Empty claude/agents/ dir (no *.md) is a usage error -----------------
echo "section 5: empty agents dir"
R4="$TMP/tree4"
mkdir -p "$R4/claude/agents"
out="$(AGENT_CHARTER_LINKS_ROOT="$R4" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "empty agents dir exits 2" || fail_test "empty agents dir exits 2" "rc=$rc"

echo ""
echo "test_validate_agent_charter_links: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
