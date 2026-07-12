#!/usr/bin/env bash
#
# Tests for check-knob-registry.sh (temperloop#164/#169, item
# registry-config-lints): a synthetic fixture repo proves the RED path (a
# default mismatch, a missing seam, an unregistered knob), the GREEN path
# (fixing each), every exemption mechanism (the `_`-prefix/generic-allowlist/
# `*_NOW` pattern auto-exclusions, the same-line `# knob:exempt` marker, the
# wholesale exempt-files list, and the RESERVED-row skip), and the
# layer-aware overlay seam (a kernel row checked against the kernel table
# alone; an overlay `add`/`redefault` row checked against its own
# owning-script; an overlay-only name counted as registered for the
# unregistered-knob sweep).
#
# Mirrors workflows/scripts/kernel/tests/test_check_personal_token_denylist.sh's
# plain mktemp-fixture + real-git-repo style (check-knob-registry.sh's
# unregistered-knob sweep shells out to list-kernel-set.sh, which itself
# shells out to `git ls-files`).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-knob-registry.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/knob-registry-checker-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="$WORK/repo"
mkdir -p "$REPO/pkg"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test

MANIFEST="$WORK/kernel-manifest.txt"
cat >"$MANIFEST" <<'EOF'
kernel pkg/*
EOF

run_checker() {
  (
    KNOB_REGISTRY_FILE="$WORK/kernel.tsv"
    KNOB_REGISTRY_OVERLAY_FILE="$WORK/overlay.tsv"
    KNOB_REGISTRY_SCAN_ROOT="$REPO"
    KNOB_REGISTRY_MANIFEST_FILE="$MANIFEST"
    KNOB_REGISTRY_EXEMPT_FILE="$WORK/exempt.txt"
    export KNOB_REGISTRY_FILE KNOB_REGISTRY_OVERLAY_FILE KNOB_REGISTRY_SCAN_ROOT
    export KNOB_REGISTRY_MANIFEST_FILE KNOB_REGISTRY_EXEMPT_FILE
    bash "$CHECKER"
  )
}

commit_repo() {
  git -C "$REPO" -c core.hooksPath=/dev/null add -A
  git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m "fixture" --allow-empty
}

# --- 1. clean kernel-only fixture: equality + sweep both pass -------------
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=10}"
echo "$KNOB_A"
EOF
echo "" >"$WORK/overlay.tsv"   # absent-equivalent (no rows) — but present so
rm -f "$WORK/overlay.tsv"      # explicitly test the ABSENT-overlay path first
cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_A	10	int	kernel	pkg/a.sh	first test knob
EOF
: >"$WORK/exempt.txt"
commit_repo

out="$(run_checker 2>&1)" || fail "1: clean fixture should pass:
$out"
echo "PASS: 1 clean kernel-only fixture (equality + sweep) passes"

# --- 2. RED: default mismatch ----------------------------------------------
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=99}"
echo "$KNOB_A"
EOF
commit_repo
out="$(run_checker 2>&1)" && fail "2: mismatched default should fail:
$out"
case "$out" in
  *"EQUALITY: mismatch for KNOB_A"*) ;;
  *) fail "2: expected an EQUALITY mismatch message, got:
$out" ;;
esac
echo "PASS: 2 default mismatch correctly flagged (RED)"

# --- 3. GREEN again after reverting -----------------------------------------
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=10}"
echo "$KNOB_A"
EOF
commit_repo
out="$(run_checker 2>&1)" || fail "3: reverted fixture should pass again:
$out"
echo "PASS: 3 clean again after reverting the mismatch (GREEN)"

# --- 4. RED: seam missing entirely (owning-script no longer has it) -------
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
echo "no knob here"
EOF
commit_repo
out="$(run_checker 2>&1)" && fail "4: missing seam should fail:
$out"
case "$out" in
  *"EQUALITY: no shell seam found for KNOB_A"*) ;;
  *) fail "4: expected a 'no shell seam found' message, got:
$out" ;;
esac
echo "PASS: 4 missing seam correctly flagged (RED)"

# --- 5. RESERVED row is skipped (no seam required) -------------------------
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=10}"
echo "$KNOB_A"
EOF
cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_A	10	int	kernel	pkg/a.sh	first test knob
KNOB_RESERVED	future	string	kernel	pkg/nonexistent.sh	RESERVED — no reader yet
EOF
commit_repo
out="$(run_checker 2>&1)" || fail "5: a RESERVED row with no seam should not fail:
$out"
echo "PASS: 5 RESERVED row skipped (no seam required)"

# --- 6. RED: unregistered knob-shaped seam ---------------------------------
cat >"$REPO/pkg/b.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_B:=hello}"
echo "$KNOB_B"
EOF
commit_repo
out="$(run_checker 2>&1)" && fail "6: unregistered knob should fail:
$out"
case "$out" in
  *"UNREGISTERED: pkg/b.sh"*"KNOB_B"*) ;;
  *) fail "6: expected an UNREGISTERED message for KNOB_B, got:
$out" ;;
esac
echo "PASS: 6 unregistered knob-shaped seam correctly flagged (RED)"

# --- 7. GREEN: registering KNOB_B fixes it ----------------------------------
cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_A	10	int	kernel	pkg/a.sh	first test knob
KNOB_RESERVED	future	string	kernel	pkg/nonexistent.sh	RESERVED — no reader yet
KNOB_B	hello	string	kernel	pkg/b.sh	second test knob
EOF
out="$(run_checker 2>&1)" || fail "7: registering KNOB_B should clear the failure:
$out"
echo "PASS: 7 registering the knob clears the unregistered failure (GREEN)"

# --- 8. GREEN: exemption mechanisms (auto + marker + exempt-file) ----------
cat >"$REPO/pkg/c.sh" <<'EOF'
#!/usr/bin/env bash
# a private, generic, test-clock, and marker-exempted "knob" each:
: "${_INTERNAL_C:=1}"
: "${TMPDIR:-/tmp}"
: "${SOME_THING_NOW:-1}"
FOO="${MYSTERY_C:-42}"  # knob:exempt — test fixture, internal computed value
EOF
cat >"$REPO/pkg/d.sh" <<'EOF'
#!/usr/bin/env bash
: "${HEREDOC_ESCAPE_D:-generator text, not a real seam}"
EOF
cat >"$WORK/exempt.txt" <<EOF
pkg/d.sh
EOF
commit_repo
out="$(run_checker 2>&1)" || fail "8: every exemption mechanism should suppress its case:
$out"
echo "PASS: 8 auto-allowlist, *_NOW pattern, same-line marker, and wholesale exempt-file all suppress correctly (GREEN)"

# --- 9. comment-only mention of a knob-shaped seam is never scanned -------
cat >"$REPO/pkg/e.sh" <<'EOF'
#!/usr/bin/env bash
# doc example: ${NOT_A_REAL_KNOB:=default}
echo ok
EOF
commit_repo
out="$(run_checker 2>&1)" || fail "9: a comment-only mention should not be flagged:
$out"
echo "PASS: 9 comment-only mention of a knob-shaped seam is not scanned"

# --- 10. layer-aware overlay: kernel row checked against kernel file alone,
#         overlay add/redefault row checked against its own owning-script --
rm -f "$REPO/pkg/e.sh"
cat >"$REPO/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=10}"
echo "$KNOB_A"
EOF
cat >"$REPO/pkg/overlay_only.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=20}"
: "${KNOB_OVERLAY_ONLY:=overlay-value}"
EOF
cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_A	10	int	kernel	pkg/a.sh	first test knob
KNOB_RESERVED	future	string	kernel	pkg/nonexistent.sh	RESERVED — no reader yet
KNOB_B	hello	string	kernel	pkg/b.sh	second test knob
EOF
cat >"$WORK/overlay.tsv" <<'EOF'
KNOB_A	20	int	kernel	pkg/overlay_only.sh	overlay redefaults KNOB_A for its own call site	redefault
KNOB_OVERLAY_ONLY	overlay-value	string	kernel	pkg/overlay_only.sh	overlay-only addition	add
EOF
commit_repo
out="$(run_checker 2>&1)" || fail "10: layer-aware overlay pass should be clean:
$out"
case "$out" in
  *"equality (overlay extension table)"*) ;;
  *) fail "10: expected the overlay equality pass to have run, got:
$out" ;;
esac
echo "PASS: 10 layer-aware overlay pass: kernel row (10) checked against pkg/a.sh, overlay redefault (20) checked against pkg/overlay_only.sh, both independently clean"

# --- 11. RED: overlay redefault mismatch is caught against its OWN file ---
cat >"$REPO/pkg/overlay_only.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=999}"
: "${KNOB_OVERLAY_ONLY:=overlay-value}"
EOF
commit_repo
out="$(run_checker 2>&1)" && fail "11: overlay redefault mismatch should fail:
$out"
case "$out" in
  *"EQUALITY: mismatch for KNOB_A (overlay row)"*) ;;
  *) fail "11: expected an overlay-row EQUALITY mismatch, got:
$out" ;;
esac
echo "PASS: 11 overlay redefault mismatch caught against its own owning-script (RED)"

# --- 12. KNOB_REGISTRY_OVERLAY_SCAN_ROOT: composed-tree seam (temperloop#243)
#         kernel rows resolve against KNOB_REGISTRY_SCAN_ROOT (pinned to a
#         vendored kernel/ subtree); an overlay add/redefault row's
#         owning-script lives OUTSIDE that subtree, at the composed root,
#         and resolves against KNOB_REGISTRY_OVERLAY_SCAN_ROOT instead.
mkdir -p "$REPO/kernel/pkg" "$REPO/overlay_pkg"
cat >"$REPO/kernel/pkg/a.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_A:=10}"
echo "$KNOB_A"
EOF
cat >"$REPO/overlay_pkg/overlay_composed.sh" <<'EOF'
#!/usr/bin/env bash
: "${KNOB_OVERLAY_COMPOSED:=composed-value}"
EOF
cat >"$WORK/kernel.tsv" <<'EOF'
KNOB_A	10	int	kernel	pkg/a.sh	first test knob
EOF
cat >"$WORK/overlay.tsv" <<'EOF'
KNOB_OVERLAY_COMPOSED	composed-value	string	kernel	overlay_pkg/overlay_composed.sh	overlay addition living outside the kernel subtree	add
EOF
: >"$WORK/exempt.txt"
commit_repo

run_checker_composed() {
  (
    KNOB_REGISTRY_FILE="$WORK/kernel.tsv"
    KNOB_REGISTRY_OVERLAY_FILE="$WORK/overlay.tsv"
    KNOB_REGISTRY_SCAN_ROOT="$REPO/kernel"
    KNOB_REGISTRY_OVERLAY_SCAN_ROOT="$REPO"
    KNOB_REGISTRY_MANIFEST_FILE="$MANIFEST"
    KNOB_REGISTRY_EXEMPT_FILE="$WORK/exempt.txt"
    export KNOB_REGISTRY_FILE KNOB_REGISTRY_OVERLAY_FILE KNOB_REGISTRY_SCAN_ROOT
    export KNOB_REGISTRY_OVERLAY_SCAN_ROOT
    export KNOB_REGISTRY_MANIFEST_FILE KNOB_REGISTRY_EXEMPT_FILE
    bash "$CHECKER"
  )
}

out="$(run_checker_composed 2>&1)" || fail "12: composed-tree overlay-scan-root seam should pass:
$out"
case "$out" in
  *"EQUALITY: no shell seam found for KNOB_OVERLAY_COMPOSED"*) fail "12: overlay row should have resolved against KNOB_REGISTRY_OVERLAY_SCAN_ROOT, not the kernel-pinned scan root:
$out" ;;
esac
echo "PASS: 12 KNOB_REGISTRY_OVERLAY_SCAN_ROOT resolves an overlay row's owning-script outside a kernel-pinned scan root"

# --- 13. RED: without KNOB_REGISTRY_OVERLAY_SCAN_ROOT (unset, so it
#         defaults to the kernel-pinned scan root), the same overlay row is
#         structurally unresolvable — proving 12 actually exercises the seam
#         and isn't passing for some other reason.
run_checker_composed_no_overlay_root() {
  (
    KNOB_REGISTRY_FILE="$WORK/kernel.tsv"
    KNOB_REGISTRY_OVERLAY_FILE="$WORK/overlay.tsv"
    KNOB_REGISTRY_SCAN_ROOT="$REPO/kernel"
    KNOB_REGISTRY_MANIFEST_FILE="$MANIFEST"
    KNOB_REGISTRY_EXEMPT_FILE="$WORK/exempt.txt"
    unset KNOB_REGISTRY_OVERLAY_SCAN_ROOT 2>/dev/null || true
    export KNOB_REGISTRY_FILE KNOB_REGISTRY_OVERLAY_FILE KNOB_REGISTRY_SCAN_ROOT
    export KNOB_REGISTRY_MANIFEST_FILE KNOB_REGISTRY_EXEMPT_FILE
    bash "$CHECKER"
  )
}
out="$(run_checker_composed_no_overlay_root 2>&1)" && fail "13: without KNOB_REGISTRY_OVERLAY_SCAN_ROOT, the composed-tree overlay row should fail to resolve:
$out"
case "$out" in
  *"EQUALITY: no shell seam found for KNOB_OVERLAY_COMPOSED"*) ;;
  *) fail "13: expected a 'no shell seam found' message for KNOB_OVERLAY_COMPOSED when the overlay-scan-root seam is unset, got:
$out" ;;
esac
echo "PASS: 13 unset KNOB_REGISTRY_OVERLAY_SCAN_ROOT correctly leaves the composed-tree overlay row unresolvable (proves 12 exercises the seam)"

echo "ALL PASS: check-knob-registry.sh"
