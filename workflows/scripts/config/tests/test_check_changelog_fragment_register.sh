#!/usr/bin/env bash
#
# Tests for check-changelog-fragment-register.sh (temperloop#2136): a
# synthetic changelog.d/-shaped fixture directory proves the three RED
# paths (bare cross-repo shorthand, an un-hooked first issue mention, a
# named jargon token) and their matching GREEN paths (the same fragment
# with the offending text removed), plus the two degenerate-input guards
# (absent / unreadable directory fail loudly) and the vacuous-pass shape
# (an empty, but present and readable, directory is not a violation — the
# legitimate post-release-cut state).
#
# Mirrors the sibling test_check_setting_prose.sh's plain mktemp-fixture
# style: no git repo needed, the checker is pointed at a scratch directory
# via its one documented seam (CHANGELOG_FRAGMENT_DIR).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-changelog-fragment-register.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/changelog-fragment-register-test-XXXXXX")"
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

FRAGDIR="$WORK/changelog.d"
mkdir -p "$FRAGDIR"

run_checker() {
  CHANGELOG_FRAGMENT_DIR="$FRAGDIR" bash "$CHECKER"
}

write_frag() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"$FRAGDIR/$name"
}

clear_frags() {
  rm -f "$FRAGDIR"/*.md
}

# --- 1. GREEN: a well-formed fragment (bold lead-in, full `#N` form) -------
clear_frags
write_frag "1-good.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667). See
  temperloop#1667 for the detail."
out="$(run_checker 2>&1)" || fail "1: well-formed fragment should pass:
$out"
echo "PASS: 1 well-formed fragment passes (GREEN)"

# --- 2. RED: bare cross-repo shorthand (K<N>) -------------------------------
clear_frags
write_frag "2-shorthand.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667). See
  K1667 for detail."
out="$(run_checker 2>&1)" && fail "2: bare K<N> shorthand should fail:
$out"
case "$out" in
  *"2-shorthand.fixed.md"*"bare cross-repo shorthand"*) : ;;
  *) fail "2: expected a bare-shorthand REGISTER finding naming the file, got:
$out" ;;
esac
echo "PASS: 2 bare K<N> shorthand fails (RED)"

# --- 2b. GREEN twin: same fragment, full form instead of shorthand ---------
clear_frags
write_frag "2-shorthand.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667). See
  temperloop#1667 for detail."
out="$(run_checker 2>&1)" || fail "2b: full-form twin should pass (discrimination — removing the bad token restores GREEN):
$out"
echo "PASS: 2b full-form twin of 2 passes (GREEN — discrimination confirmed)"

# --- 3. RED: un-hooked first issue mention ----------------------------------
clear_frags
write_frag "3-unhooked.fixed.md" \
  "- (#1667). The reaper now cleans up orphaned sandboxes on every run."
out="$(run_checker 2>&1)" && fail "3: un-hooked first issue mention should fail:
$out"
case "$out" in
  *"3-unhooked.fixed.md"*"no title hook"*) : ;;
  *) fail "3: expected a no-title-hook REGISTER finding naming the file, got:
$out" ;;
esac
echo "PASS: 3 un-hooked first issue mention fails (RED)"

# --- 3b. GREEN twin: same fragment, bold lead-in added ---------------------
clear_frags
write_frag "3-unhooked.fixed.md" \
  "- **The sandbox reaper now cleans up on every run** (#1667)."
out="$(run_checker 2>&1)" || fail "3b: bold-lead-in twin should pass (discrimination — adding the hook restores GREEN):
$out"
echo "PASS: 3b hooked twin of 3 passes (GREEN — discrimination confirmed)"

# --- 4. RED: named jargon token (docs-reviewer.md's own examples) ---------
clear_frags
write_frag "4-jargon.fixed.md" \
  "- **Fixed a WIP cap edge case** (#1667). Also touches the checks gate."
out="$(run_checker 2>&1)" && fail "4: named jargon token should fail:
$out"
case "$out" in
  *"4-jargon.fixed.md"*"internal-jargon token"*) : ;;
  *) fail "4: expected an internal-jargon-token REGISTER finding naming the file, got:
$out" ;;
esac
echo "PASS: 4 named jargon token fails (RED)"

# --- 4b. GREEN twin: same fragment, jargon reworded -------------------------
clear_frags
write_frag "4-jargon.fixed.md" \
  "- **Fixed a work-in-progress-limit edge case** (#1667). Also touches the
  checks step of \`scripts/quality-gates.sh\`."
out="$(run_checker 2>&1)" || fail "4b: reworded twin should pass (discrimination — removing the jargon restores GREEN):
$out"
echo "PASS: 4b reworded twin of 4 passes (GREEN — discrimination confirmed)"

# --- 5. GREEN: a fragment with no issue reference at all (nothing to hook) -
clear_frags
write_frag "5-noref.added.md" \
  "- **\`stats.sh\` gained an \`exact-binom\` subcommand** — a two-sided exact
  confidence interval, computed directly rather than approximated."
out="$(run_checker 2>&1)" || fail "5: a fragment with no issue reference should pass (nothing to hook):
$out"
echo "PASS: 5 no-issue-reference fragment passes (GREEN)"

# --- 6. GREEN: an empty (but present, readable) directory is NOT a violation
# — the legitimate post-release-cut state (README.md's own #, dotfiles, and
# zero fragments are all normal, not degenerate).
clear_frags
out="$(run_checker 2>&1)" || fail "6: an empty fragment directory should pass vacuously:
$out"
case "$out" in
  *"0 changelog-fragment register violations across 0 fragment"*) : ;;
  *) fail "6: expected an explicit 0-checked pass line, got:
$out" ;;
esac
echo "PASS: 6 empty directory passes vacuously (GREEN)"

# --- 7. RED (degenerate input): absent directory ----------------------------
ABSENT_DIR="$WORK/does-not-exist"
if CHANGELOG_FRAGMENT_DIR="$ABSENT_DIR" bash "$CHECKER" >"$WORK/out7" 2>&1; then
  fail "7: absent fragment directory should fail, never a silent OK"
fi
echo "PASS: 7 absent fragment directory fails, never a silent OK (RED)"

# --- 8. RED (degenerate input): unreadable directory ------------------------
UNREADABLE_DIR="$WORK/unreadable"
mkdir -p "$UNREADABLE_DIR"
chmod 000 "$UNREADABLE_DIR"
rc=0
CHANGELOG_FRAGMENT_DIR="$UNREADABLE_DIR" bash "$CHECKER" >/dev/null 2>&1 || rc=$?
chmod u+rwX "$UNREADABLE_DIR"
if [ "$rc" -eq 0 ]; then
  fail "8: unreadable fragment directory should fail, never a silent OK"
fi
echo "PASS: 8 unreadable fragment directory fails, never a silent OK (RED)"

echo
echo "test_check_changelog_fragment_register: OK — all checks passed"
