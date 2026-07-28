#!/usr/bin/env bash
#
# test_check_redundancy_fixtures.sh — synthetic-corpus tests for
# check-redundancy-fixtures.sh (temperloop#854, half (a) of the P9
# semantic-redundancy probe).
#
# Covers: the GREEN path against the real tracked corpus, plus every
# violation class against synthetic fixture JSON — missing field, bad
# label, duplicate id, and (the acceptance-property pin) a `positive` pair
# that DOES share a 10-word run.
#
# No git repo needed — unlike check-contributor-manifest.sh's own test,
# this checker never shells out to `git ls-files`.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-redundancy-fixtures.sh"
REAL_CORPUS="$CONFIG_DIR/redundancy-fixtures.json"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-check-redundancy-fixtures.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── 1. real tracked corpus is green ──────────────────────────────────────────
echo "--- 1. real tracked corpus ---"
out="$(REDUNDANCY_FIXTURES_JSON="$REAL_CORPUS" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 0 "the real tracked corpus passes cleanly"
assert_has "$out" "OK —" "the real tracked corpus prints an OK summary"

# ── 2. missing corpus file ───────────────────────────────────────────────────
echo "--- 2. missing corpus ---"
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/does-not-exist.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a missing corpus path exits 1"
assert_has "$out" "not found" "missing corpus named"

# ── 3. invalid JSON ──────────────────────────────────────────────────────────
echo "--- 3. invalid JSON ---"
printf '{ this is not json' > "$TMP/bad.json"
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/bad.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "invalid JSON exits 1"
assert_has "$out" "not valid JSON" "invalid JSON named"

# ── 4. empty fixtures array ──────────────────────────────────────────────────
echo "--- 4. empty fixtures array ---"
printf '{"fixtures": []}' > "$TMP/empty.json"
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/empty.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "an empty fixtures array exits 1"
assert_has "$out" "must be non-empty" "empty-array case named"

# ── 5. missing required field ────────────────────────────────────────────────
echo "--- 5. missing required field ---"
cat > "$TMP/missing-field.json" <<'EOF'
{
  "fixtures": [
    {
      "id": "no-rationale",
      "label": "negative",
      "kind": "hard-topical-near-miss",
      "chunk_a": {"text": "Some rule about widgets."},
      "chunk_b": {"text": "A different rule about gadgets entirely."}
    }
  ]
}
EOF
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/missing-field.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a missing rationale field exits 1"
assert_has "$out" "MISSING FIELD" "missing-field violation named"
assert_has "$out" "no rationale" "the specific missing field is named"

# ── 6. unknown label ─────────────────────────────────────────────────────────
echo "--- 6. unknown label ---"
cat > "$TMP/bad-label.json" <<'EOF'
{
  "fixtures": [
    {
      "id": "sideways-label",
      "label": "maybe",
      "kind": "paraphrase",
      "rationale": "test fixture with a bogus label",
      "chunk_a": {"text": "Rule stated one way about the topic at hand today."},
      "chunk_b": {"text": "Rule stated a different way about that very topic now."}
    }
  ]
}
EOF
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/bad-label.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "an unrecognized label value exits 1"
assert_has "$out" "UNKNOWN LABEL" "unknown-label violation named"

# ── 7. duplicate id ───────────────────────────────────────────────────────────
echo "--- 7. duplicate id ---"
cat > "$TMP/dup-id.json" <<'EOF'
{
  "fixtures": [
    {
      "id": "dup",
      "label": "negative",
      "kind": "hard-topical-near-miss",
      "rationale": "first entry",
      "chunk_a": {"text": "Widgets must always ship in blue boxes only."},
      "chunk_b": {"text": "Gadgets must always ship in red crates only."}
    },
    {
      "id": "dup",
      "label": "negative",
      "kind": "hard-topical-near-miss",
      "rationale": "second entry, same id as the first — must fail",
      "chunk_a": {"text": "Sprockets must always ship in green tubes only."},
      "chunk_b": {"text": "Cogs must always ship in yellow sleeves only."}
    }
  ]
}
EOF
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/dup-id.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a duplicate id exits 1"
assert_has "$out" "DUPLICATE ID" "duplicate-id violation named"

# ── 8. THE ACCEPTANCE PROPERTY PIN: a positive pair that shares a 10-word
#      run must fail — proves this lint actually enforces "no shared
#      10-word shingle", not merely documents the intent in a comment ──────
echo "--- 8. positive pair with a shared 10-word run (must fail) ---"
cat > "$TMP/shingle-violation.json" <<'EOF'
{
  "fixtures": [
    {
      "id": "fake-positive-actually-verbatim",
      "label": "positive",
      "kind": "paraphrase",
      "rationale": "deliberately near-verbatim — this must be REJECTED by the shingle check",
      "chunk_a": {"text": "Branch names use the pattern type slash slug and slug is a short kebab case description capped at forty characters exactly."},
      "chunk_b": {"text": "Branch names use the pattern type slash slug and slug is a short kebab case description capped at forty characters, always."}
    }
  ]
}
EOF
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/shingle-violation.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 1 "a positive pair sharing a 10-word run exits 1"
assert_has "$out" "SHARED 10-WORD SHINGLE" "the shingle-overlap violation is named"

# ── 9. a NEGATIVE pair sharing lots of language is fine (no shingle check
#      applies to negative entries) ─────────────────────────────────────────
echo "--- 9. negative pair sharing language is NOT flagged ---"
cat > "$TMP/negative-shared-language.json" <<'EOF'
{
  "fixtures": [
    {
      "id": "negative-shares-language-fine",
      "label": "negative",
      "kind": "deliberate-pointer",
      "rationale": "a negative pair may legitimately share a lot of surface language (e.g. a pointer quoting its own antecedent) — the shingle property is positive-only",
      "chunk_a": {"text": "The canonical rule is stated once here in full, at considerable length, for the record."},
      "chunk_b": {"text": "See the canonical rule stated once here in full, at considerable length, for the record — nothing added."}
    }
  ]
}
EOF
out="$(REDUNDANCY_FIXTURES_JSON="$TMP/negative-shared-language.json" bash "$CHECKER" 2>&1)"; rc=$?
assert_rc "$rc" 0 "a negative pair sharing a long run of words still passes"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_check_redundancy_fixtures: FAIL"
  exit 1
fi
echo "test_check_redundancy_fixtures: OK"
