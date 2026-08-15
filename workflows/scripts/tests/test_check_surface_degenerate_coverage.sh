#!/usr/bin/env bash
#
# test_check_surface_degenerate_coverage.sh — fixture suite for
# workflows/scripts/validate-check-surface-degenerate-coverage.sh
# (temperloop#1476, epic #1409 "a check that could not run reports
# success").
#
# This is the gate proving ITS OWN correctness — the same discipline the
# gate demands of every OTHER check surface, applied reflexively. Every
# assertion below either (a) confirms the gate is GREEN on a fixture that
# should pass, or (b) MUTATES a fixture to break exactly one thing, confirms
# the gate goes RED naming that exact surface+case, then restores and
# confirms GREEN again — never a bare "it failed", always red-then-green.
#
# REVIEW ROUND 2 (temperloop#1476): the first cut of this gate shipped three
# HIGH-severity vacuous-pass paths, each reproduced against the real gate
# before being fixed here — an EMPTY registry passed silently (HIGH 1, see
# tests 21-24 and the EMPTY-REGISTRY checks), the registered anchors lived on
# a decoupled `ok()` line that survived every real assertion being deleted
# (HIGH 2, see the self-registration checks below and
# test_validate_provider_disclosure.sh's own header), and a COMMENTED-OUT
# gate line satisfied the CI-wiring check (HIGH 3, test 4b). Five MEDIUM and
# two LOW findings are covered by the remaining new tests (registry ratchet,
# anchor uniqueness/substance/non-comment, the rename-bootstrap exploit, the
# relative-allowlist-path silent-skip, the origin/HEAD fallback, SURFACE
# existence, and the tab-collapse footgun).
#
# Every test drives the gate through its five env-var fixture seams
# (CHECK_SURFACE_REGISTRY_FILE / _ALLOWLIST_FILE / _QUALITY_GATES_FILE /
# _GIT_REPO_ROOT / _ALLOWLIST_BASE_REF), so nothing here touches the real
# committed registry/allowlist except test 1 (a deliberate sanity check that
# the real, shipped registry/allowlist/quality-gates.sh are mutually
# consistent right now).
#
# Hermetic: throwaway mktemp dirs plus throwaway git fixture repos for the
# ratchet tests — no network, nothing under this repo's real .temperloop/
# state.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$REPO_ROOT/workflows/scripts/validate-check-surface-degenerate-coverage.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-check-surface-degenerate-coverage-XXXXXX")" || exit 1
cleanup() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
total=0
ok() {
  pass=$((pass + 1))
  echo "PASS: $1"
}
count() { total=$((total + 1)); }

gitc() { git -c user.name="Check-Surface Test" -c user.email="check-surface-test@example.com" -c commit.gpgsign=false "$@"; }

# run_gate <registry> <allowlist> <quality-gates-file> <git-repo-root> [base-ref]
# base-ref defaults to empty (the gate's own auto-resolve — origin/HEAD then
# origin/main then quiet skip), matching production default. Tests that need
# a SPECIFIC base ref (the ratchet tests) pass one explicitly.
run_gate() {
  local registry="$1" allowlist="$2" qg="$3" git_root="$4" base_ref="${5:-}"
  env \
    CHECK_SURFACE_REGISTRY_FILE="$registry" \
    CHECK_SURFACE_ALLOWLIST_FILE="$allowlist" \
    CHECK_SURFACE_QUALITY_GATES_FILE="$qg" \
    CHECK_SURFACE_GIT_REPO_ROOT="$git_root" \
    CHECK_SURFACE_ALLOWLIST_BASE_REF="$base_ref" \
    CHECK_SURFACE_REPO_ROOT="$git_root" \
    bash "$GATE"
}

# check <desc-and-anchor> <cmd...> — a THIN wrapper around count/fail/ok
# whose description doubles as a check-surface-registry.tsv anchor for the
# self-registration tests below (§ SELF-REGISTRATION). A failing check
# EXITS immediately (fail() does), matching this file's existing
# fixture-then-assert style — this is deliberately NOT a bad()/accumulate
# helper: the point of `check` here is that the description lives ONLY on
# the assertion line, never on a separate trailing print that could survive
# the assertion's own deletion (HIGH 2).
check() {
  local d="$1"
  shift
  count
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

# _verdict <want_rc> <must_contain> <rc> <out> — the compound predicate the
# self-registration `check` calls drive. `want_rc` is 0 or nonzero
# (anything != 0 means "any nonzero"). Generic infrastructure ONLY — must
# never itself carry one of the self-registration anchor strings, or the
# gate's own uniqueness check (MEDIUM 5) would trip on this helper's body.
_verdict() {
  local want_rc="$1" must="$2" rc="$3" out="$4"
  if [ "$want_rc" = "0" ]; then
    [ "$rc" -eq 0 ] || return 1
  else
    [ "$rc" -ne 0 ] || return 1
  fi
  case "$out" in *"$must"*) ;; *) return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# 1. SANITY: the real, shipped registry/allowlist/quality-gates.sh (no env
#    overrides at all) are mutually consistent right now.
# ---------------------------------------------------------------------------
count
rc=0
out="$(bash "$GATE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "1: the real committed registry/allowlist should pass the gate cleanly, got rc=$rc:
$out"
case "$out" in *"validate-check-surface-degenerate-coverage: OK"*) ;; *) fail "1: expected an OK verdict line, got:
$out" ;; esac
ok "1 the real committed registry/allowlist/quality-gates.sh are mutually consistent"

# ---------------------------------------------------------------------------
# SECTION B — a minimal single-surface fixture tree, reused by tests 2-8b.
# MEDIUM 8: SURFACE existence is now enforced, so the fixture "surface" must
# be a REAL file under $B (CHECK_SURFACE_REPO_ROOT for these tests).
# ---------------------------------------------------------------------------
B="$WORK/b"
mkdir -p "$B"
QG="$B/quality-gates.sh"
TESTFILE="$B/test_fake_surface.sh"
REGISTRY="$B/registry.tsv"
FAKE_SURFACE="fake-surface.sh"
: >"$B/$FAKE_SURFACE" # the surface just needs to EXIST; content is irrelevant
# Deliberately OUTSIDE $B (the CHECK_SURFACE_GIT_REPO_ROOT these tests pass):
# $B is not a git repo at all, and the gate's own documented behavior for an
# allowlist file NOT under the git repo root is "skip the ratchet" (a
# scoping choice, not CANNOT EVALUATE) — exactly what tests 2-8b want, since
# none of them are about the ratchet. The ratchet itself gets its own
# dedicated git fixtures in SECTION G / RATCHET / RENAME / RELATIVE below.
ALLOWLIST="$WORK/allowlist.tsv"

reset_b_testfile() {
  cat >"$TESTFILE" <<'EOF'
#!/usr/bin/env bash
echo "PASS: fake-absent-case: exit 1 on absent input"
echo "PASS: fake-unreadable-case: exit 1 on unreadable input"
echo "PASS: fake-empty-case: exit 1 on empty input"
EOF
}
reset_b_testfile

reset_b_qg() {
  cat >"$QG" <<EOF
GATES=(
  "bash $TESTFILE"
)
EOF
}
reset_b_qg

reset_b_registry() {
  cat >"$REGISTRY" <<EOF
$FAKE_SURFACE	absent	covered	$TESTFILE	fake-absent-case: exit 1 on absent input
$FAKE_SURFACE	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
$FAKE_SURFACE	empty	covered	$TESTFILE	fake-empty-case: exit 1 on empty input
EOF
}
reset_b_registry
: >"$ALLOWLIST"

# ---------------------------------------------------------------------------
# 2. A fresh, correct fixture tree is GREEN.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "2: a correct fixture tree should be GREEN, got rc=$rc:
$out"
ok "2 a correct 3-case fixture tree is GREEN"

# ---------------------------------------------------------------------------
# 3. MISSING-FIXTURE discrimination: delete the [unreadable] anchor line ->
#    RED naming the exact surface+case; restore -> GREEN. THE load-bearing
#    proof that this gate can actually detect a removed fixture (acceptance
#    criterion 5).
# ---------------------------------------------------------------------------
count
sed -i.orig '/fake-unreadable-case/d' "$TESTFILE"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
mv "$TESTFILE.orig" "$TESTFILE"
[[ "$rc" -ne 0 ]] || fail "3: deleting the [unreadable] anchor should turn the gate RED, got rc=0:
$out"
case "$out" in
  *"MISSING-FIXTURE"*"$FAKE_SURFACE"*"[unreadable]"*) ;;
  *) fail "3: expected a MISSING-FIXTURE line naming $FAKE_SURFACE [unreadable], got:
$out" ;;
esac
rc=0
out2="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "3: restoring the anchor should turn the gate back GREEN, got rc=$rc:
$out2"
ok "3 MISSING-FIXTURE discrimination: delete anchor -> RED naming surface+case; restore -> GREEN"

# ---------------------------------------------------------------------------
# 4a. TEST-FILE-NOT-GATED (absent entirely): the anchor exists, but
#     quality-gates.sh never mentions the file at all -> RED naming the
#     surface+case; restoring the wiring -> GREEN.
# ---------------------------------------------------------------------------
count
: >"$QG"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_qg
[[ "$rc" -ne 0 ]] || fail "4a: an ungated test file should turn the gate RED, got rc=0:
$out"
case "$out" in
  *"TEST-FILE-NOT-GATED"*"$FAKE_SURFACE"*) ;;
  *) fail "4a: expected a TEST-FILE-NOT-GATED line naming $FAKE_SURFACE, got:
$out" ;;
esac
ok "4a TEST-FILE-NOT-GATED: a fixture never mentioned in CI is RED, naming the surface"

# ---------------------------------------------------------------------------
# 4b. TEST-FILE-NOT-GATED (commented out): HIGH 3 — a bare substring grep
#     over the whole quality-gates.sh file is satisfied by a COMMENTED-OUT
#     gate line, exactly how this repo disables a suite. This is the
#     reviewer's own reproduction, re-run against the fix: the same
#     commented-out shape must now be RED, not a silent OK.
# ---------------------------------------------------------------------------
count
cat >"$QG" <<EOF
GATES=(
  # "bash $TESTFILE"
)
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_qg
[[ "$rc" -ne 0 ]] || fail "4b: a COMMENTED-OUT gate line should turn the gate RED, got rc=0:
$out"
case "$out" in
  *"TEST-FILE-NOT-GATED"*"$FAKE_SURFACE"*) ;;
  *) fail "4b: expected a TEST-FILE-NOT-GATED line naming $FAKE_SURFACE, got:
$out" ;;
esac
rc=0
out2="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "4b: an ACTIVE (uncommented) gate line should be GREEN again, got rc=$rc:
$out2"
ok "4b TEST-FILE-NOT-GATED: a COMMENTED-OUT gate line is RED (HIGH 3), an active one is GREEN"

# ---------------------------------------------------------------------------
# 5. REGISTRY-INCOMPLETE: a surface missing one of its three case rows is
#    RED, naming the missing case. LOW 10: the mutation is asserted, not
#    merely attempted with an `&&` that could silently no-op if grep matches
#    nothing.
# ---------------------------------------------------------------------------
count
grep -v $'\tempty\t' "$REGISTRY" >"$REGISTRY.tmp"
mv "$REGISTRY.tmp" "$REGISTRY"
if grep -q $'\tempty\t' "$REGISTRY"; then
  fail "5: fixture mutation did not remove the empty-case row — the row is still present"
fi
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "5: a surface missing its empty-case row should be RED, got rc=0:
$out"
case "$out" in
  *"REGISTRY-INCOMPLETE"*"$FAKE_SURFACE"*"'empty'"*) ;;
  *) fail "5: expected a REGISTRY-INCOMPLETE line naming the missing 'empty' case, got:
$out" ;;
esac
ok "5 REGISTRY-INCOMPLETE: a surface missing a case row is RED, naming which case"

# ---------------------------------------------------------------------------
# 6. NOT-APPLICABLE-UNJUSTIFIED: a not-applicable row with an empty reason is
#    RED, never a silent free pass.
# ---------------------------------------------------------------------------
count
cat >"$REGISTRY" <<EOF
$FAKE_SURFACE	absent	covered	$TESTFILE	fake-absent-case: exit 1 on absent input
$FAKE_SURFACE	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
$FAKE_SURFACE	empty	not-applicable	-
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "6: an unjustified not-applicable row should be RED, got rc=0:
$out"
case "$out" in
  *"NOT-APPLICABLE-UNJUSTIFIED"*"$FAKE_SURFACE"*) ;;
  *) fail "6: expected a NOT-APPLICABLE-UNJUSTIFIED line, got:
$out" ;;
esac
ok "6 NOT-APPLICABLE-UNJUSTIFIED: an empty-reason not-applicable row is RED, never a free pass"

# ---------------------------------------------------------------------------
# 7. REGISTRY-ALLOWLIST-COLLISION: a surface fully registered as covered AND
#    named on the allowlist is RED — it must be one or the other.
# ---------------------------------------------------------------------------
count
printf '%s\tsome reason\n' "$FAKE_SURFACE" >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
: >"$ALLOWLIST"
[[ "$rc" -ne 0 ]] || fail "7: a surface on both the registry and the allowlist should be RED, got rc=0:
$out"
case "$out" in
  *"REGISTRY-ALLOWLIST-COLLISION"*"$FAKE_SURFACE"*) ;;
  *) fail "7: expected a REGISTRY-ALLOWLIST-COLLISION line, got:
$out" ;;
esac
ok "7 REGISTRY-ALLOWLIST-COLLISION: a surface cannot be both covered and allowlisted"

# ---------------------------------------------------------------------------
# 8. ALLOWLIST-UNJUSTIFIED: an allowlist row with an empty reason is RED.
#    Its surface must independently exist (MEDIUM 8), so this uses a SECOND
#    real dummy file rather than a nonexistent "some/other-surface.sh".
# ---------------------------------------------------------------------------
count
: >"$B/other-surface.sh"
printf 'other-surface.sh\t\n' >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
: >"$ALLOWLIST"
[[ "$rc" -ne 0 ]] || fail "8: an unjustified allowlist entry should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-UNJUSTIFIED"*"other-surface.sh"*) ;;
  *) fail "8: expected an ALLOWLIST-UNJUSTIFIED line, got:
$out" ;;
esac
ok "8 ALLOWLIST-UNJUSTIFIED: an empty-reason allowlist entry is RED, never a silent grandfather"

# ---------------------------------------------------------------------------
# 8b. SURFACE-NOT-FOUND (MEDIUM 8): a registry row naming a script the tree
#     does not have is RED — the documented SURFACE grammar, actually
#     enforced. Covers both the bare-path and the `<script>:<subcommand>`
#     shapes.
# ---------------------------------------------------------------------------
count
cat >"$REGISTRY" <<EOF
does/not/exist.sh	absent	not-applicable	-	no fixture needed, surface itself is fake
does/not/exist.sh	unreadable	not-applicable	-	no fixture needed, surface itself is fake
does/not/exist.sh	empty	not-applicable	-	no fixture needed, surface itself is fake
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "8b: a registry row naming a nonexistent script should be RED, got rc=0:
$out"
case "$out" in
  *"SURFACE-NOT-FOUND"*"does/not/exist.sh"*) ;;
  *) fail "8b: expected a SURFACE-NOT-FOUND line naming does/not/exist.sh, got:
$out" ;;
esac
ok "8b SURFACE-NOT-FOUND: a registry row naming a script the tree does not have is RED"

count
cat >"$REGISTRY" <<EOF
$TESTFILE:fake-subcommand	absent	covered	$TESTFILE	fake-absent-case: exit 1 on absent input
$TESTFILE:fake-subcommand	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
$TESTFILE:fake-subcommand	empty	covered	$TESTFILE	fake-empty-case: exit 1 on empty input
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -eq 0 ]] || fail "8c: a <script>:<subcommand> surface whose script HALF exists should pass the SURFACE check, got rc=$rc:
$out"
ok "8c SURFACE-NOT-FOUND splits on the LAST ':' — a <script>:<subcommand> surface is checked by its script half"

# ---------------------------------------------------------------------------
# 9. ANCHOR SUBSTANCE / UNIQUENESS / NON-COMMENT (MEDIUM 5).
# ---------------------------------------------------------------------------
count
cat >"$TESTFILE" <<'EOF'
#!/usr/bin/env bash
echo "PASS: e"
echo "PASS: fake-unreadable-case: exit 1 on unreadable input"
echo "PASS: fake-empty-case: exit 1 on empty input"
EOF
cat >"$REGISTRY" <<EOF
$FAKE_SURFACE	absent	covered	$TESTFILE	e
$FAKE_SURFACE	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
$FAKE_SURFACE	empty	covered	$TESTFILE	fake-empty-case: exit 1 on empty input
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "9a: a trivial 1-char anchor ('e') should be RED, got rc=0:
$out"
case "$out" in
  *"$FAKE_SURFACE"*"[absent]"*"too short"*) ;;
  *) fail "9a: expected a too-short-anchor line naming $FAKE_SURFACE [absent], got:
$out" ;;
esac
ok "9a a trivial (1-char) anchor is RED — 'e' is a valid grep -F pattern but not a valid anchor"

count
reset_b_testfile
cat >>"$TESTFILE" <<'EOF'
echo "PASS: fake-absent-case: exit 1 on absent input"
EOF
reset_b_registry
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_testfile
[[ "$rc" -ne 0 ]] || fail "9b: a DUPLICATED anchor (appears twice) should be RED, got rc=0:
$out"
case "$out" in
  *"$FAKE_SURFACE"*"[absent]"*"appears 2 times"*) ;;
  *) fail "9b: expected an 'appears 2 times' line naming $FAKE_SURFACE [absent], got:
$out" ;;
esac
ok "9b a duplicated anchor (grep -Fc > 1) is RED — a duplicate is itself the collision signal"

count
reset_b_testfile
python3 - "$TESTFILE" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out = []
for l in lines:
    if "fake-absent-case" in l:
        out.append("# " + l.lstrip())
    else:
        out.append(l)
open(p, "w").writelines(out)
PYEOF
reset_b_registry
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_testfile
[[ "$rc" -ne 0 ]] || fail "9c: an anchor whose ONLY match is inside a comment should be RED, got rc=0:
$out"
case "$out" in
  *"$FAKE_SURFACE"*"[absent]"*"inside a comment line"*) ;;
  *) fail "9c: expected an 'inside a comment line' line naming $FAKE_SURFACE [absent], got:
$out" ;;
esac
ok "9c an anchor whose only match is a comment line is RED — a comment is not an assertion"

# ---------------------------------------------------------------------------
# 10. TAB-COLLAPSE (LOW 9): `IFS=\t read` collapses consecutive tabs, so a
#     genuinely-empty TEST_FILE column (double-tab) used to shift DETAIL
#     into the TEST_FILE slot instead of parsing as empty. Proves the fix:
#     the row is recognized as MISSING-TEST-FILE, not silently misparsed.
# ---------------------------------------------------------------------------
count
printf '%s\tabsent\tcovered\t\tsome-detail-text-here\n' "$FAKE_SURFACE" >"$REGISTRY"
printf '%s\tunreadable\tnot-applicable\t-\tno fixture needed\n' "$FAKE_SURFACE" >>"$REGISTRY"
printf '%s\tempty\tnot-applicable\t-\tno fixture needed\n' "$FAKE_SURFACE" >>"$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "10: a double-tab (empty TEST_FILE) row should be RED, got rc=0:
$out"
case "$out" in
  *"MISSING-TEST-FILE"*"$FAKE_SURFACE"*"[absent]"*) ;;
  *) fail "10: expected a MISSING-TEST-FILE line naming $FAKE_SURFACE [absent] (proving the empty TEST_FILE field was NOT collapsed into DETAIL), got:
$out" ;;
esac
ok "10 a double-tab (genuinely empty TEST_FILE field) parses as empty, not collapsed into DETAIL"

# ---------------------------------------------------------------------------
# § SELF-REGISTRATION — this gate is itself a registered check surface
# (workflows/scripts/config/check-surface-registry.tsv, all three cases,
# TEST_FILE = this file). HIGH 1's structural fix: an earlier cut of this
# gate was NOT registered against itself, which is exactly how its own
# absent/unreadable/empty-registry paths shipped unverified. These three
# `check` calls are that registration's real anchors — the description IS
# the assertion (HIGH 2 discipline), so deleting one of these lines is
# indistinguishable, from the gate's point of view, from this validator
# losing its own degenerate-input coverage.
# ---------------------------------------------------------------------------
SELFREG_ABSENT="$WORK/self-registry-absent.tsv"
SELFREG_UNREADABLE="$WORK/self-registry-unreadable.tsv"
printf '%s\tabsent\tcovered\t%s\tplaceholder\n' "$FAKE_SURFACE" "$TESTFILE" >"$SELFREG_UNREADABLE"
chmod 000 "$SELFREG_UNREADABLE"
SELFREG_EMPTY="$WORK/self-registry-empty.tsv"
: >"$SELFREG_EMPTY"

selfreg_absent_rc=0
selfreg_absent_out="$(CHECK_SURFACE_REGISTRY_FILE="$SELFREG_ABSENT" bash "$GATE" 2>&1)" || selfreg_absent_rc=$?
check "the gate's own registry: an ABSENT registry file is CANNOT EVALUATE, not 0" \
  _verdict 1 "CANNOT EVALUATE" "$selfreg_absent_rc" "$selfreg_absent_out"

selfreg_unreadable_rc=0
selfreg_unreadable_out="$(CHECK_SURFACE_REGISTRY_FILE="$SELFREG_UNREADABLE" bash "$GATE" 2>&1)" || selfreg_unreadable_rc=$?
chmod 644 "$SELFREG_UNREADABLE" # belt-and-suspenders; EXIT trap also covers this
check "the gate's own registry: an UNREADABLE registry file is CANNOT EVALUATE, not 0" \
  _verdict 1 "CANNOT EVALUATE" "$selfreg_unreadable_rc" "$selfreg_unreadable_out"

selfreg_empty_rc=0
selfreg_empty_out="$(CHECK_SURFACE_REGISTRY_FILE="$SELFREG_EMPTY" bash "$GATE" 2>&1)" || selfreg_empty_rc=$?
check "the gate's own registry: an EMPTY registry file is EMPTY-REGISTRY, not 0" \
  _verdict 1 "EMPTY-REGISTRY" "$selfreg_empty_rc" "$selfreg_empty_out"

# ---------------------------------------------------------------------------
# SECTION G — the allowlist ratchet, against a throwaway git fixture repo.
# ---------------------------------------------------------------------------
G="$WORK/g"
mkdir -p "$G"
gitc -C "$G" init -q
git -C "$G" symbolic-ref HEAD refs/heads/main
: >"$G/old-surface.sh"
: >"$G/new-surface.sh"
G_ALLOWLIST_REL="allowlist.tsv"
printf 'old-surface.sh\tpre-existing, never touched by this test\n' >"$G/$G_ALLOWLIST_REL"
gitc -C "$G" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$G" commit -q -m "base: one pre-existing allowlist entry"
G_BASE="$(git -C "$G" rev-parse HEAD)"
# Non-empty (HIGH 1): a minimal, all-not-applicable registry, since this
# section is allowlist-only — an EMPTY registry would itself now fail
# EMPTY-REGISTRY and mask whatever the allowlist test is checking.
G_REGISTRY="$WORK/g-registry.tsv"
cat >"$G_REGISTRY" <<EOF
$B/$FAKE_SURFACE	absent	not-applicable	-	section G is allowlist-only; this row exists only so the registry is non-empty
$B/$FAKE_SURFACE	unreadable	not-applicable	-	section G is allowlist-only; this row exists only so the registry is non-empty
$B/$FAKE_SURFACE	empty	not-applicable	-	section G is allowlist-only; this row exists only so the registry is non-empty
EOF
G_QG="$WORK/g-qg.sh"
: >"$G_QG"

# ---------------------------------------------------------------------------
# 11. ALLOWLIST-GREW: a NEW entry, absent at the base ref, is RED naming it.
# ---------------------------------------------------------------------------
count
printf 'old-surface.sh\tpre-existing, never touched by this test\nnew-surface.sh\tjust added, should be caught\n' >"$G/$G_ALLOWLIST_REL"
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "11: a newly-added allowlist entry should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"new-surface.sh"*) ;;
  *) fail "11: expected an ALLOWLIST-GREW line naming new-surface.sh, got:
$out" ;;
esac
case "$out" in
  *"allowlist ratchet: checked against $G_BASE:$G_ALLOWLIST_REL"*) ;;
  *) fail "11: expected a one-line allowlist-ratchet verdict naming the compared ref (MEDIUM 6c), got:
$out" ;;
esac
ok "11 ALLOWLIST-GREW: an entry absent at the base ref is RED, naming it, with the ratchet verdict line present"

# ---------------------------------------------------------------------------
# 12. Shrinking is legal: removing an entry (never adding one) is GREEN.
# ---------------------------------------------------------------------------
count
: >"$G/$G_ALLOWLIST_REL" # the list is now EMPTY — a pure shrink from the base ref's one entry
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "12: shrinking the allowlist (removing an entry) should stay GREEN, got rc=$rc:
$out"
ok "12 shrinking the allowlist (removing an entry, adding none) stays GREEN"

# ---------------------------------------------------------------------------
# 13. BOOTSTRAP: the base ref has no allowlist file at all (this commit is
#     the one introducing it) -> every current entry is legal, GREEN.
# ---------------------------------------------------------------------------
count
BOOT_DIR="$WORK/g-boot"
mkdir -p "$BOOT_DIR"
gitc -C "$BOOT_DIR" init -q
git -C "$BOOT_DIR" symbolic-ref HEAD refs/heads/main
printf 'placeholder\n' >"$BOOT_DIR/README.md"
gitc -C "$BOOT_DIR" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$BOOT_DIR" commit -q -m "base: no allowlist file yet"
BOOT_BASE="$(git -C "$BOOT_DIR" rev-parse HEAD)"
: >"$BOOT_DIR/brand-new-surface.sh"
BOOT_ALLOWLIST="$BOOT_DIR/brand-new-allowlist.tsv"
printf 'brand-new-surface.sh\tthis PR introduces the file itself\n' >"$BOOT_ALLOWLIST"
# STAGE it (git add, no commit): `git diff <ref>` only ever sees TRACKED or
# STAGED content — a purely untracked file is invisible to `git diff`
# regardless of --diff-filter, so the bootstrap detection this test exists
# to prove would never even see the file without this.
gitc -C "$BOOT_DIR" add "$BOOT_ALLOWLIST" "$BOOT_DIR/brand-new-surface.sh"
BOOT_REGISTRY="$WORK/g-boot-registry.tsv"
cat >"$BOOT_REGISTRY" <<EOF
$B/$FAKE_SURFACE	absent	not-applicable	-	bootstrap section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	unreadable	not-applicable	-	bootstrap section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	empty	not-applicable	-	bootstrap section is allowlist-only; row exists only so the registry is non-empty
EOF
BOOT_QG="$WORK/g-boot-qg.sh"
: >"$BOOT_QG"
rc=0
out="$(run_gate "$BOOT_REGISTRY" "$BOOT_ALLOWLIST" "$BOOT_QG" "$BOOT_DIR" "$BOOT_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "13: a brand-new allowlist file (absent at the base ref) should be GREEN (bootstrap), got rc=$rc:
$out"
case "$out" in
  *"allowlist ratchet: SKIPPED (bootstrap"*) ;;
  *) fail "13: expected a bootstrap SKIPPED ratchet verdict line (MEDIUM 6c), got:
$out" ;;
esac
ok "13 bootstrap: an allowlist file added in this diff is legal on the commit that introduces it, and says so"

# ---------------------------------------------------------------------------
# 14. RENAME-BOOTSTRAP EXPLOIT (MEDIUM 6b): renaming an ALREADY-RATCHETED
#     allowlist to a new path, in the SAME commit that adds a new
#     non-compliant entry, must NOT get the bootstrap exemption — the new
#     path never existed before under this exact name, but git's own
#     rename-aware diff must still recognize it as a continuation, not a
#     fresh introduction, and refuse to bootstrap it.
# ---------------------------------------------------------------------------
count
RENAME_DIR="$WORK/g-rename"
mkdir -p "$RENAME_DIR"
gitc -C "$RENAME_DIR" init -q
git -C "$RENAME_DIR" symbolic-ref HEAD refs/heads/main
: >"$RENAME_DIR/old-surface.sh"
: >"$RENAME_DIR/new-surface.sh"
: >"$RENAME_DIR/padding.txt" # rename-similarity padding so git's detector recognizes the move
# `#`-prefixed: this padding gets concatenated INTO the allowlist TSV below
# (to make old/new content similar enough for git's default rename-
# similarity threshold), so it must be shaped as comment lines the TSV
# parser skips — bare text here was misparsed as 200 bogus SURFACE rows the
# first time this fixture was written.
python3 -c "print('# padding filler line\n' * 200, end='')" >"$RENAME_DIR/padding.txt"
{
  printf 'old-surface.sh\tpre-existing entry 1\n'
  cat "$RENAME_DIR/padding.txt"
} >"$RENAME_DIR/allowlist-original.tsv"
gitc -C "$RENAME_DIR" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$RENAME_DIR" commit -q -m "base: allowlist-original.tsv with one entry"
RENAME_BASE="$(git -C "$RENAME_DIR" rev-parse HEAD)"
# The exploit attempt: DELETE the original path, CREATE a same-content-plus-
# padding new path (high similarity => git detects this as a rename), and
# sneak a NEW non-compliant entry in at the same time.
rm -f "$RENAME_DIR/allowlist-original.tsv"
{
  printf 'old-surface.sh\tpre-existing entry 1\n'
  printf 'new-surface.sh\tsmuggled in alongside the rename\n'
  cat "$RENAME_DIR/padding.txt"
} >"$RENAME_DIR/allowlist-renamed.tsv"
RENAME_REGISTRY="$WORK/g-rename-registry.tsv"
cat >"$RENAME_REGISTRY" <<EOF
$B/$FAKE_SURFACE	absent	not-applicable	-	rename section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	unreadable	not-applicable	-	rename section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	empty	not-applicable	-	rename section is allowlist-only; row exists only so the registry is non-empty
EOF
RENAME_QG="$WORK/g-rename-qg.sh"
: >"$RENAME_QG"
# STAGE the delete+add (git add -A, no commit): `git diff <ref>` only ever
# sees TRACKED or STAGED content, so the rename detection this test exists
# to prove would never even see either path without this.
gitc -C "$RENAME_DIR" add -A
# Sanity: confirm git itself recognizes this as a rename, not a plain add —
# otherwise this fixture isn't exercising the exploit path at all.
rename_detected="$(git -C "$RENAME_DIR" diff -M --diff-filter=R --name-status "$RENAME_BASE" -- allowlist-original.tsv allowlist-renamed.tsv 2>/dev/null)"
[[ -n "$rename_detected" ]] || fail "14: fixture setup: git did not detect the rename — the fixture isn't exercising MEDIUM 6b at all:
$rename_detected"
rc=0
out="$(run_gate "$RENAME_REGISTRY" "$RENAME_DIR/allowlist-renamed.tsv" "$RENAME_QG" "$RENAME_DIR" "$RENAME_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "14: a renamed allowlist smuggling a new entry alongside it should be RED (never re-armed bootstrap), got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*) ;;
  *) fail "14: expected an ALLOWLIST-GREW line (the rename must not exempt the smuggled entry), got:
$out" ;;
esac
case "$out" in
  *"allowlist ratchet: SKIPPED (bootstrap"*) fail "14: the ratchet was SKIPPED as bootstrap — the rename re-armed the exemption, exactly the exploit MEDIUM 6b closes:
$out" ;;
esac
ok "14 MEDIUM 6b: a rename-plus-new-entry attack does not get the bootstrap exemption — git's own rename detection blocks it"

# ---------------------------------------------------------------------------
# 15. REGISTRY RATCHET (MEDIUM 4): a (surface,case) row present at the base
#     ref must still be present now; covered -> not-applicable is a
#     regression too.
# ---------------------------------------------------------------------------
RATCHET_DIR="$WORK/g-registry-ratchet"
mkdir -p "$RATCHET_DIR"
gitc -C "$RATCHET_DIR" init -q
git -C "$RATCHET_DIR" symbolic-ref HEAD refs/heads/main
: >"$RATCHET_DIR/ratchet-surface.sh"
RATCHET_TESTFILE="$RATCHET_DIR/test_ratchet_surface.sh"
cat >"$RATCHET_TESTFILE" <<'EOF'
#!/usr/bin/env bash
echo "PASS: ratchet-absent-case: exit 1 on absent input"
echo "PASS: ratchet-unreadable-case: exit 1 on unreadable input"
echo "PASS: ratchet-empty-case: exit 1 on empty input"
EOF
RATCHET_QG="$RATCHET_DIR/quality-gates.sh"
cat >"$RATCHET_QG" <<EOF
GATES=(
  "bash $RATCHET_TESTFILE"
)
EOF
RATCHET_REGISTRY_REL="registry.tsv"
cat >"$RATCHET_DIR/$RATCHET_REGISTRY_REL" <<EOF
ratchet-surface.sh	absent	covered	$RATCHET_TESTFILE	ratchet-absent-case: exit 1 on absent input
ratchet-surface.sh	unreadable	covered	$RATCHET_TESTFILE	ratchet-unreadable-case: exit 1 on unreadable input
ratchet-surface.sh	empty	covered	$RATCHET_TESTFILE	ratchet-empty-case: exit 1 on empty input
EOF
RATCHET_ALLOWLIST="$RATCHET_DIR/allowlist.tsv"
: >"$RATCHET_ALLOWLIST"
gitc -C "$RATCHET_DIR" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$RATCHET_DIR" commit -q -m "base: ratchet-surface.sh fully covered"
RATCHET_BASE="$(git -C "$RATCHET_DIR" rev-parse HEAD)"

# 15a. Deleting a row entirely (REGISTRY-INCOMPLETE would also fire, but the
#      ratchet must ADDITIONALLY name the regression against the base ref).
count
grep -v $'\tempty\t' "$RATCHET_DIR/$RATCHET_REGISTRY_REL" >"$RATCHET_DIR/$RATCHET_REGISTRY_REL.tmp"
mv "$RATCHET_DIR/$RATCHET_REGISTRY_REL.tmp" "$RATCHET_DIR/$RATCHET_REGISTRY_REL"
if grep -q $'\tempty\t' "$RATCHET_DIR/$RATCHET_REGISTRY_REL"; then
  fail "15a: fixture mutation did not remove the empty-case row"
fi
rc=0
out="$(run_gate "$RATCHET_DIR/$RATCHET_REGISTRY_REL" "$RATCHET_ALLOWLIST" "$RATCHET_QG" "$RATCHET_DIR" "$RATCHET_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "15a: deleting a previously-covered row should be RED, got rc=0:
$out"
case "$out" in
  *"REGISTRY-REGRESSED"*"ratchet-surface.sh"*"[empty]"*"now ABSENT"*) ;;
  *) fail "15a: expected a REGISTRY-REGRESSED line naming ratchet-surface.sh [empty] ... now ABSENT, got:
$out" ;;
esac
ok "15a REGISTRY-REGRESSED: a (surface,case) row present at the base ref but deleted now is RED"

# 15b. Downgrading covered -> not-applicable (row still present, status
#      weakened) must ALSO be caught — this is the row-deletion escape
#      hatch's quieter sibling.
count
cat >"$RATCHET_DIR/$RATCHET_REGISTRY_REL" <<EOF
ratchet-surface.sh	absent	covered	$RATCHET_TESTFILE	ratchet-absent-case: exit 1 on absent input
ratchet-surface.sh	unreadable	covered	$RATCHET_TESTFILE	ratchet-unreadable-case: exit 1 on unreadable input
ratchet-surface.sh	empty	not-applicable	-	downgraded from covered — should be caught
EOF
rc=0
out="$(run_gate "$RATCHET_DIR/$RATCHET_REGISTRY_REL" "$RATCHET_ALLOWLIST" "$RATCHET_QG" "$RATCHET_DIR" "$RATCHET_BASE" 2>&1)" || rc=$?
case "$out" in
  *"REGISTRY-REGRESSED"*"ratchet-surface.sh"*"[empty]"*"now 'not-applicable'"*) ;;
  *) fail "15b: expected a REGISTRY-REGRESSED line naming the covered->not-applicable downgrade, got:
$out" ;;
esac
[[ "$rc" -ne 0 ]] || fail "15b: downgrading covered -> not-applicable should be RED, got rc=0:
$out"
ok "15b REGISTRY-REGRESSED: downgrading a covered case to not-applicable is RED (growth-in-reverse)"

# 15c. The unmutated fixture (identical to base) stays GREEN — proves the
#      ratchet does not false-positive on a no-op re-run.
count
cat >"$RATCHET_DIR/$RATCHET_REGISTRY_REL" <<EOF
ratchet-surface.sh	absent	covered	$RATCHET_TESTFILE	ratchet-absent-case: exit 1 on absent input
ratchet-surface.sh	unreadable	covered	$RATCHET_TESTFILE	ratchet-unreadable-case: exit 1 on unreadable input
ratchet-surface.sh	empty	covered	$RATCHET_TESTFILE	ratchet-empty-case: exit 1 on empty input
EOF
rc=0
out="$(run_gate "$RATCHET_DIR/$RATCHET_REGISTRY_REL" "$RATCHET_ALLOWLIST" "$RATCHET_QG" "$RATCHET_DIR" "$RATCHET_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "15c: an unchanged registry (identical to the base ref) should stay GREEN, got rc=$rc:
$out"
case "$out" in
  *"registry ratchet: checked against $RATCHET_BASE:$RATCHET_REGISTRY_REL"*) ;;
  *) fail "15c: expected a one-line registry-ratchet verdict naming the compared ref (MEDIUM 6c), got:
$out" ;;
esac
ok "15c the registry ratchet does not false-positive on an unchanged registry, and states what it compared"

# ---------------------------------------------------------------------------
# 16. CANNOT EVALUATE: an EXPLICIT, unresolvable base ref is a hard, non-zero
#     abort — never a silent pass, since "did it regress" is undecidable
#     without a comparison point.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "refs/does-not-exist-anywhere" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "16: an unresolvable EXPLICIT ratchet base ref should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "16: expected a CANNOT EVALUATE line, got:
$out" ;; esac
case "$out" in *"CANNOT_EVALUATE"*) ;; *) fail "16: expected the machine outcome CANNOT_EVALUATE on stdout, got:
$out" ;; esac
ok "16 an unresolvable EXPLICIT ratchet base ref is CANNOT EVALUATE, non-zero, never a silent pass"

# ---------------------------------------------------------------------------
# 17. ORIGIN RESOLUTION (MEDIUM 7): no explicit base ref given, and the
#     fixture repo has NO origin remote at all -> the ratchet SKIPS quietly
#     (rc 0), never CANNOT EVALUATE — a stranger's fresh/offline clone must
#     not hard-fail `checks` over a missing remote.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "17: no origin remote at all (no explicit base ref) should SKIP the ratchet and stay GREEN, got rc=$rc:
$out"
case "$out" in
  *"allowlist ratchet: SKIPPED (no origin remote resolvable"*) ;;
  *) fail "17: expected a 'no origin remote' SKIPPED ratchet line, got:
$out" ;;
esac
ok "17 MEDIUM 7: no origin remote at all degrades to a quiet, reported SKIP — never CANNOT EVALUATE"

# ---------------------------------------------------------------------------
# 18. ORIGIN RESOLUTION (MEDIUM 7): a fixture repo WITH an origin remote
#     whose HEAD points at a non-"main" default branch (e.g. "trunk") is
#     resolved via refs/remotes/origin/HEAD, not a hardcoded "origin/main".
# ---------------------------------------------------------------------------
count
ORIGIN_BARE="$WORK/origin-bare.git"
git init -q --bare "$ORIGIN_BARE"
CLONE_DIR="$WORK/origin-clone"
mkdir -p "$CLONE_DIR"
gitc -C "$CLONE_DIR" init -q
git -C "$CLONE_DIR" symbolic-ref HEAD refs/heads/trunk
: >"$CLONE_DIR/trunk-surface.sh"
printf 'trunk-surface.sh\ttrunk baseline entry\n' >"$CLONE_DIR/allowlist.tsv"
gitc -C "$CLONE_DIR" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$CLONE_DIR" commit -q -m "trunk base"
git -C "$CLONE_DIR" remote add origin "$ORIGIN_BARE"
git -C "$CLONE_DIR" push -q origin trunk:trunk
git -C "$ORIGIN_BARE" symbolic-ref HEAD refs/heads/trunk
git -C "$CLONE_DIR" fetch -q origin
git -C "$CLONE_DIR" remote set-head origin trunk
TRUNK_REGISTRY="$WORK/trunk-registry.tsv"
cat >"$TRUNK_REGISTRY" <<EOF
$B/$FAKE_SURFACE	absent	not-applicable	-	trunk section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	unreadable	not-applicable	-	trunk section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	empty	not-applicable	-	trunk section is allowlist-only; row exists only so the registry is non-empty
EOF
TRUNK_QG="$WORK/trunk-qg.sh"
: >"$TRUNK_QG"
# Grow the allowlist locally without committing/pushing — the ratchet
# compares the WORKING TREE against origin/HEAD, so this uncommitted
# addition must be caught.
printf 'trunk-surface.sh\ttrunk baseline entry\nnew-trunk-surface.sh\tshould be caught via origin/HEAD, not a hardcoded origin/main\n' >"$CLONE_DIR/allowlist.tsv"
: >"$CLONE_DIR/new-trunk-surface.sh"
rc=0
out="$(run_gate "$TRUNK_REGISTRY" "$CLONE_DIR/allowlist.tsv" "$TRUNK_QG" "$CLONE_DIR" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "18: a growth on a non-main default branch (resolved via origin/HEAD) should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"new-trunk-surface.sh"*) ;;
  *) fail "18: expected an ALLOWLIST-GREW line naming new-trunk-surface.sh (proving origin/HEAD resolution reached the trunk branch, not a hardcoded origin/main which doesn't exist here), got:
$out" ;;
esac
case "$out" in
  *"allowlist ratchet: checked against origin/trunk:"*) ;;
  *) fail "18: expected the ratchet verdict to name origin/trunk (resolved via refs/remotes/origin/HEAD), got:
$out" ;;
esac
ok "18 MEDIUM 7: a non-'main' default branch is resolved via refs/remotes/origin/HEAD, not a hardcoded origin/main"

# ---------------------------------------------------------------------------
# 19. RELATIVE ALLOWLIST PATH (MEDIUM 6a): CHECK_SURFACE_ALLOWLIST_FILE given
#     as a path RELATIVE to CHECK_SURFACE_REPO_ROOT must still be resolved to
#     absolute before the ratchet's "is this under the git repo root" check
#     — otherwise the ratchet silently no-ops for every relative override.
# ---------------------------------------------------------------------------
count
# $G/$G_ALLOWLIST_REL was emptied by test 12 (a legal shrink) — repopulate it
# with a genuinely-grown entry so THIS test exercises what it claims to.
printf 'old-surface.sh\tpre-existing, never touched by this test\nnew-surface.sh\tjust added, should be caught\n' >"$G/$G_ALLOWLIST_REL"
rc=0
out="$(env \
  CHECK_SURFACE_REGISTRY_FILE="$G_REGISTRY" \
  CHECK_SURFACE_ALLOWLIST_FILE="$G_ALLOWLIST_REL" \
  CHECK_SURFACE_QUALITY_GATES_FILE="$G_QG" \
  CHECK_SURFACE_GIT_REPO_ROOT="$G" \
  CHECK_SURFACE_ALLOWLIST_BASE_REF="$G_BASE" \
  CHECK_SURFACE_REPO_ROOT="$G" \
  bash "$GATE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "19: a RELATIVE CHECK_SURFACE_ALLOWLIST_FILE naming a genuinely-grown allowlist should still be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"new-surface.sh"*) ;;
  *) fail "19: expected an ALLOWLIST-GREW line naming new-surface.sh (proving the RELATIVE path was resolved to absolute before the ratchet's prefix check, not silently skipped), got:
$out" ;;
esac
case "$out" in
  *"allowlist ratchet: SKIPPED"*) fail "19: the ratchet was SKIPPED — a relative CHECK_SURFACE_ALLOWLIST_FILE silently disabled it (MEDIUM 6a):
$out" ;;
esac
ok "19 MEDIUM 6a: a RELATIVE CHECK_SURFACE_ALLOWLIST_FILE is resolved to absolute — the ratchet still runs, never silently skipped"

# ---------------------------------------------------------------------------
# 20. CANNOT EVALUATE: an absent registry file.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$WORK/does-not-exist-registry.tsv" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "20: an absent registry file should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "20: expected a CANNOT EVALUATE line, got:
$out" ;; esac
ok "20 an absent registry file is CANNOT EVALUATE, non-zero, never a silent pass"

# ---------------------------------------------------------------------------
# 21. CANNOT EVALUATE: a registered TEST_FILE that does not exist.
# ---------------------------------------------------------------------------
count
: >"$B/ghost-surface.sh"
GHOST_REGISTRY="$WORK/ghost-registry.tsv"
cat >"$GHOST_REGISTRY" <<EOF
ghost-surface.sh	absent	covered	$WORK/does-not-exist-test-file.sh	some anchor
ghost-surface.sh	unreadable	not-applicable	-	no analog for this fake surface
ghost-surface.sh	empty	not-applicable	-	no analog for this fake surface
EOF
rc=0
out="$(run_gate "$GHOST_REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "21: a registered TEST_FILE that does not exist should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "21: expected a CANNOT EVALUATE line, got:
$out" ;; esac
ok "21 a registered TEST_FILE that does not exist is CANNOT EVALUATE, never a silent pass"

# ---------------------------------------------------------------------------
# 22-23. EMPTY-REGISTRY (HIGH 1): the exact reproduction the reviewer used
#     against the pre-fix gate — an empty file, and a comment-only file —
#     must both now be RED, never a vacuous "Checked 0 ... OK".
# ---------------------------------------------------------------------------
count
: >"$WORK/truly-empty-registry.tsv"
rc=0
out="$(CHECK_SURFACE_REGISTRY_FILE="$WORK/truly-empty-registry.tsv" bash "$GATE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "22: a truly empty (0-byte) registry should be RED (EMPTY-REGISTRY), got rc=0:
$out"
case "$out" in *"EMPTY-REGISTRY"*) ;; *) fail "22: expected an EMPTY-REGISTRY line, got:
$out" ;; esac
ok "22 HIGH 1: an empty registry file is RED (EMPTY-REGISTRY), not the vacuous 'Checked 0 ... OK' the reviewer reproduced"

count
printf '# nothing but comments here\n\n# still nothing\n' >"$WORK/comment-only-registry.tsv"
rc=0
out="$(CHECK_SURFACE_REGISTRY_FILE="$WORK/comment-only-registry.tsv" bash "$GATE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "23: a comment-only registry should be RED (EMPTY-REGISTRY), got rc=0:
$out"
case "$out" in *"EMPTY-REGISTRY"*) ;; *) fail "23: expected an EMPTY-REGISTRY line, got:
$out" ;; esac
ok "23 HIGH 1: a comment-only registry is ALSO RED — the same vacuous-pass shape, one indirection deeper"

# ---------------------------------------------------------------------------
# SECTION H — the VENDORED-KERNEL SUBTREE ARM (temperloop#1559): a composed
# overlay whose allowlist is a symlink into the vendored kernel subtree
# (kernel/, repo-root .kernel-pin present). A vendor bump carrying
# upstream-grown rows must pass with NO base-ref override; an
# overlay-authored row hand-edited into kernel/'s copy must still fail; a
# pin-bearing tree with NO subtree squash commit falls back fail-closed to
# the plain base-ref ratchet.
#
# The fixture repo mirrors real `git subtree pull --prefix=kernel --squash`
# anatomy: the squash commit's tree is the KERNEL repo root (unprefixed) and
# its message carries the `git-subtree-dir: kernel` / `git-subtree-split:`
# trailers; the bump lands as a two-parent merge of the previous HEAD and
# that squash commit, built with plumbing (hash-object/mktree/commit-tree)
# so no network or real subtree machinery is needed.
# ---------------------------------------------------------------------------
V="$WORK/h-vendor"
mkdir -p "$V/kernel" "$V/config"
gitc -C "$V" init -q
git -C "$V" symbolic-ref HEAD refs/heads/main
: >"$V/old-vendored.sh"
: >"$V/upstream-new.sh"
: >"$V/overlay-smuggled.sh"
printf 'old-vendored.sh\tvendored baseline entry\n' >"$V/kernel/allowlist.tsv"
ln -s ../kernel/allowlist.tsv "$V/config/allowlist.tsv"
printf 'tag v0.1.0\nsha 1111111111111111111111111111111111111111\n' >"$V/.kernel-pin"
gitc -C "$V" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$V" commit -q -m "base: composed overlay, kernel allowlist vendored at v0.1.0"
V_BASE="$(git -C "$V" rev-parse HEAD)"
# The simulated vendor bump: upstream grew the allowlist by one row
# (ratcheted by kernel CI when it landed there), and the pin moves.
printf 'old-vendored.sh\tvendored baseline entry\nupstream-new.sh\tgrown upstream, ratcheted by kernel CI when added there\n' >"$V/kernel/allowlist.tsv"
printf 'tag v0.2.0\nsha 2222222222222222222222222222222222222222\n' >"$V/.kernel-pin"
gitc -C "$V" add -A
V_NEWTREE="$(git -C "$V" write-tree)"
V_BLOB="$(git -C "$V" hash-object -w "$V/kernel/allowlist.tsv")"
V_KTREE="$(printf '100644 blob %s\tallowlist.tsv\n' "$V_BLOB" | git -C "$V" mktree)"
V_SQUASH_MSG="$(printf "Squashed 'kernel/' changes from 1111111..2222222\n\ngit-subtree-dir: kernel\ngit-subtree-split: 2222222222222222222222222222222222222222")"
V_SQUASH="$(GIT_AUTHOR_DATE="2024-02-01T00:00:00Z" GIT_COMMITTER_DATE="2024-02-01T00:00:00Z" \
  gitc -C "$V" commit-tree "$V_KTREE" -m "$V_SQUASH_MSG")"
V_MERGE="$(GIT_AUTHOR_DATE="2024-02-01T00:00:01Z" GIT_COMMITTER_DATE="2024-02-01T00:00:01Z" \
  gitc -C "$V" commit-tree "$V_NEWTREE" -p "$V_BASE" -p "$V_SQUASH" -m "chore(kernel): subtree pull v0.2.0")"
git -C "$V" update-ref refs/heads/main "$V_MERGE"
V_REGISTRY="$WORK/h-vendor-registry.tsv"
cat >"$V_REGISTRY" <<EOF
$B/$FAKE_SURFACE	absent	not-applicable	-	vendor section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	unreadable	not-applicable	-	vendor section is allowlist-only; row exists only so the registry is non-empty
$B/$FAKE_SURFACE	empty	not-applicable	-	vendor section is allowlist-only; row exists only so the registry is non-empty
EOF
V_QG="$WORK/h-vendor-qg.sh"
: >"$V_QG"

# ---------------------------------------------------------------------------
# 24. VENDOR BUMP GREEN (temperloop#1559): the upstream-grown row passes with
#     NO CHECK_SURFACE_ALLOWLIST_BASE_REF override beyond the ordinary base
#     ref — the gate ratchets subtree-sourced rows against the vendored
#     kernel's own pulled content (the subtree squash commit), not only the
#     overlay's base ref. The allowlist is handed to the gate by its SYMLINK
#     path, exercising the physical-path resolution too (git show on the
#     symlink path would return the link target text, never TSV).
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$V_REGISTRY" "$V/config/allowlist.tsv" "$V_QG" "$V" "$V_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "24: a vendor bump carrying an upstream-grown allowlist row should be GREEN via the vendored-kernel arm, got rc=$rc:
$out"
case "$out" in
  *"allowlist ratchet: checked against $V_BASE:kernel/allowlist.tsv + vendored-kernel squash $V_SQUASH"*) ;;
  *) fail "24: expected the ratchet verdict to name BOTH comparison points (base ref + vendored-kernel squash), got:
$out" ;;
esac
ok "24 temperloop#1559: an upstream-grown row arriving via the vendored kernel subtree passes, and the verdict names the squash it ratcheted against"

# ---------------------------------------------------------------------------
# 25. OVERLAY SMUGGLE STILL RED: a row hand-edited into kernel/'s copy of the
#     allowlist — present in NEITHER the base ref NOR the vendored kernel's
#     pulled content — still fails ALLOWLIST-GREW, and the upstream-grown row
#     is NOT dragged down with it. Red, then restored green.
# ---------------------------------------------------------------------------
count
printf 'old-vendored.sh\tvendored baseline entry\nupstream-new.sh\tgrown upstream, ratcheted by kernel CI when added there\noverlay-smuggled.sh\thand-edited into kernel/ by the overlay, upstream never shipped it\n' >"$V/kernel/allowlist.tsv"
rc=0
out="$(run_gate "$V_REGISTRY" "$V/config/allowlist.tsv" "$V_QG" "$V" "$V_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "25: an overlay-authored row smuggled into kernel/'s allowlist should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"overlay-smuggled.sh"*) ;;
  *) fail "25: expected an ALLOWLIST-GREW line naming overlay-smuggled.sh, got:
$out" ;;
esac
case "$out" in
  *"ALLOWLIST-GREW  upstream-new.sh"*) fail "25: the upstream-grown row was flagged alongside the smuggled one — the kernel arm should exempt it per-row:
$out" ;;
esac
# Restore the pure-vendored content and confirm green again (red-then-green).
printf 'old-vendored.sh\tvendored baseline entry\nupstream-new.sh\tgrown upstream, ratcheted by kernel CI when added there\n' >"$V/kernel/allowlist.tsv"
rc=0
out="$(run_gate "$V_REGISTRY" "$V/config/allowlist.tsv" "$V_QG" "$V" "$V_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "25: restoring the pure-vendored allowlist should return to GREEN, got rc=$rc:
$out"
ok "25 temperloop#1559: an overlay-authored row in kernel/'s copy still fails ALLOWLIST-GREW (per-row — the upstream row stays exempt), and restoring goes green"

# ---------------------------------------------------------------------------
# 26. NO-SQUASH FALLBACK IS FAIL-CLOSED: a tree with .kernel-pin and a
#     kernel/-resolving allowlist but NO subtree squash commit reachable from
#     HEAD (vendored by copy, or history too shallow) falls back to the plain
#     base-ref ratchet — growth still fails, and the verdict says why the
#     vendored-kernel arm was unavailable.
# ---------------------------------------------------------------------------
count
NOSQ="$WORK/h-nosquash"
mkdir -p "$NOSQ/kernel" "$NOSQ/config"
gitc -C "$NOSQ" init -q
git -C "$NOSQ" symbolic-ref HEAD refs/heads/main
: >"$NOSQ/old-vendored.sh"
: >"$NOSQ/upstream-new.sh"
printf 'old-vendored.sh\tvendored baseline entry\n' >"$NOSQ/kernel/allowlist.tsv"
ln -s ../kernel/allowlist.tsv "$NOSQ/config/allowlist.tsv"
printf 'tag v0.1.0\nsha 3333333333333333333333333333333333333333\n' >"$NOSQ/.kernel-pin"
gitc -C "$NOSQ" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$NOSQ" commit -q -m "base: pin-bearing tree vendored by copy (no subtree squash history)"
NOSQ_BASE="$(git -C "$NOSQ" rev-parse HEAD)"
printf 'old-vendored.sh\tvendored baseline entry\nupstream-new.sh\tgrown with no squash provenance to vouch for it\n' >"$NOSQ/kernel/allowlist.tsv"
rc=0
out="$(run_gate "$V_REGISTRY" "$NOSQ/config/allowlist.tsv" "$V_QG" "$NOSQ" "$NOSQ_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "26: growth with no subtree squash commit to vouch for it should be RED (fail-closed fallback), got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"upstream-new.sh"*) ;;
  *) fail "26: expected an ALLOWLIST-GREW line naming upstream-new.sh (plain ratchet fallback), got:
$out" ;;
esac
case "$out" in
  *"vendored-kernel arm unavailable"*) ;;
  *) fail "26: expected the verdict to say the vendored-kernel arm was unavailable and why (MEDIUM 6c legibility), got:
$out" ;;
esac
ok "26 temperloop#1559: a pin-bearing tree with no subtree squash history falls back FAIL-CLOSED to the plain base-ref ratchet, and says so"

echo
echo "$pass/$total tests passed"
[[ "$pass" -eq "$total" ]] || exit 1
