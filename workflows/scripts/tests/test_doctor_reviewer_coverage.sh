#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's check_reviewer_coverage()
# (temperloop#550, ADR 0007/0008) — the advisory WARN/INFO reviewer-
# activation-coverage check, reusing #548's non-interactive data path
# (reviewer-activation-coverage.sh) and NEVER #549's interactive
# reviewer-activate.sh.
#
# Covers:
#   1. A catalogued, unactivated reviewer language at/above
#      REVIEWER_SCAN_MIN_FILES emits a WARN line.
#   2. The WARN never touches doctor's own `non_ok` tally or exit code —
#      proven differentially: the SAME fixture tree, before vs. after
#      crossing the activation-gap threshold, yields an IDENTICAL
#      "Non-OK: N" count and exit code; only the reviewer-coverage section
#      differs.
#   3. A durably-declined language (a decline marker under
#      .claude/reviewer-state/declined/<name>) yields neither WARN nor INFO,
#      while an unrelated still-unresolved gap keeps warning.
#   4. An "uncatalogued" language — a reviewer-routing.tsv row whose
#      catalog-agent-path is DANGLING (per #548's
#      reviewer_coverage_check_integrity()) — yields a ONE-TIME INFO: present
#      on the first run, silent on an immediate second run against the same
#      (now-notified) checkout, with an unchanged exit code across both.
#   5. The check appears unconditionally in `make doctor` output (the
#      activation proof's own shape: `grep -qi 'reviewer cover'`).
#
# No network. No real HOME/FOUNDATION mutation — every case uses a
# throwaway, git-initialized tmpdir fixture (git-initialized because the
# one-time INFO state write requires confirming a real gitignore, per
# doctor.sh's own "degrade to read-only when unconfirmed" contract).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"
RAC_SH_REAL="${REPO_ROOT}/workflows/scripts/install/reviewer-activation-coverage.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-reviewer-coverage-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"
[ -f "$RAC_SH_REAL" ] || fail "0: reviewer-activation-coverage.sh not found at $RAC_SH_REAL"

# ---------------------------------------------------------------------------
# _mk_fake_found NAME — builds a minimal, independent, git-initialized fake
# FOUNDATION tree at $TMP/NAME carrying: a real copy of #548's
# reviewer-activation-coverage.sh (REUSED, never re-implemented), a
# 2-row reviewer-routing.tsv (.py -> python-reviewer, .sh -> shell-reviewer),
# and both catalog reviewer files present (so integrity passes by default —
# tests that want a DANGLING row remove one). No env/claude/board scaffolding
# is included: links_enumerate will therefore report several MISSING
# entries and doctor will exit non-zero on this fixture BEFORE any reviewer
# fixture files are added — that pre-existing non-zero is not under test;
# what's under test is that it never CHANGES because of the reviewer check.
# Prints the path to stdout.
# ---------------------------------------------------------------------------
_mk_fake_found() {
  local name="$1"
  local dir="${TMP}/${name}"
  mkdir -p \
    "${dir}/workflows/scripts/install" \
    "${dir}/workflows/scripts/config" \
    "${dir}/claude/agents/reviewers"

  git -C "$dir" init -q
  git -C "$dir" config user.email test@test
  git -C "$dir" config user.name test

  cp "$RAC_SH_REAL" "${dir}/workflows/scripts/install/reviewer-activation-coverage.sh"
  chmod +x "${dir}/workflows/scripts/install/reviewer-activation-coverage.sh"

  {
    printf '.py\tpython-reviewer\tclaude/agents/reviewers/python-reviewer.md\n'
    printf '.sh\tshell-reviewer\tclaude/agents/reviewers/shell-reviewer.md\n'
  } >"${dir}/workflows/scripts/config/reviewer-routing.tsv"

  echo '# python-reviewer (fixture placeholder)' >"${dir}/claude/agents/reviewers/python-reviewer.md"
  echo '# shell-reviewer (fixture placeholder)' >"${dir}/claude/agents/reviewers/shell-reviewer.md"

  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Tests 1 + 2: WARN emission + exit-code/non_ok isolation, proven
# differentially on the SAME tree before/after crossing threshold.
# ---------------------------------------------------------------------------
FOUND1="$(_mk_fake_found found1)"

set +e
out_before="$(bash "$DOCTOR_SH" "$FOUND1" 2>&1)"
exit_before=$?
set -e

printf '%s\n' "$out_before" | grep -qi 'reviewer cover' \
  || fail "5: doctor output missing a 'reviewer cover' section (activation-proof shape) — got: $out_before"

printf '%s\n' "$out_before" | grep -q 'no resolvable reviewer-activation gaps' \
  || fail "1a: below-threshold fixture should report no gaps yet — got: $out_before"
if printf '%s\n' "$out_before" | grep -q 'WARN.*python-reviewer'; then
  fail "1a: python-reviewer should not warn below threshold — got: $out_before"
fi

nonok_before="$(printf '%s\n' "$out_before" | grep -oE 'Non-OK: [0-9]+')"
[ -n "$nonok_before" ] || fail "1: could not parse a 'Non-OK: N' line from doctor output — got: $out_before"

pass "5: doctor output includes a 'reviewer cover' section (satisfies the activation proof)"
pass "1a: below REVIEWER_SCAN_MIN_FILES, no gap is reported"

# Cross the threshold: 3 .py files (python: 0 -> 3) and 2 more .sh files
# (shell already has 1 — the copied reviewer-activation-coverage.sh itself —
# so +2 brings it to 3). Placed under an arbitrary subdir links_enumerate
# never inspects, so this cannot perturb the non-reviewer classification.
mkdir -p "${FOUND1}/src"
for i in 1 2 3; do
  echo 'print("hi")' >"${FOUND1}/src/mod${i}.py"
done
for i in 1 2; do
  echo '#!/usr/bin/env bash' >"${FOUND1}/src/script${i}.sh"
done

set +e
out_after="$(bash "$DOCTOR_SH" "$FOUND1" 2>&1)"
exit_after=$?
set -e

printf '%s\n' "$out_after" | grep -q 'WARN.*python-reviewer' \
  || fail "1b: python-reviewer should warn at/above threshold — got: $out_after"
printf '%s\n' "$out_after" | grep -q 'WARN.*shell-reviewer' \
  || fail "1b: shell-reviewer should warn at/above threshold — got: $out_after"

pass "1b: at/above REVIEWER_SCAN_MIN_FILES, catalogued unactivated reviewers WARN"

nonok_after="$(printf '%s\n' "$out_after" | grep -oE 'Non-OK: [0-9]+')"
[ "$nonok_before" = "$nonok_after" ] \
  || fail "2: Non-OK tally changed from '$nonok_before' to '$nonok_after' just by adding a reviewer WARN — the WARN must never touch non_ok"
[ "$exit_before" -eq "$exit_after" ] \
  || fail "2: doctor's exit code changed from $exit_before to $exit_after just by adding a reviewer WARN"

pass "2: the WARN increments no tally but its own — non_ok and doctor's exit code are unchanged by it (bullet 3/4)"

# ---------------------------------------------------------------------------
# Test 3: a durably-declined language yields neither WARN nor INFO, while an
# unrelated still-open gap keeps warning.
# ---------------------------------------------------------------------------
mkdir -p "${FOUND1}/.claude/reviewer-state/declined"
touch "${FOUND1}/.claude/reviewer-state/declined/python-reviewer"

set +e
out_declined="$(bash "$DOCTOR_SH" "$FOUND1" 2>&1)"
set -e
if printf '%s\n' "$out_declined" | grep -q 'python-reviewer'; then
  fail "3: a durably-declined python-reviewer should not appear at all (WARN or INFO) — got: $out_declined"
fi
printf '%s\n' "$out_declined" | grep -q 'WARN.*shell-reviewer' \
  || fail "3: shell-reviewer (still an open, non-declined gap) should still WARN — got: $out_declined"

pass "3: a durably-declined language yields neither WARN nor INFO; an unrelated open gap still warns"

# ---------------------------------------------------------------------------
# Test 4: an uncatalogued language (DANGLING catalog-agent-path) yields a
# ONE-TIME INFO — present on the first run, silent on the second.
# ---------------------------------------------------------------------------
FOUND2="$(_mk_fake_found found2)"
# Add a routing row whose catalog-agent-path does not exist on disk.
printf '.zz\tzz-reviewer\tclaude/agents/reviewers/does-not-exist-zz.md\n' \
  >>"${FOUND2}/workflows/scripts/config/reviewer-routing.tsv"

set +e
out_info1="$(bash "$DOCTOR_SH" "$FOUND2" 2>&1)"
exit_info1=$?
set -e

printf '%s\n' "$out_info1" | grep -qi 'INFO.*uncatalogued' \
  || fail "4a: first run should show a one-time INFO for the uncatalogued (dangling) language — got: $out_info1"
printf '%s\n' "$out_info1" | grep -q 'does-not-exist-zz.md' \
  || fail "4a: the INFO should name the dangling catalog-agent-path — got: $out_info1"

[ -e "${FOUND2}/.claude/reviewer-state/doctor-uncatalogued-notified" ] \
  || fail "4a: expected a one-time notice marker under the gitignored reviewer-state dir"
git -C "$FOUND2" check-ignore -q -- ".claude/reviewer-state/doctor-uncatalogued-notified" \
  || fail "4a: the notice marker path must resolve gitignored (git check-ignore) after the write"

pass "4a: first run prints a one-time INFO for an uncatalogued (dangling) language and persists a gitignored marker"

set +e
out_info2="$(bash "$DOCTOR_SH" "$FOUND2" 2>&1)"
exit_info2=$?
set -e

if printf '%s\n' "$out_info2" | grep -qi 'INFO.*uncatalogued'; then
  fail "4b: second run should be silent (one-time INFO already shown) — got: $out_info2"
fi

[ "$exit_info1" -eq "$exit_info2" ] \
  || fail "4b: doctor's exit code changed ($exit_info1 -> $exit_info2) between the notified and silent runs"

pass "4b: second run is silent (one-time INFO already recorded); exit code unchanged across both runs"

# ---------------------------------------------------------------------------
# Test 5 (regression, temperloop#550 install-surface persona finding, HIGH):
# a pre-existing, team-shared .gitignore with NO trailing newline must not be
# corrupted by the gitignore-safety append. Before the fix, appending
# '.claude/reviewer-state/' onto a file ending "...*.pyc" (no final newline)
# glued the two lines into '*.pyc.claude/reviewer-state/', silently breaking
# the teammate's existing *.pyc rule AND failing to add the new entry.
# ---------------------------------------------------------------------------
FOUND3="$(_mk_fake_found found3)"
printf '.zz\tzz-reviewer\tclaude/agents/reviewers/does-not-exist-zz.md\n' \
  >>"${FOUND3}/workflows/scripts/config/reviewer-routing.tsv"

# A pre-existing, team-authored .gitignore with a real rule and deliberately
# NO trailing newline (the exact shape that glued before the fix).
printf '*.pyc' >"${FOUND3}/.gitignore"
touch "${FOUND3}/stray.pyc"
git -C "$FOUND3" check-ignore -q -- stray.pyc \
  || fail "5: pre-check sanity — fixture's own *.pyc rule should already ignore stray.pyc before doctor ever runs"

set +e
out_regress="$(bash "$DOCTOR_SH" "$FOUND3" 2>&1)"
set -e

printf '%s\n' "$out_regress" | grep -q "added '.claude/reviewer-state/'" \
  || fail "5: expected a console notice naming the .gitignore write — got: $out_regress"

git -C "$FOUND3" check-ignore -q -- stray.pyc \
  || fail "5: the pre-existing *.pyc rule was corrupted by the gitignore append (newline-glue regression)"
git -C "$FOUND3" check-ignore -q -- ".claude/reviewer-state/anything" \
  || fail "5: .claude/reviewer-state/ is not correctly ignored after the append"

grep -qx '\*.pyc' "${FOUND3}/.gitignore" \
  || fail "5: '*.pyc' should still be its own exact line in .gitignore (got: $(cat "${FOUND3}/.gitignore"))"
grep -qx '.claude/reviewer-state/' "${FOUND3}/.gitignore" \
  || fail "5: '.claude/reviewer-state/' should be its own exact line in .gitignore (got: $(cat "${FOUND3}/.gitignore"))"

pass "5: appending to a .gitignore with no trailing newline preserves the pre-existing rule and adds the new one cleanly (no line-gluing)"

echo
echo "All doctor reviewer-coverage tests passed."
