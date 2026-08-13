#!/usr/bin/env bash
#
# test_validate_docs_footer.sh — fixture + real-tree tests for
# workflows/scripts/validate-docs-footer.sh (the AI-authorship footer gate
# over README.md + docs/**/*.md).
#
# Covers: the real-tree happy path (the actual repo conforms — this is the
# gate's own green baseline); a passing fixture page; a missing footer; a
# malformed footer (vague model id + impossible date); a footer that is not
# the last non-blank content; a duplicated *Written by* line; a valid
# *Last updated by* append; a missing '---' rule above the footer (with
# frontmatter '---' at the top proving top-of-file rules don't count); an
# exempt page silently skipped; and the stale-exemption ratchet (an exempt
# page that GAINS a footer fails with a remove-the-exemption message).
# Zero network. BSD/macOS-safe.
#
# Usage: bash workflows/scripts/tests/test_validate_docs_footer.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-docs-footer.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/docs-footer-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FOOTER=$'\n---\n\n*Written by claude-fable-5 on 2026-08-13.*\n'

# --- 1. Real tree conforms (the gate's green baseline) ----------------------
echo "section 1: real tree"
out="$(bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "real tree exits 0" || fail_test "real tree exits 0" "rc=$rc, output: $out"
assert_has "$out" "validate-docs-footer: OK" "real tree reports OK"

# --- 2. Fixture tree: each violation class ---------------------------------
echo "section 2: fixture violations"
R="$TMP/tree"
mkdir -p "$R/docs/features" "$R/docs/adr"

printf '# Good\n\nbody\n%s' "$FOOTER" > "$R/README.md"
printf '# Good page\n\nbody\n%s' "$FOOTER" > "$R/docs/good.md"
printf '# Missing\n\nbody\n' > "$R/docs/missing.md"
printf '# Malformed\n\nbody\n\n---\n\n*Written by Claude on 2026-13-45.*\n' > "$R/docs/malformed.md"
printf '# Buried\n\nbody\n%s\nmore prose after the footer\n' "$FOOTER" > "$R/docs/buried.md"
printf '# Dup\n\nbody\n%s\n*Written by claude-opus-4-8 on 2026-08-14.*\n' "$FOOTER" > "$R/docs/dup.md"
printf '# Updated\n\nbody\n%s*Last updated by claude-opus-4-8 on 2026-08-14.*\n' "$FOOTER" > "$R/docs/updated.md"
printf -- '---\ntitle: fm\n---\n\n# NoRule\n\nbody\n\n*Written by claude-fable-5 on 2026-08-13.*\n' > "$R/docs/norule.md"
printf '# Interior\n\nbody\n%s\nstray prose inside the footer block\n*Last updated by claude-opus-4-8 on 2026-08-14.*\n' "$FOOTER" > "$R/docs/interior.md"
printf '# UpdatedOnly\n\nbody\n\n---\n\n*Last updated by claude-opus-4-8 on 2026-08-14.*\n' > "$R/docs/updated-only.md"
printf '*Written by claude-fable-5 on 2026-08-13.*\n' > "$R/docs/footer-only.md"
printf '# Exempt, clean\n\nbody\n' > "$R/docs/features/skipped.md"
printf '# Exempt, stamped\n\nbody\n%s' "$FOOTER" > "$R/docs/adr/stamped.md"

out="$(DOCS_FOOTER_ROOT="$R" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "fixture tree exits 1" || fail_test "fixture tree exits 1" "rc=$rc"
assert_has     "$out" "docs/missing.md — missing authorship footer" "missing footer named"
assert_has     "$out" "docs/malformed.md — malformed footer" "malformed model id + date named"
assert_has     "$out" "docs/buried.md — footer exists but is not the last non-blank content" "buried footer named"
assert_has     "$out" "docs/dup.md — carries 2 '*Written by …*' lines" "duplicate Written-by named"
assert_has     "$out" "docs/norule.md — footer lacks the preceding '---' rule" "frontmatter --- does not satisfy the footer rule"
assert_has     "$out" "docs/interior.md — footer block contains" "prose or malformed line inside the footer block named"
assert_has     "$out" "docs/updated-only.md — has a '*Last updated by …*' line but no well-formed '*Written by …*' line" "updated-only page named"
assert_has     "$out" "docs/footer-only.md — footer lacks the preceding '---' rule" "footer-on-line-1 handled without BSD head error"
assert_has     "$out" "docs/adr/stamped.md — is on the exemption list but carries an authorship footer" "stale exemption ratchet fires"
assert_not_has "$out" "docs/good.md" "conforming page not flagged"
assert_not_has "$out" "README.md —" "conforming README not flagged"
assert_not_has "$out" "docs/updated.md" "Last-updated append accepted"
assert_not_has "$out" "docs/features/skipped.md" "exempt page without footer silently skipped"

# --- 3. Fully conforming fixture tree exits 0 -------------------------------
echo "section 3: conforming fixture tree"
R2="$TMP/tree2"
mkdir -p "$R2/docs/features"
printf '# Good\n\nbody\n%s' "$FOOTER" > "$R2/README.md"
printf '# Good page\n\nbody\n%s' "$FOOTER" > "$R2/docs/good.md"
printf '# Exempt\n\nbody\n' > "$R2/docs/features/ref.md"
out="$(DOCS_FOOTER_ROOT="$R2" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "conforming fixture exits 0" || fail_test "conforming fixture exits 0" "rc=$rc, output: $out"
assert_has "$out" "2 page(s) conform, 1 exempt" "counts reported"

# --- 4. Bad root is a usage error -------------------------------------------
echo "section 4: error paths"
out="$(DOCS_FOOTER_ROOT="$TMP/nope" bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "missing root exits 2" || fail_test "missing root exits 2" "rc=$rc"

echo ""
echo "test_validate_docs_footer: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
