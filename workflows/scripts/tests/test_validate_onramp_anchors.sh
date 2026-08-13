#!/usr/bin/env bash
#
# test_validate_onramp_anchors.sh — fixture tests for
# workflows/scripts/validate-onramp-anchors.sh (ADR 0024, temperloop#1117).
#
# Hermetic: every case builds a throwaway fixture tree under mktemp
# (no git needed — the validator reads plain files) and points the script at
# it via ONRAMP_GATE_ROOT. The real repo is never mutated. One case (14-style,
# the validate-activation-registry.sh mold) runs the script against the REAL
# tree to prove the four real anchors agree today.
#
# Exercises:
#   1. GREEN — the real repo tree (all four anchors, as of this change)
#   2. RED   — a registered anchor names a retired value (`try --demo`)
#   3. RED   — a registered anchor's canonical value is missing entirely
#   4. GREEN — the arrow-glyph normalization: a Unicode-arrow anchor still
#              matches its ASCII canonical `adoption-path` value
#   5. RED   — adoption-sense `sandbox` in a registered anchor's window
#   6. GREEN — `try`/`sandbox` OUTSIDE a registered anchor's window is not
#              flagged (the negative assertion is scoped to the anchor set,
#              never the whole file — ADR 0024's own scoping rule)
#   7. RED   — a registered anchor-path does not exist in the tree
#   8. RED   — a malformed registry row (missing column)
#   9. RED   — an unknown value-key (typo'd) fails loudly, not silently
#  10. GREEN — locator drift within the window still matches (an unrelated
#              line inserted above the anchor)
#
# Usage: bash workflows/scripts/tests/test_validate_onramp_anchors.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/validate-onramp-anchors.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_status() {
  local want="$1" got="$2" name="$3"
  if [[ "$want" == "$got" ]]; then ok "$name"; else bad "$name" "expected exit $want, got $got"; fi
}
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) bad "$name" "expected output to contain: $needle" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) bad "$name" "expected output NOT to contain: $needle" ;;
    *) ok "$name" ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# new_fixture <dir> — a minimal tree carrying the four real anchor files
# (copied verbatim from the real repo, so the fixture stays representative
# of the actual surrounding context each anchor's window reads) plus the
# real registry. Callers mutate from there.
new_fixture() {
  local d="$1"
  mkdir -p "$d/bin" "$d/docs/features" "$d/workflows/scripts/config"
  cp "$REPO/bin/temperloop" "$d/bin/temperloop"
  cp "$REPO/README.md" "$d/README.md"
  cp "$REPO/bin/README.md" "$d/bin/README.md"
  cp "$REPO/docs/features/install-cli.md" "$d/docs/features/install-cli.md"
  cp "$REPO/workflows/scripts/config/onramp-anchors.tsv" "$d/workflows/scripts/config/onramp-anchors.tsv"
}

# run_gate <root> -> RUN_OUT / RUN_STATUS
run_gate() {
  RUN_OUT="$(ONRAMP_GATE_ROOT="$1" bash "$SCRIPT" 2>&1)"
  RUN_STATUS=$?
}

# replace_line <file> <line-no> <new-content>
replace_line() {
  local f="$1" n="$2" content="$3"
  awk -v n="$n" -v c="$content" 'NR==n{print c; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ── 1. GREEN: the real repo tree ─────────────────────────────────────────
echo "1. the real repo's four anchors agree"
run_gate "$REPO"
assert_status 0 "$RUN_STATUS" "passes against the real tree"
assert_has "$RUN_OUT" "checked: 11" "checks all 11 registered rows"
assert_not_has "$RUN_OUT" "FAIL" "no failures against the real tree"

# ── 2. RED: a registered anchor names a retired value ───────────────────
echo "2. a registered anchor is made to disagree (try --demo)"
D="$TMP/r2"; new_fixture "$D"
replace_line "$D/bin/temperloop" 144 "Start here: temperloop try --demo"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails — the anchor now names a retired value"
assert_has "$RUN_OUT" "bin/temperloop:144" "names the failing anchor"
assert_has "$RUN_OUT" "retired value 'try'" "names the retired token it found"

# ── 3. RED: a registered anchor's canonical value goes missing ─────────────
echo "3. a registered anchor's canonical value is missing entirely"
D="$TMP/r3"; new_fixture "$D"
replace_line "$D/README.md" 73 "## 2. Getting started"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails — the heading no longer says the canonical phrase"
assert_has "$RUN_OUT" "README.md:73" "names the failing anchor"
assert_has "$RUN_OUT" "expected value not found" "names the failure reason"

# ── 4. GREEN: arrow-glyph normalization ─────────────────────────────────
echo "4. Unicode-arrow anchor still matches the ASCII canonical value"
D="$TMP/r4"; new_fixture "$D"
run_gate "$D"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "ok    README.md:73 (adoption-path)" "the Unicode-arrow README heading passes the ASCII adoption-path check"
assert_has "$RUN_OUT" "ok    docs/features/install-cli.md:41 (adoption-path)" "the ASCII-arrow install-cli.md line passes the same check"

# ── 5. RED: adoption-sense `sandbox` in a registered anchor's window ───────
echo "5. adoption-sense sandbox in a registered anchor's window"
D="$TMP/r5"; new_fixture "$D"
replace_line "$D/bin/README.md" 72 "## Quickstart: sandbox -> first epic -> promote -> adopt"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails — sandbox is a retired adoption-sense noun"
assert_has "$RUN_OUT" "bin/README.md:72" "names the failing anchor"
assert_has "$RUN_OUT" "retired value 'sandbox'" "names the retired token"

# ── 6. GREEN: retired tokens OUTSIDE a registered anchor's window ──────────
# The negative assertion is scoped to the registered anchor windows only —
# a legitimate historical mention elsewhere in the SAME file, far from any
# registered locator, is not this gate's business (ADR 0024's own scoping
# rule; CHANGELOG.md/docs/adr/**/Plans-archive/** carry it as history too,
# but this case proves the scoping even WITHIN a registered file).
echo "6. try/sandbox far outside any registered anchor's window stays unflagged"
D="$TMP/r6"; new_fixture "$D"
{
  echo ""
  echo "## Legacy commands (history)"
  echo ""
  echo "\`temperloop try\` and \`temperloop sandbox\` were the old on-ramp; both are retired."
} >> "$D/bin/README.md"
run_gate "$D"
assert_status 0 "$RUN_STATUS" "still passes — the mention is far outside any registered window"
assert_not_has "$RUN_OUT" "FAIL" "no failure from the out-of-window historical mention"

# ── 7. RED: a registered anchor-path does not exist ─────────────────────
echo "7. a registered anchor-path is missing from the tree"
D="$TMP/r7"; new_fixture "$D"
rm "$D/docs/features/install-cli.md"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails — the registered file is gone"
assert_has "$RUN_OUT" "anchor file missing" "names the failure reason"

# ── 8. RED: a malformed registry row ────────────────────────────────────
echo "8. a malformed registry row (missing value-key column)"
D="$TMP/r8"; new_fixture "$D"
printf 'bin/temperloop\t144\n' >> "$D/workflows/scripts/config/onramp-anchors.tsv"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails loudly rather than silently skipping"
assert_has "$RUN_OUT" "malformed row" "names the parse failure"

# ── 9. RED: an unknown value-key ─────────────────────────────────────────
echo "9. a typo'd value-key is not in the canonical-value table"
D="$TMP/r9"; new_fixture "$D"
printf 'bin/temperloop\t144\tfirst-subcomand\n' >> "$D/workflows/scripts/config/onramp-anchors.tsv"
run_gate "$D"
assert_status 1 "$RUN_STATUS" "fails — unknown key is a hard failure, not a silent skip"
assert_has "$RUN_OUT" "unknown value-key" "names the failure reason"

# ── 10. GREEN: locator drift within the window tolerance ────────────────
echo "10. an unrelated line inserted above the anchor still resolves"
D="$TMP/r10"; new_fixture "$D"
awk 'NR==90{print "<!-- an unrelated comment inserted above the anchor -->"} {print}' \
  "$D/README.md" > "$D/README.md.tmp" && mv "$D/README.md.tmp" "$D/README.md"
run_gate "$D"
assert_status 0 "$RUN_STATUS" "still passes — the shift is within the window tolerance"
assert_not_has "$RUN_OUT" "FAIL" "no failure from the in-window shift"

echo
echo "test_validate_onramp_anchors: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
