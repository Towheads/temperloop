#!/usr/bin/env bash
#
# Tests for check-kernel-manifest.sh's subtree-root support (temperloop#680,
# derived from foundation#870): the checker must accept a
# KERNEL_MANIFEST_ROOT that is a SUBDIRECTORY of an enclosing git checkout
# with no `.git` of its own — e.g. a downstream overlay's vendored kernel/
# subtree — not just a checkout's own toplevel.
#
# Covers:
#   1. GREEN  — a fully-classified subtree root (no own .git) passes clean.
#   2. RED    — an unclassified path under a subtree root fails, naming the
#               offending path (git ls-files, run after cd-ing into the
#               subtree, already returns subtree-relative paths — no
#               prefix-mapping needed, per the design review's key fact).
#   3. guard  — a directory with NO enclosing git checkout at all (never a
#               repo, anywhere in its ancestry) still fails the guard, exit
#               non-zero, naming the root — the negative control proving the
#               relaxation didn't just delete the guard outright.
#   4. GREEN  — the classic case (root IS a checkout's own toplevel, real
#               .git) is unaffected by the relaxation.
#   5. RED    — duplicate-entry lint (temperloop#1801): the same glob on two
#               manifest lines fails, naming the pattern and both line
#               numbers.
#   6. RED    — a duplicate is flagged even across DIFFERENT classes.
#
# Mirrors test_check_producer_egress.sh / test_check_personal_token_denylist.sh's
# plain mktemp-fixture style — no framework, just `fail()` + sequential asserts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$KERNEL_DIR/check-kernel-manifest.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kernel-manifest-subtree-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

git_init() {
  git -C "$1" init -q
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

# --- fixture: a repo whose root vendors a kernel/ subtree with NO own .git,
# mimicking a downstream overlay's vendored kernel checkout. --------------
REPO="$WORK/overlay-repo"
mkdir -p "$REPO/kernel/scripts"
git_init "$REPO"
echo 'echo hi' > "$REPO/kernel/scripts/foo.sh"
cat > "$REPO/kernel/manifest.txt" <<'EOF'
kernel scripts/**
kernel manifest.txt
EOF
git -C "$REPO" -c core.hooksPath=/dev/null add -A
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m init

if [[ -e "$REPO/kernel/.git" ]]; then
  fail "fixture setup: kernel/ subtree unexpectedly has its own .git"
fi

# --- 1: GREEN — fully-classified subtree root (no own .git) passes -------
if ! KERNEL_MANIFEST_ROOT="$REPO/kernel" KERNEL_MANIFEST_FILE="$REPO/kernel/manifest.txt" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "1: fully-classified subtree root (no own .git) should pass"
fi
out="$(KERNEL_MANIFEST_ROOT="$REPO/kernel" KERNEL_MANIFEST_FILE="$REPO/kernel/manifest.txt" bash "$SCRIPT" 2>&1 || true)"
case "$out" in
  *"not a git checkout"*|*"not inside a git checkout"*)
    fail "1: subtree root with no own .git should NOT trip the git-checkout guard; got: $out"
    ;;
esac
case "$out" in
  *"OK"*) ;;
  *) fail "1: expected an OK pass line; got: $out" ;;
esac
echo "PASS: 1 fully-classified subtree root (no own .git) passes clean"

# --- 2: RED — unclassified path under a subtree root, named in output ----
UNCLASSIFIED_MANIFEST="$WORK/unclassified-manifest.txt"
echo 'kernel scripts/**' > "$UNCLASSIFIED_MANIFEST"
if KERNEL_MANIFEST_ROOT="$REPO/kernel" KERNEL_MANIFEST_FILE="$UNCLASSIFIED_MANIFEST" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "2: an unclassified path (manifest.txt itself, not covered) should FAIL, but it passed"
fi
out="$(KERNEL_MANIFEST_ROOT="$REPO/kernel" KERNEL_MANIFEST_FILE="$UNCLASSIFIED_MANIFEST" bash "$SCRIPT" 2>&1 || true)"
case "$out" in
  *"UNCLASSIFIED"*"manifest.txt"*) ;;
  *) fail "2: failure output should name the offending subtree-relative path 'manifest.txt'; got: $out" ;;
esac
echo "PASS: 2 unclassified path under a subtree root fails, named by its subtree-relative path"

# --- 3: guard — no enclosing git checkout anywhere fails cleanly ---------
NOGIT="$WORK/plain-dir/kernel"
mkdir -p "$NOGIT"
if KERNEL_MANIFEST_ROOT="$NOGIT" KERNEL_MANIFEST_FILE="$REPO/kernel/manifest.txt" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "3: a root with no enclosing git checkout at all should FAIL the guard, but it passed"
fi
out="$(KERNEL_MANIFEST_ROOT="$NOGIT" KERNEL_MANIFEST_FILE="$REPO/kernel/manifest.txt" bash "$SCRIPT" 2>&1 || true)"
case "$out" in
  *"$NOGIT"*"not inside a git checkout"*) ;;
  *) fail "3: guard failure should name the root and say it is not inside a git checkout; got: $out" ;;
esac
echo "PASS: 3 a root with no enclosing git checkout anywhere still fails the guard"

# --- 4: GREEN — classic case (root is a checkout's own toplevel) unaffected
CLASSIC="$WORK/classic-repo"
mkdir -p "$CLASSIC"
git_init "$CLASSIC"
echo 'echo hi' > "$CLASSIC/foo.sh"
cat > "$CLASSIC/manifest.txt" <<'EOF'
kernel foo.sh
kernel manifest.txt
EOF
git -C "$CLASSIC" -c core.hooksPath=/dev/null add -A
git -C "$CLASSIC" -c core.hooksPath=/dev/null commit -q -m init

if ! KERNEL_MANIFEST_ROOT="$CLASSIC" KERNEL_MANIFEST_FILE="$CLASSIC/manifest.txt" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "4: classic own-.git root should still pass unaffected"
fi
echo "PASS: 4 classic own-.git root invocation is unaffected"

# --- 5: RED — duplicate-entry lint (temperloop#1801): the same glob on two
# manifest lines fails, naming the pattern and BOTH line numbers, even
# though coverage itself is complete. ------------------------------------
DUP_MANIFEST="$WORK/dup-manifest.txt"
cat > "$DUP_MANIFEST" <<'EOF'
# comment line (line numbers below must count this line too)
kernel foo.sh
kernel manifest.txt
kernel foo.sh
EOF
if KERNEL_MANIFEST_ROOT="$CLASSIC" KERNEL_MANIFEST_FILE="$DUP_MANIFEST" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "5: a duplicated manifest glob should FAIL the duplicate-entry lint, but it passed"
fi
out="$(KERNEL_MANIFEST_ROOT="$CLASSIC" KERNEL_MANIFEST_FILE="$DUP_MANIFEST" bash "$SCRIPT" 2>&1 || true)"
case "$out" in
  *"DUPLICATE"*"foo.sh — lines 2 and 4"*) ;;
  *) fail "5: duplicate failure should name the glob and both line numbers ('foo.sh — lines 2 and 4'); got: $out" ;;
esac
echo "PASS: 5 duplicated manifest glob fails, naming the pattern and both line numbers"

# --- 6: RED — a duplicate is flagged even when the two lines carry
# DIFFERENT classes (a same-length tie the longest-pattern rule cannot
# break — resolution would be incidental parse order). --------------------
DUPCLASS_MANIFEST="$WORK/dupclass-manifest.txt"
cat > "$DUPCLASS_MANIFEST" <<'EOF'
kernel foo.sh
kernel manifest.txt
overlay foo.sh
EOF
if KERNEL_MANIFEST_ROOT="$CLASSIC" KERNEL_MANIFEST_FILE="$DUPCLASS_MANIFEST" bash "$SCRIPT" >/dev/null 2>&1; then
  fail "6: the same glob under two DIFFERENT classes should FAIL the duplicate-entry lint, but it passed"
fi
out="$(KERNEL_MANIFEST_ROOT="$CLASSIC" KERNEL_MANIFEST_FILE="$DUPCLASS_MANIFEST" bash "$SCRIPT" 2>&1 || true)"
case "$out" in
  *"DUPLICATE"*"foo.sh — lines 1 and 3"*) ;;
  *) fail "6: cross-class duplicate should be flagged by pattern with both line numbers; got: $out" ;;
esac
echo "PASS: 6 same glob under two different classes is still a duplicate"

echo "ALL PASS: check-kernel-manifest.sh subtree-root support + duplicate-entry lint"
