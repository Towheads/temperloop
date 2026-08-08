#!/usr/bin/env bash
#
# test_assemble_changelog.sh — end-to-end tests for scripts/assemble-changelog.sh
# (temperloop#1321, epic #1299 "changelog merge-conflict hotspot").
#
# The lib's own parsing/assembly unit tests live in
# workflows/scripts/lib/tests/test_changelog.sh (T10-T19). THIS suite covers
# the executable: flag handling, the in-place rewrite, fragment deletion, the
# refuse-to-write arms, and the two properties that make the change safe to
# ship additively —
#
#   1. NO FRAGMENTS => CHANGELOG.md is left BYTE-IDENTICAL. The existing
#      `## [Unreleased]` flow keeps working untouched.
#   2. ADDITIVE OVER A NON-EMPTY [Unreleased], proven against the REPO'S OWN
#      REAL CHANGELOG.md, not just a toy fixture. `main`'s Unreleased section
#      is substantial; an assembler that assumed it was empty would silently
#      drop everything accumulated since the last tag. The real-file leg also
#      asserts that changelog_breaking_sections() /
#      changelog_sections_in_range() / changelog_version_headings() return
#      byte-identical results before and after — the downstream BREAKING
#      acknowledgment contract that scripts/update-kernel.sh and
#      bin/subcommands/update.sh read.
#
# Fast, no network, no git operations: every write lands in a mktemp dir and
# the repo's own CHANGELOG.md is only ever COPIED, never modified.
#
# Usage: bash scripts/tests/test_assemble_changelog.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ASSEMBLER="$REPO_ROOT/scripts/assemble-changelog.sh"

# shellcheck source=../../workflows/scripts/lib/changelog.sh
source "$REPO_ROOT/workflows/scripts/lib/changelog.sh"

fail_count=0
pass_count=0

pass() { echo "  ok - $1"; pass_count=$((pass_count + 1)); }
fail() { echo "  NOT OK - $1"; fail_count=$((fail_count + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected: [$expected], got: [$actual])"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -F "$needle" <<<"$haystack" >/dev/null; then
    pass "$desc"
  else
    fail "$desc (expected output to contain: $needle)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -F "$needle" <<<"$haystack" >/dev/null; then
    fail "$desc (output should NOT contain: $needle)"
  else
    pass "$desc"
  fi
}

assert_files_equal() {
  local desc="$1" a="$2" b="$3"
  if cmp -s "$a" "$b"; then
    pass "$desc"
  else
    fail "$desc (files differ: $a vs $b)"
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Fixture helpers — each case gets its own isolated tree.
# ---------------------------------------------------------------------------
CASE_N=0
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  mkdir -p "$CASE_DIR/changelog.d"
  CHANGELOG="$CASE_DIR/CHANGELOG.md"
  FRAGS="$CASE_DIR/changelog.d"
}

write_nonempty_changelog() {
  cat > "$CHANGELOG" <<'EOF'
# Changelog

Preamble prose that must survive.

## [Unreleased]

### Changed

- **existing changed entry** (#1).

### Fixed

- **existing fixed entry** (#2).

## [0.2.0] - 2026-02-01

### Changed — BREAKING

- shipped breaking change.

## [0.1.0] - 2026-01-01

### Added

- the beginning.
EOF
}

frag() {
  local fname="$1"; shift
  printf '%s\n' "$@" > "$FRAGS/$fname"
}

run_assembler() {
  bash "$ASSEMBLER" --changelog "$CHANGELOG" --fragment-dir "$FRAGS" "$@" 2>&1
}

# ===========================================================================
# T1 — no fragments: CHANGELOG.md is left BYTE-IDENTICAL
#
# This is the "additive and non-breaking on its own" guarantee. Nothing yet
# REQUIRES a fragment, so a tree with an empty changelog.d/ must come out the
# far side untouched — not merely structurally equivalent.
# ===========================================================================
echo "T1: no fragments -> byte-identical changelog"
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
out="$(run_assembler)"
rc=$?
assert_eq "exits 0" "0" "$rc"
assert_contains "says it left the file alone" "left untouched" "$out"
assert_files_equal "CHANGELOG.md is byte-identical" "$CASE_DIR/before.md" "$CHANGELOG"

# ===========================================================================
# T2 — the additive merge over a non-empty [Unreleased]
# ===========================================================================
echo "T2: additive merge over a non-empty [Unreleased]"
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '10-a.changed.md'        '- **new changed** (#10).'
frag '11-b.added.md'          '- **new added** (#11).'
frag '12-c.fixed.breaking.md' '- **breaking fix** (#12).'
out="$(run_assembler)"
assert_contains "reports the fragment count" "assembled 3 fragment(s)" "$out"
assert_contains "flags the breaking marker" "BREAKING" "$out"

body="$(cat "$CHANGELOG")"
assert_contains "preamble prose survives"        "Preamble prose that must survive." "$body"
assert_contains "existing Changed entry survives" "**existing changed entry** (#1)." "$body"
assert_contains "existing Fixed entry survives"   "**existing fixed entry** (#2)."   "$body"
assert_contains "new Changed fragment merged"     "**new changed** (#10)."           "$body"
assert_contains "new Fixed fragment merged"       "**breaking fix** (#12)."          "$body"
assert_contains "brand-new Added section created" "**new added** (#11)."             "$body"

# Released history is never touched.
assert_contains "released 0.2.0 heading intact" "## [0.2.0] - 2026-02-01" "$body"
assert_contains "released 0.1.0 heading intact" "## [0.1.0] - 2026-01-01" "$body"
assert_eq "released 0.2.0 body untouched" "$(changelog_sections_in_range v0.1.0 v0.2.0 "$CASE_DIR/before.md")" \
  "$(changelog_sections_in_range v0.1.0 v0.2.0 "$CHANGELOG")"

# The BREAKING signal lands on HEADINGS, which is the only place
# changelog_breaking_sections() reads it from.
assert_contains "Unreleased heading carries BREAKING" "## [Unreleased] — BREAKING" "$body"
assert_contains "the breaking category's sub-heading carries it too" "### Fixed — BREAKING" "$body"
assert_eq "a non-breaking category keeps a BARE sub-heading" "### Changed" \
  "$(changelog_unreleased_body "$CHANGELOG" | grep '^### Changed')"

# Consumed fragments are gone; the placeholder-free dir is empty.
assert_eq "fragments deleted after assembly" "" "$(changelog_fragment_names "$FRAGS")"

# ===========================================================================
# T3 — --keep-fragments leaves the fragment files on disk
# ===========================================================================
echo "T3: --keep-fragments"
new_case
write_nonempty_changelog
frag '20-a.changed.md' '- **kept** (#20).'
out="$(run_assembler --keep-fragments)"
assert_contains "says it kept them" "left as-is" "$out"
assert_eq "fragment still present" "20-a.changed.md" "$(changelog_fragment_names "$FRAGS")"
assert_contains "but the changelog was still rewritten" "**kept** (#20)." "$(cat "$CHANGELOG")"

# ===========================================================================
# T4 — --dry-run writes nothing and deletes nothing
# ===========================================================================
echo "T4: --dry-run"
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '30-a.changed.md' '- **dry** (#30).'
out="$(run_assembler --dry-run)"
assert_contains "prints the assembled changelog to stdout" "**dry** (#30)." "$out"
assert_files_equal "CHANGELOG.md untouched" "$CASE_DIR/before.md" "$CHANGELOG"
assert_eq "fragment untouched" "30-a.changed.md" "$(changelog_fragment_names "$FRAGS")"

# ===========================================================================
# T5 — --list and --check
# ===========================================================================
echo "T5: --list / --check"
new_case
write_nonempty_changelog
frag 'zz.fixed.md'   '- zz'
frag 'aa.added.md'   '- aa'
assert_eq "--list prints assembly order" "aa.added.md
zz.fixed.md" "$(run_assembler --list)"
out="$(run_assembler --check)"
rc=$?
assert_eq "--check exits 0 on a clean dir" "0" "$rc"
assert_contains "--check reports the count" "2 fragment(s)" "$out"
assert_eq "--check wrote nothing" "aa.added.md
zz.fixed.md" "$(changelog_fragment_names "$FRAGS")"

# ===========================================================================
# T6 — the refuse-to-write arms. Every one of these would otherwise SILENTLY
# drop somebody's changelog entry, which is the failure fragments exist to
# prevent, not to introduce.
# ===========================================================================
echo "T6: malformed input fails loudly and writes nothing"

# 6a — unrecognised filename
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag 'good.changed.md' '- fine'
printf -- '- orphaned entry\n' > "$FRAGS/typo.chnaged.md"
out="$(run_assembler)"
rc=$?
assert_eq "unrecognised filename exits 1" "1" "$rc"
assert_contains "names the offending file" "typo.chnaged.md" "$out"
assert_contains "names the expected format" "<slug>.<category>" "$out"
assert_files_equal "nothing was written" "$CASE_DIR/before.md" "$CHANGELOG"
assert_eq "the good fragment was not consumed either" "good.changed.md" "$(changelog_fragment_names "$FRAGS")"

# 6b — empty fragment
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
: > "$FRAGS/blank.changed.md"
out="$(run_assembler)"
rc=$?
assert_eq "empty fragment exits 1" "1" "$rc"
assert_contains "explains why an empty fragment is fatal" "lost entry" "$out"
assert_files_equal "nothing was written" "$CASE_DIR/before.md" "$CHANGELOG"

# 6c — a body carrying its own heading (could forge a BREAKING signal)
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
printf -- '- entry\n### Forged — BREAKING\n' > "$FRAGS/sneaky.changed.md"
out="$(run_assembler)"
rc=$?
assert_eq "body heading exits 1" "1" "$rc"
assert_contains "points at the offending line" "sneaky.changed.md:2" "$out"
assert_files_equal "nothing was written" "$CASE_DIR/before.md" "$CHANGELOG"

# 6d — no [Unreleased] section to merge into
new_case
mkdir -p "$FRAGS"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [0.1.0] - 2026-01-01

### Added

- the beginning.
EOF
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '40-a.changed.md' '- **orphan** (#40).'
out="$(run_assembler)"
rc=$?
assert_eq "missing [Unreleased] exits 1" "1" "$rc"
assert_contains "says what to do" "add one before assembling" "$out"
assert_files_equal "nothing was written" "$CASE_DIR/before.md" "$CHANGELOG"

# 6e — unknown flag is a usage error, distinct from a content error
new_case
write_nonempty_changelog
out="$(run_assembler --nope)"
rc=$?
assert_eq "unknown flag exits 2" "2" "$rc"
assert_contains "names the bad argument" "unknown argument: --nope" "$out"

# ===========================================================================
# T7 — only the FIRST `## [Unreleased]` heading is rewritten.
#
# `## [Unreleased] — BREAKING` also occurs inside historical release prose
# further down a real CHANGELOG (VERSIONING.md § Cutting a release warns about
# exactly this: a replace_all edit rewrites shipped history).
# ===========================================================================
echo "T7: historical prose quoting the Unreleased heading is untouched"
new_case
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- current work.

## [0.2.0] - 2026-02-01

### Changed

- a release note that quotes the heading verbatim:

## [Unreleased] — BREAKING

  ...as prose, in shipped history.
EOF
frag '50-a.changed.breaking.md' '- **breaks** (#50).'
run_assembler >/dev/null
assert_eq "exactly two Unreleased-ish headings remain (ours + the historical one)" "2" \
  "$(grep -c '^## \[Unreleased\]' "$CHANGELOG")"
assert_contains "the historical quote is intact" "  ...as prose, in shipped history." "$(cat "$CHANGELOG")"
assert_eq "the fragment landed in the live section only" "1" \
  "$(changelog_unreleased_body "$CHANGELOG" | grep -c 'breaks')"

# ===========================================================================
# T8 — against the REPO'S OWN REAL CHANGELOG.md.
#
# The highest-risk path: a substantial, multi-paragraph `## [Unreleased]`
# body. Asserts the merge is purely additive (the diff is EXACTLY the added
# fragment lines) and that the three downstream range helpers are byte-stable.
# ===========================================================================
echo "T8: real CHANGELOG.md — additive, and range helpers byte-stable"
new_case
cp "$REPO_ROOT/CHANGELOG.md" "$CHANGELOG"
cp "$REPO_ROOT/CHANGELOG.md" "$CASE_DIR/before.md"

before_breaking="$(changelog_breaking_sections "" v99.99.99 "$CASE_DIR/before.md")"
before_range="$(changelog_sections_in_range "" v99.99.99 "$CASE_DIR/before.md")"
before_headings="$(changelog_version_headings "$CASE_DIR/before.md")"
before_unreleased="$(changelog_unreleased_body "$CASE_DIR/before.md")"

frag '1321-fragment-demo.changed.md' '- **assembler smoke entry** (#1321).'
run_assembler >/dev/null

assert_eq "changelog_breaking_sections unchanged" "$before_breaking" \
  "$(changelog_breaking_sections "" v99.99.99 "$CHANGELOG")"
assert_eq "changelog_sections_in_range unchanged" "$before_range" \
  "$(changelog_sections_in_range "" v99.99.99 "$CHANGELOG")"
assert_eq "changelog_version_headings unchanged" "$before_headings" \
  "$(changelog_version_headings "$CHANGELOG")"

# The whole-file diff is exactly the added lines — nothing dropped, nothing
# reordered, no whitespace churn across thousands of lines of history.
removed="$(diff "$CASE_DIR/before.md" "$CHANGELOG" | grep -c '^<')"
assert_eq "not one line removed from the real changelog" "0" "$removed"
assert_contains "the new entry is present" "**assembler smoke entry** (#1321)." "$(cat "$CHANGELOG")"

# Every line the real Unreleased body already had is still there.
missing=0
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    if ! grep -F -- "$line" "$CHANGELOG" >/dev/null; then
      missing=$((missing + 1))
    fi
  fi
done <<<"$before_unreleased"
assert_eq "every pre-existing [Unreleased] line survived" "0" "$missing"

echo
echo "test_assemble_changelog.sh: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
