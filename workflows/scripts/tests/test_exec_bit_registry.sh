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

# OVERLAY_FILE — the registry OVERLAY EXTENSION seam (temperloop#1876) every
# run_gate call points at. Defaults to a path that does not exist, so tests
# 1-15 (written before the overlay axis existed) see exactly the kernel-only
# shape they always did — AND are hermetic: without this override the gate
# would fall back to its real default, the SHIPPED overlay path in this repo,
# so an overlay file appearing there later would silently leak into every
# fixture. SECTION K below re-points it deliberately.
OVERLAY_FILE="$WORK/no-such-overlay.tsv"

# run_gate <registry> <allowlist> <repo-root> [base-ref]
run_gate() {
  local registry="$1" allowlist="$2" repo_root="$3" base_ref="${4:-}"
  env \
    EXEC_BIT_REGISTRY_FILE="$registry" \
    EXEC_BIT_REGISTRY_OVERLAY_FILE="$OVERLAY_FILE" \
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
# SECTION K — the OVERLAY EXTENSION axis and the UNADOPTED-UPSTREAM-ROW
# tolerance (temperloop#1876). Every assertion here is DISCRIMINATING: each
# tolerated case is paired with the case that must still FAIL, so a tolerance
# that over-fired (or that hollowed out the gate's real job) goes red.
#
# The fixture is deliberately NOT a git repo — the `.kernel-pin` consumer
# discriminator is a plain file test, and these tests are about the tolerance,
# not the ratchet (SECTION G owns that).
# ---------------------------------------------------------------------------
K="$WORK/k"
mkdir -p "$K"
K_REGISTRY="$K/registry.tsv"
K_OVERLAY="$K/registry.overlay.tsv"
K_ALLOWLIST="$K/allowlist.tsv"
K_PIN="$K/.kernel-pin"
# ADOPTED: present and executable — the "row that must still be checked for
# real" control. UNADOPTED: deliberately NEVER created on disk.
printf '#!/usr/bin/env bash\necho hi\n' >"$K/adopted-hook.sh"
chmod 755 "$K/adopted-hook.sh"
K_UNADOPTED="unadopted-kernel-hook.sh"

reset_k() {
  {
    printf 'adopted-hook.sh\tadopted by this consumer: present and executable\n'
    printf '%s\ta kernel hook this consumer never adopted\n' "$K_UNADOPTED"
  } >"$K_REGISTRY"
  : >"$K_OVERLAY"
  : >"$K_ALLOWLIST"
  chmod 755 "$K/adopted-hook.sh"
}
reset_k
OVERLAY_FILE="$K_OVERLAY"

# ---------------------------------------------------------------------------
# 16. TOLERANCE, direction 1 — WITH a repo-root .kernel-pin, a KERNEL-owned
#     row naming an absent path is GREEN and is REPORTED as a note (never
#     silently skipped: a silent skip is the "gate looks like it passed when
#     it never ran" failure this suite exists to prevent).
# ---------------------------------------------------------------------------
count
printf 'tag: v0.37.0\n' >"$K_PIN"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "16: a kernel row for unadopted content should be GREEN under .kernel-pin, got rc=$rc:
$out"
case "$out" in
  *"note: registry row $K_UNADOPTED names a script this repo did not adopt"*"temperloop#1876"*) ;;
  *) fail "16: expected a reported note line naming $K_UNADOPTED and citing temperloop#1876, got:
$out" ;;
esac
case "$out" in
  *"PATH-NOT-FOUND"*) fail "16: the tolerated row must not also emit PATH-NOT-FOUND, got:
$out" ;;
esac
ok "16 tolerance (with .kernel-pin): a kernel row for unadopted content is GREEN and REPORTED, not silent"

# ---------------------------------------------------------------------------
# 17. TOLERANCE, direction 2 — the SAME registry, the SAME absent path, in a
#     tree with NO .kernel-pin (i.e. the kernel's own repo) still FAILS
#     PATH-NOT-FOUND. This is the over-tolerance guard: without it, test 16
#     alone would pass just as happily against a blanket mute.
# ---------------------------------------------------------------------------
count
rm -f "$K_PIN"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "17: with NO .kernel-pin the same absent path must still be RED, got rc=0:
$out"
case "$out" in
  *"PATH-NOT-FOUND"*"$K_UNADOPTED"*) ;;
  *) fail "17: expected PATH-NOT-FOUND naming $K_UNADOPTED, got:
$out" ;;
esac
case "$out" in
  *"note: registry row $K_UNADOPTED"*) fail "17: no tolerance note may be emitted without a .kernel-pin, got:
$out" ;;
esac
ok "17 no tolerance (no .kernel-pin): the same absent path still fails PATH-NOT-FOUND"

# ---------------------------------------------------------------------------
# 18. The improved PATH-NOT-FOUND remediation text names the adopted-subset
#     case AND warns off the wrong remedy (symlinking kernel content into a
#     consumer — the mis-remediation temperloop#1840's wording walked an
#     operator into). Asserted on test 17's own output.
# ---------------------------------------------------------------------------
count
case "$out" in
  *"VENDORING CONSUMER"*".kernel-pin"*) ;;
  *) fail "18: expected the PATH-NOT-FOUND line to name the adopted-subset case and .kernel-pin, got:
$out" ;;
esac
case "$out" in
  *"Do NOT symlink kernel content"*) ;;
  *) fail "18: expected the PATH-NOT-FOUND line to warn off symlinking kernel content in, got:
$out" ;;
esac
ok "18 PATH-NOT-FOUND names the adopted-subset remediation and warns off the wrong remedy recorded in temperloop#1840"

# ---------------------------------------------------------------------------
# 19. CONDITION (b) PRESERVED — with the .kernel-pin present, an OVERLAY-
#     authored row naming an absent path STILL FAILS. "Upstream ships more
#     than I adopted" is tolerated; "my own ledger has rotted" is not.
# ---------------------------------------------------------------------------
count
printf 'tag: v0.37.0\n' >"$K_PIN"
printf 'overlay-owned-missing.sh\ta script this consumer owns and lost\n' >"$K_OVERLAY"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "19: an overlay-authored row naming an absent path must be RED even under .kernel-pin, got rc=0:
$out"
case "$out" in
  *"PATH-NOT-FOUND"*"overlay-owned-missing.sh"*) ;;
  *) fail "19: expected PATH-NOT-FOUND naming overlay-owned-missing.sh, got:
$out" ;;
esac
case "$out" in
  *"row from $K_OVERLAY"*) ;;
  *) fail "19: expected the failure to name the OVERLAY file as the row's source, got:
$out" ;;
esac
# ...and the kernel row's tolerance is unaffected by the overlay row's failure.
case "$out" in
  *"note: registry row $K_UNADOPTED names a script this repo did not adopt"*) ;;
  *) fail "19: the kernel row should still be tolerated and reported, got:
$out" ;;
esac
ok "19 condition (b): an OVERLAY-authored row naming an absent path still FAILS under .kernel-pin"
reset_k

# ---------------------------------------------------------------------------
# 20. MUTATION PROOF — the tolerance did not hollow out the gate's real job.
#     With the .kernel-pin present AND a tolerated unadopted row in the same
#     registry, dropping the executable bit on a path that DOES exist is
#     still RED (EXEC-BIT-MISSING, naming the file and its actual mode).
#     Restore -> GREEN, with the tolerance note still reported.
# ---------------------------------------------------------------------------
count
printf 'tag: v0.37.0\n' >"$K_PIN"
chmod 644 "$K/adopted-hook.sh"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "20a: EXEC-BIT-MISSING must still fire alongside a tolerated row, got rc=0:
$out"
case "$out" in
  *"EXEC-BIT-MISSING"*"adopted-hook.sh"*"mode is 644"*) ;;
  *) fail "20a: expected EXEC-BIT-MISSING naming adopted-hook.sh and mode 644, got:
$out" ;;
esac
ok "20a mutation proof: EXEC-BIT-MISSING still fires for a path that DOES exist, tolerance notwithstanding"

count
chmod 755 "$K/adopted-hook.sh"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "20b: restoring the bit should return the fixture to GREEN, got rc=$rc:
$out"
case "$out" in
  *"note: registry row $K_UNADOPTED"*) ;;
  *) fail "20b: expected the tolerance note to survive the restore, got:
$out" ;;
esac
ok "20b restoring the bit returns to GREEN with the tolerance note still reported"

# ---------------------------------------------------------------------------
# 21. MUTATION PROOF, second gate — MISSING-REASON still fires for a
#     KERNEL-owned row under a .kernel-pin. The tolerance is scoped to
#     EXISTENCE alone; a present path's other checks are untouched.
# ---------------------------------------------------------------------------
count
printf 'adopted-hook.sh\t\n%s\ta kernel hook this consumer never adopted\n' "$K_UNADOPTED" >"$K_REGISTRY"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "21: MISSING-REASON must still fire under a .kernel-pin, got rc=0:
$out"
case "$out" in *"MISSING-REASON"*"adopted-hook.sh"*) ;; *) fail "21: expected MISSING-REASON naming adopted-hook.sh, got:
$out" ;; esac
ok "21 mutation proof: MISSING-REASON still fires under a .kernel-pin"
reset_k

# ---------------------------------------------------------------------------
# 22. MUTATION PROOF, third gate — GRANDFATHER-STALE still fires under a
#     .kernel-pin (a path that became compliant but is still allowlisted).
# ---------------------------------------------------------------------------
count
printf 'adopted-hook.sh\tstale debt entry\n' >"$K_ALLOWLIST"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "22: GRANDFATHER-STALE must still fire under a .kernel-pin, got rc=0:
$out"
case "$out" in *"GRANDFATHER-STALE"*"adopted-hook.sh"*) ;; *) fail "22: expected GRANDFATHER-STALE naming adopted-hook.sh, got:
$out" ;; esac
ok "22 mutation proof: GRANDFATHER-STALE still fires under a .kernel-pin"
reset_k

# ---------------------------------------------------------------------------
# 23. The OVERLAY EXTENSION is genuinely UNIONED IN: an overlay row naming a
#     present, executable path is checked like any other and reported in the
#     verdict line's overlay count. (Without this, the overlay file could be
#     ignored entirely and every test above would still pass.)
# ---------------------------------------------------------------------------
count
printf '#!/usr/bin/env bash\necho hi\n' >"$K/consumer-own-hook.sh"
chmod 755 "$K/consumer-own-hook.sh"
printf 'consumer-own-hook.sh\tthis consumer owns and directly invokes it\n' >"$K_OVERLAY"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "23a: a compliant overlay row should be GREEN, got rc=$rc:
$out"
case "$out" in
  *"of which 1 from the overlay extension $K_OVERLAY"*) ;;
  *) fail "23a: expected the verdict line to report 1 overlay row, got:
$out" ;;
esac
ok "23a the overlay extension is unioned in and counted in the verdict line"

count
chmod 644 "$K/consumer-own-hook.sh"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "23b: an overlay row's dropped bit should be RED, got rc=0:
$out"
case "$out" in *"EXEC-BIT-MISSING"*"consumer-own-hook.sh"*) ;; *) fail "23b: expected EXEC-BIT-MISSING naming consumer-own-hook.sh, got:
$out" ;; esac
ok "23b an overlay row is enforced exactly like a kernel row (dropped bit -> RED)"
chmod 755 "$K/consumer-own-hook.sh"

# ---------------------------------------------------------------------------
# 24. DUPLICATE-PATH across the union names the file the offending row
#     actually came from — with two source files in play, a message
#     hardcoding the kernel path would send someone hunting in the wrong one.
# ---------------------------------------------------------------------------
count
printf 'adopted-hook.sh\tduplicated by the overlay\n' >"$K_OVERLAY"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
[[ "$rc" -ne 0 ]] || fail "24: a path registered in BOTH files should be RED, got rc=0:
$out"
case "$out" in
  *"DUPLICATE-PATH"*"adopted-hook.sh"*"this row from $K_OVERLAY"*) ;;
  *) fail "24: expected DUPLICATE-PATH naming the overlay file as the duplicate row's source, got:
$out" ;;
esac
ok "24 DUPLICATE-PATH across the kernel/overlay union names the offending row's own source file"
reset_k

# ---------------------------------------------------------------------------
# 25. An UNREADABLE overlay extension is CANNOT EVALUATE (rc=2), never a
#     silent pass — silently skipping it would drop every consumer-owned row
#     and read as a clean run. (An ABSENT overlay is the kernel-only default
#     and stays legal — tests 1-15 above all exercise exactly that.)
# ---------------------------------------------------------------------------
count
printf 'consumer-own-hook.sh\tthis consumer owns and directly invokes it\n' >"$K_OVERLAY"
chmod 000 "$K_OVERLAY"
rc=0
out="$(run_gate "$K_REGISTRY" "$K_ALLOWLIST" "$K" 2>&1)" || rc=$?
chmod 644 "$K_OVERLAY"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: 25 unreadable-overlay check meaningless as root" >&2
else
  [[ "$rc" -eq 2 ]] || fail "25: an unreadable overlay should CANNOT EVALUATE (rc=2), got rc=$rc:
$out"
  case "$out" in
    *"CANNOT EVALUATE"*"registry overlay extension exists but is not readable"*) ;;
    *) fail "25: expected a CANNOT EVALUATE / overlay-not-readable line, got:
$out" ;;
  esac
fi
ok "25 an unreadable overlay extension is CANNOT EVALUATE (rc=2), not a silent pass"
reset_k
rm -f "$K_PIN"

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "---"
echo "test_exec_bit_registry: $pass/$total passed"
[[ "$pass" -eq "$total" ]] || exit 1
exit 0
