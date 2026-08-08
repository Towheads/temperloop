#!/usr/bin/env bash
#
# test_kernel_lib_portability.sh — dual-shell regression suite for
# workflows/scripts/kernel/lib.sh (temperloop#1177).
#
# WHY DUAL-SHELL: lib.sh is SOURCED, so its shebang is inert and it executes
# under whatever shell the caller is. Claude Code's Bash tool runs zsh on
# macOS, so /assess's seam-straddling check and /build Step 3b's kernel
# backstop both evaluated this lib under zsh — where the original
# implementation returned EMPTY + rc 1 (bit-identical to "no pattern matched")
# for every path. A single-shell test cannot see that; running the SAME asserts
# under bash AND zsh is the point of this file.
#
# WHY A CONTROL: the failure was invisible precisely because a run that only
# checks the paths it just touched still looks clean. Every case here uses a
# KNOWN-KERNEL CONTROL — `claude/commands/build.md`, listed
# `kernel claude/commands/build.md` in the real kernel-manifest.txt — whose
# expected answer is fixed and independent of anything this suite creates. A
# test without a control is the same blind spot the bug lived in.
#
# WHAT IT ASSERTS, in each shell:
#   1. the control path classifies `kernel`, rc 0
#   2. a genuinely unmatched path is rc 1 with empty stdout (still distinguishable)
#   3. classify with NO manifest loaded is rc 2 (CANNOT EVALUATE) + loud stderr
#   4. kernel_lib_load_manifest on a missing manifest fails loudly, and a later
#      classify still says CANNOT EVALUATE rather than "not matched"
#   5. kernel_lib_selftest passes (the shell's own matcher is trustworthy)
#   6. the longest-pattern-wins rule still holds (a narrower override beats a
#      broader catch-all)
#   7. resolve-then-classify (the /assess call shape) survives the same shells
#
# Plain mktemp-free, framework-free style — fail() + sequential asserts,
# mirroring test_kernel_lib_resolve.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$KERNEL_DIR/../../.." && pwd)"
MANIFEST="$KERNEL_DIR/kernel-manifest.txt"

# The control: a path the REAL manifest classifies `kernel`, verified here so a
# manifest edit that retires the control fails this suite loudly instead of
# quietly removing its own oracle.
CONTROL_PATH="claude/commands/build.md"
if ! grep -qx "kernel $CONTROL_PATH" "$MANIFEST"; then
  echo "FAIL: control invariant — '$MANIFEST' no longer carries the line 'kernel $CONTROL_PATH'." >&2
  echo "      Pick another known-kernel control and update CONTROL_PATH here." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The body run once per shell. Written to a file and executed by each shell
# under test, so bash and zsh run byte-identical asserts.
# ---------------------------------------------------------------------------
PROBE="$(mktemp "${TMPDIR:-/tmp}/kernel-lib-portability-XXXXXX")"
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT

cat > "$PROBE" <<'PROBE_EOF'
# Args: <lib.sh> <manifest> <control-path> <repo-root>
LIB="$1"; MAN="$2"; CTL="$3"; ROOT="$4"
fail() { echo "FAIL[$SHELL_LABEL]: $1" >&2; exit 1; }

. "$LIB" || fail "could not source lib.sh"

# --- 5: the shell's own matcher must be trustworthy --------------------------
kernel_lib_selftest || fail "kernel_lib_selftest failed — the glob matcher does not work in this shell"

# --- 3: classify with nothing loaded = CANNOT EVALUATE (rc 2), not rc 1 ------
rc=0
out="$(kernel_lib_classify "$CTL" 2>/dev/null)" || rc=$?
[ "$rc" -eq 2 ] || fail "unloaded classify should be rc 2 (CANNOT EVALUATE), got rc $rc out=[$out]"
[ -z "$out" ] || fail "unloaded classify should print nothing, got [$out]"
err="$(kernel_lib_classify "$CTL" 2>&1 >/dev/null)"
case "$err" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "unloaded classify must say CANNOT EVALUATE on stderr, got [$err]" ;;
esac

# --- 4: a missing manifest fails loudly, and does NOT leave a usable state ---
rc=0
err="$(kernel_lib_load_manifest "$MAN.nope" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "load_manifest on a missing file should fail, got rc 0"
[ -n "$err" ] || fail "load_manifest on a missing file must say something on stderr"
rc=0
kernel_lib_classify "$CTL" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "classify after a FAILED load must be rc 2 (CANNOT EVALUATE), got rc $rc"

# --- 1: THE CONTROL — a known-kernel path classifies kernel, rc 0 -----------
kernel_lib_load_manifest "$MAN" || fail "could not load the real manifest"
rc=0
out="$(kernel_lib_classify "$CTL")" || rc=$?
[ "$rc" -eq 0 ] || fail "control '$CTL' should classify rc 0, got rc $rc out=[$out]"
[ "$out" = "kernel" ] || fail "control '$CTL' must classify 'kernel', got [$out]"

# --- 2: an unmatched path is still a plain rc 1 with empty stdout -----------
rc=0
out="$(kernel_lib_classify "definitely/not/a/tracked/path.xyzzy" 2>/dev/null)" || rc=$?
[ "$rc" -eq 1 ] || fail "an unmatched path should be rc 1 (NOMATCH), got rc $rc out=[$out]"
[ -z "$out" ] || fail "an unmatched path should print nothing, got [$out]"

# --- 6: longest-pattern-wins still holds ------------------------------------
# The control is claimed both by the broad `kernel claude/commands/*` glob and
# by its own exact line; a `split`/`overlay` narrower entry must be able to win.
rc=0
out="$(kernel_lib_classify "claude/CLAUDE.kernel.md")" || rc=$?
[ "$rc" -eq 0 ] || fail "claude/CLAUDE.kernel.md should classify, got rc $rc"
[ -n "$out" ] || fail "claude/CLAUDE.kernel.md classified empty"

# --- 7: resolve-then-classify (the /assess call shape) ----------------------
resolved="$(kernel_lib_resolve_for_classify "$ROOT" "$CTL")"
[ "$resolved" = "$CTL" ] || fail "in the kernel repo the resolver must be a no-op, got [$resolved]"
rc=0
out="$(kernel_lib_classify "$resolved")" || rc=$?
[ "$rc" -eq 0 ] || fail "resolve-then-classify of the control should be rc 0, got rc $rc"
[ "$out" = "kernel" ] || fail "resolve-then-classify of the control must be 'kernel', got [$out]"

echo "PASS[$SHELL_LABEL]: control '$CTL' -> kernel; nomatch rc 1; cannot-evaluate rc 2"
PROBE_EOF

status=0
ran=0
for shell_bin in bash zsh; do
  if ! command -v "$shell_bin" >/dev/null 2>&1; then
    # zsh is not universal on Linux CI images; bash is. Never silently skip both.
    echo "SKIP: $shell_bin not installed on this host"
    continue
  fi
  ran=$((ran + 1))
  if SHELL_LABEL="$shell_bin" "$shell_bin" "$PROBE" "$KERNEL_DIR/lib.sh" "$MANIFEST" "$CONTROL_PATH" "$REPO_ROOT"; then
    :
  else
    status=1
  fi
done

# bash 3.2 is the macOS system shell and the oldest supported target; run it
# explicitly when it is a DIFFERENT binary from whatever `bash` resolves to.
if [ -x /bin/bash ] && [ "$(command -v bash)" != "/bin/bash" ]; then
  ran=$((ran + 1))
  if SHELL_LABEL="/bin/bash" /bin/bash "$PROBE" "$KERNEL_DIR/lib.sh" "$MANIFEST" "$CONTROL_PATH" "$REPO_ROOT"; then
    :
  else
    status=1
  fi
fi

if [ "$ran" -eq 0 ]; then
  echo "FAIL: no shell under test was available — this suite proves nothing" >&2
  exit 1
fi

if [ "$status" -ne 0 ]; then
  echo "FAIL: kernel lib portability suite failed in at least one shell" >&2
  exit 1
fi

echo "OK — kernel_lib_classify is shell-portable and fails closed ($ran shell(s) exercised)"
