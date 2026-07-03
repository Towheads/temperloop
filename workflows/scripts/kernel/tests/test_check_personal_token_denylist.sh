#!/usr/bin/env bash
#
# Tests for check-personal-token-denylist.sh (foundation #798): a synthetic
# fixture repo + manifest proves the RED path (an injected personal token
# fails the check), the GREEN path (removing it passes), and both exemption
# mechanisms (per-line `# denylist:allow` marker, and the file-level exempt
# list) actually suppress a match rather than silently matching nothing.
#
# Mirrors workflows/scripts/board/tests/test_boards_conf.sh's plain
# mktemp-fixture style — no framework, just `fail()` + sequential asserts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kernel-denylist-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture repo: a real git checkout (check-personal-token-denylist.sh's
# list-kernel-set.sh call shells out to `git ls-files`) -------------------
REPO="$WORK/repo"
mkdir -p "$REPO/kernel_dir"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test

echo "hello world" > "$REPO/kernel_dir/clean.sh"
echo "this line is FiNe" > "$REPO/kernel_dir/allowed.sh"
git -C "$REPO" -c core.hooksPath=/dev/null add -A
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m init

MANIFEST="$WORK/kernel-manifest.txt"
cat > "$MANIFEST" <<'EOF'
kernel kernel_dir/*
EOF

DENYLIST="$WORK/denylist.tsv"
cat > "$DENYLIST" <<'EOF'
FakeOrgName	synthetic personal org token (test fixture)
EOF

EXEMPT="$WORK/exempt.txt"
: > "$EXEMPT"

run_check() {
  KERNEL_MANIFEST_ROOT="$REPO" \
  KERNEL_MANIFEST_FILE="$MANIFEST" \
  KERNEL_DENYLIST_FILE="$DENYLIST" \
  KERNEL_DENYLIST_EXEMPT_FILE="$EXEMPT" \
    bash "$KERNEL_DIR/check-personal-token-denylist.sh"
}

# --- 1: GREEN — no injected token, check passes -----------------------------
if ! run_check >/dev/null 2>&1; then
  fail "1: clean fixture should pass (no personal token present)"
fi
echo "PASS: 1 clean fixture passes"

# --- 2: RED — inject a synthetic personal token, check fails ---------------
echo "owner=FakeOrgName" >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "inject leak"

if run_check >/dev/null 2>&1; then
  fail "2: fixture with an injected personal token should FAIL, but passed"
fi
out="$(run_check 2>&1 || true)"
case "$out" in
  *"clean.sh"*"FakeOrgName"*) ;;
  *) fail "2: failure output should name the offending file/token; got: $out" ;;
esac
echo "PASS: 2 injected token is caught (red demonstration)"

# --- 3: GREEN again — remove the token, check passes ------------------------
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null
if ! run_check >/dev/null 2>&1; then
  fail "3: reverting the injected token should restore a passing check"
fi
echo "PASS: 3 fix restores a passing check"

# --- 4: per-line \`# denylist:allow\` marker suppresses a match ------------
echo "owner=FakeOrgName  # denylist:allow — test fixture, intentional" >> "$REPO/kernel_dir/allowed.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "add allow-marked line"
if ! run_check >/dev/null 2>&1; then
  fail "4: a line carrying the denylist:allow marker should be suppressed"
fi
echo "PASS: 4 denylist:allow marker suppresses a match"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 5: file-level exemption list suppresses a whole file -------------------
echo "owner=FakeOrgName" >> "$REPO/kernel_dir/allowed.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "add unmarked leak to allowed.sh"
if run_check >/dev/null 2>&1; then
  fail "5 setup: unmarked leak in allowed.sh should fail before exemption is added"
fi
echo "kernel_dir/allowed.sh" > "$EXEMPT"
if ! run_check >/dev/null 2>&1; then
  fail "5: file-level exemption list should suppress the whole file"
fi
echo "PASS: 5 file-level exemption list suppresses a whole file"

echo "PASS: all check-personal-token-denylist.sh fixture tests"
