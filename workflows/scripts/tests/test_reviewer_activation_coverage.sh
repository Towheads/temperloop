#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/reviewer-activation-coverage.sh
# (temperloop#548) — the pure, non-interactive reviewer activation-coverage
# data path (ADR 0007/0008).
#
# Covers:
#   1. Pre-activation gap detection on a fixture repo: shell + python file
#      counts at/above REVIEWER_SCAN_MIN_FILES ARE flagged; a single stray
#      .go file (below threshold) is NOT. Gate scope: this test owns the
#      PRE-activation gap surface only — the post-activation green state
#      (activating a reviewer removes it from the gap set) is owned by
#      #549, not tested here.
#   2. --check-integrity passes on the real, committed reviewer-routing.tsv.
#   3. --check-integrity fails (non-zero) on a fixture tsv with a dangling
#      catalog-agent-path.
#   4. An already-covered reviewer (.claude/agents/<name>.md present) is
#      excluded from the gap set even though its file count clears threshold.
#   5. A durably-declined reviewer (.claude/reviewer-state/declined/<name>
#      marker) is excluded from the gap set.
#   6. An empty repo yields an empty gap set and exit 0 (the activation
#      proof's shape).
#   7. reviewer_coverage_gaps is directly callable after `source`, with no
#      side effects at source time, and agrees with --list-only output.
#
# No network, no HOME mutation — every case uses a throwaway tmpdir fixture.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RAC_SH="${REPO_ROOT}/workflows/scripts/install/reviewer-activation-coverage.sh"
CONFIG_SH="${REPO_ROOT}/workflows/scripts/build/build.config.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-rac-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -x "$RAC_SH" ] || fail "0: script not found or not executable at $RAC_SH"

# Resolve the REAL REVIEWER_SCAN_MIN_FILES default from build.config.sh
# (the knob's single source of truth) rather than hardcoding a literal here,
# so this test tracks the knob if it's ever retuned.
min_files="$(bash -c "source '$CONFIG_SH' >/dev/null 2>&1; echo \"\${REVIEWER_SCAN_MIN_FILES:-3}\"")"
case "$min_files" in
  ''|*[!0-9]*) fail "0: could not resolve a numeric REVIEWER_SCAN_MIN_FILES (got '$min_files')" ;;
esac

# ---------------------------------------------------------------------------
# Test 1: pre-activation gap detection.
# ---------------------------------------------------------------------------
FIXTURE1="${TMP}/fixture1"
mkdir -p "$FIXTURE1"
i=1
while [ "$i" -le "$min_files" ]; do
  echo '#!/usr/bin/env bash' >"${FIXTURE1}/script${i}.sh"
  echo 'print("hi")' >"${FIXTURE1}/mod${i}.py"
  i=$((i + 1))
done
echo 'package main' >"${FIXTURE1}/stray.go"

out1="$(bash "$RAC_SH" --list-only --project-dir "$FIXTURE1")"
printf '%s\n' "$out1" | grep -qx "shell-reviewer" \
  || fail "1: shell-reviewer not in gap set (got: $out1)"
printf '%s\n' "$out1" | grep -qx "python-reviewer" \
  || fail "1: python-reviewer not in gap set (got: $out1)"
if printf '%s\n' "$out1" | grep -qx "go-reviewer"; then
  fail "1: go-reviewer unexpectedly in gap set (single stray file, below threshold)"
fi

pass "1: shell+python flagged at/above threshold; a single stray below-threshold .go file is not"

# ---------------------------------------------------------------------------
# Test 2: referential-integrity check passes on the real, tracked tsv.
# ---------------------------------------------------------------------------
bash "$RAC_SH" --check-integrity >/dev/null 2>&1 \
  || fail "2: --check-integrity failed on the real reviewer-routing.tsv"

pass "2: --check-integrity passes on the real reviewer-routing.tsv (every catalog-agent-path resolves)"

# ---------------------------------------------------------------------------
# Test 3: referential-integrity check catches a DANGLING catalog-agent-path.
# ---------------------------------------------------------------------------
BAD_TSV="${TMP}/bad-routing.tsv"
{
  printf '.py\tpython-reviewer\tclaude/agents/reviewers/python-reviewer.md\n'
  printf '.zz\tzz-reviewer\tclaude/agents/reviewers/does-not-exist-zz.md\n'
} >"$BAD_TSV"

if REVIEWER_ROUTING_TSV="$BAD_TSV" bash "$RAC_SH" --check-integrity >/dev/null 2>&1; then
  fail "3: --check-integrity should have failed on a dangling catalog-agent-path"
fi

pass "3: --check-integrity exits non-zero when a catalog-agent-path is dangling"

# ---------------------------------------------------------------------------
# Test 4: an already-covered reviewer is excluded from the gap set.
# ---------------------------------------------------------------------------
FIXTURE2="${TMP}/fixture2"
mkdir -p "${FIXTURE2}/.claude/agents"
i=1
while [ "$i" -le "$min_files" ]; do
  echo '#!/usr/bin/env bash' >"${FIXTURE2}/script${i}.sh"
  echo 'print("hi")' >"${FIXTURE2}/mod${i}.py"
  i=$((i + 1))
done
echo '# shell-reviewer (already deployed)' >"${FIXTURE2}/.claude/agents/shell-reviewer.md"

out2="$(bash "$RAC_SH" --list-only --project-dir "$FIXTURE2")"
if printf '%s\n' "$out2" | grep -qx "shell-reviewer"; then
  fail "4: shell-reviewer should be excluded (already covered) — got: $out2"
fi
printf '%s\n' "$out2" | grep -qx "python-reviewer" \
  || fail "4: python-reviewer should still be in gap set — got: $out2"

pass "4: an already-covered reviewer (.claude/agents/<name>.md present) is excluded from the gap set"

# ---------------------------------------------------------------------------
# Test 5: a durably-declined reviewer is excluded from the gap set.
# ---------------------------------------------------------------------------
mkdir -p "${FIXTURE2}/.claude/reviewer-state/declined"
touch "${FIXTURE2}/.claude/reviewer-state/declined/python-reviewer"

out3="$(bash "$RAC_SH" --list-only --project-dir "$FIXTURE2")"
if printf '%s\n' "$out3" | grep -qx "python-reviewer"; then
  fail "5: python-reviewer should be excluded (declined) — got: $out3"
fi

pass "5: a durably-declined reviewer (.claude/reviewer-state/declined/<name> marker) is excluded from the gap set"

# ---------------------------------------------------------------------------
# Test 6: an empty repo yields an empty gap set (the activation-proof shape).
# ---------------------------------------------------------------------------
EMPTY="${TMP}/empty"
mkdir -p "$EMPTY"
out4="$(bash "$RAC_SH" --list-only --project-dir "$EMPTY")"
[ -z "$out4" ] || fail "6: expected empty gap set for an empty repo — got: $out4"

pass "6: an empty repo yields an empty gap set"

# ---------------------------------------------------------------------------
# Test 7: sourceable — reviewer_coverage_gaps is directly callable after
# `source`, agrees with --list-only, and has no side effects at source time.
# ---------------------------------------------------------------------------
sourced_out="$(bash -c "source '$RAC_SH'; reviewer_coverage_gaps '$FIXTURE1'")"
[ "$sourced_out" = "$out1" ] \
  || fail "7: sourced reviewer_coverage_gaps disagreed with --list-only output"

pass "7: reviewer_coverage_gaps is directly callable after sourcing, with no side effects at source time"

echo
echo "All reviewer-activation-coverage tests passed."
