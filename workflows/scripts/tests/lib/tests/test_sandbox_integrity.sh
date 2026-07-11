#!/usr/bin/env bash
# Tests for the sandbox-integrity layer (temperloop#266) appended onto
# workflows/scripts/tests/lib/sandbox.sh — sandbox_preflight_links,
# sandbox_tripwire_snapshot/sandbox_tripwire_check, and
# sandbox_tree_manifest/sandbox_tree_diff. Sibling to test_sandbox.sh (which
# stays scoped to the original sandbox-core functions) rather than folded
# into it, so this item's own feature-manifest claim has a clean path.
#
# Covers:
#   1. sandbox_preflight_links: passes against this repo's REAL links.sh
#      (every target resolves under the sandbox root); NEGATIVE — a fixture
#      links.sh emitting a hardcoded absolute path outside the sandbox fails
#      the preflight.
#   2. sandbox_tree_manifest / sandbox_tree_diff: identical trees pass; an
#      added file fails; the SAME added file passes once excluded via a
#      caller-supplied exclusion file; a retargeted symlink fails (the
#      symlink's target is recorded, never followed).
#   3. sandbox_tripwire_snapshot / sandbox_tripwire_check: no drift between
#      snapshot and check passes; a write to a fixtured "real" path between
#      snapshot and check is caught; an absent watched path is handled
#      gracefully (no error), and its later *appearance* is itself flagged
#      as drift.
#
# All "real path" fixtures live under a throwaway mktemp scratch root — this
# suite never reads or writes the actual $HOME/.claude or
# $HOME/.local/bin/temperloop on the machine running it.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../../.." && pwd)"
# shellcheck source=workflows/scripts/tests/lib/sandbox.sh
source "$HERE/../sandbox.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-integrity-test-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# =============================================================================
# 1. sandbox_preflight_links
# =============================================================================
sandbox_up test-preflight-pos
sandbox_preflight_links "$REPO_ROOT" \
  || fail "1a: sandbox_preflight_links rejected a target from this repo's real links.sh (every target should resolve under \$SANDBOX_ROOT)"
sandbox_down
pass "1a: sandbox_preflight_links accepts every real links_enumerate target (all resolve under the sandbox root)"

# NEGATIVE: a fixture links.sh whose links_enumerate hardcodes an absolute
# path outside any sandbox root.
FIXTURE_LINKS="$SCRATCH/bad-links.sh"
cat > "$FIXTURE_LINKS" <<'FIXTURE_EOF'
links_enumerate() {
  printf '/etc/definitely-outside-any-sandbox\tsymlink\t/somewhere\n'
}
FIXTURE_EOF

sandbox_up test-preflight-neg
neg_out=""
if sandbox_preflight_links "$REPO_ROOT" "$FIXTURE_LINKS" 2>"$SCRATCH/preflight-neg.err"; then
  sandbox_down
  fail "1b: sandbox_preflight_links PASSED against a fixture with a hardcoded out-of-sandbox target (should have failed)"
fi
neg_out="$(cat "$SCRATCH/preflight-neg.err")"
grep -q "escapes sandbox root" <<<"$neg_out" \
  || fail "1b: failure message did not name the escaping target (got: $neg_out)"
sandbox_down
pass "1b (NEGATIVE): sandbox_preflight_links fails a fixture whose links_enumerate hardcodes an absolute path outside the sandbox — output: ${neg_out}"

# =============================================================================
# 2. sandbox_tree_manifest / sandbox_tree_diff
# =============================================================================
TREE_A="$SCRATCH/tree-a"
TREE_B="$SCRATCH/tree-b"
mkdir -p "$TREE_A/sub" "$TREE_B/sub"
echo "hello" > "$TREE_A/sub/file.txt"
echo "hello" > "$TREE_B/sub/file.txt"
ln -s "some/target" "$TREE_A/a-link"
ln -s "some/target" "$TREE_B/a-link"

sandbox_tree_manifest "$TREE_A" > "$SCRATCH/manifest-a.tsv"
sandbox_tree_manifest "$TREE_B" > "$SCRATCH/manifest-b.tsv"

# 2a. identical trees pass.
sandbox_tree_diff "$SCRATCH/manifest-a.tsv" "$SCRATCH/manifest-b.tsv" \
  || fail "2a: sandbox_tree_diff reported a difference between two identical trees"
pass "2a: sandbox_tree_diff passes on two identical trees"

# 2b. an added file fails.
echo "new" > "$TREE_B/sub/extra.txt"
sandbox_tree_manifest "$TREE_B" > "$SCRATCH/manifest-b.tsv"
if sandbox_tree_diff "$SCRATCH/manifest-a.tsv" "$SCRATCH/manifest-b.tsv" >"$SCRATCH/diff-2b.out" 2>&1; then
  fail "2b: sandbox_tree_diff did not detect an added file (tree B has sub/extra.txt, tree A does not)"
fi
pass "2b (NEGATIVE): sandbox_tree_diff fails when tree B has an added file tree A lacks"

# 2c. the SAME added file passes once excluded.
printf 'sub/extra.txt\n' > "$SCRATCH/exclude.list"
sandbox_tree_diff "$SCRATCH/manifest-a.tsv" "$SCRATCH/manifest-b.tsv" "$SCRATCH/exclude.list" \
  || fail "2c: sandbox_tree_diff still failed after excluding the one added path via a caller-supplied exclusion file"
pass "2c: sandbox_tree_diff passes once the added file's path is in the caller-supplied exclusion set"

# 2d. a retargeted symlink fails (target changed, never followed).
rm "$TREE_B/sub/extra.txt"
rm "$TREE_B/a-link"
ln -s "other/target" "$TREE_B/a-link"
sandbox_tree_manifest "$TREE_B" > "$SCRATCH/manifest-b.tsv"
if sandbox_tree_diff "$SCRATCH/manifest-a.tsv" "$SCRATCH/manifest-b.tsv" >"$SCRATCH/diff-2d.out" 2>&1; then
  fail "2d: sandbox_tree_diff did not detect a retargeted symlink (a-link: some/target -> other/target)"
fi
grep -q "a-link" "$SCRATCH/diff-2d.out" \
  || fail "2d: diff output did not mention the retargeted symlink's path (got: $(cat "$SCRATCH/diff-2d.out"))"
pass "2d (NEGATIVE): sandbox_tree_diff fails on a retargeted symlink (the symlink's own target string is recorded, never followed)"

# =============================================================================
# 3. sandbox_tripwire_snapshot / sandbox_tripwire_check
# =============================================================================
# Fixture our OWN "real" paths inside the scratch root — this suite never
# touches the actual $HOME/.claude or $HOME/.local/bin/temperloop.
FAKE_REAL_CLAUDE="$SCRATCH/fake-real-home/.claude"
FAKE_REAL_TEMPERLOOP="$SCRATCH/fake-real-home/.local/bin/temperloop"
mkdir -p "$FAKE_REAL_CLAUDE" "$(dirname "$FAKE_REAL_TEMPERLOOP")"
echo '{"model":"stub"}' > "$FAKE_REAL_CLAUDE/settings.json"
printf '#!/bin/sh\necho stub\n' > "$FAKE_REAL_TEMPERLOOP"

# 3a. no drift.
sandbox_up test-tripwire-nodrift
sandbox_tripwire_snapshot t1 "$FAKE_REAL_CLAUDE" "$FAKE_REAL_TEMPERLOOP"
sandbox_tripwire_check t1 \
  || fail "3a: sandbox_tripwire_check reported drift with no write between snapshot and check"
sandbox_down
pass "3a: sandbox_tripwire_check passes when nothing wrote to the watched real paths between snapshot and check"

# 3b. NEGATIVE: a deliberate out-of-sandbox write between snapshots is caught.
sandbox_up test-tripwire-drift
sandbox_tripwire_snapshot t2 "$FAKE_REAL_CLAUDE" "$FAKE_REAL_TEMPERLOOP"
# Simulate a sandboxed run that (incorrectly) escaped and wrote to the real
# path directly — this write itself happens OUTSIDE sandbox_run, exactly
# like a real escape would.
echo "escaped-write" >> "$FAKE_REAL_CLAUDE/settings.json"
if sandbox_tripwire_check t2 2>"$SCRATCH/tripwire-drift.err"; then
  sandbox_down
  fail "3b: sandbox_tripwire_check did not catch a deliberate write to a watched real path between snapshot and check"
fi
grep -q "drift detected" "$SCRATCH/tripwire-drift.err" \
  || fail "3b: drift failure message missing (got: $(cat "$SCRATCH/tripwire-drift.err"))"
sandbox_down
pass "3b (NEGATIVE): sandbox_tripwire_check catches a deliberate out-of-sandbox write between snapshot and check"

# 3c. absent watched path handled gracefully (no error), and its later
# appearance is itself flagged as drift.
ABSENT_PATH="$SCRATCH/fake-real-home/.local/bin/does-not-exist-yet"
sandbox_up test-tripwire-absent
sandbox_tripwire_snapshot t3 "$ABSENT_PATH" \
  || fail "3c: sandbox_tripwire_snapshot errored on a currently-absent watched path (must handle gracefully)"
sandbox_tripwire_check t3 \
  || fail "3c: sandbox_tripwire_check reported drift for an absent path that is still absent"
# Now make it appear — an existence flip must be caught as drift too.
echo "now-exists" > "$ABSENT_PATH"
if sandbox_tripwire_check t3 2>/dev/null; then
  sandbox_down
  fail "3c: sandbox_tripwire_check missed an absent-to-present flip on a watched path"
fi
sandbox_down
pass "3c: sandbox_tripwire_snapshot/check handle an absent watched path gracefully, and still catch its later appearance as drift"

echo
echo "ALL PASS: test_sandbox_integrity.sh"
