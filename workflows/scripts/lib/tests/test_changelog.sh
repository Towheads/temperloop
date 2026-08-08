#!/usr/bin/env bash
#
# test_changelog.sh — unit tests for workflows/scripts/lib/changelog.sh
# (temperloop#429, ADR 0002 follow-on "lift breaking_sections() out of
# scripts/update-kernel.sh into a shared lib"). Fast, no-network, no-git
# tests against a literal fixture CHANGELOG — the heavier end-to-end proof
# (real git tags, a real checkout) lives in
# workflows/scripts/tests/test_update_subcommand.sh and
# scripts/tests/test_update_kernel.sh; this suite is the lib's own
# self-contained coverage.
#
# Usage: bash workflows/scripts/lib/tests/test_changelog.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"
CHANGELOG_LIB="$REPO_ROOT/workflows/scripts/lib/changelog.sh"

# shellcheck source=../changelog.sh
source "$CHANGELOG_LIB"

fail_count=0
pass_count=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected: $expected, got: $actual)"
    fail_count=$((fail_count + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  # `-e` is required, not stylistic: a changelog needle routinely STARTS WITH
  # a dash (`- some entry`), which grep would otherwise read as a flag bundle
  # and fail on with a usage error rather than a verdict.
  if grep -qF -e "$needle" <<<"$haystack"; then
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected output to contain: $needle)"
    fail_count=$((fail_count + 1))
  fi
}

assert_empty() {
  local desc="$1" actual="$2"
  if [[ -z "$actual" ]]; then
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected empty, got: $actual)"
    fail_count=$((fail_count + 1))
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CHANGELOG="$TMP_ROOT/CHANGELOG.md"
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

## [0.3.0] - 2026-07-10 — BREAKING

### BREAKING — board adapter rename

- Renamed `board_foo` to `board_bar`. MIGRATION: update every overlay caller
  of `board_foo` before pulling this tag.

## [0.2.0] - 2026-07-05

### Added

- A new optional plan-schema field; nothing existing changes.

## [0.1.0] - 2026-07-01

### Added

- Initial release.
EOF

# ---------------------------------------------------------------------------
# T1 — changelog_semver_major
# ---------------------------------------------------------------------------
echo "T1: changelog_semver_major"
assert_eq "v2.3.4 -> 2" "2" "$(changelog_semver_major v2.3.4)"
assert_eq "0.1.0 -> 0" "0" "$(changelog_semver_major 0.1.0)"
assert_eq "malformed -> 0" "0" "$(changelog_semver_major garbage)"
assert_eq "empty -> 0" "0" "$(changelog_semver_major "")"

# ---------------------------------------------------------------------------
# T2 — changelog_breaking_sections: range containing a BREAKING section
# ---------------------------------------------------------------------------
echo "T2: changelog_breaking_sections — range with a BREAKING section"
out="$(changelog_breaking_sections v0.1.0 v0.3.0 "$CHANGELOG")"
assert_contains "includes the BREAKING heading" "## [0.3.0]" "$out"
assert_contains "includes the migration note" "update every overlay caller" "$out"
if grep -qF "## [0.2.0]" <<<"$out"; then
  echo "  NOT OK - T2 must not include the non-breaking 0.2.0 section"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T2 excludes the non-breaking 0.2.0 section"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T3 — changelog_breaking_sections: additive-only range -> empty
# ---------------------------------------------------------------------------
echo "T3: changelog_breaking_sections — additive-only range (0.1.0 -> 0.2.0)"
out="$(changelog_breaking_sections v0.1.0 v0.2.0 "$CHANGELOG")"
assert_empty "no BREAKING section in an additive-only range" "$out"

# ---------------------------------------------------------------------------
# T4 — changelog_sections_in_range: full delta, breaking or not
# ---------------------------------------------------------------------------
echo "T4: changelog_sections_in_range — full delta (0.1.0 -> 0.3.0)"
out="$(changelog_sections_in_range v0.1.0 v0.3.0 "$CHANGELOG")"
assert_contains "includes 0.2.0 (additive)" "## [0.2.0]" "$out"
assert_contains "includes 0.3.0 (breaking)" "## [0.3.0]" "$out"
if grep -qF "## [0.1.0]" <<<"$out"; then
  echo "  NOT OK - T4 must not include the CURRENT (0.1.0) section itself"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T4 excludes the current tag's own section (cur is exclusive)"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T5 — changelog_sections_in_range: empty cur ("") -> whole history up to target
# ---------------------------------------------------------------------------
echo "T5: changelog_sections_in_range — empty cur (untagged clone) -> whole history"
out="$(changelog_sections_in_range "" v0.2.0 "$CHANGELOG")"
assert_contains "includes 0.1.0" "## [0.1.0]" "$out"
assert_contains "includes 0.2.0" "## [0.2.0]" "$out"
if grep -qF "## [0.3.0]" <<<"$out"; then
  echo "  NOT OK - T5 must not include anything past the target"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T5 excludes sections past the target tag"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T6 — empty range (cur == target) -> empty output, both functions
# ---------------------------------------------------------------------------
echo "T6: empty range (cur == target) -> empty output"
assert_empty "changelog_sections_in_range, cur==target" "$(changelog_sections_in_range v0.2.0 v0.2.0 "$CHANGELOG")"
assert_empty "changelog_breaking_sections, cur==target" "$(changelog_breaking_sections v0.2.0 v0.2.0 "$CHANGELOG")"

# ---------------------------------------------------------------------------
# T7 — missing changelog file -> both functions return empty, rc 0
# ---------------------------------------------------------------------------
echo "T7: missing changelog file -> empty output, no error"
out="$(changelog_breaking_sections v0.1.0 v0.3.0 "$TMP_ROOT/does-not-exist.md")"; rc=$?
assert_empty "changelog_breaking_sections on a missing file" "$out"
assert_eq "changelog_breaking_sections rc 0 on a missing file" "0" "$rc"

# ---------------------------------------------------------------------------
# T8 — changelog_unreleased_body (temperloop#960, the CHANGELOG-entry gate)
# ---------------------------------------------------------------------------
echo "T8: changelog_unreleased_body"
assert_empty "an empty [Unreleased] section yields nothing" \
  "$(changelog_unreleased_body "$CHANGELOG" | grep -Ev '^[[:space:]]*$')"

POPULATED="$TMP_ROOT/populated.md"
cat > "$POPULATED" <<'EOF'
# Changelog

## [Unreleased] — BREAKING

### Changed — BREAKING

- Renamed a board helper. MIGRATION: update your overlay.

## [0.1.0] - 2026-07-01

### Added

- Initial release.
EOF
out="$(changelog_unreleased_body "$POPULATED")"
assert_contains "includes the section's own body" "Renamed a board helper" "$out"
if grep -qF "## [Unreleased]" <<<"$out"; then
  echo "  NOT OK - T8 must exclude the [Unreleased] heading itself (a BREAKING suffix is not an entry)"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T8 excludes the [Unreleased] heading line itself"
  pass_count=$((pass_count + 1))
fi
if grep -qF "Initial release" <<<"$out"; then
  echo "  NOT OK - T8 must stop at the next '## [' heading"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T8 stops at the next version heading"
  pass_count=$((pass_count + 1))
fi
assert_empty "missing file -> empty, no error" "$(changelog_unreleased_body "$TMP_ROOT/does-not-exist.md")"

# ---------------------------------------------------------------------------
# T9 — changelog_version_headings
# ---------------------------------------------------------------------------
echo "T9: changelog_version_headings"
out="$(changelog_version_headings "$CHANGELOG")"
assert_eq "lists every version heading in file order" "0.3.0
0.2.0
0.1.0" "$out"
if grep -qF "Unreleased" <<<"$out"; then
  echo "  NOT OK - T9 must not list the non-version [Unreleased] heading"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T9 omits [Unreleased] (not version-shaped)"
  pass_count=$((pass_count + 1))
fi
assert_empty "missing file -> empty, no error" "$(changelog_version_headings "$TMP_ROOT/does-not-exist.md")"

# ===========================================================================
# Fragment support (temperloop#1321, epic #1299) — `changelog.d/` per-entry
# fragment files and the release-time assembly of those fragments into
# `## [Unreleased]`. Same fast, no-network, no-git shape as the suites above:
# literal fixtures in a temp dir, no real repo touched.
# ===========================================================================

FRAG_DIR="$TMP_ROOT/changelog.d"
mkdir -p "$FRAG_DIR"

frag() {
  # frag <filename> <body...>  — write one fragment file
  local fname="$1"; shift
  printf '%s\n' "$@" > "$FRAG_DIR/$fname"
}

reset_fragments() {
  rm -rf "$FRAG_DIR"
  mkdir -p "$FRAG_DIR"
}

# ---------------------------------------------------------------------------
# T10 — changelog_fragment_category_order / _title
# ---------------------------------------------------------------------------
echo "T10: category vocabulary"
assert_eq "canonical order is Keep-a-Changelog's six" "added
changed
deprecated
removed
fixed
security" "$(changelog_fragment_category_order)"
assert_eq "title-cases a category" "Deprecated" "$(changelog_fragment_title deprecated)"
if changelog_fragment_title bogus >/dev/null 2>&1; then
  echo "  NOT OK - T10 an unknown category must not title-case"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T10 unknown category rejected (doubles as the validator)"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T11 — changelog_fragment_parse: the filename IS the index
# ---------------------------------------------------------------------------
echo "T11: changelog_fragment_parse"
assert_eq "plain fragment" "changed 0 1321-slug" "$(changelog_fragment_parse '1321-slug.changed.md')"
assert_eq "breaking marker" "fixed 1 42-x" "$(changelog_fragment_parse '42-x.fixed.breaking.md')"
assert_eq "a path is reduced to its basename" "added 0 7-y" "$(changelog_fragment_parse 'a/b/changelog.d/7-y.added.md')"

# Every rejection below is a filename that would otherwise be SILENTLY skipped
# and take somebody's changelog entry with it.
for bad in \
  'noextension.changed' \
  'no-category.md' \
  '1321-slug.bogus.md' \
  '1321-slug.changed.breaking.extra.md' \
  '.changed.md' \
  '-leading-dash.changed.md' \
  'has space.changed.md' \
  'README.md'
do
  if changelog_fragment_parse "$bad" >/dev/null 2>&1; then
    echo "  NOT OK - T11 must reject malformed name: $bad"
    fail_count=$((fail_count + 1))
  else
    echo "  ok - T11 rejects $bad"
    pass_count=$((pass_count + 1))
  fi
done

assert_eq "category accessor" "security" "$(changelog_fragment_category 'x.security.md')"
if changelog_fragment_is_breaking 'x.security.breaking.md'; then
  echo "  ok - T11 is_breaking true on the marker"
  pass_count=$((pass_count + 1))
else
  echo "  NOT OK - T11 is_breaking should be true"
  fail_count=$((fail_count + 1))
fi
if changelog_fragment_is_breaking 'x.security.md'; then
  echo "  NOT OK - T11 is_breaking should be false"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T11 is_breaking false without the marker"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T12 — assembly ORDER is total and derives from filenames alone (index-free)
# ---------------------------------------------------------------------------
echo "T12: changelog_fragment_names ordering"
reset_fragments
frag 'zz.fixed.md'      '- zz fixed'
frag 'bb.added.md'      '- bb added'
frag 'aa.fixed.md'      '- aa fixed'
frag 'cc.security.md'   '- cc security'
frag 'dd.changed.md'    '- dd changed'
assert_eq "category order first, then LC_ALL=C by filename" "bb.added.md
dd.changed.md
aa.fixed.md
zz.fixed.md
cc.security.md" "$(changelog_fragment_names "$FRAG_DIR")"
assert_empty "absent directory -> empty, no error" "$(changelog_fragment_names "$TMP_ROOT/no-such-dir")"

# The ratified constraint: NO index file is consulted. Dropping a file in is
# the whole registration step, which is what lets two concurrent PRs write
# disjoint files and share no line.
if [[ -e "$FRAG_DIR/index" || -e "$FRAG_DIR/order.txt" ]]; then
  echo "  NOT OK - T12 fragment dir must stay index-free"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T12 ordering needed no index file"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T13 — placeholders vs. malformed files
# ---------------------------------------------------------------------------
echo "T13: changelog_fragment_invalid"
reset_fragments
frag 'ok.changed.md' '- fine'
: > "$FRAG_DIR/.gitkeep"
printf '# docs\n' > "$FRAG_DIR/README.md"
printf 'stray\n'   > "$FRAG_DIR/notes.txt"
printf 'stray\n'   > "$FRAG_DIR/typo.chnaged.md"
assert_eq "README.md and dotfiles are placeholders; the rest is reported" "notes.txt
typo.chnaged.md" "$(changelog_fragment_invalid "$FRAG_DIR")"
assert_eq "placeholders are not fragments either" "ok.changed.md" "$(changelog_fragment_names "$FRAG_DIR")"

# ---------------------------------------------------------------------------
# T14 — body handling: trim the edges, keep the middle
# ---------------------------------------------------------------------------
echo "T14: changelog_fragment_body"
reset_fragments
printf '\n\n- first para\n\n  second para\n\n\n' > "$FRAG_DIR/a.changed.md"
assert_eq "leading/trailing blanks trimmed, interior kept" "- first para

  second para" "$(changelog_fragment_body "$FRAG_DIR/a.changed.md")"
: > "$FRAG_DIR/b.fixed.md"
assert_eq "an empty fragment is reported, not silently dropped" "b.fixed.md" "$(changelog_fragment_empty "$FRAG_DIR")"

printf -- '- entry\n### Sneaky — BREAKING\n#### fine\n' > "$FRAG_DIR/c.added.md"
assert_contains "an h3 in a body is an offender (it could forge a BREAKING signal)" \
  "c.added.md:2:" "$(changelog_fragment_body_offenders "$FRAG_DIR")"
if changelog_fragment_body_offenders "$FRAG_DIR" | grep -F 'c.added.md:3:' >/dev/null; then
  echo "  NOT OK - T14 h4 inside an entry is legal and must not be flagged"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T14 h4 inside an entry is not flagged"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T15 — changelog_fragment_has_breaking
# ---------------------------------------------------------------------------
echo "T15: changelog_fragment_has_breaking"
reset_fragments
frag 'a.changed.md' '- plain'
if changelog_fragment_has_breaking "$FRAG_DIR"; then
  echo "  NOT OK - T15 no breaking fragment present"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T15 false with no breaking fragment"
  pass_count=$((pass_count + 1))
fi
frag 'b.removed.breaking.md' '- gone'
if changelog_fragment_has_breaking "$FRAG_DIR"; then
  echo "  ok - T15 true once one fragment is breaking"
  pass_count=$((pass_count + 1))
else
  echo "  NOT OK - T15 should be true"
  fail_count=$((fail_count + 1))
fi

# ---------------------------------------------------------------------------
# T16 — changelog_assemble_unreleased_body over a NON-EMPTY Unreleased body.
#
# This is the highest-risk path and the reason the assembler is additive: the
# real `## [Unreleased]` is routinely substantial, so an assembler that
# assumed it was empty would REPLACE rather than merge and silently drop
# everything accumulated since the last tag.
# ---------------------------------------------------------------------------
echo "T16: assembly over a non-empty [Unreleased]"
NONEMPTY="$TMP_ROOT/nonempty.md"
cat > "$NONEMPTY" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- **existing changed entry** (#1).

### Fixed

- **existing fixed entry** (#2).

## [0.2.0] - 2026-01-01

### Added

- shipped already.
EOF

reset_fragments
frag '10-a.changed.md'         '- **new changed** (#10).'
frag '11-b.added.md'           '- **new added** (#11).'
frag '12-c.fixed.breaking.md'  '- **breaking fix** (#12).'
out="$(changelog_assemble_unreleased_body "$FRAG_DIR" "$NONEMPTY")"

assert_contains "existing Changed entry SURVIVES" "**existing changed entry** (#1)." "$out"
assert_contains "existing Fixed entry SURVIVES"   "**existing fixed entry** (#2)."   "$out"
assert_contains "fragment merged into existing Changed" "**new changed** (#10)." "$out"
assert_contains "fragment merged into existing Fixed"   "**breaking fix** (#12)." "$out"
assert_contains "new category gets its own sub-heading" "### Added" "$out"
assert_contains "breaking fragment suffixes ITS sub-heading" "### Fixed — BREAKING" "$out"
assert_eq "non-breaking category keeps a bare heading" "### Changed" \
  "$(printf '%s\n' "$out" | grep '^### Changed')"

# Ordering: a brand-new category is INSERTED at its canonical position, and no
# existing sub-section is reordered.
assert_eq "sub-headings in canonical order, existing ones not moved" "### Added
### Changed
### Fixed — BREAKING" "$(printf '%s\n' "$out" | grep '^### ')"

# Shape parity with what changelog_unreleased_body() reads today.
assert_eq "body opens with a blank line, as today" "" "$(printf '%s\n' "$out" | sed -n '1p')"

# The assembled body must never leak a `## [` heading — that would truncate
# the Unreleased section for every downstream reader.
if printf '%s\n' "$out" | grep '^## \[' >/dev/null; then
  echo "  NOT OK - T16 assembled body must not contain a '## [' heading"
  fail_count=$((fail_count + 1))
else
  echo "  ok - T16 assembled body contains no version heading"
  pass_count=$((pass_count + 1))
fi

# ---------------------------------------------------------------------------
# T17 — assembly over an EMPTY [Unreleased] body (the post-cut state)
# ---------------------------------------------------------------------------
echo "T17: assembly over an empty [Unreleased]"
EMPTYUNREL="$TMP_ROOT/empty-unreleased.md"
cat > "$EMPTYUNREL" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-01-01

### Added

- shipped already.
EOF
reset_fragments
frag '1-a.security.md' '- **sec entry** (#1).'
frag '2-b.added.md'    '- **add entry** (#2).'
out="$(changelog_assemble_unreleased_body "$FRAG_DIR" "$EMPTYUNREL")"
assert_eq "creates both sections in canonical order" "### Added
### Security" "$(printf '%s\n' "$out" | grep '^### ')"
assert_contains "carries the entries" "**sec entry** (#1)." "$out"

# ---------------------------------------------------------------------------
# T18 — no fragments: the assembled body equals the current body
# ---------------------------------------------------------------------------
echo "T18: no fragments is a no-op on the body"
reset_fragments
assert_eq "empty fragment dir -> body unchanged" \
  "$(changelog_unreleased_body "$NONEMPTY")" \
  "$(changelog_assemble_unreleased_body "$FRAG_DIR" "$NONEMPTY")"

# ---------------------------------------------------------------------------
# T19 — a category that appears TWICE in the body is merged once, not twice
# ---------------------------------------------------------------------------
echo "T19: duplicate sub-heading is merged exactly once"
DUP="$TMP_ROOT/dup.md"
cat > "$DUP" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- first changed block.

### Changed

- second changed block.

## [0.1.0] - 2026-01-01

### Added

- old.
EOF
reset_fragments
frag '9-z.changed.md' '- **once only** (#9).'
out="$(changelog_assemble_unreleased_body "$FRAG_DIR" "$DUP")"
assert_eq "the fragment appears exactly once" "1" \
  "$(printf '%s\n' "$out" | grep -c 'once only')"
assert_eq "both existing blocks survive" "2" \
  "$(printf '%s\n' "$out" | grep -c 'changed block')"

# ---------------------------------------------------------------------------
# T20 — a non-regular entry is REPORTED, never silently filtered
#
# The listing keeps only regular files, because only a regular file can be
# read as a fragment body. Without a matching report, a fragment placed one
# level down (`changelog.d/subdir/1-nested.added.md`) is invisible end to end:
# validation calls the directory well-formed, the fragment never assembles,
# and it survives the post-cut deletion loop — on disk looking pending while
# the release ships without it. A DANGLING SYMLINK is the nastier half: its
# name parses fine, so nothing about the filename gives it away.
# ---------------------------------------------------------------------------
echo "T20: non-regular entries are reported as invalid"
reset_fragments
frag 'ok.changed.md' '- fine'
mkdir -p "$FRAG_DIR/subdir"
printf -- '- nested\n' > "$FRAG_DIR/subdir/1-nested.added.md"
ln -s "$TMP_ROOT/does-not-exist.md" "$FRAG_DIR/1-dangling.added.md"
assert_eq "both non-regular entries are listed" "1-dangling.added.md
subdir" "$(changelog_fragment_nonregular "$FRAG_DIR")"
assert_eq "a dangling symlink with a CONFORMING name is still invalid" "1-dangling.added.md
subdir" "$(changelog_fragment_invalid "$FRAG_DIR")"
assert_eq "only the real file is treated as a fragment" "ok.changed.md" \
  "$(changelog_fragment_names "$FRAG_DIR")"
rm -f "$FRAG_DIR/1-dangling.added.md"
rm -rf "$FRAG_DIR/subdir"

# ---------------------------------------------------------------------------
# T21 — a body cannot forge assembler control data
#
# The assembler's metadata travels OUT OF BAND (a control-only manifest plus
# one body file per category), so fragment text is never parsed as control.
# Before that, both were multiplexed onto one stream with in-band
# `##CATEGORY## <cat> <brk>` / `##BEGIN##` sentinels and a body line was
# indistinguishable from a control line — `##CATEGORY## security 1` in a body
# assembled to `### Security — BREAKING`, forging the heading
# changelog_breaking_sections() keys on (the downstream acknowledgment gate
# for every vendoring overlay), and `##BEGIN##` was silently deleted.
#
# Two properties, and BOTH matter: the tokens are rejected loudly by the
# offender check, AND — with that check bypassed — they are inert text.
# ---------------------------------------------------------------------------
echo "T21: fragment bodies cannot forge assembler control data"
reset_fragments
frag 'forge.added.md' '- looks innocuous' '##CATEGORY## security 1' '- more'
frag 'begin.added.md' '- second' '##BEGIN##'
offenders="$(changelog_fragment_body_offenders "$FRAG_DIR")"
assert_contains "the ##CATEGORY## line is an offender" "forge.added.md:2" "$offenders"
assert_contains "the ##BEGIN## line is an offender" "begin.added.md:2" "$offenders"

out="$(changelog_assemble_unreleased_body "$FRAG_DIR" "$CHANGELOG")"
assert_eq "no category is set by a body line" "0" \
  "$(printf '%s\n' "$out" | grep -c '^### Security')"
assert_eq "no BREAKING marker is forged by a body line" "0" \
  "$(printf '%s\n' "$out" | grep -c 'BREAKING')"
assert_eq "##BEGIN## is preserved as literal text, not swallowed" "1" \
  "$(printf '%s\n' "$out" | grep -c '^##BEGIN##$')"
assert_contains "the surrounding entry text survives intact" "- more" "$out"

# ---------------------------------------------------------------------------
# T22 — the heading scan is fence-aware
#
# An UNINDENTED ``` fence in the Unreleased body may legitimately contain a
# line like `### Added` as sample text. Treating it as a real sub-heading
# split the section at it, injected a blank line INSIDE the fence (mutating
# existing content), and appended fragments into the resulting pseudo-section.
# ---------------------------------------------------------------------------
echo "T22: an unindented code fence is not a sub-heading"
FENCED="$TMP_ROOT/fenced.md"
cat > "$FENCED" <<'EOF'
# Changelog

## [Unreleased]

### Added

- documents the format:

```
### Added

- sample inside a fence
```

- a real trailing entry

## [0.1.0] - 2026-01-01

- old.
EOF
reset_fragments
frag '9-z.added.md' '- **below the fence** (#9).'
out="$(changelog_assemble_unreleased_body "$FRAG_DIR" "$FENCED")"
assert_eq "the fenced block comes through unchanged" \
  "$(awk '/^```$/ { n++; next } n == 1 { print }' "$FENCED")" \
  "$(printf '%s\n' "$out" | awk '/^```$/ { n++; next } n == 1 { print }')"
assert_eq "the fragment is merged exactly once" "1" \
  "$(printf '%s\n' "$out" | grep -c 'below the fence')"
# The entry must sit AFTER the closing fence — inside it is the defect.
entry_at="$(printf '%s\n' "$out" | grep -n 'below the fence' | cut -d: -f1)"
close_at="$(printf '%s\n' "$out" | grep -n '^```$' | sed -n '2p' | cut -d: -f1)"
if [[ -n "$entry_at" && -n "$close_at" && "$entry_at" -gt "$close_at" ]]; then
  echo "  ok - the entry landed after the closing fence"
  pass_count=$((pass_count + 1))
else
  echo "  NOT OK - the entry landed inside the fence (entry $entry_at, fence close $close_at)"
  fail_count=$((fail_count + 1))
fi

echo
echo "test_changelog.sh: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
