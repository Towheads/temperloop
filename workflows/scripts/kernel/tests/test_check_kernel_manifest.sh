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

echo "ALL PASS: check-kernel-manifest.sh subtree-root support"
