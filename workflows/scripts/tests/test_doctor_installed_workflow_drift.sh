#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's
# check_installed_workflow_drift() (temperloop#1397) — the CONTENT
# counterpart to classify_entry()'s target-string comparison and to
# check_cross_checkout_split()'s path-identity comparison.
#
# WHY THIS CHECK EXISTS. /build Step 3, /sweep Step 0.3 and /fix Step 3 all
# invoke the orchestrator by scriptPath at "$HOME/.claude/workflows/
# build-level.mjs" — the INSTALLED copy, not the checkout's. Two live
# reproductions: 2026-08-10 (installed 153,468 bytes dated Aug 7 vs a repo
# copy of 169,056) and 2026-08-21 (installed 204,139 dated Aug 15 vs a repo
# copy of 212,478 dated Aug 21 — an entire overnight run executed a six-day-
# stale orchestrator, including the batches that merged temperloop#1587's
# escalation-payload fix, whose payloads then still showed the pre-fix
# contradiction). Nothing on any surface reported it; both times it was
# noticed only because a session happened to diff the two by hand.
#
# Covers (the discrimination set the acceptance names):
#   1. IN SYNC   — byte-identical copies report OK and nothing else.
#   2. DRIFT (installed STALE) — differing copies report DRIFT, print BOTH
#                  sizes, BOTH mtimes and TWO DISTINCT sha256 digests, name
#                  the REPO copy as newer, and drive doctor's exit non-zero.
#   2b. READ-ONLY — that DRIFT run leaves the installed copy byte-for-byte
#                  untouched (the scope bar: detect and report, never
#                  auto-install into ~/.claude).
#   3. DRIFT (installed NEWER) — the mirror direction is reported as such,
#                  not collapsed into one undirected "they differ".
#   4. ABSENT    — no installed copy at all: its OWN outcome token, never
#                  DRIFT and never OK.
#   5. UNKNOWN   — the installed path exists but cannot be compared (a
#                  dangling symlink): indeterminate, reported as neither
#                  drift nor clean, and non-zero (temperloop#1409/#1476 —
#                  a check that could not run must not report success).
#   6. SKIPPED   — the checkout ships no claude/workflows/*.mjs at all.
#   7. NOT ONE-FILE — every *.mjs is compared, not just build-level.mjs.
#
# Hermetic: every case runs the real doctor.sh under an isolated HOME (via
# `env -i`) pointed at a throwaway tmpdir fixture, never the operator's real
# ~/.claude. Same posture as test_doctor_cross_checkout_split.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-installed-workflow-drift-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Physically resolve (macOS: /tmp -> /private/tmp, and $TMPDIR itself is often
# already a symlink) so string comparisons against the check's own `pwd -P`
# resolved output compare apples to apples.
TMP="$(cd "$TMP" && pwd -P)"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ] || fail "0: doctor.sh not found at $DOCTOR_SH"

# ---------------------------------------------------------------------------
# _mk_checkout NAME — a minimal fake kernel checkout carrying exactly the one
# surface this check reads: a claude/workflows/ directory. Prints its path.
# ---------------------------------------------------------------------------
_mk_checkout() {
  local dir="${TMP}/$1"
  mkdir -p "${dir}/claude/workflows"
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# _run_doctor HOME FOUNDATION — runs the real doctor.sh in a fully isolated
# subprocess env. Sets DOCTOR_OUT (combined output) and DOCTOR_EXIT.
#
# Deliberately NOT `out="$(_run_doctor ...)"`: doctor exits non-zero on these
# minimal fixtures for reasons unrelated to this check (links_enumerate
# unconditionally enumerates ~/.local/bin targets no fixture provisions), and
# a command substitution that inherits `set -e` would abort the suite before
# a single assertion ran.
# ---------------------------------------------------------------------------
DOCTOR_OUT=""
DOCTOR_EXIT=0
_run_doctor() {
  local home="$1" foundation="$2" log="${TMP}/doctor.out"
  set +e
  env -i HOME="$home" PATH="$PATH" bash "$DOCTOR_SH" "$foundation" >"$log" 2>&1
  DOCTOR_EXIT=$?
  set -e
  DOCTOR_OUT="$(cat "$log")"
}

# Slice out just this check's section (from its header line to the blank line
# that ends it) so an assertion can never accidentally match another check.
_section() {
  printf '%s\n' "$DOCTOR_OUT" | sed -n '/Installed build-workflow content check/,/^$/p'
}

# has PATTERN -> rc 0 iff the section matches (ERE). Written as a function so
# a NEGATIVE assertion can be `if has ...; then fail ...; fi` — a bare
# `grep -q ... && fail` is unsafe under `set -e`: when grep does NOT match
# (which is the PASSING case for a negative assertion) the AND-list returns
# non-zero and the suite aborts having asserted nothing.
has() { grep -qE "$1" <<<"$SECTION"; }

# ---------------------------------------------------------------------------
# Case 1 (CLEAN): identical copies -> OK, and no other outcome token.
# ---------------------------------------------------------------------------
F1="$(_mk_checkout c1)"
H1="${TMP}/home1"; mkdir -p "${H1}/.claude/workflows"
printf '// build-level orchestrator\nconst gateVerdict = 1;\n' >"${F1}/claude/workflows/build-level.mjs"
cp "${F1}/claude/workflows/build-level.mjs" "${H1}/.claude/workflows/build-level.mjs"

_run_doctor "$H1" "$F1"
SECTION="$(_section)"
has '^  OK ' || fail "1: identical copies should report OK — got: $SECTION"
has 'byte-identical' || fail "1: OK line should say the copies are byte-identical — got: $SECTION"
if has '^  (DRIFT|ABSENT|UNKNOWN)'; then
  fail "1: identical copies must NOT report DRIFT/ABSENT/UNKNOWN — got: $SECTION"
fi
pass "1: identical installed and repo copies report OK (clean)"

# ---------------------------------------------------------------------------
# Case 2 (THE REGRESSION CASE — installed copy STALE): drifted copies report
# DRIFT, print BOTH sizes / BOTH mtimes / TWO DISTINCT sha256 digests, name
# the REPO copy as the newer one, and doctor exits non-zero.
#
# Timestamps are set at MIDDAY, not midnight: `env -i` drops TZ, so the
# check's own rendering may land in a different zone than `touch`'s local
# interpretation, and a midnight stamp could cross a date boundary.
# ---------------------------------------------------------------------------
F2="$(_mk_checkout c2)"
H2="${TMP}/home2"; mkdir -p "${H2}/.claude/workflows"
# The installed copy is the SMALLER, OLDER one — the live 2026-08-21 shape.
printf '// stale orchestrator, no gateVerdict\n' >"${H2}/.claude/workflows/build-level.mjs"
printf '// current orchestrator\nconst gateVerdict = 1;\n// plus six more days of machinery\n' \
  >"${F2}/claude/workflows/build-level.mjs"
touch -t 202608151200 "${H2}/.claude/workflows/build-level.mjs"
touch -t 202608211200 "${F2}/claude/workflows/build-level.mjs"

INSTALLED_SIZE_2="$(wc -c <"${H2}/.claude/workflows/build-level.mjs" | tr -d ' ')"
REPO_SIZE_2="$(wc -c <"${F2}/claude/workflows/build-level.mjs" | tr -d ' ')"

_run_doctor "$H2" "$F2"
SECTION="$(_section)"
EXIT2="$DOCTOR_EXIT"

has '^  DRIFT ' || fail "2: differing copies should report DRIFT — got: $SECTION"
has "(^|[^0-9])${INSTALLED_SIZE_2}([^0-9]|$)" \
  || fail "2: DRIFT report should name the installed copy size ($INSTALLED_SIZE_2) — got: $SECTION"
has "(^|[^0-9])${REPO_SIZE_2}([^0-9]|$)" \
  || fail "2: DRIFT report should name the repo copy size ($REPO_SIZE_2) — got: $SECTION"
has '2026-08-15' || fail "2: DRIFT report should name the installed copy mtime (2026-08-15) — got: $SECTION"
has '2026-08-21' || fail "2: DRIFT report should name the repo copy mtime (2026-08-21) — got: $SECTION"
# BOTH digests, and they must actually DIFFER — a report that printed one
# digest twice would look identical to a reader skimming it.
DIGESTS_2="$( { grep -oE 'sha256 [0-9a-f]{64}' <<<"$SECTION" || true; } | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
[ "$DIGESTS_2" = "2" ] \
  || fail "2: DRIFT report should print TWO DISTINCT sha256 digests, got $DIGESTS_2 — $SECTION"
has 'NEWER: the REPO copy' \
  || fail "2: DRIFT report must name WHICH side is newer (the repo copy) — got: $SECTION"
has 'STALE' || fail "2: DRIFT report should call the installed copy stale — got: $SECTION"
# Coarse-grained regression guard, same posture as the sibling doctor tests:
# the minimal fixture's overall exit is ALSO non-zero for unrelated reasons
# (links_enumerate unconditionally enumerates ~/.local/bin targets the fixture
# never provisions), so this does not ISOLATE this check's contribution — but
# it does pin that DRIFT is never swallowed into a clean (exit 0) result.
[ "$EXIT2" -ne 0 ] || fail "2: doctor's exit code should be non-zero on workflow content DRIFT"
pass "2: a stale installed copy is caught as DRIFT, naming both sizes/mtimes/digests and which is newer, non-zero exit"

# ---------------------------------------------------------------------------
# Case 2b (READ-ONLY, the scope bar): the DRIFT run above must not have
# written to the fixture HOME. Detect and report — never auto-install.
# ---------------------------------------------------------------------------
[ "$(wc -c <"${H2}/.claude/workflows/build-level.mjs" | tr -d ' ')" = "$INSTALLED_SIZE_2" ] \
  || fail "2b: the check must never write to ~/.claude — the installed copy changed size"
has 'never writes to' \
  || fail "2b: DRIFT report should state that it only reports and never writes — got: $SECTION"
pass "2b: a DRIFT run leaves the installed copy untouched and says so"

# ---------------------------------------------------------------------------
# Case 3 (MIRROR DIRECTION — installed copy NEWER): the report must name the
# installed side as newer, not collapse both directions into "they differ".
# ---------------------------------------------------------------------------
F3="$(_mk_checkout c3)"
H3="${TMP}/home3"; mkdir -p "${H3}/.claude/workflows"
printf '// newer installed orchestrator\nconst gateVerdict = 1;\n' >"${H3}/.claude/workflows/build-level.mjs"
printf '// older repo copy\n' >"${F3}/claude/workflows/build-level.mjs"
touch -t 202608211200 "${H3}/.claude/workflows/build-level.mjs"
touch -t 202608151200 "${F3}/claude/workflows/build-level.mjs"

_run_doctor "$H3" "$F3"
SECTION="$(_section)"
has '^  DRIFT ' || fail "3: differing copies should report DRIFT — got: $SECTION"
has 'NEWER: the INSTALLED copy' \
  || fail "3: the mirror direction must be named as the INSTALLED copy being newer — got: $SECTION"
if has 'NEWER: the REPO copy'; then
  fail "3: must not claim the repo copy is newer when it is older — got: $SECTION"
fi
pass "3: the mirror drift direction is reported as installed-newer, not an undirected difference"

# ---------------------------------------------------------------------------
# Case 4 (ABSENT — the absence-vs-indeterminacy split, temperloop#1591/#1523):
# no installed copy at all is its OWN outcome. Not DRIFT, not OK.
# ---------------------------------------------------------------------------
F4="$(_mk_checkout c4)"
H4="${TMP}/home4"; mkdir -p "${H4}/.claude"
printf '// current orchestrator\n' >"${F4}/claude/workflows/build-level.mjs"

_run_doctor "$H4" "$F4"
SECTION="$(_section)"
has '^  ABSENT ' || fail "4: an absent installed copy should report ABSENT — got: $SECTION"
if has '^  (DRIFT|OK|UNKNOWN)'; then
  fail "4: ABSENT must not also read as DRIFT, OK or UNKNOWN — got: $SECTION"
fi
has 'NOT drift' || fail "4: the ABSENT line should say explicitly that it is not drift — got: $SECTION"
has 'NOT an in-sync result' \
  || fail "4: the ABSENT line should say explicitly that it is not a clean result — got: $SECTION"
pass "4: an absent installed copy is its own outcome — neither drift nor clean"

# ---------------------------------------------------------------------------
# Case 5 (UNKNOWN — indeterminate, never clean): the installed path exists as
# a DANGLING symlink. The check ran but could not evaluate, so it must not
# report success (temperloop#1409/#1476).
# ---------------------------------------------------------------------------
F5="$(_mk_checkout c5)"
H5="${TMP}/home5"; mkdir -p "${H5}/.claude/workflows"
printf '// current orchestrator\n' >"${F5}/claude/workflows/build-level.mjs"
ln -s "${TMP}/nonexistent-target.mjs" "${H5}/.claude/workflows/build-level.mjs"

_run_doctor "$H5" "$F5"
SECTION="$(_section)"
has '^  UNKNOWN ' || fail "5: a dangling installed symlink should report UNKNOWN — got: $SECTION"
has 'dangling symlink' || fail "5: the UNKNOWN line should name WHY it could not evaluate — got: $SECTION"
if has '^  (DRIFT|OK|ABSENT)'; then
  fail "5: UNKNOWN must not also read as DRIFT, OK or ABSENT — got: $SECTION"
fi
[ "$DOCTOR_EXIT" -ne 0 ] || fail "5: an indeterminate comparison must not exit 0"
pass "5: an uncomparable installed copy reports UNKNOWN — indeterminate, never clean"

# ---------------------------------------------------------------------------
# Case 6 (SKIPPED): a checkout that ships no claude/workflows/*.mjs has
# nothing to compare AGAINST — degrade legibly, never error.
# ---------------------------------------------------------------------------
F6="$(_mk_checkout c6)"
H6="${TMP}/home6"; mkdir -p "${H6}/.claude/workflows"
printf '// an installed copy with no repo counterpart\n' >"${H6}/.claude/workflows/build-level.mjs"

_run_doctor "$H6" "$F6"
SECTION="$(_section)"
has '^  SKIPPED ' \
  || fail "6: a checkout with no claude/workflows/*.mjs should report SKIPPED — got: $SECTION"
if has '^  (DRIFT|OK|ABSENT|UNKNOWN)'; then
  fail "6: SKIPPED must not also read as any comparison outcome — got: $SECTION"
fi
pass "6: a checkout shipping no workflow scripts degrades to SKIPPED"

# ---------------------------------------------------------------------------
# Case 7 (NOT SCOPED TO ONE FILENAME): the check covers every *.mjs the
# checkout ships, so the next workflow added under claude/workflows/ does not
# silently inherit the original defect.
# ---------------------------------------------------------------------------
F7="$(_mk_checkout c7)"
H7="${TMP}/home7"; mkdir -p "${H7}/.claude/workflows"
printf '// identical\n' >"${F7}/claude/workflows/build-level.mjs"
cp "${F7}/claude/workflows/build-level.mjs" "${H7}/.claude/workflows/build-level.mjs"
printf '// repo side of a SECOND workflow\n' >"${F7}/claude/workflows/other-level.mjs"
printf '// drifted installed side of the second workflow\n' >"${H7}/.claude/workflows/other-level.mjs"

_run_doctor "$H7" "$F7"
SECTION="$(_section)"
has '^  DRIFT .*other-level\.mjs' \
  || fail "7: drift in a workflow other than build-level.mjs should still be caught — got: $SECTION"
has '^  OK .*build-level\.mjs' \
  || fail "7: the in-sync build-level.mjs should still report OK alongside — got: $SECTION"
[ "$DOCTOR_EXIT" -ne 0 ] || fail "7: drift in a second workflow should still exit non-zero"
pass "7: every claude/workflows/*.mjs is compared, not just build-level.mjs"

# ---------------------------------------------------------------------------
# Case 8 (EXIT-CODE WIRING, structural): cases 2/5/7 above assert a non-zero
# exit, but they cannot ISOLATE this check's own contribution — a minimal
# fixture's overall exit is non-zero anyway (links_enumerate unconditionally
# enumerates ~/.local/bin targets no fixture provisions), so those assertions
# only pin that DRIFT is never SWALLOWED into a clean exit. This case closes
# the remaining gap structurally: the check's status variable must actually be
# read by doctor.sh's final exit condition. Without it the function could
# return 1 forever and doctor would still exit 0 on an otherwise-clean host —
# the exact silent-green shape this whole check exists to prevent.
# ---------------------------------------------------------------------------
grep -q 'check_installed_workflow_drift || workflow_drift_status=\$?' "$DOCTOR_SH" \
  || fail "8: doctor.sh must capture check_installed_workflow_drift's status into workflow_drift_status"
sed -n '/^if (( non_ok > 0/,/then$/p' "$DOCTOR_SH" | grep 'workflow_drift_status != 0' >/dev/null \
  || fail "8: workflow_drift_status must be read by doctor.sh's final exit condition"
pass "8: the check's verdict is wired into doctor's own exit code"

echo
echo "All check_installed_workflow_drift() tests passed."
