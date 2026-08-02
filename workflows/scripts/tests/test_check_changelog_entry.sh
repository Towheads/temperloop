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
# Exercises:
#   1. RED   — contract surface changed, no [Unreleased] entry
#   2. GREEN — same change, entry added
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

# new_repo <dir> — a fixture checkout with VERSIONING.md + CHANGELOG.md + a
# couple of contract-surface files, all in one base commit. Echoes the base sha.
new_repo() {
  local d="$1"
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
  git -C "$d" add -A >/dev/null
  git -C "$d" commit -qm "base" >/dev/null
  git -C "$d" rev-parse HEAD
}

# run_gate <root> <base> [env assignments...] — run the script, capture stdout,
# stderr and exit status into RUN_OUT / RUN_STATUS.
run_gate() {
  local root="$1" base="$2"; shift 2
  RUN_OUT="$(env -u GITHUB_EVENT_NAME -u CHANGELOG_GATE_PR_BODY -u CHANGELOG_GATE_PR_LABELS \
    CHANGELOG_GATE_ROOT="$root" "$@" bash "$SCRIPT" --base "$base" 2>&1)"
  RUN_STATUS=$?
}

# ── 1. RED: contract surface changed, no [Unreleased] entry ─────────────────
echo "1. contract surface changed, no entry"
D="$TMP/r1"; BASE="$(new_repo "$D")"
echo "# build v2" > "$D/claude/commands/build.md"
git -C "$D" commit -aqm "tweak the build command spec"
run_gate "$D" "$BASE"
assert_status 1 "$RUN_STATUS" "fails the check"
assert_has "$RUN_OUT" "claude/commands/build.md" "names the touched contract-surface file"
assert_has "$RUN_OUT" "## [Unreleased]" "names the section to add to"
assert_has "$RUN_OUT" "no-changelog" "documents the opt-out label"

# ── 2. GREEN: same change with an entry ─────────────────────────────────────
echo "2. same change, [Unreleased] entry added"
D="$TMP/r2"; BASE="$(new_repo "$D")"
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
assert_status 0 "$RUN_STATUS" "passes"
assert_has "$RUN_OUT" "gained an entry" "reports the entry it found"

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
assert_status 1 "$RUN_STATUS" "fails — a heading with no bullet is not an entry"

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

echo
echo "test_check_changelog_entry: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
