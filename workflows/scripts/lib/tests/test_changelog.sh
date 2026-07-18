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
  if grep -qF "$needle" <<<"$haystack"; then
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

echo
echo "test_changelog.sh: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
