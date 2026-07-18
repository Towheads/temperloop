#!/usr/bin/env bash
#
# test_prereq_scoping.sh — per-subcommand prereq scoping (temperloop#412,
# "subcommand-prereq-scoping"). Proves the actual regression the issue
# described: unlike bin/subcommands/tests/test_try.sh (which invokes
# try.sh DIRECTLY and therefore never exercised the dispatcher's own
# gate), every test here dispatches through the REAL `bin/temperloop`
# entrypoint — the exact path a stranger's first `temperloop try` /
# `temperloop install` takes.
#
# Covers:
#   T1  `temperloop try` (through the dispatcher) runs to completion with
#       gh entirely absent from PATH and no claude either — zero-auth,
#       per try.sh's own documented contract, reachable end to end.
#   T2  `temperloop install --dry-run` and `temperloop uninstall --dry-run`
#       (through the dispatcher) reach their own subcommand logic with
#       neither gh nor claude on PATH — the dispatcher never gates them.
#   T3  the declarative `# prereqs: ...` mechanism itself, against a
#       synthetic subcommand (not a real shipped one, since none declare
#       a hard dispatch-level prereq today — see bin/temperloop's own
#       header comment for why): a subcommand that DOES declare `gh` (or
#       `claude`) is still hard-blocked, legibly, BEFORE any of its own
#       code runs (proven by a marker file the subcommand body would
#       otherwise create) — and runs normally once the declared prereq is
#       satisfied.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../.."
TEMPERLOOP="$BIN_DIR/temperloop"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prereq-scoping-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

BASH_BIN="$(command -v bash)"

# --- a PATH with every tool these subcommands need EXCEPT gh/claude --------
NOGH_NOCLAUDE="$WORK/no-gh-no-claude-bin"
mkdir -p "$NOGH_NOCLAUDE"
for tool in git jq awk sed grep sort mktemp date find cut printf cat sleep \
            bash dirname basename readlink chmod mkdir rm cp ln touch env; do
  b="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$b" ] && ln -sf "$b" "$NOGH_NOCLAUDE/$tool"
done

# =============================================================================
# T1 -- `temperloop try` through the real dispatcher, gh+claude both absent:
# must run to completion (exit 0) per try.sh's own zero-auth contract,
# never hitting the old blanket dispatcher-level gate.
# =============================================================================
REPO="$WORK/fixture-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo one > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: seed fixture"

rc=0
out="$(PATH="$NOGH_NOCLAUDE" "$BASH_BIN" "$TEMPERLOOP" try \
  --dir "$REPO" --gh-repo test-owner/test-demo --timeout 5 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "T1: 'temperloop try' with gh+claude absent should exit 0 (got $rc, output: $out)"
case "$out" in
  *"temperloop: fix the above, then re-run"*)
    fail "T1: 'temperloop try' hit the old blanket dispatcher-level prereq gate (output: $out)" ;;
esac
case "$out" in
  *"== temperloop try =="*) ;;
  *) fail "T1: expected the try banner (output: $out)" ;;
esac
case "$out" in
  *"gh CLI not found on PATH"*) ;;
  *) fail "T1: expected try.sh's OWN gh-absent skip reason (output: $out)" ;;
esac
case "$out" in
  *"temperloop try: done (zero writes)"*) ;;
  *) fail "T1: expected try.sh's own completion line (output: $out)" ;;
esac
pass "T1: 'temperloop try' (dispatcher-invoked, gh+claude both absent from PATH) runs to completion with zero auth, per try.sh's own contract"

# =============================================================================
# T2 -- `temperloop install --dry-run` / `temperloop uninstall --dry-run`
# through the real dispatcher, gh+claude both absent: must reach their own
# subcommand logic (zero-write dry-run output), never the dispatcher gate.
# Both subcommands never call gh/claude themselves (see their own header
# comments), so this also proves they are dispatched with ZERO
# dispatcher-level prereq checks, matching what they actually need.
# =============================================================================
rc=0
out="$(PATH="$NOGH_NOCLAUDE" "$BASH_BIN" "$TEMPERLOOP" install --dry-run 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "T2: 'temperloop install --dry-run' with gh+claude absent should exit 0 (got $rc, output: $out)"
case "$out" in
  *"temperloop: fix the above, then re-run"*)
    fail "T2: 'temperloop install --dry-run' hit the dispatcher-level prereq gate (output: $out)" ;;
esac
case "$out" in
  *"temperloop install: done (dry run)"*) ;;
  *) fail "T2: expected install.sh's own dry-run completion line (output: $out)" ;;
esac
pass "T2a: 'temperloop install --dry-run' (dispatcher-invoked, gh+claude absent) skips the gh-auth check entirely and reaches install.sh's own dry-run logic"

rc=0
out="$(PATH="$NOGH_NOCLAUDE" "$BASH_BIN" "$TEMPERLOOP" uninstall --dry-run 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "T2: 'temperloop uninstall --dry-run' with gh+claude absent should exit 0 (got $rc, output: $out)"
case "$out" in
  *"temperloop: fix the above, then re-run"*)
    fail "T2: 'temperloop uninstall --dry-run' hit the dispatcher-level prereq gate (output: $out)" ;;
esac
case "$out" in
  *"temperloop uninstall"*) ;;
  *) fail "T2: expected uninstall.sh's own output banner (output: $out)" ;;
esac
pass "T2b: 'temperloop uninstall --dry-run' (dispatcher-invoked, gh+claude absent) skips the gh-auth check entirely and reaches uninstall.sh's own logic"

# =============================================================================
# T3 -- the declarative `# prereqs: ...` mechanism: a SYNTHETIC subcommand
# (no shipped subcommand declares a hard dispatch-level prereq today — see
# bin/temperloop's own header comment) proves a subcommand that genuinely
# needs gh/claude still fails legibly BEFORE doing any work, and runs
# normally once satisfied.
# =============================================================================
SYNTH="$WORK/synth-bin"
mkdir -p "$SYNTH/lib" "$SYNTH/subcommands"
cp "$TEMPERLOOP" "$SYNTH/temperloop"
chmod +x "$SYNTH/temperloop"
cp "$BIN_DIR/lib/common.sh" "$SYNTH/lib/common.sh"

MARKER="$WORK/marker-file"
cat > "$SYNTH/subcommands/needs-gh-claude.sh" <<EOF
#!/usr/bin/env bash
# description: synthetic test subcommand — declares both prereqs
# prereqs: claude gh
touch "$MARKER"
echo "needs-gh-claude: ran"
exit 0
EOF
chmod +x "$SYNTH/subcommands/needs-gh-claude.sh"

# -- 3a: neither tool present -> dispatcher hard-blocks BEFORE any work ------
rm -f "$MARKER"
rc=0
out="$(PATH="$NOGH_NOCLAUDE" "$BASH_BIN" "$SYNTH/temperloop" needs-gh-claude 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "T3a: declared-prereq subcommand with neither tool present should exit 1 (got $rc, output: $out)"
[ ! -e "$MARKER" ] || fail "T3a: subcommand body ran despite its declared prereqs being unmet — dispatcher gate did not block before work"
case "$out" in
  *"'claude' (Claude Code CLI) not found on PATH"*) ;;
  *) fail "T3a: expected the claude-missing message (output: $out)" ;;
esac
case "$out" in
  *"'gh' (GitHub CLI) not found on PATH"*) ;;
  *) fail "T3a: expected the gh-missing message (output: $out)" ;;
esac
case "$out" in
  *"temperloop: fix the above, then re-run: temperloop needs-gh-claude"*) ;;
  *) fail "T3a: expected the fix-and-re-run banner (output: $out)" ;;
esac
pass "T3a: a subcommand declaring '# prereqs: claude gh' is hard-blocked before doing any work when neither tool is present (marker file never created)"

# -- 3b: gh present but unauthenticated, claude absent -> still blocked -----
FAKEBIN="$WORK/fake-gh-unauth-bin"
mkdir -p "$FAKEBIN"
for tool in git jq awk sed grep sort mktemp date find cut printf cat sleep \
            bash dirname basename readlink chmod mkdir rm cp ln touch env; do
  b="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$b" ] && ln -sf "$b" "$FAKEBIN/$tool"
done
cat > "$FAKEBIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then exit 1; fi
exit 0
FAKE_GH_EOF
chmod +x "$FAKEBIN/gh"

rm -f "$MARKER"
rc=0
out="$(PATH="$FAKEBIN" "$BASH_BIN" "$SYNTH/temperloop" needs-gh-claude 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "T3b: declared-prereq subcommand with unauthenticated gh + no claude should exit 1 (got $rc, output: $out)"
[ ! -e "$MARKER" ] || fail "T3b: subcommand body ran despite unmet prereqs"
case "$out" in
  *"'gh' is installed but not authenticated"*) ;;
  *) fail "T3b: expected the gh-unauthenticated message (output: $out)" ;;
esac
pass "T3b: gh present-but-unauthenticated still hard-blocks a subcommand declaring '# prereqs: gh'"

# -- 3c: both satisfied -> dispatch proceeds, subcommand body actually runs -
cat > "$FAKEBIN/claude" <<'FAKE_CLAUDE_EOF'
#!/usr/bin/env bash
exit 0
FAKE_CLAUDE_EOF
chmod +x "$FAKEBIN/claude"
cat > "$FAKEBIN/gh" <<'FAKE_GH_OK_EOF'
#!/usr/bin/env bash
exit 0
FAKE_GH_OK_EOF
chmod +x "$FAKEBIN/gh"

rm -f "$MARKER"
rc=0
out="$(PATH="$FAKEBIN" "$BASH_BIN" "$SYNTH/temperloop" needs-gh-claude 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "T3c: declared-prereq subcommand with both satisfied should exit 0 (got $rc, output: $out)"
[ -e "$MARKER" ] || fail "T3c: subcommand body never ran despite both declared prereqs being satisfied"
case "$out" in
  *"needs-gh-claude: ran"*) ;;
  *) fail "T3c: expected the subcommand's own output (output: $out)" ;;
esac
pass "T3c: once both declared prereqs are satisfied, dispatch proceeds and the subcommand body actually runs"

echo
echo "ALL PASS: test_prereq_scoping.sh"
