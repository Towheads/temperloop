#!/usr/bin/env bash
#
# test_validate_design_brief.sh — fixture tests for
# workflows/scripts/validate-design-brief.sh (temperloop#216).
#
# Covers both checks the validator runs:
#   (A) schema citation check — against the real claude/design-schema.md
#       (must stay clean) and against a fixture with a deliberately dangling
#       citation (must fail, DANGLING-CITATION).
#   (B) brief conformance check — against a purpose-built minimal conformant
#       fixture (must pass) and three distinct failure-shaped fixtures: a
#       dropped disposition line (MISSING-DISPOSITION), an absent heading
#       (MISSING-DIMENSION), and a malformed disposition value
#       (BAD-DISPOSITION).
# Also proves the bare CI-mode invocation (no flags) is what quality-gates.sh
# runs and stays green against the real tree.
#
# Zero network, zero git-repo scaffolding needed — the validator reads plain
# files, not a git index, so fixtures are just files under
# workflows/scripts/tests/fixtures/.
#
# Usage: bash workflows/scripts/tests/test_validate_design_brief.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-design-brief.sh"
BRIEF_FIXTURES="$REPO/workflows/scripts/tests/fixtures/design-briefs"
SCHEMA_FIXTURES="$REPO/workflows/scripts/tests/fixtures/design-schema"

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
assert_lacks() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "expected NOT to find: $needle" ;;
    *) ok "$name" ;;
  esac
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

out=""
rc=0
run() {
  rc=0
  out="$(DESIGN_SCHEMA_ROOT="$REPO" bash "$SCRIPT" "$@" 2>&1)" || rc=$?
}

# ── 1. bare CI-mode invocation: schema citation check on the real tree ──────
echo "--- 1. bare invocation (CI mode) against the real schema ---"
run
assert_rc "$rc" 0 "bare invocation exits 0 on the real tree"
assert_has "$out" "validate-design-brief: OK" "bare invocation says OK"
assert_lacks "$out" "DANGLING-CITATION" "real schema has no dangling citations"

# ── 2. schema citation check: real schema explicitly via --schema ───────────
echo "--- 2. --schema on the real claude/design-schema.md ---"
run --schema "$REPO/claude/design-schema.md"
assert_rc "$rc" 0 "real schema file exits 0"
assert_has "$out" "validate-design-brief: OK" "real schema says OK"

# ── 3. schema citation check: fixture with a dangling citation ──────────────
echo "--- 3. --schema on the dangling-citation fixture ---"
run --schema "$SCHEMA_FIXTURES/dangling-citation.md"
assert_rc "$rc" 1 "dangling-citation fixture exits 1"
assert_has "$out" "DANGLING-CITATION  dimension 2 — 'workflows/scripts/validate-nonexistent-thing.sh'" "dangling citation named"
assert_lacks "$out" "dimension 1 —" "the real citation in row 1 is NOT flagged"

# ── 4. brief conformance: minimal conformant fixture passes ─────────────────
echo "--- 4. --brief on the minimal-conformant fixture ---"
run --brief "$BRIEF_FIXTURES/minimal-conformant.md"
assert_rc "$rc" 0 "conformant fixture exits 0"
assert_has "$out" "validate-design-brief: OK" "conformant fixture says OK"
assert_has "$out" "16 dimension heading(s) found" "all 16 dimensions counted"

# ── 5. brief conformance: dropped disposition line ───────────────────────────
echo "--- 5. --brief on missing-dimension (dropped disposition, dim 9) ---"
run --brief "$BRIEF_FIXTURES/missing-dimension.md"
assert_rc "$rc" 1 "missing-dimension fixture exits 1"
assert_has "$out" "MISSING-DISPOSITION  missing-dimension.md dimension 9" "missing disposition named on dim 9"

# ── 6. brief conformance: heading entirely absent ────────────────────────────
echo "--- 6. --brief on missing-heading (no '## 12.' heading at all) ---"
run --brief "$BRIEF_FIXTURES/missing-heading.md"
assert_rc "$rc" 1 "missing-heading fixture exits 1"
assert_has "$out" "MISSING-DIMENSION  missing-heading.md — kernel dimension 12" "missing dimension 12 named"

# ── 7. brief conformance: malformed disposition grammar ──────────────────────
echo "--- 7. --brief on bad-grammar (dim 6 disposition doesn't match the grammar) ---"
run --brief "$BRIEF_FIXTURES/bad-grammar.md"
assert_rc "$rc" 1 "bad-grammar fixture exits 1"
assert_has "$out" "BAD-DISPOSITION  bad-grammar.md dimension 6 — 'disposition: skipped'" "bad disposition value named"

# ── 8. brief conformance: brief file itself absent ───────────────────────────
echo "--- 8. --brief on a nonexistent path ---"
run --brief "$BRIEF_FIXTURES/does-not-exist.md"
assert_rc "$rc" 1 "nonexistent brief file exits 1"
assert_has "$out" "BRIEF-NOT-FOUND" "brief-not-found named"

# ── 9. usage errors ───────────────────────────────────────────────────────────
echo "--- 9. usage errors ---"
run --brief
assert_rc "$rc" 2 "--brief with no path exits 2"
run --bogus-flag
assert_rc "$rc" 2 "unknown flag exits 2"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_validate_design_brief: FAIL"
  exit 1
fi
echo "test_validate_design_brief: OK"
