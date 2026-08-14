#!/usr/bin/env bash
#
# test_exec_bit_registry.sh — fixture suite for
# workflows/scripts/validate-exec-bit-registry.sh (temperloop#1326, epic
# #1415 "gate the dropped executable bit, keyed to a registry").
#
# Every assertion below either (a) confirms the gate is GREEN on a fixture
# that should pass, or (b) MUTATES a fixture to break exactly one thing,
# confirms the gate goes RED naming the exact path (and, for the executable-
# bit check, the actual mode), then restores and confirms GREEN again.
#
# Every test drives the gate through its fixture-seam env vars
# (EXEC_BIT_REGISTRY_FILE / _ALLOWLIST_FILE / _GIT_REPO_ROOT / _REPO_ROOT /
# _ALLOWLIST_BASE_REF), so nothing here touches the real committed registry
# except test 1 (a sanity check that the real, shipped registry/allowlist
# are mutually consistent right now — this is the item's own red-before/
# green-after live instance: workflows/scripts/validate-check-surface-
# degenerate-coverage.sh had lost its bit and this gate now protects it).
#
# Hermetic: throwaway mktemp dirs plus a throwaway git fixture repo for the
# ratchet tests — no network, nothing under this repo's real .temperloop/
# state.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
GATE="$REPO_ROOT/workflows/scripts/validate-exec-bit-registry.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-exec-bit-registry-XXXXXX")" || exit 1
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

gitc() { git -c user.name="Exec-Bit Test" -c user.email="exec-bit-test@example.com" -c commit.gpgsign=false "$@"; }

# run_gate <registry> <allowlist> <repo-root> [base-ref]
run_gate() {
  local registry="$1" allowlist="$2" repo_root="$3" base_ref="${4:-}"
  env \
    EXEC_BIT_REGISTRY_FILE="$registry" \
    EXEC_BIT_ALLOWLIST_FILE="$allowlist" \
    EXEC_BIT_GIT_REPO_ROOT="$repo_root" \
    EXEC_BIT_ALLOWLIST_BASE_REF="$base_ref" \
    EXEC_BIT_REPO_ROOT="$repo_root" \
    bash "$GATE"
}

# ---------------------------------------------------------------------------
# 1. SANITY: the real, shipped registry/allowlist (no env overrides) are
#    mutually consistent right now — every registered path is 755.
# ---------------------------------------------------------------------------
count
rc=0
out="$(bash "$GATE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "1: the real committed registry/allowlist should pass the gate cleanly, got rc=$rc:
$out"
case "$out" in *"validate-exec-bit-registry: OK"*) ;; *) fail "1: expected an OK verdict line, got:
$out" ;; esac
ok "1 the real committed registry/allowlist are mutually consistent"

# ---------------------------------------------------------------------------
# SECTION B — a minimal single-path fixture tree, reused by tests 2-9.
# ---------------------------------------------------------------------------
B="$WORK/b"
mkdir -p "$B"
REGISTRY="$B/registry.tsv"
ALLOWLIST="$B/allowlist.tsv"
FIXTURE="fixture-script.sh"
printf '#!/usr/bin/env bash\necho hi\n' >"$B/$FIXTURE"
chmod 755 "$B/$FIXTURE"

reset_b_registry() {
  printf '%s\tfixture entrypoint for the test suite\n' "$FIXTURE" >"$REGISTRY"
}
reset_b_registry
: >"$ALLOWLIST"

# B is deliberately NOT a git repo — the gate's documented behavior for an
# allowlist file not under a resolvable git working tree is "skip the
# ratchet" (a scoping choice, not CANNOT EVALUATE), which is exactly what
# tests 2-9 want since none of them are about the ratchet. The ratchet gets
# its own dedicated git fixture in SECTION G below.

# ---------------------------------------------------------------------------
# 2. A fresh, correct fixture tree is GREEN.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "2: a correct single-entry fixture should be GREEN, got rc=$rc:
$out"
case "$out" in *"validate-exec-bit-registry: OK"*) ;; *) fail "2: expected OK, got:
$out" ;; esac
ok "2 a fresh, correct fixture tree is GREEN"

# ---------------------------------------------------------------------------
# 3. EXEC-BIT-MISSING discrimination: drop the fixture's executable bit ->
#    RED, naming the path AND its actual mode. Restore -> GREEN. This is the
#    item's own acceptance-criterion-3 shape, reproduced on a throwaway
#    fixture (the sanity test above already proves it on the real, live
#    validate-check-surface-degenerate-coverage.sh instance).
# ---------------------------------------------------------------------------
count
chmod 644 "$B/$FIXTURE"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "3a: a registered path missing its executable bit should be RED, got rc=0:
$out"
case "$out" in
  *"EXEC-BIT-MISSING"*"$FIXTURE"*"mode is 644"*) ;;
  *) fail "3a: expected an EXEC-BIT-MISSING line naming $FIXTURE and mode 644, got:
$out" ;;
esac
ok "3a EXEC-BIT-MISSING: a dropped bit goes RED, naming the file and its actual mode (644)"

count
chmod 755 "$B/$FIXTURE"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "3b: restoring the bit should return the fixture to GREEN, got rc=$rc:
$out"
ok "3b restoring the executable bit returns the gate to GREEN"

# ---------------------------------------------------------------------------
# 4. PATH-NOT-FOUND: a registered path that does not exist in the tree.
# ---------------------------------------------------------------------------
count
printf 'does-not-exist.sh\tnever created\n' >"$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "4: a registered path that does not exist should be RED, got rc=0:
$out"
case "$out" in *"PATH-NOT-FOUND"*"does-not-exist.sh"*) ;; *) fail "4: expected PATH-NOT-FOUND naming the missing path, got:
$out" ;; esac
ok "4 PATH-NOT-FOUND: a registered path absent from the tree is RED, naming it"
reset_b_registry

# ---------------------------------------------------------------------------
# 5. MISSING-REASON: an empty REASON column is RED.
# ---------------------------------------------------------------------------
count
printf '%s\t\n' "$FIXTURE" >"$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "5: an empty REASON should be RED, got rc=0:
$out"
case "$out" in *"MISSING-REASON"*"$FIXTURE"*) ;; *) fail "5: expected MISSING-REASON naming $FIXTURE, got:
$out" ;; esac
ok "5 MISSING-REASON: a registry row with an empty REASON is RED"
reset_b_registry

# ---------------------------------------------------------------------------
# 6. DUPLICATE-PATH: the same path registered twice is RED.
# ---------------------------------------------------------------------------
count
{
  printf '%s\tfirst\n' "$FIXTURE"
  printf '%s\tsecond\n' "$FIXTURE"
} >"$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "6: a duplicate registry row should be RED, got rc=0:
$out"
case "$out" in *"DUPLICATE-PATH"*"$FIXTURE"*) ;; *) fail "6: expected DUPLICATE-PATH naming $FIXTURE, got:
$out" ;; esac
ok "6 DUPLICATE-PATH: registering the same path twice is RED"
reset_b_registry

# ---------------------------------------------------------------------------
# 7. Grandfather allowlist: a non-compliant registered path that IS listed
#    on the allowlist is a reported KNOWN-DEBT line, not a failure.
# ---------------------------------------------------------------------------
count
chmod 644 "$B/$FIXTURE"
printf '%s\ttracked debt, fix later\n' "$FIXTURE" >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "7: a grandfathered non-compliant path should stay GREEN, got rc=$rc:
$out"
case "$out" in *"KNOWN-DEBT"*"$FIXTURE"*) ;; *) fail "7: expected a KNOWN-DEBT line naming $FIXTURE, got:
$out" ;; esac
ok "7 a grandfathered non-compliant path is GREEN with a reported KNOWN-DEBT line, not a failure"

# ---------------------------------------------------------------------------
# 8. GRANDFATHER-STALE: the same path becomes compliant (bit restored) but
#    is still listed on the allowlist -> RED (debt must be paid down by
#    removing the exemption, not just fixing the bit).
# ---------------------------------------------------------------------------
count
chmod 755 "$B/$FIXTURE"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "8: a compliant-but-still-grandfathered path should be RED, got rc=0:
$out"
case "$out" in *"GRANDFATHER-STALE"*"$FIXTURE"*) ;; *) fail "8: expected GRANDFATHER-STALE naming $FIXTURE, got:
$out" ;; esac
ok "8 GRANDFATHER-STALE: a path that became compliant but is still allowlisted is RED"
: >"$ALLOWLIST"

# ---------------------------------------------------------------------------
# 9. ALLOWLIST-UNREGISTERED: an allowlist entry for a path the registry does
#    not carry at all.
# ---------------------------------------------------------------------------
count
printf 'never-registered.sh\tsome reason\n' >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "9: an allowlist entry for an unregistered path should be RED, got rc=0:
$out"
case "$out" in *"ALLOWLIST-UNREGISTERED"*"never-registered.sh"*) ;; *) fail "9: expected ALLOWLIST-UNREGISTERED naming never-registered.sh, got:
$out" ;; esac
ok "9 ALLOWLIST-UNREGISTERED: allowlisting a path the registry does not carry is RED"
: >"$ALLOWLIST"

# ---------------------------------------------------------------------------
# 10. ALLOWLIST-UNJUSTIFIED: an allowlist row with an empty REASON is RED.
# ---------------------------------------------------------------------------
count
printf '%s\t\n' "$FIXTURE" >"$ALLOWLIST"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "10: an allowlist row with an empty REASON should be RED, got rc=0:
$out"
case "$out" in *"ALLOWLIST-UNJUSTIFIED"*"$FIXTURE"*) ;; *) fail "10: expected ALLOWLIST-UNJUSTIFIED naming $FIXTURE, got:
$out" ;; esac
ok "10 ALLOWLIST-UNJUSTIFIED: an allowlist row with an empty REASON is RED"
: >"$ALLOWLIST"

# ---------------------------------------------------------------------------
# 11. EMPTY-REGISTRY: a registry with zero parsed rows is RED, not a vacuous
#     pass.
# ---------------------------------------------------------------------------
count
: >"$REGISTRY"
rc=0
out="$(run_gate "$REGISTRY" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "11: an empty registry should be RED, got rc=0:
$out"
case "$out" in *"EMPTY-REGISTRY"*) ;; *) fail "11: expected EMPTY-REGISTRY, got:
$out" ;; esac
ok "11 EMPTY-REGISTRY: an empty registry fails rather than passing vacuously"
reset_b_registry

# ---------------------------------------------------------------------------
# 12. CANNOT EVALUATE: absent and unreadable registry files fail closed
#     (rc=2, RC_CANNOT_EVALUATE), never a silent pass.
# ---------------------------------------------------------------------------
count
rc=0
out="$(run_gate "$B/does-not-exist.tsv" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
[[ "$rc" -eq 2 ]] || fail "12a: an absent registry should CANNOT EVALUATE (rc=2), got rc=$rc:
$out"
case "$out" in *"CANNOT EVALUATE"*"registry file not found"*) ;; *) fail "12a: expected a CANNOT EVALUATE line, got:
$out" ;; esac
ok "12a an absent registry file is CANNOT EVALUATE (rc=2), not a silent pass"

count
UNREADABLE="$B/unreadable-registry.tsv"
reset_b_registry
cp "$REGISTRY" "$UNREADABLE"
chmod 000 "$UNREADABLE"
rc=0
out="$(run_gate "$UNREADABLE" "$ALLOWLIST" "$B" 2>&1)" || rc=$?
chmod 644 "$UNREADABLE"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: 12b unreadable-registry check meaningless as root" >&2
else
  [[ "$rc" -eq 2 ]] || fail "12b: an unreadable registry should CANNOT EVALUATE (rc=2), got rc=$rc:
$out"
  case "$out" in *"CANNOT EVALUATE"*"not readable"*) ;; *) fail "12b: expected a CANNOT EVALUATE / not-readable line, got:
$out" ;; esac
fi
ok "12b an unreadable registry file is CANNOT EVALUATE (rc=2), not a silent pass"

# ---------------------------------------------------------------------------
# SECTION G — the allowlist ratchet, against a throwaway git fixture repo.
# ---------------------------------------------------------------------------
G="$WORK/g"
mkdir -p "$G"
gitc -C "$G" init -q
git -C "$G" symbolic-ref HEAD refs/heads/main
printf '#!/usr/bin/env bash\necho hi\n' >"$G/old-fixture.sh"
printf '#!/usr/bin/env bash\necho hi\n' >"$G/new-fixture.sh"
# old-fixture.sh stays genuinely non-compliant (644) — it is the pre-existing
# grandfathered debt these ratchet tests must not disturb. new-fixture.sh
# stays COMPLIANT (755) — these tests are about the ALLOWLIST ratchet, not
# the executable-bit check, so it must never itself trip EXEC-BIT-MISSING.
chmod 644 "$G/old-fixture.sh"
chmod 755 "$G/new-fixture.sh"
G_REGISTRY_REL="registry.tsv"
G_ALLOWLIST_REL="allowlist.tsv"
{
  printf 'old-fixture.sh\tpre-existing debt, never touched by this test\n'
  printf 'new-fixture.sh\tpre-existing debt, never touched by this test\n'
} >"$G/$G_REGISTRY_REL"
printf 'old-fixture.sh\tpre-existing, never touched by this test\n' >"$G/$G_ALLOWLIST_REL"
gitc -C "$G" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$G" commit -q -m "base: one pre-existing allowlist entry"
G_BASE="$(git -C "$G" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 13. ALLOWLIST-GREW: a NEW entry, absent at the base ref, is RED naming it.
# ---------------------------------------------------------------------------
count
printf 'old-fixture.sh\tpre-existing, never touched by this test\nnew-fixture.sh\tjust added, should be caught\n' >"$G/$G_ALLOWLIST_REL"
rc=0
out="$(run_gate "$G/$G_REGISTRY_REL" "$G/$G_ALLOWLIST_REL" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "13: a newly-added allowlist entry should be RED, got rc=0:
$out"
case "$out" in
  *"ALLOWLIST-GREW"*"new-fixture.sh"*) ;;
  *) fail "13: expected an ALLOWLIST-GREW line naming new-fixture.sh, got:
$out" ;;
esac
case "$out" in
  *"allowlist ratchet: checked against $G_BASE:$G_ALLOWLIST_REL"*) ;;
  *) fail "13: expected a one-line allowlist-ratchet verdict naming the compared ref, got:
$out" ;;
esac
ok "13 ALLOWLIST-GREW: an entry absent at the base ref is RED, naming it, with the ratchet verdict line present"

# ---------------------------------------------------------------------------
# 14. Shrinking is legal: removing an entry (never adding one) is GREEN.
#     Shrink back to exactly the base ref's one entry (old-fixture.sh stays
#     grandfathered — it is genuinely non-compliant, mode 644 — dropping it
#     too would trip EXEC-BIT-MISSING and mask what this test checks).
# ---------------------------------------------------------------------------
count
printf 'old-fixture.sh\tpre-existing, never touched by this test\n' >"$G/$G_ALLOWLIST_REL"
rc=0
out="$(run_gate "$G/$G_REGISTRY_REL" "$G/$G_ALLOWLIST_REL" "$G" "$G_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "14: shrinking the allowlist (removing an entry) should stay GREEN, got rc=$rc:
$out"
ok "14 shrinking the allowlist (removing an entry, adding none) stays GREEN"

# ---------------------------------------------------------------------------
# 15. BOOTSTRAP: the base ref has no allowlist file at all (this commit is
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
printf '#!/usr/bin/env bash\necho hi\n' >"$BOOT_DIR/brand-new-fixture.sh"
chmod 644 "$BOOT_DIR/brand-new-fixture.sh"
BOOT_REGISTRY="$BOOT_DIR/brand-new-registry.tsv"
printf 'brand-new-fixture.sh\tthis PR introduces the file itself\n' >"$BOOT_REGISTRY"
BOOT_ALLOWLIST="$BOOT_DIR/brand-new-allowlist.tsv"
printf 'brand-new-fixture.sh\tthis PR introduces the file itself\n' >"$BOOT_ALLOWLIST"
# STAGE it (git add, no commit): `git diff <ref>` only ever sees TRACKED or
# STAGED content — a purely untracked file is invisible to `git diff`
# regardless of --diff-filter, so the bootstrap detection this test exists
# to prove would never even see the file without this.
gitc -C "$BOOT_DIR" add "$BOOT_ALLOWLIST" "$BOOT_REGISTRY" "$BOOT_DIR/brand-new-fixture.sh"
rc=0
out="$(run_gate "$BOOT_REGISTRY" "$BOOT_ALLOWLIST" "$BOOT_DIR" "$BOOT_BASE" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "15: a brand-new allowlist file (absent at the base ref) should be GREEN (bootstrap), got rc=$rc:
$out"
case "$out" in
  *"allowlist ratchet: SKIPPED (bootstrap"*) ;;
  *) fail "15: expected a bootstrap SKIPPED ratchet verdict line, got:
$out" ;;
esac
ok "15 bootstrap: an allowlist file added in this diff is legal on the commit that introduces it, and says so"

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "---"
echo "test_exec_bit_registry: $pass/$total passed"
[[ "$pass" -eq "$total" ]] || exit 1
exit 0
