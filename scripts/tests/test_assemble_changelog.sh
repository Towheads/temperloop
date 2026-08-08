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
# T15 additionally covers `--assert-empty <rev>`, the CUT-TIME assertion added
# by temperloop#1322 that closes the cut-vs-sibling OMISSION race.
#
# Fast and no network. Every write lands in a mktemp dir and the repo's own
# CHANGELOG.md is only ever COPIED, never modified; the only git operations are
# T15's throwaway `git init` fixtures, which never touch this repo.
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
  # `-e` is required, not stylistic: a changelog needle routinely STARTS WITH
  # a dash (`- some entry`), which grep would otherwise read as a flag bundle
  # and fail on with a usage error rather than a verdict.
  if grep -F -e "$needle" <<<"$haystack" >/dev/null; then
    pass "$desc"
  else
    fail "$desc (expected output to contain: $needle)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -F -e "$needle" <<<"$haystack" >/dev/null; then
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

# ---------------------------------------------------------------------------
# T8b — the SAME real changelog, with stray whitespace INJECTED.
#
# T8 above is content-dependent by construction: it can only catch a
# whitespace-normalising rewrite when the repo's own `[Unreleased]` happens to
# contain the stray whitespace at the moment the suite runs. It did not — and
# a `main` that HAD picked up a double blank line ejected an already-green PR
# from the merge queue, because the merge_group trial branch assembled that
# `main` and lost the line (temperloop#1321).
#
# So: inject the whitespace rather than wait for it. This leg asserts the
# additive property against a deliberately-imperfect copy of the real file, so
# the guarantee holds for ANY `main`, not just a tidy one.
# ---------------------------------------------------------------------------
new_case
awk '
  /^## \[Unreleased\]/ { unrel = 1; print; next }
  # An extra blank immediately before the next version heading — a doubled
  # TRAILING run at the end of the Unreleased body.
  unrel && /^## \[/ { print ""; unrel = 0; print; next }
  # An extra blank before the first sub-heading — a doubled run mid-section.
  unrel && /^### / && !injected { injected = 1; print "" }
  { print }
' "$REPO_ROOT/CHANGELOG.md" > "$CHANGELOG"
cp "$CHANGELOG" "$CASE_DIR/before.md"

# The injection must actually have produced a double blank, or this leg is
# silently vacuous — the exact failure mode that let the original defect reach
# the merge queue.
assert_eq "T8b the fixture really does carry a double blank line" "1" \
  "$(awk 'prev == "" && $0 == "" && !seen { seen = 1; print 1 } { prev = $0 }' "$CHANGELOG")"

frag '1321-injected-demo.changed.md' '- **injected-whitespace smoke entry** (#1321).'
run_assembler >/dev/null

removed="$(diff "$CASE_DIR/before.md" "$CHANGELOG" | grep -c '^<')"
assert_eq "T8b not one line removed from the whitespace-injected changelog" "0" "$removed"
assert_contains "T8b the new entry is present" \
  "**injected-whitespace smoke entry** (#1321)." "$(cat "$CHANGELOG")"
assert_eq "T8b changelog_version_headings unchanged" "$before_headings" \
  "$(changelog_version_headings "$CHANGELOG")"

# ===========================================================================
# T9 — a FAILING assembly must refuse to write (the destroy-everything bug)
#
# THE DEFECT. The script ran `changelog_assemble_unreleased_body ... >"$body"`
# under `set -uo pipefail` — no `-e`, and the status discarded. On any failure
# (the lib's own `mktemp` returning non-zero, a crashed awk) `$body` came back
# EMPTY, the rewrite printed the `## [Unreleased]` heading with nothing under
# it and swallowed the entire pre-existing section, and the old guard — which
# checked the REWRITTEN CHANGELOG, still non-empty because the rest of the
# file was intact — passed. Exit 0, "assembled N fragment(s)", every
# accumulated entry gone, and the fragments deleted immediately after.
#
# Both failure shapes are forced here via a SHIM TREE rather than asserted on
# the happy path: the assembler resolves its lib relative to its own path, so
# a copy of the lib with `changelog_assemble_unreleased_body` overridden
# reproduces the exact conditions without touching the real one.
# ===========================================================================
echo "T9: a failing assembly refuses to write and keeps the fragments"

make_shim() {
  # make_shim <dir> <override-body> — a REPO_ROOT-shaped tree whose lib has
  # changelog_assemble_unreleased_body replaced.
  local shim="$1" override="$2"
  mkdir -p "$shim/scripts" "$shim/workflows/scripts/lib"
  ln -sf "$ASSEMBLER" "$shim/scripts/assemble-changelog.sh"
  cp "$REPO_ROOT/workflows/scripts/lib/changelog.sh" "$shim/workflows/scripts/lib/changelog.sh"
  printf 'changelog_assemble_unreleased_body() { %s }\n' "$override" \
    >> "$shim/workflows/scripts/lib/changelog.sh"
}

# T9a — the assembly returns NON-ZERO.
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '30-a.added.md' '- **entry that must not vanish** (#30).'
make_shim "$CASE_DIR/shim" 'return 1;'
out="$(bash "$CASE_DIR/shim/scripts/assemble-changelog.sh" \
  --changelog "$CHANGELOG" --fragment-dir "$FRAGS" 2>&1)"
rc=$?
assert_eq "T9a exits non-zero" "1" "$rc"
assert_contains "T9a names the cause" "assembly failed" "$out"
assert_not_contains "T9a never claims success" "assembled 1 fragment(s)" "$out"
assert_files_equal "T9a CHANGELOG.md byte-identical" "$CASE_DIR/before.md" "$CHANGELOG"
assert_eq "T9a fragment kept" "30-a.added.md" "$(changelog_fragment_names "$FRAGS")"

# T9b — the assembly exits 0 but emits an EMPTY body. This is the silent arm
# `|| die` alone cannot catch, and the one the old out_tmp guard passed.
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '31-a.added.md' '- **entry that must not vanish** (#31).'
make_shim "$CASE_DIR/shim" 'return 0;'
out="$(bash "$CASE_DIR/shim/scripts/assemble-changelog.sh" \
  --changelog "$CHANGELOG" --fragment-dir "$FRAGS" 2>&1)"
rc=$?
assert_eq "T9b exits non-zero" "1" "$rc"
assert_contains "T9b names the shrunken body" "refusing to write" "$out"
assert_not_contains "T9b never claims success" "assembled 1 fragment(s)" "$out"
assert_files_equal "T9b CHANGELOG.md byte-identical" "$CASE_DIR/before.md" "$CHANGELOG"
assert_eq "T9b fragment kept" "31-a.added.md" "$(changelog_fragment_names "$FRAGS")"
assert_contains "T9b [Unreleased] body still intact" "**existing changed entry** (#1)." "$(cat "$CHANGELOG")"

# ===========================================================================
# T10 — a fragment body cannot forge the BREAKING marker
#
# THE DEFECT. The assembler multiplexed metadata and bodies onto ONE stream
# with in-band `##CATEGORY## <cat> <brk>` / `##BEGIN##` sentinels, so a body
# line was indistinguishable from a control line — and the body-heading check
# missed them, because `/^## /` requires a SPACE after the hashes that
# `##CATEGORY##` does not have. A fragment whose body said
# `##CATEGORY## security 1` passed `--check` as "all well-formed" and
# assembled to `### Security — BREAKING`: a forgery of the exact heading
# changelog_breaking_sections() keys on, which gates the downstream pull for
# every vendoring overlay. A `##BEGIN##` body line was silently DELETED.
#
# Metadata now travels out of band (one body file per category), so this is
# structurally impossible; the loud rejection below is the second line.
# ===========================================================================
echo "T10: a fragment body cannot forge the BREAKING marker"
new_case
write_nonempty_changelog
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '40-forge.added.md' '- looks innocuous' '##CATEGORY## security 1' '- more text'
frag '41-begin.added.md' '- second entry' '##BEGIN##' '- after the sentinel'
out="$(run_assembler --check)"
rc=$?
assert_eq "T10 --check exits non-zero" "1" "$rc"
assert_not_contains "T10 --check never says all well-formed" "all well-formed" "$out"
assert_contains "T10 names the ##CATEGORY## line" "40-forge.added.md:2" "$out"
assert_contains "T10 names the ##BEGIN## line" "41-begin.added.md:2" "$out"

out="$(run_assembler)"
rc=$?
assert_eq "T10 apply exits non-zero" "1" "$rc"
assert_files_equal "T10 CHANGELOG.md untouched" "$CASE_DIR/before.md" "$CHANGELOG"
assert_not_contains "T10 no forged Security section" "### Security" "$(cat "$CHANGELOG")"
assert_not_contains "T10 no forged BREAKING heading" "BREAKING" \
  "$(changelog_unreleased_body "$CHANGELOG")"

# The STRUCTURAL half: even with the validation arm bypassed, sentinel text in
# a body is inert literal content — it cannot set a category or a flag, and it
# is no longer silently deleted.
new_case
write_nonempty_changelog
frag '42-forge.added.md' '- entry one' '##CATEGORY## security 1' '##BEGIN##'
assembled="$(changelog_assemble_unreleased_body "$FRAGS" "$CHANGELOG")"
assert_not_contains "T10 out-of-band: no Security section from a body line" "### Security" "$assembled"
assert_not_contains "T10 out-of-band: no BREAKING heading from a body line" "BREAKING" "$assembled"
assert_contains "T10 out-of-band: ##BEGIN## survives as literal text" "##BEGIN##" "$assembled"

# ===========================================================================
# T11 — a failed WRITE leaves the fragments undeleted
#
# THE DEFECT. `cat "$out_tmp" >"$CHANGELOG"` truncated the real file in place,
# its status unchecked, and the `rm -f` loop ran after an unconditional
# success message. Against a read-only CHANGELOG.md the old code printed
# "assembled 1 fragment(s)" and "removed 1 consumed fragment(s)" and exited 0
# with the entry present in NEITHER place — the only two copies destroyed in
# one run. The write is now staged beside the target and renamed, and the
# fragments are deleted only after a replace that actually succeeded.
# ===========================================================================
echo "T11: a failed write leaves the fragments undeleted"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skipped — running as root, filesystem permissions are not enforced"
else
  # T11a — read-only CHANGELOG.md.
  new_case
  write_nonempty_changelog
  cp "$CHANGELOG" "$CASE_DIR/before.md"
  frag '50-a.added.md' '- **entry that must not vanish** (#50).'
  chmod a-w "$CHANGELOG"
  out="$(run_assembler)"
  rc=$?
  chmod u+w "$CHANGELOG"
  assert_eq "T11a exits non-zero" "1" "$rc"
  assert_not_contains "T11a never claims success" "assembled 1 fragment(s)" "$out"
  assert_not_contains "T11a never claims deletion" "removed 1 consumed" "$out"
  assert_files_equal "T11a CHANGELOG.md byte-identical" "$CASE_DIR/before.md" "$CHANGELOG"
  assert_eq "T11a fragment kept — the entry still exists somewhere" \
    "50-a.added.md" "$(changelog_fragment_names "$FRAGS")"

  # T11b — an unwritable directory, so even STAGING the replacement fails.
  new_case
  write_nonempty_changelog
  cp "$CHANGELOG" "$CASE_DIR/before.md"
  frag '51-a.added.md' '- **entry that must not vanish** (#51).'
  chmod a-w "$CASE_DIR"
  out="$(run_assembler)"
  rc=$?
  chmod u+w "$CASE_DIR"
  assert_eq "T11b exits non-zero" "1" "$rc"
  assert_contains "T11b names the staging failure" "cannot stage a replacement" "$out"
  assert_files_equal "T11b CHANGELOG.md byte-identical" "$CASE_DIR/before.md" "$CHANGELOG"
  assert_eq "T11b fragment kept" "51-a.added.md" "$(changelog_fragment_names "$FRAGS")"
  assert_eq "T11b no staging temp left behind" "0" \
    "$(find "$CASE_DIR" -maxdepth 1 -name '.assemble-changelog.*' | wc -l | tr -d ' ')"
fi

# ===========================================================================
# T12 — a fragment the lister cannot read is reported, never skipped
#
# THE DEFECT. The listing filtered to regular files with no diagnostic, so a
# fragment one level down (`changelog.d/subdir/1-nested.added.md`) was
# invisible end to end: `--check` reported "all well-formed", the fragment
# never assembled, and it survived the deletion loop — sitting on disk looking
# pending while the release shipped without it. A dangling symlink whose NAME
# conforms is the same failure with no filename tell at all.
# ===========================================================================
echo "T12: a subdirectory or dangling symlink fails --check"
new_case
write_nonempty_changelog
mkdir -p "$FRAGS/subdir"
printf -- '- nested and invisible\n' > "$FRAGS/subdir/1-nested.added.md"
out="$(run_assembler --check)"
rc=$?
assert_eq "T12 subdirectory exits non-zero" "1" "$rc"
assert_not_contains "T12 never says all well-formed" "all well-formed" "$out"
assert_contains "T12 names the subdirectory" "subdir" "$out"

new_case
write_nonempty_changelog
ln -s "$CASE_DIR/does-not-exist.md" "$FRAGS/1-dangling.added.md"
out="$(run_assembler --check)"
rc=$?
assert_eq "T12 dangling symlink exits non-zero" "1" "$rc"
assert_contains "T12 names the dangling symlink" "1-dangling.added.md" "$out"

# ===========================================================================
# T13 — an unindented code fence in [Unreleased] is not a sub-heading
#
# THE DEFECT. The heading scan was fence-unaware, so a fenced sample line like
# `### Added` inside the Unreleased body registered as a real sub-heading:
# the section was split at it, a blank line was injected INSIDE the fence
# (mutating existing content), and fragments were appended into the resulting
# pseudo-section instead of the real one.
# ===========================================================================
echo "T13: an unindented code fence is not treated as a sub-heading"
new_case
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

### Added

- an entry documenting the fragment format:

```
### Added

- sample bullet inside a fence
```

- a real trailing entry

## [0.1.0] - 2026-01-01

- the beginning.
EOF
cp "$CHANGELOG" "$CASE_DIR/before.md"
frag '60-a.added.md' '- **appended below the fence** (#60).'
run_assembler >/dev/null
removed="$(diff "$CASE_DIR/before.md" "$CHANGELOG" | grep -c '^<')"
assert_eq "T13 not one line removed" "0" "$removed"
assert_contains "T13 the new entry landed" "**appended below the fence** (#60)." "$(cat "$CHANGELOG")"
# The fenced block's own content must come through byte-identical: the defect
# injected a blank line and the fragment INSIDE the fence.
fence_block() { awk '/^```$/ { n++; next } n == 1 { print }' "$1"; }
assert_eq "T13 the fenced block is byte-identical" \
  "$(fence_block "$CASE_DIR/before.md")" "$(fence_block "$CHANGELOG")"

# And the entry must land AFTER the closing fence — in the real sub-section,
# not the pseudo-section the fenced `### Added` used to create.
entry_line="$(grep -n 'appended below the fence' "$CHANGELOG" | cut -d: -f1)"
close_line="$(grep -n '^```$' "$CHANGELOG" | sed -n '2p' | cut -d: -f1)"
if [[ -n "$entry_line" && -n "$close_line" && "$entry_line" -gt "$close_line" ]]; then
  pass "T13 the entry landed after the closing fence, not inside it"
else
  fail "T13 the entry landed inside the fence (entry line $entry_line, closing fence $close_line)"
fi

# ===========================================================================
# T14 — the rewrite is INSERT-ONLY: existing blank lines are byte-preserved.
#
# THE DEFECT. The emitter RECONSTRUCTED the Unreleased body rather than
# splicing into it — it stripped each sub-section's leading/trailing blank run
# and re-emitted one canonical blank line around every heading. So the output
# depended on incidental whitespace in the INPUT: a `[Unreleased]` carrying a
# stray DOUBLE blank line assembled to one line FEWER than it started with,
# while the same body without one assembled purely additively. Same code, two
# answers. That is how a green PR was ejected from the merge queue — the
# merge_group trial branch merged a `main` that had picked up a double blank,
# and T8's "not one line removed" assertion flipped to 1 (temperloop#1321).
#
# T8 only catches this when the REAL changelog happens to contain the stray
# whitespace, which is exactly the content-dependence at issue. This case
# fixes the input so the property is asserted unconditionally.
# ===========================================================================
echo "T14: existing blank lines are byte-preserved (insert-only rewrite)"
new_case
cat > "$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

### Added

- normal single-blank layout, which must ALSO come through unchanged


### Changed

- reached across a stray DOUBLE blank line

### Fixed

- last entry before a trailing blank run


## [0.1.0] - 2026-01-01

- the beginning.
EOF
cp "$CHANGELOG" "$CASE_DIR/before.md"

# Three fragments, so all three splice paths run over this body at once: a
# merge into the section immediately AFTER the double blank, a merge into the
# section that ends in the trailing blank run, and a BRAND-NEW section flushed
# at end-of-body (`security` sorts last), which is the path that would trample
# that trailing run if it normalised.
frag '14-a.changed.md'  '- **merged into an existing section** (#14a).'
frag '14-b.fixed.md'    '- **merged into the section before the trailing run** (#14b).'
frag '14-c.security.md' '- **brand-new section at end of body** (#14c).'
run_assembler >/dev/null

# BYTE-IDENTITY, not merely "no content lost". `diff` reporting zero `<` lines
# AND zero change/delete hunks proves the before-file is an exact, in-order,
# byte-for-byte subsequence of the after-file: every pre-existing line is still
# there, unedited and unreordered, and the whole diff is pure insertion.
d="$(diff "$CASE_DIR/before.md" "$CHANGELOG")"
assert_eq "T14 not one line removed or changed" "0" "$(grep -c '^<' <<<"$d")"
assert_eq "T14 every diff hunk is a pure append" "0" \
  "$(grep -c '^[0-9,]*[cd]' <<<"$d")"

# The two specific runs the old emitter collapsed, named individually so a
# future regression reports WHICH one it broke rather than a bare line count.
# `blanks_before <file> <regex>` — the length of the blank run immediately
# preceding the first line matching <regex>.
blanks_before() {
  awk -v pat="$2" '$0 ~ pat { print b + 0; exit } /^[ \t]*$/ { b++; next } { b = 0 }' "$1"
}
assert_eq "T14 the double blank before ### Changed survived" "2" \
  "$(blanks_before "$CHANGELOG" '^### Changed$')"
# The pre-existing trailing run now sits before the brand-new section that was
# flushed at end-of-body — still two lines, neither of them consumed.
assert_eq "T14 the trailing blank run survived the end-of-body flush" "2" \
  "$(blanks_before "$CHANGELOG" '^### Security$')"
# Guard against over-correction: the normal single-blank layout must not grow.
assert_eq "T14 the normal single-blank layout is untouched" "1" \
  "$(blanks_before "$CHANGELOG" '^### Added$')"

assert_contains "T14 the existing-section merge landed" \
  "**merged into an existing section** (#14a)." "$(cat "$CHANGELOG")"
assert_contains "T14 the pre-trailing-run merge landed" \
  "**merged into the section before the trailing run** (#14b)." "$(cat "$CHANGELOG")"
assert_contains "T14 the brand-new section was created" "### Security" "$(cat "$CHANGELOG")"
assert_contains "T14 the brand-new section entry landed" \
  "**brand-new section at end of body** (#14c)." "$(cat "$CHANGELOG")"

# The downstream readers must still parse the result.
assert_eq "T14 version headings unchanged" "0.1.0" \
  "$(changelog_version_headings "$CHANGELOG")"

# ===========================================================================
# T15 — `--assert-empty <rev>`: the CUT-TIME assertion (temperloop#1322).
#
# It closes the cut-vs-sibling OMISSION race, which nothing else in the
# pipeline can see: a cut PR deletes fragments A and B while a sibling PR adds
# fragment C, the two touch DISJOINT files so git merges them clean, and C
# lands before the tag with its entry MISSING — not wrong — from the assembled
# release section. The leftover file at the tagged commit is the only
# evidence, so that is what this asserts. It replaced VERSIONING.md § Cutting
# a release step 1's merge-walking `^CHANGELOG.md$` backfill loop.
#
# These are the suite's only git-touching cases; every repo is a throwaway
# under mktemp and the repo's own tree is never read or written.
# ===========================================================================
echo "T15: --assert-empty (the cut-time assertion)"

git_case() {
  new_case
  git -C "$CASE_DIR" init -q >/dev/null 2>&1
  git -C "$CASE_DIR" config user.email t@example.com
  git -C "$CASE_DIR" config user.name Tester
  git -C "$CASE_DIR" config commit.gpgsign false
  write_nonempty_changelog
}

git_commit() {
  git -C "$CASE_DIR" add -A >/dev/null 2>&1
  git -C "$CASE_DIR" commit -qm "$1" >/dev/null 2>&1
}

# T15a — a clean tag. The sanctioned placeholders must not trip it.
git_case
printf '# placeholder\n' > "$FRAGS/README.md"
: > "$FRAGS/.gitkeep"
git_commit "cut"
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15a a clean commit exits 0" "0" "$rc"
assert_contains "T15a says so" "no unassembled fragments" "$out"

# T15b — the race itself: a sibling's fragment survived to the tagged commit.
git_case
frag '90-sibling.added.md' '- **the sibling entry that would have gone missing** (#90).'
git_commit "cut with a sibling fragment merged in behind it"
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15b exits 1" "1" "$rc"
assert_contains "T15b names the leftover file" "90-sibling.added.md" "$out"
assert_contains "T15b names the failure class" "omission race" "$out"
assert_contains "T15b names the remedy" "re-run scripts/assemble-changelog.sh" "$out"
assert_contains "T15b forbids the destructive shortcut" "Do NOT delete them" "$out"

# T15c — a fragment hidden one level down is reported too: it is every bit as
# unassembled as one at the top of the directory (T12's shape, at a rev).
git_case
mkdir -p "$FRAGS/sub"
printf -- '- **nested** (#91).\n' > "$FRAGS/sub/91-nested.added.md"
git_commit "cut with a nested fragment"
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15c a nested fragment exits 1" "1" "$rc"
assert_contains "T15c names the nested path" "sub/91-nested.added.md" "$out"

# T15d — REV-SCOPED, never working-tree scoped. This is what makes the
# assertion usable mid-cut: the answer is about the commit being tagged,
# whatever the working tree happens to hold at the time.
git_case
frag '92-committed.added.md' '- **committed** (#92).'
git_commit "a commit that carries a fragment"
rm -f "$FRAGS/92-committed.added.md"          # gone from the working tree only
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15d still fails: the fragment is in the COMMIT" "1" "$rc"
assert_contains "T15d names it" "92-committed.added.md" "$out"

git_case
: > "$FRAGS/.gitkeep"
git_commit "a clean commit"
frag '93-uncommitted.added.md' '- **uncommitted** (#93).'   # working tree only
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15d2 passes: an UNCOMMITTED fragment is not at the rev" "0" "$rc"

# T15e — an unresolvable rev is a loud error, never a silent pass. A cut-time
# assertion that exits 0 because it could not resolve what it was asked about
# is the same "quietly narrows to zero" failure the gate refuses to commit.
git_case
: > "$FRAGS/.gitkeep"
git_commit "a clean commit"
out="$(run_assembler --assert-empty v9.9.9-does-not-exist)"
rc=$?
assert_eq "T15e an unresolvable rev exits non-zero" "1" "$rc"
assert_contains "T15e names the rev" "v9.9.9-does-not-exist" "$out"

# T15f — a non-git tree is an error too, not an accidental pass.
new_case
write_nonempty_changelog
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15f a non-git tree exits non-zero" "1" "$rc"
assert_contains "T15f says why" "not a git checkout" "$out"

# T15g — a --fragment-dir that does not EXIST at the rev is an error, never an
# "ok". This is the finding's sharp edge: the ok line read identically for
# "the cut is clean" and "I looked in a directory that has never existed", and
# it is the last gate before a tag. Only the PARENT of --fragment-dir was ever
# validated, so a misspelled directory matched nothing and passed.
git_case
: > "$FRAGS/.gitkeep"
git_commit "a clean commit"
out="$(bash "$ASSEMBLER" --changelog "$CHANGELOG" \
  --fragment-dir "$CASE_DIR/changelogd-typo" --assert-empty HEAD 2>&1)"
rc=$?
assert_eq "T15g a fragment dir absent at the rev exits non-zero" "1" "$rc"
assert_not_contains "T15g never reports ok" "no unassembled fragments" "$out"
assert_contains "T15g names the directory it could not read" "changelogd-typo" "$out"

# T15h — an UNREADABLE tree is an error too. The `ls-tree` call used to swallow
# both stderr and its exit status (`2>/dev/null || true`), so ANY failure of
# the tree read produced empty output, an empty leftover set, and a clean
# verdict. Forced here by deleting the fragment directory's own tree object:
# the COMMIT still resolves (so the rev guard passes) while the tree read
# cannot succeed — the treeless-partial-clone shape, reproduced locally.
git_case
frag '94-unreadable.added.md' '- **an entry that must not vanish** (#94).'
git_commit "a commit carrying a fragment"
frag_tree="$(git -C "$CASE_DIR" rev-parse "HEAD:changelog.d")"
rm -f "$CASE_DIR/.git/objects/${frag_tree:0:2}/${frag_tree:2}"
out="$(run_assembler --assert-empty HEAD)"
rc=$?
assert_eq "T15h an unreadable tree exits non-zero" "1" "$rc"
assert_not_contains "T15h never reports ok" "no unassembled fragments" "$out"

# T15i — a trailing mode flag must not silently CANCEL the assertion. MODE was
# last-assignment-wins, so `--assert-empty HEAD --check` set the rev and then
# overwrote the mode: a release script composing --check for "extra validation"
# got a green that asserted nothing at all.
new_case
out="$(run_assembler --assert-empty HEAD --check)"
rc=$?
assert_eq "T15i a trailing mode flag is a usage error" "2" "$rc"
assert_contains "T15i names the conflict" "conflicting mode flags" "$out"
assert_not_contains "T15i does not silently run the other mode" "all well-formed" "$out"

new_case
out="$(run_assembler --check --assert-empty HEAD)"
rc=$?
assert_eq "T15i2 rejected in the other order too" "2" "$rc"
assert_contains "T15i2 names the conflict" "conflicting mode flags" "$out"

echo
echo "test_assemble_changelog.sh: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
