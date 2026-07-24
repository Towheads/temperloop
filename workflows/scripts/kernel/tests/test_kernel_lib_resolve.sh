#!/usr/bin/env bash
#
# Tests for kernel_lib_resolve_for_classify (workflows/scripts/kernel/lib.sh) —
# the symlinked-vendored-kernel resolution that fixes /assess mis-scoping a
# kernel-symlinked file as foundation-local (foundation#1050).
#
# Builds a fixture that mirrors the real foundation layout: a consumer repo that
# vendors the kernel as a `kernel/` subtree and surfaces it via a DIRECTORY
# symlink (`claude/agents -> ../kernel/claude/agents`, exactly what
# `ls -l foundation/claude/agents` shows). The helper must map BOTH the surface
# symlink form and the git-real vendored form of a kernel file to the
# manifest-relative `claude/agents/x.md`, which the REAL kernel manifest then
# classifies as kernel — while a genuine overlay file and the kernel-repo
# self-case (no vendoring) are left to classify exactly as before.
#
# Plain mktemp-fixture style — no framework, just fail() + sequential asserts,
# mirroring test_check_kernel_manifest.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"

# shellcheck source=workflows/scripts/kernel/lib.sh
source "$KERNEL_DIR/lib.sh"
kernel_lib_load_manifest "$KERNEL_DIR/kernel-manifest.txt" || { echo "FAIL: could not load real manifest" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
pass=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/kernel-resolve-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture: a consumer repo that vendors kernel/ and dir-symlinks into it ---
REPO="$WORK/consumer"
mkdir -p "$REPO/kernel/claude/agents" "$REPO/dashboard"
: > "$REPO/kernel/claude/CLAUDE.kernel.md"          # marks kernel/ as the kernel root
: > "$REPO/kernel/claude/agents/x.md"               # a kernel-owned file
: > "$REPO/dashboard/data.json"                     # a genuine overlay file
mkdir -p "$REPO/claude"                             # the surface claude/ dir
ln -s ../kernel/claude/agents "$REPO/claude/agents" # the foundation-style dir symlink
[ -L "$REPO/claude/agents" ] || fail "fixture: claude/agents should be a symlink"

# resolve + classify in one step, the way /assess uses them.
rc() { kernel_lib_classify "$(kernel_lib_resolve_for_classify "$1" "$2")"; }

# --- 1: surface symlink form → maps to claude/agents/x.md → kernel (acceptance)
got="$(kernel_lib_resolve_for_classify "$REPO" "claude/agents/x.md")"
[ "$got" = "claude/agents/x.md" ] || fail "1: surface path should map to claude/agents/x.md, got [$got]"
cls="$(rc "$REPO" "claude/agents/x.md")" || cls=""
[ "$cls" = "kernel" ] || fail "1: symlinked claude/agents/x.md must classify kernel, got [$cls]"
ok "surface symlink claude/agents/x.md → kernel (the #1050 acceptance fixture)"

# --- 2: git-real vendored form → same mapping → kernel ------------------------
got="$(kernel_lib_resolve_for_classify "$REPO" "kernel/claude/agents/x.md")"
[ "$got" = "claude/agents/x.md" ] || fail "2: vendored path should map to claude/agents/x.md, got [$got]"
cls="$(rc "$REPO" "kernel/claude/agents/x.md")" || cls=""
[ "$cls" = "kernel" ] || fail "2: vendored kernel/claude/agents/x.md must classify kernel, got [$cls]"
ok "vendored kernel/claude/agents/x.md → kernel (the mis-scoped git-real form)"

# --- 3: a not-yet-created file inside the symlinked kernel dir → kernel -------
# (the dir resolves even though the file doesn't exist yet — a new kernel file
# planned by /assess must still route upstream.)
cls="$(rc "$REPO" "claude/agents/brand-new.md")" || cls=""
[ "$cls" = "kernel" ] || fail "3: a new file in the symlinked kernel dir must classify kernel, got [$cls]"
ok "new file in symlinked kernel dir → kernel (routes upstream before it exists)"

# --- 4: genuine overlay file → unchanged → overlay ---------------------------
got="$(kernel_lib_resolve_for_classify "$REPO" "dashboard/data.json")"
[ "$got" = "dashboard/data.json" ] || fail "4: overlay path should be unchanged, got [$got]"
cls="$(rc "$REPO" "dashboard/data.json")" || cls=""
[ "$cls" = "overlay" ] || fail "4: dashboard/data.json must stay overlay, got [$cls]"
ok "genuine overlay file → unchanged → overlay (no false kernel routing)"

# --- 5: kernel-repo self-case (root IS the kernel, no vendoring) → no-op ------
KREPO="$WORK/kernel-repo"
mkdir -p "$KREPO/claude/agents"
: > "$KREPO/claude/CLAUDE.kernel.md"                # root itself is the kernel
: > "$KREPO/claude/agents/y.md"
got="$(kernel_lib_resolve_for_classify "$KREPO" "claude/agents/y.md")"
[ "$got" = "claude/agents/y.md" ] || fail "5: kernel-repo path should be unchanged, got [$got]"
cls="$(rc "$KREPO" "claude/agents/y.md")" || cls=""
[ "$cls" = "kernel" ] || fail "5: kernel-repo claude/agents/y.md must classify kernel, got [$cls]"
ok "kernel-repo self-case → unchanged path → kernel (helper is a no-op here)"

# --- 6: unresolvable path (missing dir) → literal fallback -------------------
got="$(kernel_lib_resolve_for_classify "$REPO" "no/such/dir/z.md")"
[ "$got" = "no/such/dir/z.md" ] || fail "6: unresolvable path should fall back to literal, got [$got]"
ok "unresolvable path → literal fallback (never fails)"

# --- 7: empty/missing args → literal, no crash -------------------------------
got="$(kernel_lib_resolve_for_classify "" "claude/agents/x.md")"
[ "$got" = "claude/agents/x.md" ] || fail "7: empty repo_root should return the literal path, got [$got]"
ok "empty repo_root → literal path, no crash"

# --- 8: RELATIVE repo_root + a hostile CDPATH must not corrupt the result -----
# Guards the CDPATH-stdout-pollution failure mode: with a relative repo_root, a
# bare `cd <relpath>` consults CDPATH and echoes on a hit. The decoy carries the
# exact colliding subpath, so a CDPATH hit WOULD fire without the `CDPATH=` guard
# in the helper — this case passes only because that guard neutralizes it.
mkdir -p "$WORK/cdp-decoy/consumer/claude/agents"
got="$(cd "$WORK" && CDPATH="$WORK/cdp-decoy" kernel_lib_resolve_for_classify "consumer" "claude/agents/x.md")"
[ "$got" = "claude/agents/x.md" ] \
  || fail "8: relative repo_root + hostile CDPATH corrupted the result, got [$got]"
ok "relative repo_root + hostile CDPATH → clean mapping (CDPATH= guard holds)"

echo "ALL PASS: test_kernel_lib_resolve.sh ($pass cases)"
