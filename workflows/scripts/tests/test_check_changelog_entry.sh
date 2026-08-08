#!/usr/bin/env bash
#
# test_check_changelog_entry.sh — tests for workflows/scripts/check-changelog-entry.sh,
# the CHANGELOG `## [Unreleased]` merge gate (temperloop#960).
#
# Hermetic: every case builds a throwaway git repo under mktemp and points the
# script at it with CHANGELOG_GATE_ROOT + an explicit --base sha. No network, no
# `gh`, no origin remote, and the real repo is never mutated (one read-only case
# runs the script against it to prove the REAL VERSIONING.md table still parses).
#
# FRAGMENT CUTOVER (temperloop#1322): property (1) now asks for a
# `changelog.d/` fragment, not a line under `## [Unreleased]`. Where a case
# below changed verdict, the assertion it REPLACES is kept beside it rather
# than deleted — case 2a is the old case-2 fixture verbatim, now asserting that
# the direct-line path no longer satisfies the gate, and 2b is its fragment
# equivalent. Case 23 is the fragment-era analogue of case 10 (a bare `###`
# sub-heading was not an entry; an empty fragment is not either).
#
# Exercises:
#   1. RED   — contract surface changed, no fragment
#  2a. RED   — the old path: a direct `## [Unreleased]` line no longer suffices
#  2b. GREEN — same change carrying a changelog.d/ fragment
#   3. GREEN — only non-contract-surface files changed
#   4. GREEN — explicit opt-out via PR label
#   5. GREEN — explicit opt-out via PR-body marker
#   6. GREEN — explicit opt-out via commit-message trailer
#   7. RED   — opt-out marker with NO reason is not an opt-out
#   8. GREEN — release cut (Unreleased emptied into a new version section)
#   9. RED   — CHANGELOG touched, but only under an OLD version section
#  10. RED   — only a bare `###` sub-heading added under [Unreleased]
#  11. GREEN — bare-token (basename) contract-surface pattern matches (VERSION)
#  12. SKIP  — GITHUB_EVENT_NAME=merge_group skips (no PR body/label in payload)
#  13. RED   — the contract-surface table is unparseable -> loud failure
#  14. REAL  — the real repo's VERSIONING.md table parses (no loud failure)
#
# Section scope (temperloop#1151) — the released-section boundary, both
# directions, reproducing the REAL observed shapes rather than synthetic ones:
#  15. RED   — drift-in (temperloop#1138): a concurrent release cut lands a
#              version section beneath [Unreleased] and the PR's entry resolves
#              into the TOP of it
#  16. RED   — history loss (the temperloop#1125 over-correction): moving your
#              OWN entry back out of a released section also pulls ANOTHER PR's
#              block out with it
#  17. GREEN — the release cut itself, unmodified: creating a section and
#              moving [Unreleased] down into it is never a section-scope
#              violation (the base-ref discriminator)
#  18. GREEN — the deliberate amendment (temperloop#1143 shape): marking an
#              already-shipped release BREAKING + adding its migration note,
#              via the explicit `Changelog: amend` marker (all three channels)
#  19. RED   — an amendment marker with NO reason is not an amendment
#  20. RED   — `Changelog: none` does NOT waive section scope (the two verbs
#              are siblings, not synonyms)
#  21. RED   — a CHANGELOG-ONLY PR (no contract surface touched) that steals
#              from a released section still fails
#
# The fragment cutover's own states (temperloop#1322):
#  22. RED   — a fragment one level down is never assembled, so it is not an
#              entry
#  23. RED   — an EMPTY fragment is not an entry (analogue of case 10)
#  24. RED   — a fragment whose filename does not conform is not an entry
#  25. GREEN — a release cut DELETES fragments; deletions are not entries, and
#              the new version section is what carries the cut
#  26. RED   — no changelog.d/ AND no .kernel-pin => FAIL LOUDLY (a kernel
#              checkout that lost the directory must not silently disable the
#              gate)
#  27. SKIP  — no changelog.d/ but .kernel-pin present => an actionable skip
#              naming the pinned kernel tag, the BREAKING classification and
#              the enabling command
#  28. RED   — the fail-loud arm is a statement about the TREE: it fires even
#              when the diff touches no contract surface at all
#  29. RED   — an un-migrated overlay still gets property (2): the completeness
#              skip never disables the released-section-scope check
#  30. PROP  — the property the cutover buys: two concurrent fragment PRs merge
#              CLEAN where the same two [Unreleased] edits CONFLICT
#  31. RED   — no CHANGELOG.md AND no .kernel-pin => FAIL LOUDLY. The SAME
#              discriminator as case 26, on the probe that runs first: without
#              it the fail-loud arm was unreachable for a tree that had lost
#              CHANGELOG.md, and probe ORDER was the only thing standing
#              between this gate and its own stated invariant
#  32. SKIP  — no CHANGELOG.md but .kernel-pin present => the actionable skip
#  33. RED   — a tree that lost BOTH CHANGELOG.md and changelog.d/, with no
#              pin, fails rather than skipping on the first probe
#  34. HELP  — `--help` reaches the usage block and the exit-code table (the
#              header grew past the old fixed line range)
#
# Usage: bash workflows/scripts/tests/test_check_changelog_entry.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/check-changelog-entry.sh"

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

# ── Fixture VERSIONING.md ───────────────────────────────────────────────────
# Deliberately mirrors the REAL file's shape, including the two parse hazards
# the script must survive: a cell containing an ESCAPED pipe (`\|`), and a
# backticked non-path token (`some_function_name`) that must be filtered out
# rather than treated as a path pattern.
write_versioning() {
  cat > "$1/VERSIONING.md" <<'EOF'
# Versioning

## The core idea

Prose.

### The contract surface

These are the seams an adopter depends on.

| Surface | What couples to it | Where it lives |
|---|---|---|
| **Board adapter** | overlay scripts calling `board_resolve` | `scripts/board/lib/board.sh`, `boards.conf` |
| **Pipeline commands** | operators running the slash commands | `claude/commands/*.md`, `claude/plan-schema.md` |
| **Hooks** | a machine's installed hooks | `claude/hooks/*.sh` |
| **Quality-gate contract** | CI + local gate parity | `scripts/quality-gates.sh`, `.github/workflows/ci.yml` |
| **CLI surface** | callers of `bin/tool` | `bin/tool`, `bin/subcommands/*` |
| **Shipped version stamp** | the release artifact's own version | `VERSION`, `bin/lib/common.sh` (`some_function_name`) |
| **Setting registry** | callers reading the row shape (`name\|default\|type`) | `config/setting-registry.tsv` |
| **Published schemas** | anything a stranger reads to conform | various `*.contract.md`, `*-schema.md` |

Prose after the table, which must not be parsed as a row.

## Bump rules

More prose.
EOF
}

CHANGELOG_SEED='# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- The first release.
'

# new_repo <dir> [tree-shape] — a fixture checkout with VERSIONING.md +
# CHANGELOG.md + a couple of contract-surface files, all in one base commit.
# Echoes the base sha.
#
# <tree-shape> selects which of the three trees the cutover distinguishes:
#   fragments    (default) a migrated tree: changelog.d/ present, no pin
#   nofrag       no changelog.d/ and no .kernel-pin — a kernel checkout that
#                lost the directory (the fail-loud arm)
#   nofrag-pin   no changelog.d/ but .kernel-pin present — an un-migrated
#                vendoring consumer (the legible-skip arm)
#   frag-pin     changelog.d/ AND .kernel-pin — a MIGRATED vendoring consumer.
#                Used to isolate the CHANGELOG.md probe from the changelog.d/
#                one: only the file under test is ever the missing thing.
new_repo() {
  local d="$1" shape="${2:-fragments}"
  mkdir -p "$d/claude/commands" "$d/docs" "$d/bin"
  git -C "$d" init -q >/dev/null 2>&1
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Tester
  git -C "$d" config commit.gpgsign false
  write_versioning "$d"
  printf '%s' "$CHANGELOG_SEED" > "$d/CHANGELOG.md"
  echo "# build" > "$d/claude/commands/build.md"
  echo "0.1.0" > "$d/VERSION"
  echo "notes" > "$d/docs/notes.md"
  case "$shape" in
    fragments)
      mkdir -p "$d/changelog.d"
      : > "$d/changelog.d/.gitkeep"
      ;;
    nofrag) : ;;
    nofrag-pin)
      printf '# .kernel-pin\ntag v0.42.0\nsha deadbeef\n' > "$d/.kernel-pin"
      ;;
    frag-pin)
      mkdir -p "$d/changelog.d"
      : > "$d/changelog.d/.gitkeep"
      printf '# .kernel-pin\ntag v0.42.0\nsha deadbeef\n' > "$d/.kernel-pin"
      ;;
    *) echo "new_repo: unknown tree-shape '$shape'" >&2; exit 2 ;;
  esac
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm "base" >/dev/null
  git -C "$d" rev-parse HEAD
}

# frag <dir> <name> [line...] — write a changelog.d/ fragment in the fixture.
frag() {
  local d="$1" name="$2"; shift 2
  mkdir -p "$(dirname "$d/changelog.d/$name")"
  if [[ $# -eq 0 ]]; then
    : > "$d/changelog.d/$name"
  else
    printf '%s\n' "$@" > "$d/changelog.d/$name"
  fi
}

# run_gate <root> <base> [env assignments...] — run the script, capture stdout,
# stderr and exit status into RUN_OUT / RUN_STATUS.
run_gate() {
  local root="$1" base="$2"; shift 2
  RUN_OUT="$(env -u GITHUB_EVENT_NAME -u CHANGELOG_GATE_PR_BODY -u CHANGELOG_GATE_PR_LABELS \
    CHANGELOG_GATE_ROOT="$root" "$@" bash "$SCRIPT" --base "$base" 2>&1)"
  RUN_STATUS=$?
}

# ── 1. RED: contract surface changed, no fragment ───────────────────────────
echo "1. contract surface changed, no fragment"
D="$TMP/r1"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails the check"
assert_has "$RUN_OUT" "claude/commands/build.md" "names the touched contract-surface file"
# Replaces the pre-cutover assertion `assert_has "## [Unreleased]"` — the
# remedy the message must now name is a fragment path, not a section.
assert_has "$RUN_OUT" "changelog.d/<slug>.<category>[.breaking].md" "names the fragment to add"
assert_has "$RUN_OUT" "no-changelog" "documents the opt-out label"

# ── 2a. RED: the OLD path no longer satisfies the gate ──────────────────────
# The fixture is the pre-cutover case 2 verbatim — a direct `## [Unreleased]`
# line and nothing else. It used to pass; the whole point of the cutover is
# that it does not, because that line is the merge-conflict anchor.
echo "2a. a direct [Unreleased] line no longer suffices"
D="$TMP/r2a"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- Tweaked the build command spec.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — the [Unreleased] line is no longer an entry"
assert_not_has "$RUN_OUT" "gained an entry" "does not report the old-style entry as satisfying"
assert_has "$RUN_OUT" "adds no changelog.d/ fragment" "says what is missing"

# ── 2b. GREEN: the same change carrying a fragment ──────────────────────────
echo "2b. same change, changelog.d/ fragment added"
D="$TMP/r2b"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
frag "$D" "1322-tweak.changed.md" "- Tweaked the build command spec."
git -C "$D" add -A >/dev/null
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "carries a changelog.d/ fragment" "reports the fragment it found"
assert_has "$RUN_OUT" "changelog.d/1322-tweak.changed.md" "names the fragment"

# ── 3. GREEN: nothing on the contract surface ───────────────────────────────
echo "3. only non-contract-surface files changed"
D="$TMP/r3"; BASE="$(new_repo "$D")"
echo "more notes" >> "$D/docs/notes.md"
git -C "$D" commit -aqm "docs tweak"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "no contract-surface path changed" "says why it passed"

# ── 4-6. GREEN: the three explicit opt-out channels ─────────────────────────
echo "4. opt-out via PR label"
D="$TMP/r4"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "reword a comment"
run_gate "$D" "$BASE" CHANGELOG_GATE_PR_LABELS="chore, no-changelog ,Operational"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "opted out via the PR label" "records the channel"

echo "5. opt-out via PR-body marker"
D="$TMP/r5"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "reword a comment"
run_gate "$D" "$BASE" CHANGELOG_GATE_PR_BODY="## Summary
Comment rewording only.

Changelog: none - comment rewording, no adopter-visible change
"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "opted out via the PR body" "records the channel"
assert_has "$RUN_OUT" "comment rewording, no adopter-visible change" "echoes the recorded reason"

echo "6. opt-out via commit-message trailer"
D="$TMP/r6"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "reword a comment

Changelog: none — comment rewording only"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "opted out via the commit message" "records the channel"

# ── 7. RED: a marker with no reason records nothing ─────────────────────────
echo "7. opt-out marker with no reason"
D="$TMP/r7"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "reword a comment

Changelog: none"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "still fails — the reason is required"
assert_not_has "$RUN_OUT" "opted out" "does not treat it as an opt-out"

# ── 8. GREEN: a release cut legitimately empties [Unreleased] ───────────────
echo "8. release cut"
D="$TMP/r8"; BASE="$(new_repo "$D")"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-02-02

### Changed

- Tweaked the build command spec.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
echo "0.2.0" > "$D/VERSION"
git -C "$D" commit -aqm "chore(release): cut v0.2.0"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "release cut" "recognizes the release cut"

# ── 9. RED: CHANGELOG touched, but not under [Unreleased] ───────────────────
echo "9. CHANGELOG touched only under an old version section"
D="$TMP/r9"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.1.0] - 2026-01-01

### Added

- The first release.
- A retroactively documented thing that belongs to an ALREADY-RELEASED version.
EOF
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — touching CHANGELOG.md is not enough"

# ── 10. RED: an empty sub-heading is not an entry ───────────────────────────
echo "10. only a bare sub-heading added under [Unreleased]"
D="$TMP/r10"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Changed

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — no fragment (and a bare heading was never an entry either)"

# ── 11. GREEN/RED: a bare-token pattern matches by basename ─────────────────
echo "11. bare-token (basename) contract-surface pattern"
D="$TMP/r11"; BASE="$(new_repo "$D")"
echo "0.1.1" > "$D/VERSION"
git -C "$D" commit -aqm "bump the version stamp"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "VERSION counts as contract surface"
assert_has "$RUN_OUT" "- VERSION" "names it in the touched list"

# ── 12. SKIP: merge_group carries no PR body/label ──────────────────────────
echo "12. merge_group event skips"
D="$TMP/r12"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "tweak the build command spec"
RUN_OUT="$(CHANGELOG_GATE_ROOT="$D" GITHUB_EVENT_NAME=merge_group bash "$SCRIPT" --base "$BASE" 2>&1)"
RUN_STATUS=$?
assert_status 0 "$RUN_STATUS" "skips instead of failing"
assert_has "$RUN_OUT" "skipped —" "the skip is legible, never silent"
assert_has "$RUN_OUT" "merge_group" "names the event"

# ── 13. RED: an unparseable contract-surface table fails LOUDLY ─────────────
echo "13. unparseable contract-surface table"
D="$TMP/r13"; BASE="$(new_repo "$D")"
cat > "$D/VERSIONING.md" <<'EOF'
# Versioning

### The surface that things couple to

Someone renamed the heading and dropped the table.
EOF
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "rename the versioning heading"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails rather than silently enforcing nothing"
assert_has "$RUN_OUT" "contract-surface path pattern" "names the parse failure"

# ── 14. REAL: the real VERSIONING.md table still parses ─────────────────────
echo "14. the real repo's contract-surface table parses"
RUN_OUT="$(env -u GITHUB_EVENT_NAME -u CHANGELOG_GATE_PR_BODY -u CHANGELOG_GATE_PR_LABELS \
  bash "$SCRIPT" 2>&1)"
RUN_STATUS=$?
assert_not_has "$RUN_OUT" "contract-surface path pattern" "no parse failure against the real tree"
if [[ "$RUN_STATUS" == "0" || "$RUN_STATUS" == "1" ]]; then
  ok "runs to a real verdict against the real tree (exit $RUN_STATUS)"
else
  bad "real-tree run" "unexpected exit $RUN_STATUS: $RUN_OUT"
fi

# ═══ Section scope (temperloop#1151) ════════════════════════════════════════
# These reproduce the three REAL incidents named in the issue. The fixtures
# below advance the base past `new_repo`'s seed commit so the base ref already
# carries the released section under test — which is the whole discriminator:
# a section that exists AT THE BASE has shipped; a section this change creates
# is a release cut.

# rebase_base <dir> <msg> — commit the current CHANGELOG.md as a new base and
# echo its sha (the "main advanced under the PR" world).
rebase_base() {
  git -C "$1" commit -aqm "$2"
  git -C "$1" rev-parse HEAD
}

# ── 15. RED: drift-in — temperloop#1138 ─────────────────────────────────────
# Main cut v0.26.0 directly beneath [Unreleased]; on rebase the PR's own added
# lines resolve into the TOP of a release that does not contain its work.
echo "15. drift-in: an entry lands in an already-released section (#1138)"
D="$TMP/r15"; new_repo "$D" >/dev/null
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05 — BREAKING

### Removed — BREAKING

- The Projects-v2/GraphQL arm is removed from the board adapter.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
BASE="$(rebase_base "$D" "chore(release): cut v0.26.0")"
echo "# build v2" > "$D/claude/commands/build.md"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05 — BREAKING

### Changed

- Tweaked the build command spec.

### Removed — BREAKING

- The Projects-v2/GraphQL arm is removed from the board adapter.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — the entry drifted into a released section"
assert_has "$RUN_OUT" "ALREADY RELEASED" "says the section had already shipped"
assert_has "$RUN_OUT" "[0.26.0]" "names the section the lines landed in"
assert_has "$RUN_OUT" "## [Unreleased]" "names the section they belong in"
assert_has "$RUN_OUT" "Tweaked the build command spec." "quotes the drifted line"

# ── 16. RED: history loss — the temperloop#1125 over-correction ─────────────
# A worker correctly moves its OWN entry back out of [0.27.0] but also pulls
# temperloop#1138's `### Removed — BREAKING` block out with it, where that
# block legitimately belonged. The more damaging direction, and invisible to
# review because the diff reads as a legitimate move.
echo "16. history loss: a released section loses an entry that shipped in it (#1125)"
D="$TMP/r16"; new_repo "$D" >/dev/null
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.27.0] - 2026-08-05 — BREAKING

### Changed

- Tweaked the build command spec.

### Removed — BREAKING

- The board adapter's Projects-v2 arm is gone (temperloop#1138, merged before this cut).

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
BASE="$(rebase_base "$D" "chore(release): cut v0.27.0")"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- Tweaked the build command spec.

## [0.27.0] - 2026-08-05 — BREAKING

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "move my entry back under Unreleased"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — a released section lost lines"
assert_has "$RUN_OUT" "REMOVED from already-released section(s) [0.27.0]" "names the direction and the section"
assert_has "$RUN_OUT" "temperloop#1138, merged before this cut" "quotes the erased entry"
assert_has "$RUN_OUT" "changelog-amend" "documents the amendment label"

# ── 17. GREEN: the release cut itself is never a section-scope violation ────
# A cut creates `## [x.y.z]` directly beneath [Unreleased] and moves the
# accumulated entries down into it — "lines added inside a version section" and
# "a version section changed" are both TRUE here. The base-ref discriminator is
# what separates this from case 15: at the base, [0.2.0] did not exist.
echo "17. a release cut still passes, unmodified"
D="$TMP/r17"; new_repo "$D" >/dev/null
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- Tweaked the build command spec.

### Removed — BREAKING

- The board adapter's Projects-v2 arm is gone.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
BASE="$(rebase_base "$D" "feat: accumulate some unreleased work")"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-02-02 — BREAKING

### Changed

- Tweaked the build command spec.

### Removed — BREAKING

- The board adapter's Projects-v2 arm is gone.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
echo "0.2.0" > "$D/VERSION"
git -C "$D" commit -aqm "chore(release): cut v0.2.0"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_not_has "$RUN_OUT" "ALREADY RELEASED" "the created section is not treated as released"
assert_has "$RUN_OUT" "release cut" "still recognized as a release cut"

# ── 18. GREEN: the deliberate amendment — temperloop#1143 shape ─────────────
# Retroactively marking an already-shipped release BREAKING and adding the
# migration note it should have carried. This MUST still be possible — via the
# explicit marker, in any of the same three channels.
echo "18. deliberate amendment of a shipped release (#1143)"
amend_repo() {
  local d="$1"
  new_repo "$d" >/dev/null
  cat > "$d/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05

### Removed

- The Projects-v2/GraphQL arm is removed from the board adapter.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
  rebase_base "$d" "chore(release): cut v0.26.0"
}
amend_head() {
  cat > "$1/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05 — BREAKING

### Removed — BREAKING

- The Projects-v2/GraphQL arm is removed from the board adapter.

  **Migration.** There is no configuration path back to Projects-v2; an
  adopter who wants it forks the board adapter.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
}

D="$TMP/r18"; BASE="$(amend_repo "$D")"
amend_head "$D"
git -C "$D" commit -aqm "docs(changelog): mark v0.26.0 BREAKING and add its migration note"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "without the marker it fails (the check really bites)"
run_gate "$D" "$BASE" CHANGELOG_GATE_PR_LABELS="chore, changelog-amend ,Operational"
assert_status 0 "$RUN_STATUS" "passes via the amendment LABEL"
assert_has "$RUN_OUT" "recorded the amendment via the PR label" "records the channel"
run_gate "$D" "$BASE" CHANGELOG_GATE_PR_BODY="## Summary
v0.26.0 shipped four PRs with no BREAKING marker.

Changelog: amend - v0.26.0 shipped breaking with no marker; adding it retroactively
"
assert_status 0 "$RUN_STATUS" "passes via the amendment marker in the PR BODY"
assert_has "$RUN_OUT" "recorded the amendment via the PR body" "records the channel"
assert_has "$RUN_OUT" "adding it retroactively" "echoes the recorded reason"

D="$TMP/r18t"; BASE="$(amend_repo "$D")"
amend_head "$D"
git -C "$D" commit -aqm "docs(changelog): mark v0.26.0 BREAKING

Changelog: amend — v0.26.0 shipped breaking with no marker"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes via the amendment marker in the COMMIT message"
assert_has "$RUN_OUT" "recorded the amendment via the commit message" "records the channel"

# ── 19. RED: an amendment marker with no reason records nothing ─────────────
echo "19. amendment marker with no reason"
D="$TMP/r19"; BASE="$(amend_repo "$D")"
amend_head "$D"
git -C "$D" commit -aqm "docs(changelog): mark v0.26.0 BREAKING

Changelog: amend"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "still fails — the reason is required"
assert_not_has "$RUN_OUT" "recorded the amendment" "does not treat it as an amendment"

# ── 20. RED: `none` and `amend` are siblings, not synonyms ──────────────────
echo "20. a 'Changelog: none' opt-out does not waive section scope"
D="$TMP/r20"; BASE="$(amend_repo "$D")"
amend_head "$D"
git -C "$D" commit -aqm "docs(changelog): mark v0.26.0 BREAKING

Changelog: none — prose-only changelog touch-up"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — the skip verb waives the entry requirement only"
assert_has "$RUN_OUT" "ALREADY RELEASED" "fails for the section-scope reason"

# ── 21. RED: a CHANGELOG-ONLY PR can steal from a released section too ──────
# No contract surface is touched here, so property (1) would pass this change
# outright; the section-scope check runs independently of it.
echo "21. CHANGELOG-only change that erases a released entry"
D="$TMP/r21"; BASE="$(amend_repo "$D")"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "docs(changelog): tidy up"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails even with no contract-surface path touched"
assert_not_has "$RUN_OUT" "no contract-surface path changed" "does not short-circuit on the contract-surface test"
assert_has "$RUN_OUT" "REMOVED from already-released section(s) [0.26.0]" "names the direction and the section"

# ═══ The fragment cutover (temperloop#1322) ═════════════════════════════════

# ── 22. RED: a nested fragment is never assembled, so it is not an entry ────
# `changelog.d/sub/x.added.md` parses fine by BASENAME but the assembler only
# reads regular files DIRECTLY in the directory — it would sit there looking
# pending while the release shipped without it.
echo "22. a fragment one level down does not count"
D="$TMP/r22"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
frag "$D" "sub/1322-nested.changed.md" "- A nested entry that never assembles."
git -C "$D" add -A >/dev/null
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — a nested fragment is not an entry"

# ── 23. RED: an EMPTY fragment is not an entry ──────────────────────────────
# The fragment-era analogue of case 10: an empty fragment is a lost entry, and
# the assembler refuses to cut on one.
echo "23. an empty fragment is not an entry"
D="$TMP/r23"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
frag "$D" "1322-empty.changed.md" "" "   "
git -C "$D" add -A >/dev/null
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — a blank fragment is a lost entry, not an entry"

# ── 24. RED: a non-conforming filename is not an entry ──────────────────────
echo "24. a malformed fragment filename does not count"
D="$TMP/r24"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
frag "$D" "1322-typo.chagned.md" "- A typo'd category is never assembled."
git -C "$D" add -A >/dev/null
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — an unrecognised filename is not an entry"

# ── 25. GREEN: a release cut DELETES fragments and still passes ─────────────
# The cut runs the assembler: fragments are folded into [Unreleased], the body
# moves down into a new version section, and the fragment files are removed. A
# deletion must not read as an entry (it is the opposite), so what carries the
# cut is still the version-heading set growing.
echo "25. a release cut deletes fragments and still passes"
D="$TMP/r25"; new_repo "$D" >/dev/null
frag "$D" "1300-earlier.changed.md" "- An entry accumulated since the last tag."
git -C "$D" add -A >/dev/null
BASE="$(rebase_base "$D" "feat: accumulate an entry as a fragment")"
git -C "$D" rm -q "changelog.d/1300-earlier.changed.md"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.2.0] - 2026-02-02

### Changed

- An entry accumulated since the last tag.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
echo "0.2.0" > "$D/VERSION"
git -C "$D" add -A >/dev/null
git -C "$D" commit -qm "chore(release): cut v0.2.0"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "release cut" "recognized as a release cut, not a missing entry"

# ── 26. RED: no changelog.d/ AND no .kernel-pin => FAIL LOUDLY ──────────────
# The mandatory companion to the skip below. Without it the skip would let the
# kernel's own tree silently disable this gate the moment the directory went
# missing — the exact "quietly narrows to zero" failure the contract-surface
# parse already refuses to commit.
echo "26. no changelog.d/ and no .kernel-pin fails loudly"
D="$TMP/r26"; BASE="$(new_repo "$D" nofrag)"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails loudly rather than skipping"
assert_has "$RUN_OUT" "no changelog.d/ at" "names the missing directory"
assert_has "$RUN_OUT" ".kernel-pin" "names the discriminator"
assert_has "$RUN_OUT" "mkdir -p changelog.d" "names the concrete remedy"

# ── 27. SKIP: no changelog.d/ but .kernel-pin present => actionable skip ────
# An un-migrated vendoring overlay keeps building green and is told, on the run
# where it would otherwise have been enforced, exactly what to create.
echo "27. an un-migrated vendoring consumer gets an actionable skip"
D="$TMP/r27"; BASE="$(new_repo "$D" nofrag-pin)"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "skips instead of failing"
assert_has "$RUN_OUT" "skipped —" "the skip is legible, never silent"
assert_has "$RUN_OUT" "has not migrated to changelog fragments" "says what is missing"
assert_has "$RUN_OUT" "v0.42.0" "names the pinned kernel release from .kernel-pin"
assert_has "$RUN_OUT" "BREAKING" "names the classification"
assert_has "$RUN_OUT" "mkdir -p changelog.d" "names the concrete enabling step"
assert_has "$RUN_OUT" "Completeness is NOT enforced" "is explicit that the property is off"

# ── 28. RED: the fail-loud arm is about the TREE, not the diff ──────────────
# A kernel checkout that lost changelog.d/ must fail on EVERY PR — including
# one touching no contract surface, which would otherwise exit 0 long before
# property (1) is reached.
echo "28. the fail-loud arm fires with no contract surface touched"
D="$TMP/r28"; BASE="$(new_repo "$D" nofrag)"
echo "more notes" >> "$D/docs/notes.md"
git -C "$D" commit -aqm "docs tweak"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails even though no contract surface changed"
assert_not_has "$RUN_OUT" "no contract-surface path changed" "does not reach the contract-surface verdict"

# ── 29. RED: the completeness skip never disables section scope ─────────────
# An un-migrated overlay loses property (1) and KEEPS property (2). Same
# fixture shape as case 21 (a CHANGELOG-only theft), on a pinned tree with no
# changelog.d/.
echo "29. an un-migrated overlay still gets section scope enforced"
D="$TMP/r29"; new_repo "$D" nofrag-pin >/dev/null
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05

### Removed

- The Projects-v2/GraphQL arm is removed from the board adapter.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
BASE="$(rebase_base "$D" "chore(release): cut v0.26.0")"
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [0.26.0] - 2026-08-05

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "docs(changelog): tidy up"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails — property (2) survives the property (1) skip"
assert_has "$RUN_OUT" "REMOVED from already-released section(s) [0.26.0]" "names the direction and the section"

# ── 30. PROP: the collision the cutover removes ─────────────────────────────
# This is the property the whole epic buys, asserted directly rather than
# argued: two concurrent contract-surface PRs that CONFLICT when each writes a
# line under `## [Unreleased]` MERGE CLEAN when each writes its own fragment.
# No gate involvement — this is git's own verdict on the two shapes.
echo "30. two concurrent fragment PRs merge clean where [Unreleased] edits conflict"
D="$TMP/r30"; new_repo "$D" >/dev/null
cat > "$D/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Changed

- baseline entry.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
git -C "$D" commit -aqm "seed an Unreleased body"
MAIN="$(git -C "$D" rev-parse --abbrev-ref HEAD)"
SEED="$(git -C "$D" rev-parse HEAD)"

unreleased_variant() {
  cat > "$D/CHANGELOG.md" <<EOF
# Changelog

## [Unreleased]

### Changed

- entry $1.
- baseline entry.

## [0.1.0] - 2026-01-01

### Added

- The first release.
EOF
}

for who in A B; do
  git -C "$D" checkout -q -b "pr-line-$who" "$SEED"
  unreleased_variant "$who"
  git -C "$D" commit -aqm "pr $who: add an [Unreleased] line"
done
git -C "$D" checkout -q "$MAIN"
git -C "$D" merge -q --no-edit pr-line-A >/dev/null 2>&1
git -C "$D" merge --no-edit pr-line-B >/dev/null 2>&1
LINE_MERGE=$?
git -C "$D" merge --abort >/dev/null 2>&1 || true
if [[ "$LINE_MERGE" -ne 0 ]]; then
  ok "the pre-cutover shape really does conflict (git exit $LINE_MERGE)"
else
  bad "pre-cutover shape" "expected the two [Unreleased] edits to conflict, but git merged them"
fi

# Back to the shared ancestor, then run the SAME two PRs as fragments.
git -C "$D" reset -q --hard "$SEED"
for who in A B; do
  git -C "$D" checkout -q -b "pr-frag-$who" "$SEED"
  frag "$D" "1322-pr-$who.changed.md" "- entry $who."
  git -C "$D" add -A >/dev/null
  git -C "$D" commit -qm "pr $who: add a fragment"
done
git -C "$D" checkout -q "$MAIN"
git -C "$D" merge -q --no-edit pr-frag-A >/dev/null 2>&1
git -C "$D" merge --no-edit pr-frag-B >/dev/null 2>&1
FRAG_MERGE=$?
assert_status 0 "$FRAG_MERGE" "the same two PRs merge CLEAN as fragments"
if [[ -f "$D/changelog.d/1322-pr-A.changed.md" && -f "$D/changelog.d/1322-pr-B.changed.md" ]]; then
  ok "both entries survive the merge"
else
  bad "fragment merge" "expected both fragments present after the merge"
fi

# ── 31. RED: no CHANGELOG.md AND no .kernel-pin => FAIL LOUDLY ──────────────
# The SAME discriminator as case 26, applied to the probe that runs FIRST.
# Before this, the CHANGELOG.md probe exited 0 unconditionally, so a kernel
# checkout that had lost CHANGELOG.md never reached the fail-loud arm below it
# — probe ORDER was the only thing standing between this gate and the
# invariant its own header states. A tree that lost CHANGELOG.md is at least as
# broken as one that lost changelog.d/.
echo "31. no CHANGELOG.md and no .kernel-pin fails loudly"
D="$TMP/r31"; BASE="$(new_repo "$D")"
git -C "$D" rm -q CHANGELOG.md >/dev/null
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "lose CHANGELOG.md"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails loudly rather than skipping"
assert_has "$RUN_OUT" "no CHANGELOG.md at" "names the missing file"
assert_has "$RUN_OUT" ".kernel-pin" "names the discriminator"
assert_not_has "$RUN_OUT" "this tree keeps no changelog" "never reports the unconditional skip"

# ── 32. SKIP: no CHANGELOG.md but .kernel-pin present => actionable skip ────
# A tree that genuinely keeps no changelog is a VENDORING CONSUMER, and the pin
# is what says so. It keeps building green and is told which kernel's gate is
# running. `frag-pin` keeps changelog.d/ present so ONLY CHANGELOG.md is
# missing — the probe under test in isolation.
echo "32. a pinned consumer with no CHANGELOG.md gets an actionable skip"
D="$TMP/r32"; BASE="$(new_repo "$D" frag-pin)"
git -C "$D" rm -q CHANGELOG.md >/dev/null
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "a consumer that keeps no changelog"
run_gate "$D" "$BASE"
assert_status 0 "$RUN_STATUS" "skips instead of failing"
assert_has "$RUN_OUT" "skipped —" "the skip is legible, never silent"
assert_has "$RUN_OUT" "keeps no changelog" "says what is missing"
assert_has "$RUN_OUT" "v0.42.0" "names the pinned kernel release from .kernel-pin"

# ── 33. RED: a tree that lost BOTH files still fails on the first probe ─────
# The shape the review reproduced: no CHANGELOG.md, no changelog.d/, no pin.
# Both fail-loud arms apply; the first one reached must fire.
echo "33. a tree that lost both CHANGELOG.md and changelog.d/ fails"
D="$TMP/r33"; BASE="$(new_repo "$D" nofrag)"
git -C "$D" rm -q CHANGELOG.md >/dev/null
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "lose both"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails rather than skipping"
assert_has "$RUN_OUT" "FAIL —" "the failure is loud"

# ── 34. HELP: --help reaches the usage block ───────────────────────────────
# The header grew past the old fixed `2,20p` range, so --help printed 19 lines
# of rationale and NO usage and NO exit codes — while the kernel's own
# § Tool invocation discipline tells a caller to read exactly that block first.
# Anchored range, so the header can grow again without silently truncating it.
echo "34. --help prints the usage block and the exit codes"
HELP_OUT="$(bash "$SCRIPT" --help 2>&1)"; HELP_RC=$?
assert_status 0 "$HELP_RC" "exits 0"
assert_has "$HELP_OUT" "Usage:" "prints the usage line"
assert_has "$HELP_OUT" "check-changelog-entry.sh [--base REF] [--head REF]" "prints the invocation"
assert_has "$HELP_OUT" "Exit codes:" "prints the exit-code table"

echo
echo "test_check_changelog_entry: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
