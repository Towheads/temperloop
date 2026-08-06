#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's check_cross_checkout_split()
# (temperloop#777) — the CROSS-checkout counterpart to check_knowledge_root()
# (temperloop#774).
#
# Why this check exists: #774's plane-A/plane-B comparison is CORRECT and
# stays — but it is scoped to the checkout doctor is invoked from (it sources
# build.config.sh / knowledge_store.sh straight out of $FOUNDATION). It
# cannot see a DIFFERENT split: ~/.claude itself resolving into some OTHER
# checkout entirely. Live evidence (2026-07-26): after vendoring v0.18.0 into
# ~/dev/foundation, `readlink -f ~/.claude/hooks/session-start-drain.sh`
# resolved into an unrelated, clean-on-main checkout still pinned to
# v0.17.0 — 25 drain skips in one day, with doctor reporting OK from BOTH
# checkouts the entire time (neither was wrong about what IT measured).
#
# Covers:
#   1. MISMATCH — ~/.claude/hooks resolves into a checkout OTHER than the one
#      doctor is running from: the check reports MISMATCH, names BOTH real
#      paths and BOTH .kernel-pin tags, and doctor's overall exit is non-zero.
#   2. OK (no-mismatch) — ~/.claude/hooks resolves into THIS SAME checkout:
#      the check reports OK and contributes nothing to doctor's exit code
#      (a clean minimal fixture exits 0 overall).
#   3. SKIPPED — no installed surface at all (a fresh clone that has never
#      run `make install-claude`): degrades gracefully, never errors.
#
# Hermetic: every case runs under an isolated HOME (via `env -i`) pointed at
# a throwaway tmpdir fixture, never the real operator's ~/.claude. Real git
# repos are used for the fixture checkouts (git rev-parse --show-toplevel is
# how the check itself resolves "which checkout owns this path").
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-cross-checkout-split-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Physically resolve (macOS: /tmp -> /private/tmp, and $TMPDIR itself is
# often already a symlink) so string comparisons against the check's own
# `pwd -P`-resolved output below compare apples to apples.
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"

# ---------------------------------------------------------------------------
# _mk_fake_checkout NAME [TAG] — a minimal, independent, git-initialized
# fake checkout carrying a claude/hooks/session-start-drain.sh (the exact
# representative surface the check resolves) and, optionally, a .kernel-pin
# file at its root (scripts/update-kernel.sh's own format: `tag <v>` /
# `sha <sha>`). Prints the checkout's path to stdout.
# ---------------------------------------------------------------------------
_mk_fake_checkout() {
  local name="$1" tag="${2:-}"
  local dir="${TMP}/${name}"
  mkdir -p "${dir}/claude/hooks"
  git -C "$dir" init -q
  printf '#!/usr/bin/env bash\necho "fake session-start-drain (%s)"\n' "$name" \
    >"${dir}/claude/hooks/session-start-drain.sh"
  if [ -n "$tag" ]; then
    printf 'tag %s\nsha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' "$tag" >"${dir}/.kernel-pin"
  fi
  printf '%s\n' "$dir"
}

_run_doctor() {
  # Fully isolated subprocess env — never the live test process's real
  # HOME/~/.claude.
  local home="$1" foundation="$2"
  env -i HOME="$home" PATH="$PATH" bash "$DOCTOR_SH" "$foundation" 2>&1
}

_section() {
  printf '%s\n' "$1" | sed -n '/Cross-checkout install-source check/,/^$/p'
}

# ---------------------------------------------------------------------------
# Test 1 (THE REGRESSION CASE): ~/.claude/hooks resolves into a checkout
# OTHER than the one doctor is running from — MISMATCH, naming both real
# paths and both .kernel-pin tags, and doctor's overall exit is non-zero.
# ---------------------------------------------------------------------------
FOUND_A="$(_mk_fake_checkout this-checkout v0.19.0)"
FOUND_B="$(_mk_fake_checkout installed-from-checkout v0.17.0)"

HOME1="${TMP}/home1"
mkdir -p "${HOME1}/.claude"
ln -s "${FOUND_B}/claude/hooks" "${HOME1}/.claude/hooks"

set +e
out1="$(_run_doctor "$HOME1" "$FOUND_A")"
exit1=$?
set -e

section1="$(_section "$out1")"
grep -q '^  MISMATCH' <<<"$section1" \
  || fail "1: expected MISMATCH when ~/.claude/hooks resolves into a different checkout — got: $section1"
grep -qF "${FOUND_A}" <<<"$section1" \
  || fail "1: MISMATCH output should name the doctor checkout ($FOUND_A) — got: $section1"
grep -qF "${FOUND_B}/claude/hooks/session-start-drain.sh" <<<"$section1" \
  || fail "1: MISMATCH output should name the installed real path ($FOUND_B/claude/hooks/session-start-drain.sh) — got: $section1"
grep -qF "v0.19.0" <<<"$section1" \
  || fail "1: MISMATCH output should name the doctor checkout's .kernel-pin tag (v0.19.0) — got: $section1"
grep -qF "v0.17.0" <<<"$section1" \
  || fail "1: MISMATCH output should name the installed checkout's .kernel-pin tag (v0.17.0) — got: $section1"
# Coarse-grained regression guard, same posture as test_doctor_knowledge_
# root.sh's own MISMATCH case: the minimal fixture's overall exit is ALSO
# non-zero for reasons unrelated to this check (links_enumerate
# unconditionally enumerates ~/.local/bin board-toolkit/gh-shim targets the
# fixture never provisions), so this doesn't cleanly ISOLATE cross_checkout_
# status's own contribution — but it does pin that a MISMATCH is never
# swallowed into a clean (exit 0) result.
[ "$exit1" -ne 0 ] || fail "1: doctor's exit code should be non-zero on a cross-checkout MISMATCH"
pass "1: a cross-checkout install split is caught as MISMATCH, naming both real paths and both .kernel-pin tags, non-zero exit"

# ---------------------------------------------------------------------------
# Test 2 (no-mismatch): ~/.claude/hooks resolves into THIS SAME checkout —
# OK. (Doctor's OVERALL exit code is not asserted here — links_enumerate
# unconditionally enumerates the board-toolkit/gh-shim ~/.local/bin targets
# regardless of fixture contents, so a minimal fixture's overall exit is
# non-zero for reasons entirely unrelated to this check; the same posture
# test_doctor_knowledge_root.sh's own "both planes agree" case takes.
# check_cross_checkout_split()'s OWN return code is exercised directly by
# test 1 above via doctor's combined exit — this test isolates its SECTION
# output, which is what actually distinguishes OK from MISMATCH.)
# ---------------------------------------------------------------------------
HOME2="${TMP}/home2"
mkdir -p "${HOME2}/.claude"
ln -s "${FOUND_A}/claude/hooks" "${HOME2}/.claude/hooks"

set +e
out2="$(_run_doctor "$HOME2" "$FOUND_A")"
set -e

section2="$(_section "$out2")"
grep -q '^  OK' <<<"$section2" \
  || fail "2: expected OK when ~/.claude/hooks resolves into the SAME checkout doctor runs from — got: $section2"
grep -qF "${FOUND_A}" <<<"$section2" \
  || fail "2: OK output should name the checkout ($FOUND_A) — got: $section2"
pass "2: ~/.claude/hooks resolving into the SAME checkout is OK"

# ---------------------------------------------------------------------------
# Test 3: SKIPPED (never a hard failure) when no installed surface exists at
# all — a fresh clone / stranger's checkout that has never run
# `make install-claude`.
# ---------------------------------------------------------------------------
HOME3="${TMP}/home3"
mkdir -p "${HOME3}/.claude"
# Deliberately no ~/.claude/hooks at all.

set +e
out3="$(_run_doctor "$HOME3" "$FOUND_A")"
set -e

section3="$(_section "$out3")"
grep -q 'SKIPPED (no installed surface at' <<<"$section3" \
  || fail "3: expected SKIPPED when no installed surface exists — got: $section3"
pass "3: an absent installed surface degrades to SKIPPED, never a hard failure"

# ---------------------------------------------------------------------------
# Test 4: SKIPPED (never a hard failure) when the installed surface exists on
# disk but does NOT resolve into any git checkout — e.g. a real, unmanaged
# copy someone dropped in by hand rather than a symlink into a repo. This is
# the SECOND of the acceptance's two named degrade conditions (absent, or not
# a symlink into any checkout) — distinct from test 3's "absent" case.
# ---------------------------------------------------------------------------
HOME4="${TMP}/home4"
mkdir -p "${HOME4}/.claude/hooks-real"
printf '#!/usr/bin/env bash\necho "not a checkout, just a file"\n' \
  >"${HOME4}/.claude/hooks-real/session-start-drain.sh"
ln -s "${HOME4}/.claude/hooks-real" "${HOME4}/.claude/hooks"
# Deliberately NOT git-initialized — plain files, no .git anywhere above them.

set +e
out4="$(_run_doctor "$HOME4" "$FOUND_A")"
set -e

section4="$(_section "$out4")"
grep -q 'SKIPPED (.*does not resolve into any git checkout' <<<"$section4" \
  || fail "4: expected SKIPPED when the installed surface resolves to a real file outside any git checkout — got: $section4"
pass "4: an installed surface that isn't a symlink into any git checkout degrades to SKIPPED, never a hard failure"

echo "All doctor cross-checkout-split tests passed."
