#!/usr/bin/env bash
#
# test_update_kernel.sh — unit tests for scripts/update-kernel.sh's
# breaking-delta gate (temperloop#89, follow-up to the versioning spike #79 /
# PR #88). Mirrors the env-override fixture style of the kernel-drift-check
# test (workflows/scripts/tests/test_kernel_drift_check.sh): every scenario
# runs against a synthetic throwaway repo dir under a tmpdir — never this
# repo's own .kernel-pin / CHANGELOG — with the gate's KERNEL_UPDATE_* seams
# pointed at fixtures and KERNEL_UPDATE_DRY_RUN=1 so no real subtree pull or
# network happens. The gate itself is what's under test.
#
# Usage: scripts/tests/test_update_kernel.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UPDATE_KERNEL="$REPO_ROOT/scripts/update-kernel.sh"

fail_count=0
pass_count=0

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok - $desc (exit $actual)"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected exit $expected, got $actual)"
    fail_count=$((fail_count + 1))
  fi
}

assert_output_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "  NOT OK - $desc (expected output to contain: $needle)"
    echo "    --- actual output ---"
    while IFS= read -r line; do echo "    $line"; done <<<"$haystack"
    fail_count=$((fail_count + 1))
  fi
}

assert_output_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if grep -qF "$needle" <<<"$haystack"; then
    echo "  NOT OK - $desc (expected output to NOT contain: $needle)"
    fail_count=$((fail_count + 1))
  else
    echo "  ok - $desc"
    pass_count=$((pass_count + 1))
  fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Fixture builder: a dir with a .kernel-pin (recording the current tag) and a
# CHANGELOG.md carrying a pre-1.0 BREAKING-marked section (0.3.0) plus an
# additive one (0.2.0) and a post-1.0 pair (1.2.0 additive, 2.0.0 no marker).
#
#   build_fixture <dir> <current-tag>
# ---------------------------------------------------------------------------
build_fixture() {
  local dir="$1" cur_tag="$2"
  rm -rf "$dir"
  mkdir -p "$dir"
  {
    echo "tag $cur_tag"
    echo "sha 0000000000000000000000000000000000dead"
  } > "$dir/.kernel-pin"
  cat > "$dir/CHANGELOG.md" <<'CHANGELOG_EOF'
# Changelog

## [Unreleased]

## [2.0.0] - 2026-08-01

### Changed

- Post-1.0 major bump with no BREAKING marker line; the major increment is
  itself the breaking signal post-1.0.

## [1.2.0] - 2026-07-20

### Added

- A purely additive capability, no marker.

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
CHANGELOG_EOF
}

run_gate() {
  # run_gate <fixture-dir> <target-tag> [extra env assignments...]
  local dir="$1" target="$2"; shift 2
  env -i PATH="$PATH" HOME="$HOME" \
    KERNEL_UPDATE_ROOT="$dir" \
    KERNEL_UPDATE_PIN_FILE="$dir/.kernel-pin" \
    KERNEL_UPDATE_CHANGELOG="$dir/CHANGELOG.md" \
    KERNEL_UPDATE_DRY_RUN=1 \
    KERNEL_UPDATE_ASSUME_TTY=0 \
    KERNEL_TAG="$target" \
    "$@" \
    bash "$UPDATE_KERNEL" 2>&1
}

# ---------------------------------------------------------------------------
# T1 — additive delta (v0.1.0 -> v0.2.0), unattended -> pulls unprompted, exit 0
# ---------------------------------------------------------------------------
echo "T1: additive delta (0.1.0 -> 0.2.0), unattended -> proceeds unprompted"
FIX="$TMP_ROOT/t1"; build_fixture "$FIX" v0.1.0
out="$(run_gate "$FIX" v0.2.0)"; rc=$?
assert_exit "T1 exits 0" 0 "$rc"
assert_output_contains "T1 reports additive/patch pull" "additive/patch delta" "$out"
assert_output_contains "T1 reaches the (dry-run) pull" "would pull kernel/" "$out"
assert_output_lacks "T1 does not flag breaking" "BREAKING delta detected" "$out"

# ---------------------------------------------------------------------------
# T2 — breaking delta (v0.1.0 -> v0.3.0, BREAKING-marked), unattended, no ack
#      -> REFUSES (exit 1) and prints the migration notes
# ---------------------------------------------------------------------------
echo "T2: breaking delta (0.1.0 -> 0.3.0), unattended, no ack -> REFUSES + migration notes"
FIX="$TMP_ROOT/t2"; build_fixture "$FIX" v0.1.0
out="$(run_gate "$FIX" v0.3.0)"; rc=$?
assert_exit "T2 exits 1 (refused)" 1 "$rc"
assert_output_contains "T2 flags breaking" "BREAKING delta detected" "$out"
assert_output_contains "T2 refuses unattended" "REFUSED" "$out"
assert_output_contains "T2 prints migration notes" "update every overlay caller" "$out"
assert_output_lacks "T2 does NOT pull" "would pull kernel/" "$out"

# ---------------------------------------------------------------------------
# T3 — same breaking delta WITH KERNEL_ALLOW_BREAKING=1 -> proceeds (exit 0),
#      still prints migration notes
# ---------------------------------------------------------------------------
echo "T3: breaking delta (0.1.0 -> 0.3.0) with KERNEL_ALLOW_BREAKING=1 -> proceeds"
FIX="$TMP_ROOT/t3"; build_fixture "$FIX" v0.1.0
out="$(run_gate "$FIX" v0.3.0 KERNEL_ALLOW_BREAKING=1)"; rc=$?
assert_exit "T3 exits 0 (acknowledged)" 0 "$rc"
assert_output_contains "T3 acknowledges" "breaking delta acknowledged" "$out"
assert_output_contains "T3 still prints migration notes" "update every overlay caller" "$out"
assert_output_contains "T3 reaches the (dry-run) pull" "would pull kernel/" "$out"

# ---------------------------------------------------------------------------
# T4 — post-1.0 major increment (v1.2.0 -> v2.0.0), NO BREAKING marker in the
#      2.0.0 section -> the major bump alone triggers the refusal, exit 1
# ---------------------------------------------------------------------------
echo "T4: post-1.0 major bump (1.2.0 -> 2.0.0), no marker -> REFUSES on major increment"
FIX="$TMP_ROOT/t4"; build_fixture "$FIX" v1.2.0
out="$(run_gate "$FIX" v2.0.0)"; rc=$?
assert_exit "T4 exits 1 (refused on major bump)" 1 "$rc"
assert_output_contains "T4 flags breaking" "BREAKING delta detected" "$out"
assert_output_contains "T4 notes the major increment" "major-version increment" "$out"

# ---------------------------------------------------------------------------
# T5 — patch/additive post-1.0 (v1.2.0 -> ... same-major additive) proceeds.
#      Use a target in the pre-1.0 additive band's sibling: 1.2.0 -> 1.2.0 is
#      idempotent; instead assert a same-major, in-range additive pulls. Here
#      1.2.0 -> 1.2.0 has empty range -> additive -> proceeds unprompted.
# ---------------------------------------------------------------------------
echo "T5: same-major, no BREAKING section in range (1.2.0 -> 1.2.0) -> proceeds"
FIX="$TMP_ROOT/t5"; build_fixture "$FIX" v1.2.0
out="$(run_gate "$FIX" v1.2.0)"; rc=$?
assert_exit "T5 exits 0" 0 "$rc"
assert_output_contains "T5 reports additive/patch pull" "additive/patch delta" "$out"
assert_output_lacks "T5 does not flag breaking" "BREAKING delta detected" "$out"

# ---------------------------------------------------------------------------
# T6 — first-time vendor (no pin tag) -> gate is a no-op, proceeds, exit 0
# ---------------------------------------------------------------------------
echo "T6: no current pin (first-time vendor) -> gate no-op, proceeds"
FIX="$TMP_ROOT/t6"; build_fixture "$FIX" v0.1.0
: > "$FIX/.kernel-pin"   # empty pin -> no current tag
out="$(run_gate "$FIX" v0.3.0)"; rc=$?
assert_exit "T6 exits 0 (no gate without a prior surface)" 0 "$rc"
assert_output_contains "T6 notes first-time vendor" "first-time vendor" "$out"
assert_output_lacks "T6 does not refuse" "REFUSED" "$out"

echo
echo "update-kernel tests: $pass_count passed, $fail_count failed"
if (( fail_count > 0 )); then
  exit 1
fi
exit 0
