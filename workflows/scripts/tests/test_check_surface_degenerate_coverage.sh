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
# Every test drives the gate through its five env-var fixture seams
# (CHECK_SURFACE_REGISTRY_FILE / _ALLOWLIST_FILE / _QUALITY_GATES_FILE /
# _GIT_REPO_ROOT / _ALLOWLIST_BASE_REF), so nothing here touches the real
# committed registry/allowlist except test 1 (a deliberate sanity check that
# the real, shipped registry/allowlist/quality-gates.sh are mutually
# consistent right now).
#
# Hermetic: throwaway mktemp dirs plus a throwaway git fixture repo for the
# allowlist-ratchet tests (SECTION G) — no network, nothing under this
# repo's real .temperloop/ state.
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
run_gate() {
  local registry="$1" allowlist="$2" qg="$3" git_root="$4" base_ref="${5:-origin/main}"
  env \
    CHECK_SURFACE_REGISTRY_FILE="$registry" \
    CHECK_SURFACE_ALLOWLIST_FILE="$allowlist" \
    CHECK_SURFACE_QUALITY_GATES_FILE="$qg" \
    CHECK_SURFACE_GIT_REPO_ROOT="$git_root" \
    CHECK_SURFACE_ALLOWLIST_BASE_REF="$base_ref" \
    CHECK_SURFACE_REPO_ROOT="$git_root" \
    bash "$GATE"
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
# SECTION B — a minimal single-surface fixture tree, reused by tests 2-7.
# ---------------------------------------------------------------------------
B="$WORK/b"
mkdir -p "$B"
QG="$B/quality-gates.sh"
TESTFILE="$B/test_fake_surface.sh"
REGISTRY="$B/registry.tsv"
# Deliberately OUTSIDE $B (the CHECK_SURFACE_GIT_REPO_ROOT these tests pass):
# $B is not a git repo at all, and the gate's own documented behavior for an
# allowlist file NOT under the git repo root is "skip the ratchet" (a
# scoping choice, not CANNOT EVALUATE) — exactly what tests 2-8 want, since
# none of them are about the ratchet. The ratchet itself gets its own
# dedicated git fixture in SECTION G below.
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

cat >"$QG" <<EOF
GATES=(
  "bash $TESTFILE"
)
EOF

reset_b_registry() {
  cat >"$REGISTRY" <<EOF
fake/surface.sh	absent	covered	$TESTFILE	fake-absent-case: exit 1 on absent input
fake/surface.sh	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
fake/surface.sh	empty	covered	$TESTFILE	fake-empty-case: exit 1 on empty input
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
  *"MISSING-FIXTURE"*"fake/surface.sh"*"[unreadable]"*) ;;
  *) fail "3: expected a MISSING-FIXTURE line naming fake/surface.sh [unreadable], got:
$out" ;;
esac
rc=0
out2="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "3: restoring the anchor should turn the gate back GREEN, got rc=$rc:
$out2"
ok "3 MISSING-FIXTURE discrimination: delete anchor -> RED naming surface+case; restore -> GREEN"

# ---------------------------------------------------------------------------
# 4. TEST-FILE-NOT-GATED: the anchor exists, but quality-gates.sh never
#    invokes the file -> RED naming the surface+case; restoring the wiring
#    -> GREEN.
# ---------------------------------------------------------------------------
count
: >"$QG"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
cat >"$QG" <<EOF
GATES=(
  "bash $TESTFILE"
)
EOF
[[ "$rc" -ne 0 ]] || fail "4: an ungated test file should turn the gate RED, got rc=0:
$out"
case "$out" in
  *"TEST-FILE-NOT-GATED"*"fake/surface.sh"*) ;;
  *) fail "4: expected a TEST-FILE-NOT-GATED line naming fake/surface.sh, got:
$out" ;;
esac
ok "4 TEST-FILE-NOT-GATED: a fixture nobody runs in CI is RED, naming the surface"

# ---------------------------------------------------------------------------
# 5. REGISTRY-INCOMPLETE: a surface missing one of its three case rows is
#    RED, naming the missing case.
# ---------------------------------------------------------------------------
count
grep -v $'\tempty\t' "$REGISTRY" >"$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "5: a surface missing its empty-case row should be RED, got rc=0:
$out"
case "$out" in
  *"REGISTRY-INCOMPLETE"*"fake/surface.sh"*"'empty'"*) ;;
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
fake/surface.sh	absent	covered	$TESTFILE	fake-absent-case: exit 1 on absent input
fake/surface.sh	unreadable	covered	$TESTFILE	fake-unreadable-case: exit 1 on unreadable input
fake/surface.sh	empty	not-applicable	-
EOF
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
reset_b_registry
[[ "$rc" -ne 0 ]] || fail "6: an unjustified not-applicable row should be RED, got rc=0:
$out"
case "$out" in
  *"NOT-APPLICABLE-UNJUSTIFIED"*"fake/surface.sh"*) ;;
  *) fail "6: expected a NOT-APPLICABLE-UNJUSTIFIED line, got:
$out" ;;
esac
ok "6 NOT-APPLICABLE-UNJUSTIFIED: an empty-reason not-applicable row is RED, never a free pass"

# ---------------------------------------------------------------------------
# 7. REGISTRY-ALLOWLIST-COLLISION: a surface fully registered as covered AND
#    named on the allowlist is RED — it must be one or the other.
# ---------------------------------------------------------------------------
count
printf 'fake/surface.sh\tsome reason\n' >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
: >"$ALLOWLIST"
[[ "$rc" -ne 0 ]] || fail "7: a surface on both the registry and the allowlist should be RED, got rc=0:
$out"
case "$out" in
  *"REGISTRY-ALLOWLIST-COLLISION"*"fake/surface.sh"*) ;;
  *) fail "7: expected a REGISTRY-ALLOWLIST-COLLISION line, got:
$out" ;;
esac
ok "7 REGISTRY-ALLOWLIST-COLLISION: a surface cannot be both covered and allowlisted"

# ---------------------------------------------------------------------------
# 8. ALLOWLIST-UNJUSTIFIED: an allowlist row with an empty reason is RED.
# ---------------------------------------------------------------------------
count
printf 'some/other-surface.sh\t\n' >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
: >"$ALLOWLIST"
[[ "$rc" -ne 0 ]] || fail "8: an unjustified allowlist entry should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-UNJUSTIFIED"*"some/other-surface.sh"*) ;;
  *) fail "8: expected an ALLOWLIST-UNJUSTIFIED line, got:
$out" ;;
esac
ok "8 ALLOWLIST-UNJUSTIFIED: an empty-reason allowlist entry is RED, never a silent grandfather"

# ---------------------------------------------------------------------------
# SECTION G — the allowlist ratchet, against a throwaway git fixture repo.
# ---------------------------------------------------------------------------
G="$WORK/g"
mkdir -p "$G"
gitc -C "$G" init -q
git -C "$G" symbolic-ref HEAD refs/heads/main
G_ALLOWLIST_REL="allowlist.tsv"
printf 'old/surface.sh\tpre-existing, never touched by this test\n' >"$G/$G_ALLOWLIST_REL"
gitc -C "$G" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$G" commit -q -m "base: one pre-existing allowlist entry"
G_BASE="$(git -C "$G" rev-parse HEAD)"
G_REGISTRY="$WORK/g-registry.tsv" # empty registry — this section is allowlist-only
: >"$G_REGISTRY"
G_QG="$WORK/g-qg.sh"
: >"$G_QG"

# ---------------------------------------------------------------------------
# 9. ALLOWLIST-GREW: a NEW entry, absent at the base ref, is RED naming it.
# ---------------------------------------------------------------------------
count
printf 'old/surface.sh\tpre-existing, never touched by this test\nnew/surface.sh\tjust added, should be caught\n' >"$G/$G_ALLOWLIST_REL"
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "9: a newly-added allowlist entry should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"new/surface.sh"*) ;;
  *) fail "9: expected an ALLOWLIST-GREW line naming new/surface.sh, got:
$out" ;;
esac
ok "9 ALLOWLIST-GREW: an entry absent at the base ref is RED, naming it"

# ---------------------------------------------------------------------------
# 10. Shrinking is legal: removing an entry (never adding one) is GREEN.
# ---------------------------------------------------------------------------
count
: >"$G/$G_ALLOWLIST_REL" # the list is now EMPTY — a pure shrink from the base ref's one entry
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "10: shrinking the allowlist (removing an entry) should stay GREEN, got rc=$rc:
$out"
ok "10 shrinking the allowlist (removing an entry, adding none) stays GREEN"

# ---------------------------------------------------------------------------
# 11. BOOTSTRAP: the base ref has no allowlist file at all (this commit is
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
BOOT_ALLOWLIST="$BOOT_DIR/brand-new-allowlist.tsv"
printf 'brand/new-surface.sh\tthis PR introduces the file itself\n' >"$BOOT_ALLOWLIST"
BOOT_REGISTRY="$WORK/g-boot-registry.tsv"
: >"$BOOT_REGISTRY"
BOOT_QG="$WORK/g-boot-qg.sh"
: >"$BOOT_QG"
rc=0
out="$(run_gate "$BOOT_REGISTRY" "$BOOT_ALLOWLIST" "$BOOT_QG" "$BOOT_DIR" "$BOOT_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "11: a brand-new allowlist file (absent at the base ref) should be GREEN (bootstrap), got rc=$rc:
$out"
ok "11 bootstrap: an allowlist file absent at the base ref is legal on the commit that introduces it"

# ---------------------------------------------------------------------------
# 12. CANNOT EVALUATE: an unresolvable base ref is a hard, non-zero abort —
#     never a silent pass, since "did it grow" is undecidable without a
#     comparison point.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$G_REGISTRY" "$G/$G_ALLOWLIST_REL" "$G_QG" "$G" "refs/does-not-exist-anywhere" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "12: an unresolvable ratchet base ref should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "12: expected a CANNOT EVALUATE line, got:
$out" ;; esac
case "$out" in *"CANNOT_EVALUATE"*) ;; *) fail "12: expected the machine outcome CANNOT_EVALUATE on stdout, got:
$out" ;; esac
ok "12 an unresolvable allowlist ratchet base ref is CANNOT EVALUATE, non-zero, never a silent pass"

# ---------------------------------------------------------------------------
# 13. CANNOT EVALUATE: an absent registry file.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$WORK/does-not-exist-registry.tsv" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "13: an absent registry file should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "13: expected a CANNOT EVALUATE line, got:
$out" ;; esac
ok "13 an absent registry file is CANNOT EVALUATE, non-zero, never a silent pass"

# ---------------------------------------------------------------------------
# 14. CANNOT EVALUATE: a registered TEST_FILE that does not exist.
# ---------------------------------------------------------------------------
count
GHOST_REGISTRY="$WORK/ghost-registry.tsv"
cat >"$GHOST_REGISTRY" <<EOF
ghost/surface.sh	absent	covered	$WORK/does-not-exist-test-file.sh	some anchor
ghost/surface.sh	unreadable	not-applicable	-	no analog for this fake surface
ghost/surface.sh	empty	not-applicable	-	no analog for this fake surface
EOF
rc=0
out="$(run_gate "$GHOST_REGISTRY" "$ALLOWLIST" "$QG" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "14: a registered TEST_FILE that does not exist should be CANNOT EVALUATE, got rc=0:
$out"
case "$out" in *"CANNOT EVALUATE"*) ;; *) fail "14: expected a CANNOT EVALUATE line, got:
$out" ;; esac
ok "14 a registered TEST_FILE that does not exist is CANNOT EVALUATE, never a silent pass"

echo
echo "$pass/$total tests passed"
[[ "$pass" -eq "$total" ]] || exit 1
