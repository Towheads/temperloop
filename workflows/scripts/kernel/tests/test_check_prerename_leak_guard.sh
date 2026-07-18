#!/usr/bin/env bash
#
# Tests for check-prerename-leak-guard.sh (temperloop#433, gate-sweep item):
# a synthetic fixture repo + verdict table proves the RED path (an
# unreviewed pre-rename identifier fails the check) for all three violation
# shapes (env-var, path-leaf, and the XDG-anchor requirement that tells a
# real legacy subdir apart from a same-named-but-unrelated prose mention),
# the GREEN path (removing it passes), and that every verdict-table entry
# (windowed, allowlist, no-action) and both compat-shim "always allowed"
# literals (.foundation/ and bin/foundation) are genuinely suppressed rather
# than the check silently matching nothing.
#
# Mirrors workflows/scripts/kernel/tests/test_check_personal_token_denylist.sh's
# plain mktemp-fixture style — no framework, just fail() + sequential asserts.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$(cd "$HERE/.." && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prerename-leak-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture repo: a real git checkout (list-kernel-set.sh shells out to
# `git ls-files`) -------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/kernel_dir"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test

echo "hello world" > "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null add -A
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m init

MANIFEST="$WORK/kernel-manifest.txt"
cat > "$MANIFEST" <<'EOF'
kernel kernel_dir/*
EOF

VERDICTS="$WORK/verdicts.tsv"
cat > "$VERDICTS" <<'EOF'
env	FOUNDATION_HOME	windowed	synthetic windowed env fixture
env	FOUNDATION_TESTVAR	no-action	synthetic no-action env fixture
path-leaf	boards.conf	windowed	synthetic windowed path-leaf fixture
path-leaf	agent-heartbeat	allowlist	synthetic allowlist path-leaf fixture
EOF

EXEMPT="$WORK/exempt.txt"
: > "$EXEMPT"

run_check() {
  KERNEL_MANIFEST_ROOT="$REPO" \
  KERNEL_MANIFEST_FILE="$MANIFEST" \
  PRERENAME_VERDICTS_FILE="$VERDICTS" \
  PRERENAME_EXEMPT_FILE="$EXEMPT" \
    bash "$KERNEL_DIR/check-prerename-leak-guard.sh"
}

# --- 1: GREEN — clean fixture, no pre-rename identifier at all --------------
if ! run_check >/dev/null 2>&1; then
  fail "1: clean fixture should pass (no pre-rename identifier present)"
fi
echo "PASS: 1 clean fixture passes"

# --- 2: RED — an unreviewed FOUNDATION_-prefixed env var is a new leak -----
# shellcheck disable=SC2016  # single-quoted: this is fixture text written verbatim, not expansion
echo 'FOUNDATION_TOTALLY_NEW="$HOME/.local/share/foundation"' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "inject unreviewed env leak"
if run_check >/dev/null 2>&1; then
  fail "2: an unreviewed FOUNDATION_-prefixed env var should FAIL, but passed"
fi
out="$(run_check 2>&1 || true)"
case "$out" in
  *"clean.sh"*"FOUNDATION_TOTALLY_NEW"*) ;;
  *) fail "2: failure output should name the offending file/token; got: $out" ;;
esac
echo "PASS: 2 unreviewed env-var leak is caught (red demonstration)"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 3: GREEN — a KNOWN env token (on the verdict table) passes ------------
# shellcheck disable=SC2016  # single-quoted: fixture text written verbatim, not expansion
echo 'echo "$FOUNDATION_HOME"' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "reference a windowed env var"
if ! run_check >/dev/null 2>&1; then
  fail "3: a verdict-table-known env token (FOUNDATION_HOME, windowed) should pass"
fi
echo "PASS: 3 a windowed verdict-table env token is suppressed"

# --- 4: GREEN — a no-action verdict env token passes too -------------------
echo 'FOUNDATION_TESTVAR=1' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "reference a no-action env var"
if ! run_check >/dev/null 2>&1; then
  fail "4: a verdict-table-known no-action env token should pass"
fi
echo "PASS: 4 a no-action verdict-table env token is suppressed"
git -C "$REPO" -c core.hooksPath=/dev/null reset --hard HEAD~2 -q

# --- 5: RED — an unreviewed leaf under an XDG-anchored legacy subdir -------
# shellcheck disable=SC2016  # single-quoted: fixture text written verbatim, not expansion
echo 'DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation/totally-new-leaf"' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "inject unreviewed path-leaf leak"
if run_check >/dev/null 2>&1; then
  fail "5: an unreviewed foundation/<leaf> under an XDG anchor should FAIL, but passed"
fi
out="$(run_check 2>&1 || true)"
case "$out" in
  *"clean.sh"*"totally-new-leaf"*) ;;
  *) fail "5: failure output should name the offending file/leaf; got: $out" ;;
esac
echo "PASS: 5 unreviewed path-leaf leak is caught (red demonstration)"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 6: GREEN — a KNOWN path-leaf (windowed) passes, XDG-anchored ----------
# shellcheck disable=SC2016  # single-quoted: fixture text written verbatim, not expansion
echo 'CONF="${XDG_CONFIG_HOME:-$HOME/.config}/foundation/boards.conf"' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "reference the windowed boards.conf leaf"
if ! run_check >/dev/null 2>&1; then
  fail "6: a verdict-table-known path-leaf (boards.conf, windowed) should pass"
fi
echo "PASS: 6 a windowed verdict-table path-leaf is suppressed"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 7: GREEN — a KNOWN path-leaf (allowlist) passes -----------------------
# shellcheck disable=SC2016  # single-quoted: fixture text written verbatim, not expansion
echo 'DIR="${XDG_STATE_HOME:-$HOME/.local/state}/foundation/agent-heartbeat"' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "reference the allowlisted agent-heartbeat leaf"
if ! run_check >/dev/null 2>&1; then
  fail "7: a verdict-table-known path-leaf (agent-heartbeat, allowlist) should pass"
fi
echo "PASS: 7 an allowlisted verdict-table path-leaf is suppressed"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 8: GREEN — a foundation/<leaf>-shaped mention with NO XDG anchor on the
# same line is NOT treated as a legacy-subdir candidate at all (it's a prose
# reference to the unrelated, real, still-`foundation`-named overlay repo,
# e.g. `foundation/workflows/...`) — even though "workflows" is nowhere on
# the verdict table, this must NOT fail.
echo '# see foundation/workflows/scripts for the overlay repo layout' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "add an unrelated same-named-repo prose mention"
if ! run_check >/dev/null 2>&1; then
  fail "8: a foundation/<leaf> mention with no XDG anchor on the line must not be treated as a candidate"
fi
echo "PASS: 8 an un-anchored foundation/<leaf> prose mention (different, real, same-named repo) is ignored"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 9: GREEN — the compat shim's own two always-allowed literals ---------
# (.foundation/<any leaf>, and bin/foundation) never need a verdict-table row.
cat >> "$REPO/kernel_dir/clean.sh" <<'EOF'
# reads .foundation/config through the window
CFG=".foundation/some-new-leaf-nobody-reviewed"
# bin/foundation still dispatches through the window
EOF
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "reference the compat shim's own literals"
if ! run_check >/dev/null 2>&1; then
  fail "9: .foundation/<any leaf> and bin/foundation must always pass, unconditionally"
fi
echo "PASS: 9 the compat shim's own .foundation/ and bin/foundation literals are unconditionally allowed"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 10: file-level exemption list suppresses a whole file -----------------
echo 'FOUNDATION_UNREVIEWED_AGAIN=1' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "add unmarked leak"
if run_check >/dev/null 2>&1; then
  fail "10 setup: unmarked leak should fail before exemption is added"
fi
echo "kernel_dir/clean.sh" > "$EXEMPT"
if ! run_check >/dev/null 2>&1; then
  fail "10: this gate's own file-level exemption list should suppress the whole file"
fi
echo "PASS: 10 file-level exemption list (prerename-leak-exempt-files.txt) suppresses a whole file"
: > "$EXEMPT"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null

# --- 11: REGRESSION — this gate must NOT reuse another gate's exempt list --
# check-personal-token-denylist.sh's own exempt list wholesale-exempts
# bin/README.md/README.md for an unrelated reason (they repeat the kernel's
# public clone URL); an earlier version of this gate blanket-reused that
# whole file and, as a result, silently stopped scanning bin/README.md
# entirely — exactly the file acceptance criterion 2 requires it to cover.
# Prove that ANY file exempted only by a fixture standing in for that OTHER
# list is still scanned (not exempted) by THIS gate, whether or not such a
# file also happens to be named in personal-token-denylist-exempt-files.txt.
OTHER_GATE_EXEMPT="$WORK/other-gate-exempt.txt"
echo "kernel_dir/clean.sh" > "$OTHER_GATE_EXEMPT"
echo 'FOUNDATION_STILL_UNREVIEWED=1' >> "$REPO/kernel_dir/clean.sh"
git -C "$REPO" -c core.hooksPath=/dev/null commit -aq -m "add unmarked leak (regression fixture)"
if run_check >/dev/null 2>&1; then
  fail "11: an unreviewed leak in a file exempted only by a DIFFERENT gate's list must still fail here"
fi
echo "PASS: 11 a file exempted only by another gate's list is still scanned by this gate"
git -C "$REPO" -c core.hooksPath=/dev/null revert --no-edit HEAD >/dev/null
rm -f "$OTHER_GATE_EXEMPT"

# --- 12: GREEN again — final state is clean ---------------------------------
if ! run_check >/dev/null 2>&1; then
  fail "12: after reverting all injected leaks the fixture should pass again"
fi
echo "PASS: 12 fixture returns to a clean, passing state"

echo "PASS: all check-prerename-leak-guard.sh fixture tests"
