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
# Round-2 review additions (§3e round 2): the "could-not-run" state (cases
# 9-10) — a checker that cannot load its lib, or whose fragment directory
# is readable-but-unsearchable, must fail loudly rather than report a
# false "0 violations" OK; the per-bullet title-hook scoping fix (cases
# 11-11b) — a bold lead-in on one bullet must not satisfy the hook
# requirement for a DIFFERENT bullet's own first issue mention; and a
# mixed-directory case (case 12) pinning the checked-count and per-file
# attribution when more than one fragment is present at once.
#
# Round-3 review additions (§3e round 3): case 9 no longer mutates the real
# repo tree (it runs a scratch copy of the checker out of an empty fake lib
# root — see its own comment and the ZERO REPO MUTATION note below); case 9b
# covers the INCOMPLETE-lib arm of the same silent-green class (a lib
# defining `changelog_fragment_names` but not `changelog_fragment_body`);
# cases 14/14b cover an unreadable fragment FILE in an otherwise-normal
# directory — the file-granularity twin of case 8, and the third arm of the
# reads-green-while-inert class; and case 15 pins the right-hand anchor on
# check 3 so `checks gate-paths.tsv` is not read as the `checks gate` jargon
# token. Cases 8, 10 and 14 now skip under root, which does not enforce the
# permission bits they rely on.
#
# Mirrors the sibling test_check_setting_prose.sh's plain mktemp-fixture
# style: no git repo needed, the checker is pointed at a scratch directory
# via its one documented seam (CHANGELOG_FRAGMENT_DIR).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-changelog-fragment-register.sh"

# ZERO REPO MUTATION (round-3 HIGH 1). This suite never moves, edits, or
# removes a tracked repo file. Cases 9/9b reach the "cannot load its lib"
# state by running a SCRATCH COPY of the checker out of a fake script root
# whose sibling `../lib/` is empty (or holds a deliberately-incomplete lib) —
# see those cases for why that reproduces the real state exactly.
#
# An earlier cut of case 9 `mv`'d the real workflows/scripts/lib/changelog.sh
# aside and back. That raced every other gate that reads it: this gate is NOT
# in scripts/quality-gates.sh's SERIAL_LANE_PINS, so it runs in the shared
# bounded-concurrency pool alongside workflows/scripts/lib/tests/
# test_changelog.sh, scripts/tests/test_assemble_changelog.sh,
# workflows/scripts/check-changelog-entry.sh, the register checker gate
# immediately adjacent to it in KERNEL_GATES, and `make shellcheck`'s find(1)
# walk — all of which see the file vanish. That is the same shape
# SERIAL_LANE_PINS's own comment block documents against itself (four
# failures in six concurrent runs), except worse: it REMOVES the file rather
# than editing it. A pin would not have been an adequate fallback either — it
# serialises this test only against the existing pins, not against those
# pool-lane changelog gates. Mutating a mirror instead of the shared file is
# the pattern that same comment block recommends.

fail() { echo "FAIL: $1" >&2; exit 1; }

# Root skips the permission-dependent cases (8, 10, 14). Root bypasses the
# filesystem permission bits those fixtures rely on, so a `chmod 000`/`444`
# path stays readable and the case would fail red purely because of the
# running user. Same convention as the sibling suite
# scripts/tests/test_assemble_changelog.sh.
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/changelog-fragment-register-test-XXXXXX")"
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
# A bare `trap cleanup INT` would clean up and then let bash RESUME after the
# interrupted command, so Ctrl-C would carry on running with the scratch dir
# already gone and report a confusing exit 1 an operator cannot tell apart
# from a genuine assertion failure. Each signal arm therefore exits with the
# conventional 128+signo (round-3 MEDIUM).
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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
if [ "$IS_ROOT" -eq 1 ]; then
  echo "  skipped — running as root, filesystem permissions are not enforced"
else
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
fi

# --- 9. RED (could-not-run, HIGH 1 belts 1/2): changelog.sh unsourceable ---
# A checker that cannot load its own lib (renamed, missing, or defines
# nothing) must fail loudly, never fall through the unchecked `source` +
# process-substitution loop to a green "0 violations" (the reported bug:
# `command not found` on stderr, exit 0, printed alongside a fixture that
# violates all three checks).
#
# REPRODUCED IN SCRATCH, NOT BY TOUCHING THE REPO (round-3 HIGH 1). The
# checker resolves its lib purely script-relatively, from
# `$SCRIPT_DIR/../lib/changelog.sh`, and its `REPO_ROOT` is unused once
# CHANGELOG_FRAGMENT_DIR is set — so a copy of the checker under a fake
# script root whose sibling `lib/` is EMPTY hits the identical `source`
# failure, with zero mutation of the real tree. See the header for why the
# previous `mv`-the-real-lib form was a live race against the gate pool.
clear_frags
write_frag "9-good.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667)."
FAKEROOT9="$WORK/fakeroot9"
mkdir -p "$FAKEROOT9/config" "$FAKEROOT9/lib"   # lib/ deliberately left empty
cp "$CHECKER" "$FAKEROOT9/config/"
rc=0
CHANGELOG_FRAGMENT_DIR="$FRAGDIR" \
  bash "$FAKEROOT9/config/check-changelog-fragment-register.sh" \
  >"$WORK/out9" 2>&1 || rc=$?
out="$(cat "$WORK/out9")"
if [ "$rc" -eq 0 ]; then
  fail "9: an unsourceable changelog.sh must fail loudly, never report a false OK:
$out"
fi
case "$out" in
  *"cannot load"*) : ;;
  *) fail "9: expected a 'cannot load changelog.sh' message, got:
$out" ;;
esac
echo "PASS: 9 unsourceable changelog.sh fails loudly, never a false OK (RED — could-not-run)"

# --- 9b. RED (could-not-run, belt 2): lib loads but is INCOMPLETE ----------
# A lib that defines `changelog_fragment_names` but NOT
# `changelog_fragment_body` reaches the same silent green by a different
# door: `body="$(changelog_fragment_body …)"` is a command substitution, so
# the `command not found` status is DISCARDED and `$body` is simply empty —
# both greps find nothing and the per-bullet hook check exits 0 on an empty
# body, so every fragment passes vacuously while the raw-glob cross-check
# (belt 3) still agrees with $checked. Belt 2 must therefore name EVERY lib
# function the loop depends on, not just the listing one.
FAKEROOT9B="$WORK/fakeroot9b"
mkdir -p "$FAKEROOT9B/config" "$FAKEROOT9B/lib"
cp "$CHECKER" "$FAKEROOT9B/config/"
cat >"$FAKEROOT9B/lib/changelog.sh" <<'PARTIAL_LIB'
# Deliberately incomplete: the listing helper only, no body reader.
changelog_fragment_names() { printf '9-good.fixed.md\n'; }
PARTIAL_LIB
rc=0
CHANGELOG_FRAGMENT_DIR="$FRAGDIR" \
  bash "$FAKEROOT9B/config/check-changelog-fragment-register.sh" \
  >"$WORK/out9b" 2>&1 || rc=$?
out="$(cat "$WORK/out9b")"
if [ "$rc" -eq 0 ]; then
  fail "9b: a lib missing changelog_fragment_body must fail loudly, never report a false OK:
$out"
fi
case "$out" in
  *"did not define changelog_fragment_body"*) : ;;
  *) fail "9b: expected a 'did not define changelog_fragment_body' message, got:
$out" ;;
esac
echo "PASS: 9b incomplete lib (no changelog_fragment_body) fails loudly, never a false OK (RED — could-not-run)"

# --- 10. RED (could-not-run, HIGH 1 belt 3): dir readable but not
# searchable (chmod 444) ------------------------------------------------
# This is the SECOND arm of the reported bug: the `-r` degenerate-input
# guard passes (the directory IS readable), but every entry is then
# invisible to changelog.sh's own `-e`/`-L` tests (which need the
# directory's execute/search bit), so the main loop silently processes
# zero fragments while a real one sits on disk. The independent raw-glob
# cross-check (belt 3) must catch this and fail loudly rather than print
# "OK — 0 ... checked".
if [ "$IS_ROOT" -eq 1 ]; then
  echo "  skipped — running as root, filesystem permissions are not enforced"
else
  clear_frags
  write_frag "10-good.fixed.md" \
    "- **A hard-killed test run no longer strands its sandbox** (#1667)."
  chmod 444 "$FRAGDIR"
  rc=0
  run_checker >"$WORK/out10" 2>&1 || rc=$?
  chmod u+rwx "$FRAGDIR"
  out="$(cat "$WORK/out10")"
  if [ "$rc" -eq 0 ]; then
    fail "10: a readable-but-unsearchable fragment dir (with a real fragment inside) must fail loudly, never report a false OK:
$out"
  fi
  case "$out" in
    *"OK — 0"*) fail "10: got the exact reads-green-while-inert shape (a silent 0-fragment OK) this belt exists to catch:
$out" ;;
  esac
  case "$out" in
    *"sanity mismatch"*) : ;;
    *) fail "10: expected a sanity-mismatch message naming the raw vs. processed count, got:
$out" ;;
  esac
  echo "PASS: 10 readable-but-unsearchable dir with a real fragment fails loudly, never a false OK (RED — could-not-run)"
fi

# --- 11. RED: multi-bullet fragment, only bullet 1 hooked (MEDIUM 2) -------
# Reproduces the reported false-pass: a bold lead-in on bullet 1 must NOT
# satisfy the hook requirement for bullet 2's own, separate first `#N`.
clear_frags
write_frag "11-multibullet.fixed.md" \
  "- **Hooked** thing.
- Another thing (temperloop#2136)."
out="$(run_checker 2>&1)" && fail "11: bullet 2's un-hooked first mention should fail even though bullet 1 is hooked:
$out"
case "$out" in
  *"11-multibullet.fixed.md"*"no title hook"*) : ;;
  *) fail "11: expected a no-title-hook REGISTER finding naming the file, got:
$out" ;;
esac
echo "PASS: 11 multi-bullet fragment with an un-hooked second bullet fails (RED — per-bullet scoping)"

# --- 11b. GREEN twin: same fragment, both bullets individually hooked -----
clear_frags
write_frag "11-multibullet.fixed.md" \
  "- **Hooked** thing.
- **Another hooked thing** (temperloop#2136)."
out="$(run_checker 2>&1)" || fail "11b: a multi-bullet fragment with every bullet individually hooked should pass:
$out"
echo "PASS: 11b every-bullet-hooked twin of 11 passes (GREEN — per-bullet scoping confirmed)"

# --- 12. RED: mixed directory — one clean fragment, one dirty ---------------
# No prior case exercised more than one fragment at once; this pins both
# the counter (checked = 2) and per-file attribution (the finding names
# only the dirty file, never the clean one).
clear_frags
write_frag "12a-clean.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667)."
write_frag "12b-dirty.fixed.md" \
  "- (#1667). The reaper now cleans up orphaned sandboxes on every run."
out="$(run_checker 2>&1)" && fail "12: a directory with one dirty fragment among clean ones should fail:
$out"
case "$out" in
  *"across 2 fragment"*) : ;;
  *) fail "12: expected the sanity-checked, per-run 'checked' counter to read 2, got:
$out" ;;
esac
case "$out" in
  *"12b-dirty.fixed.md"*"no title hook"*) : ;;
  *) fail "12: expected the finding to name the dirty file, got:
$out" ;;
esac
case "$out" in
  *"12a-clean.fixed.md"*) fail "12: the clean file must not be named in any finding, got:
$out" ;;
  *) : ;;
esac
echo "PASS: 12 mixed directory (1 clean + 1 dirty) fails, checked=2, names only the dirty file (RED — mixed-directory)"

# --- 13. RED (LOW 2): explicitly-empty CHANGELOG_FRAGMENT_DIR must not
# silently redirect at the real tree -----------------------------------
# `${VAR-default}` (not `${VAR:=default}`) means an explicitly-empty value
# stays empty rather than being treated as unset; the empty path then fails
# the `-e` degenerate-input guard loudly instead of falling through to scan
# whatever changelog.d/ the checker happens to sit next to.
rc=0
CHANGELOG_FRAGMENT_DIR="" bash "$CHECKER" >"$WORK/out13" 2>&1 || rc=$?
out="$(cat "$WORK/out13")"
if [ "$rc" -eq 0 ]; then
  fail "13: an explicitly-empty CHANGELOG_FRAGMENT_DIR must fail, never silently scan the real tree:
$out"
fi
case "$out" in
  *"not found"*) : ;;
  *) fail "13: expected a 'fragment directory not found' message for the empty path, got:
$out" ;;
esac
echo "PASS: 13 explicitly-empty CHANGELOG_FRAGMENT_DIR fails loudly, never silently redirects (RED)"

# --- 14. RED (could-not-run, round-3 HIGH 2): an unreadable fragment FILE
# in an otherwise-normal directory ---------------------------------------
# The file-granularity twin of case 8's directory-granularity guard, and the
# THIRD arm of the same reads-green-while-inert class cases 9/10 close.
# `changelog_fragment_body` shells out to awk inside a command substitution,
# so an unreadable fragment produced `awk: can't open file …` on stderr, an
# EMPTY body, and a green "OK — 0 violations across 1 fragment(s) checked" —
# byte-for-byte the signature the belts exist to end. Belt 3 cannot see it:
# the file IS on disk, so the raw glob count and $checked agree.
if [ "$IS_ROOT" -eq 1 ]; then
  echo "  skipped — running as root, filesystem permissions are not enforced"
else
  clear_frags
  write_frag "14-unreadable.fixed.md" \
    "- **A hard-killed test run no longer strands its sandbox** (#1667)."
  chmod 000 "$FRAGDIR/14-unreadable.fixed.md"
  rc=0
  run_checker >"$WORK/out14" 2>&1 || rc=$?
  chmod u+rw "$FRAGDIR/14-unreadable.fixed.md"
  out="$(cat "$WORK/out14")"
  if [ "$rc" -eq 0 ]; then
    fail "14: check-changelog-fragment-register.sh [unreadable]: an unreadable fragment directory OR an unreadable fragment FILE exits non-zero, never a silent OK — got exit 0:
$out"
  fi
  case "$out" in
    *"OK — 0"*) fail "14: got the exact reads-green-while-inert shape (a vacuous 0-violation OK over a fragment that was never read):
$out" ;;
  esac
  case "$out" in
    *"fragment unreadable"*"14-unreadable.fixed.md"*) : ;;
    *) fail "14: expected a per-file 'fragment unreadable' message naming the file, got:
$out" ;;
  esac
  echo "PASS: 14 unreadable fragment FILE fails loudly, never a vacuous OK (RED — could-not-run)"
fi

# --- 14b. GREEN twin: the same fragment, readable --------------------------
clear_frags
write_frag "14-unreadable.fixed.md" \
  "- **A hard-killed test run no longer strands its sandbox** (#1667)."
out="$(run_checker 2>&1)" || fail "14b: the same fragment, readable, should pass (discrimination — restoring the read bit restores GREEN):
$out"
case "$out" in
  *"across 1 fragment"*) : ;;
  *) fail "14b: expected the readable twin to actually be READ (checked = 1), got:
$out" ;;
esac
echo "PASS: 14b readable twin of 14 passes and is actually read (GREEN — discrimination confirmed)"

# --- 15. GREEN (round-3 LOW 3): `checks gate-paths.tsv` is not the jargon
# token -------------------------------------------------------------------
# Check 3's separator was widened to `[ -]+` so it would catch this corpus's
# real `` `checks` gate `` spelling; that also made a bare `checks
# gate-paths.tsv` match — a phrase with real occasion to appear in these
# fragments, since that file is a live artifact fragments discuss. The
# right-hand anchor closes that collision without weakening case 4.
clear_frags
write_frag "15-gatepaths.fixed.md" \
  "- **Two new gates joined the kernel suite** (#2136) — both rows landed in
  \`workflows/scripts/config/gate-paths.tsv\`, the checks gate-paths.tsv file
  the selector reads."
out="$(run_checker 2>&1)" || fail "15: a fragment naming \`checks gate-paths.tsv\` must not trip the jargon check:
$out"
echo "PASS: 15 'checks gate-paths.tsv' does not trip the jargon check (GREEN — right-anchored)"

echo
echo "test_check_changelog_fragment_register: OK — all checks passed"
