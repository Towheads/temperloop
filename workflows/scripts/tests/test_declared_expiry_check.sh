#!/usr/bin/env bash
#
# test_declared_expiry_check.sh — fixture tests for
# workflows/scripts/declared-expiry-check.sh (temperloop#831, epic #810 P10).
#
# Covers the acceptance's own required demonstrations: a known-positive
# date-form fixture (an expiry date already past -> EXPIRED), a
# known-positive issue-form fixture modelled on the overlay's "## Phase 1
# parity comparison rule" (a heading declaring "temporary — removed at
# Phase 3, F#956"-shaped prose, whose `expires:` issue ref is mocked CLOSED
# via --dry-run/--fixture -> EXPIRED), and a known-negative fixture (a future
# date -> NOT expired). Also covers: the surface-intersection scoping
# (citation-registry.tsv rows whose file is NOT a contributor-manifest.tsv
# row are excluded and named), the "reads as temporary, declares nothing"
# heuristic bucket, the coverage/adoption arithmetic and its GO/NO-GO verdict
# against the pre-registered threshold, an open (not yet closed) issue-form
# reference staying un-flagged, a genuinely OFFLINE gh failure (a real,
# non-dry-run `gh` call that fails, via a PATH-shadowing fake binary)
# degrading LEGIBLY to an UNRESOLVED line rather than crashing or silently
# dropping the row, and the two missing-input degrade-to-skip paths (missing
# citation registry / missing contributor manifest each print a clear
# stderr note and exit 0 — this script's own findings never fail a build).
#
# Zero real network: --dry-run/--fixture covers the deterministic issue-form
# paths; the offline test shadows `gh` on PATH with a script that simply
# exits 1, run WITHOUT --dry-run, to exercise the genuine live-call-failure
# branch directly.
#
# Usage: bash workflows/scripts/tests/test_declared_expiry_check.sh

set -uo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$REPO/workflows/scripts/declared-expiry-check.sh"

pass=0
fail=0
ok() { echo "  ok    $1"; pass=$((pass + 1)); }
fail_test() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }
assert_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) fail_test "$name" "expected to find: $needle" ;;
  esac
}
assert_not_has() {
  local haystack="$1" needle="$2" name="$3"
  case "$haystack" in
    *"$needle"*) fail_test "$name" "did NOT expect to find: $needle" ;;
    *) ok "$name" ;;
  esac
}
assert_rc() {
  local got="$1" want="$2" name="$3"
  if [ "$got" -eq "$want" ]; then ok "$name"; else fail_test "$name" "expected exit $want, got $got"; fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

[ -f "$SCRIPT" ] || { echo "test_declared_expiry_check: script not found: $SCRIPT" >&2; exit 1; }

# ── Build a fixture repo carrying all three required demonstration rules,
#    plus one out-of-scope row and one reads-as-temporary/no-expiry row ────
FIX="$TMP/fixture-repo"
mkdir -p "$FIX/claude/commands" "$FIX/workflows/scripts/config"
git -C "$FIX" init -q 2>/dev/null || { mkdir -p "$FIX"; git -C "$FIX" init -q; }
git -C "$FIX" config user.email test@example.com
git -C "$FIX" config user.name test

cat >"$FIX/claude/commands/build.md" <<'EOF'
---
description: Build things.
---

A date-form known-positive rule; its declared expiry has already passed. <!-- cite: DP.1 incident:K#1 expires:2020-01-01 -->

## Phase 1 parity comparison rule (temporary — removed at Phase 3, F#956)

An issue-form known-positive rule modelled on the overlay's own "temporary — removed at Phase 3, F#956" heading; its named retirement issue is mocked CLOSED. <!-- cite: IP.1 incident:K#2 expires:acme/widgets#956 -->

A known-negative rule; its declared expiry has not yet passed. <!-- cite: NG.1 incident:K#3 expires:2099-01-01 -->

An open-issue-form rule; its named retirement issue is still open, so it must NOT be flagged. <!-- cite: OI.1 incident:K#5 expires:acme/widgets#42 -->

A rule that reads as temporary in prose (a temporary measure) but declares no expiry at all. <!-- cite: TU.1 incident:K#4 -->

A permanent rule with no temporal language and no expiry -- never counted in either coverage bucket. <!-- cite: PR.1 incident:K#6 -->
EOF

cat >"$FIX/claude/CLAUDE.kernel.md" <<'EOF'
# Out-of-scope fixture

A rule whose FILE is registered but is NOT a contributor-manifest row. <!-- cite: OOS.1 incident:K#7 -->
EOF

cat >"$FIX/CLAUDE.md" <<'EOF'
thin pointer file
EOF

REG="$FIX/workflows/scripts/config/citation-registry.tsv"
cat >"$REG" <<'EOF'
DP.1	claude/commands/build.md
IP.1	claude/commands/build.md
NG.1	claude/commands/build.md
OI.1	claude/commands/build.md
TU.1	claude/commands/build.md
PR.1	claude/commands/build.md
OOS.1	claude/CLAUDE.kernel.md
EOF

MANIFEST="$FIX/workflows/scripts/config/contributor-manifest.tsv"
cat >"$MANIFEST" <<'EOF'
CLAUDE.md	full	kernel-pointer	harness-auto
claude/commands/build.md	frontmatter:description	command-listing	harness-auto
EOF

git -C "$FIX" add -A
git -C "$FIX" commit -q -m fixture

GHFIX="$TMP/gh-fixtures"
mkdir -p "$GHFIX"
printf '{"state":"CLOSED"}\n' >"$GHFIX/issue-acme-widgets-956.json"
printf '{"state":"OPEN"}\n' >"$GHFIX/issue-acme-widgets-42.json"

run() {
  CITATION_REGISTRY_FILE="$REG" CONTRIBUTOR_MANIFEST_TSV="$MANIFEST" \
    DECLARED_EXPIRY_SCAN_ROOT="$FIX" DECLARED_EXPIRY_TODAY="2026-07-28" \
    bash "$SCRIPT" --dry-run --fixture "$GHFIX" 2>&1
}

echo "--- 1. the three required demonstration fixtures ---"
out1="$(run)"; rc1=$?
assert_rc "$rc1" 0 "the check always exits 0 (report-only; never fails a build)"
assert_has "$out1" "DP.1" "date-form known-positive row appears in the report"
assert_has "$out1" "date 2020-01-01 has passed" "date-form known-positive is reported EXPIRED"
assert_has "$out1" "IP.1" "issue-form known-positive row appears in the report"
assert_has "$out1" "acme/widgets#956 is CLOSED" "issue-form known-positive (modelled on the overlay's Phase 1 parity rule) is reported EXPIRED once its retirement issue is closed"
assert_has "$out1" "NG.1" "known-negative row appears in the report"
assert_has "$out1" "expires:2099-01-01 (not yet passed)" "known-negative (future date) is reported NOT expired"

echo "--- 2. open-issue-form stays un-flagged ---"
assert_has "$out1" "OI.1" "open-issue-form row appears in the report"
assert_has "$out1" "still OPEN" "an open (not yet closed) retirement issue is reported as still open, never EXPIRED"
# The EXPIRED section itself must not mention OI.1 anywhere before its own
# "DECLARED, not yet expired" section header appears — a coarse but
# sufficient ordering check given the report's fixed section order.
expired_section="$(printf '%s\n' "$out1" | sed -n '/^EXPIRED/,/^UNRESOLVED/p')"
assert_not_has "$expired_section" "OI.1" "the open-issue-form row is NOT listed under EXPIRED"

echo "--- 3. surface scoping: out-of-scope file is excluded and named ---"
assert_has "$out1" "claude/CLAUDE.kernel.md" "the out-of-scope file (registered but not a contributor-manifest row) is named in the excluded list"
assert_not_has "$out1" "OOS.1" "the out-of-scope row (OOS.1) is never evaluated or reported"

echo "--- 4. reads-as-temporary heuristic, and the permanent-rule non-match ---"
assert_has "$out1" "TU.1" "the reads-as-temporary/no-expiry row appears in the report"
assert_has "$out1" "reads as temporary in prose, declares no expiry" "TU.1 is bucketed as reads-as-temporary"
assert_not_has "$out1" "PR.1	claude/commands/build.md	(reads as temporary" "the permanent rule (no temporal language, no expiry) is never bucketed as reads-as-temporary"

echo "--- 5. coverage/adoption arithmetic + GO/NO-GO ---"
# in-scope: DP.1, IP.1, NG.1, OI.1, TU.1, PR.1 = 6. Declared: DP.1, IP.1, NG.1, OI.1 = 4.
# reads-as-temporary-undeclared: TU.1 = 1. denom = 5. adoption = 4/5 = 80%.
assert_has "$out1" "4 of 6 in-scope standing rule(s) declare an expiry" "coverage numerator/denominator over the in-scope surface is correct"
assert_has "$out1" "1 additional rule(s) read as temporary in prose but declare no expiry" "the reads-as-temporary count is correct"
assert_has "$out1" "Adoption denominator (declared + reads-as-temporary-but-undeclared): 5" "the adoption denominator sums declared + reads-as-temporary"
assert_has "$out1" "80.00%" "the adoption percentage is computed correctly (4/5 = 80%)"
assert_has "$out1" "GO/NO-GO: GO" "80% adoption meets the pre-registered threshold -> GO"
assert_has "$out1" "LIMIT (stated, not papered over)" "the report states its own undeclared-temporary-rule blind spot explicitly"

echo "--- 6. genuine OFFLINE degrade (a real, non-dry-run gh call fails) ---"
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "fake gh: simulated offline failure" >&2
exit 1
EOF
chmod +x "$FAKEBIN/gh"
out6="$(PATH="$FAKEBIN:$PATH" CITATION_REGISTRY_FILE="$REG" CONTRIBUTOR_MANIFEST_TSV="$MANIFEST" \
  DECLARED_EXPIRY_SCAN_ROOT="$FIX" DECLARED_EXPIRY_TODAY="2026-07-28" \
  bash "$SCRIPT" 2>&1)"; rc6=$?
assert_rc "$rc6" 0 "an offline gh failure never crashes the script or fails its exit code"
assert_has "$out6" "UNRESOLVED" "the UNRESOLVED section is present"
assert_has "$out6" "IP.1" "the issue-form row is named in the UNRESOLVED section when gh is unavailable"
assert_has "$out6" "gh unavailable/offline" "the offline degrade reason is stated plainly"
assert_has "$out6" "never silently dropped" "the report states the row was not silently dropped"
assert_has "$out6" "OI.1" "the OTHER issue-form row is ALSO reported unresolved (both need gh; neither is silently skipped)"
# the date-form row must resolve regardless — it never touches gh at all.
assert_has "$out6" "date 2020-01-01 has passed" "the date-form row still resolves correctly even when gh is entirely unavailable"

echo "--- 7. missing-input degrade-to-skip (never a build failure) ---"
out7a="$(CITATION_REGISTRY_FILE="$TMP/no-such-registry.tsv" CONTRIBUTOR_MANIFEST_TSV="$MANIFEST" \
  DECLARED_EXPIRY_SCAN_ROOT="$FIX" bash "$SCRIPT" 2>&1)"; rc7a=$?
assert_rc "$rc7a" 0 "a missing citation registry degrades to a clean skip, not a failure"
assert_has "$out7a" "citation registry not found" "the missing-registry skip message is clear"

out7b="$(CITATION_REGISTRY_FILE="$REG" CONTRIBUTOR_MANIFEST_TSV="$TMP/no-such-manifest.tsv" \
  DECLARED_EXPIRY_SCAN_ROOT="$FIX" bash "$SCRIPT" 2>&1)"; rc7b=$?
assert_rc "$rc7b" 0 "a missing contributor manifest degrades to a clean skip, not a failure"
assert_has "$out7b" "contributor manifest not found" "the missing-manifest skip message is clear"

echo "--- 8. usage/argument handling ---"
bash "$SCRIPT" --dry-run >/dev/null 2>&1; rc8=$?
assert_rc "$rc8" 2 "--dry-run without --fixture is a usage error"
bash "$SCRIPT" --nonsense >/dev/null 2>&1; rc8b=$?
assert_rc "$rc8b" 2 "an unrecognized argument is a usage error"

# ── Tally ─────────────────────────────────────────────────────────────────────
echo "---"
echo "pass: $pass | fail: $fail"
if [ "$fail" -ne 0 ]; then
  echo "test_declared_expiry_check: FAIL"
  exit 1
fi
echo "test_declared_expiry_check: OK"
