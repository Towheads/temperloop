#!/usr/bin/env bash
#
# test_stats.sh — tests for workflows/scripts/model-comparison/stats.sh (and
# its numeric core, stats.py). temperloop#1249, "comparison statistics
# library" (epic #1225, model comparison harness).
#
# Every assertion here runs against KNOWN-ANSWER FIXTURES computed by
# actually running the deterministic core (random.Random(seed)'s Mersenne
# Twister sequence is stable across CPython versions for a fixed seed) —
# never a live model call, never a network read. Settings are PINNED by env
# for every invocation (same convention test_item_efficiency.sh's PINNED_ENV
# uses) so these assertions never silently move when build.config.sh's
# defaults are re-tuned; a real drift is caught by a *different*, explicit
# test (§ 5 below), not by this suite's own numbers shifting underfoot.
#
# Covers every temperloop#1249 acceptance bullet:
#   1. bootstrap CI for a cost-per-merged-outcome delta, known-answer fixture
#   2. minimum detectable effect at two different N
#   3. the inconclusive floor — below threshold NEVER returns a winner, and
#      the threshold boundary is asserted in BOTH directions
#   4. coverage % against the emit-FEASIBLE seat denominator (not the full
#      seat inventory)
#   5. every tunable is registered in setting-registry.tsv with a default in
#      build.config.sh
#   6. error/degradation paths: empty deltas, non-numeric deltas, bad flags

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../../.." && pwd)"
STATS="$REPO/workflows/scripts/model-comparison/stats.sh"
CORE="$REPO/workflows/scripts/model-comparison/stats.py"
REGISTRY="$REPO/workflows/scripts/config/setting-registry.tsv"
CONFIG="$REPO/workflows/scripts/build/build.config.sh"

[ -f "$STATS" ] || { echo "FATAL: stats.sh not found at $STATS" >&2; exit 1; }
[ -f "$CORE" ] || { echo "FATAL: stats.py not found at $CORE" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this test" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}
check_close() { # <desc> <want> <got> <epsilon>
  local d="$1" want="$2" got="$3" eps="$4"
  if awk -v w="$want" -v g="$got" -v e="$eps" 'BEGIN{d=w-g; if (d<0) d=-d; exit !(d<=e)}'; then
    ok "$d"
  else
    bad "$d" "want [$want] +/- $eps, got [$got]"
  fi
}

# PINNED settings — the same convention test_item_efficiency.sh's PINNED_ENV
# uses: fix every tunable this suite depends on so a later re-tune of
# build.config.sh's defaults can never silently move these assertions.
PINNED_ENV=(MODEL_COMPARISON_BOOTSTRAP_ITERATIONS=500 MODEL_COMPARISON_BOOTSTRAP_SEED=42
            MODEL_COMPARISON_CI_WIDTH_PCT=95 MODEL_COMPARISON_MIN_SAMPLE_N=5
            MODEL_COMPARISON_EMIT_FEASIBLE_SEATS=3)

run() { env "${PINNED_ENV[@]}" bash "$STATS" "$@"; }

# ===========================================================================
# 1. Bootstrap CI — known-answer fixture. Never a live model call or network
#    read: the "cost-per-merged-outcome delta" is a plain JSON array of
#    numbers (candidate cost minus baseline cost per matched outcome).
# ===========================================================================
echo "1. bootstrap CI (known-answer fixture):"
CI_CANDIDATE_BETTER="$(run bootstrap-ci --deltas '[-0.4,-0.2,-0.3,-0.1,-0.5,-0.2,-0.3,-0.4]')"
check "the record is a single valid JSON object" \
  bash -c "printf '%s' '$CI_CANDIDATE_BETTER' | jq -e 'type == \"object\"' >/dev/null"
check_eq "n is carried" "8" "$(printf '%s' "$CI_CANDIDATE_BETTER" | jq -r '.n')"
check_eq "iterations/seed/ci_width_pct echo the PINNED settings" "500 42 95" \
  "$(printf '%s' "$CI_CANDIDATE_BETTER" | jq -r '"\(.iterations) \(.seed) \(.ci_width_pct)"')"
check_eq "mean is the plain sample mean: -0.3" "-0.3" "$(printf '%s' "$CI_CANDIDATE_BETTER" | jq -r '.mean')"
check_eq "KNOWN-ANSWER lower bound: -0.3875" "-0.3875" "$(printf '%s' "$CI_CANDIDATE_BETTER" | jq -r '.lower')"
check_eq "KNOWN-ANSWER upper bound: -0.225" "-0.225" "$(printf '%s' "$CI_CANDIDATE_BETTER" | jq -r '.upper')"

# Determinism: same deltas + same PINNED settings -> byte-identical output,
# every time (the property the known-answer fixture above depends on).
CI_REPEAT="$(run bootstrap-ci --deltas '[-0.4,-0.2,-0.3,-0.1,-0.5,-0.2,-0.3,-0.4]')"
check_eq "re-running the SAME fixture reproduces the SAME CI exactly" \
  "$CI_CANDIDATE_BETTER" "$CI_REPEAT"

# stdin form (a report producer piping deltas in, never a --deltas flag).
CI_STDIN="$(printf '%s' '[-0.4,-0.2,-0.3,-0.1,-0.5,-0.2,-0.3,-0.4]' | run bootstrap-ci)"
check_eq "reading deltas from stdin reproduces the same known answer" \
  "$CI_CANDIDATE_BETTER" "$CI_STDIN"

# ===========================================================================
# 2. Minimum detectable effect — at TWO different N, so a permanently-
#    unreachable verdict is visible before spend rather than after it.
# ===========================================================================
echo "2. minimum detectable effect at N:"
MDE_N10="$(run mde --n 10 --stddev 1.0)"
MDE_N40="$(run mde --n 40 --stddev 1.0)"
check_close "MDE at n=10, stddev=1.0, 95% CI: z*1.0/sqrt(10) = 0.61980" \
  "0.61980" "$(printf '%s' "$MDE_N10" | jq -r '.mde')" "0.0001"
check_close "MDE at n=40, stddev=1.0, 95% CI: z*1.0/sqrt(40) = 0.30990" \
  "0.30990" "$(printf '%s' "$MDE_N40" | jq -r '.mde')" "0.0001"
MDE10_VAL="$(printf '%s' "$MDE_N10" | jq -r '.mde')"
MDE40_VAL="$(printf '%s' "$MDE_N40" | jq -r '.mde')"
check "MDE at the LARGER N is smaller — more N makes smaller deltas detectable" \
  awk -v a="$MDE10_VAL" -v b="$MDE40_VAL" 'BEGIN{exit !(b<a)}'
check_close "quadrupling N halves MDE (sqrt(4)=2): mde(n=40) ~= mde(n=10)/2" \
  "$(awk -v a="$MDE10_VAL" 'BEGIN{print a/2}')" "$MDE40_VAL" "0.0005"

# ===========================================================================
# 3. THE INCONCLUSIVE FLOOR — a run below the threshold NEVER returns a
#    winner, and the threshold boundary is asserted in BOTH directions.
#    MODEL_COMPARISON_MIN_SAMPLE_N is PINNED to 5 above.
# ===========================================================================
echo "3. inconclusive floor (threshold boundary, both directions):"
BELOW="$(run verdict --deltas '[-0.4,-0.2,-0.3,-0.1]')"   # n=4, threshold=5
check_eq "n=4 (BELOW the threshold of 5) is echoed" "4" "$(printf '%s' "$BELOW" | jq -r '.n')"
check_eq "n=4: verdict is inconclusive" "inconclusive" "$(printf '%s' "$BELOW" | jq -r '.verdict')"
check_eq "n=4: lower is null — NO winner-shaped field is populated" "null" "$(printf '%s' "$BELOW" | jq -r '.lower')"
check_eq "n=4: upper is null too" "null" "$(printf '%s' "$BELOW" | jq -r '.upper')"
check_eq "n=4: mde is null (an inconclusive run reports no detectable-effect claim)" \
  "null" "$(printf '%s' "$BELOW" | jq -r '.mde')"

AT="$(run verdict --deltas '[-0.4,-0.2,-0.3,-0.1,-0.5]')"  # n=5, threshold=5 (AT the boundary)
check_eq "n=5 (AT the threshold of 5) is echoed" "5" "$(printf '%s' "$AT" | jq -r '.n')"
check_eq "n=5: verdict is NOT inconclusive — the boundary itself clears the floor" \
  "candidate_better" "$(printf '%s' "$AT" | jq -r '.verdict')"
check "n=5: lower IS populated (a real CI, not null)" \
  bash -c "printf '%s' '$AT' | jq -e '.lower != null' >/dev/null"
check "n=5: mde IS populated" \
  bash -c "printf '%s' '$AT' | jq -e '.mde != null' >/dev/null"

# The other two winner shapes, over the SAME n=8 sample (min-sample overridden
# below the sample size so all three fixtures clear the floor and only the
# CI's own position relative to zero decides the verdict).
POS8="$(run verdict --deltas '[0.4,0.2,0.3,0.1,0.5,0.2,0.3,0.4]')"
check_eq "all-positive deltas (candidate cost MORE): baseline_better" \
  "baseline_better" "$(printf '%s' "$POS8" | jq -r '.verdict')"
MIXED8="$(run verdict --deltas '[0.1,-0.1,0.05,-0.05,0.2,-0.2,0.15,-0.15]')"
check_eq "a CI straddling zero: no_significant_difference (never a fabricated winner)" \
  "no_significant_difference" "$(printf '%s' "$MIXED8" | jq -r '.verdict')"

# ===========================================================================
# 4. Coverage % — against the emit-FEASIBLE seat denominator the L0
#    usage-capture spike defined (temperloop#1246), never the full 12-seat
#    inventory.
# ===========================================================================
echo "4. coverage % (emit-feasible denominator, not the full seat inventory):"
COV_FULL="$(run coverage --observed-seats 3)"
check_eq "3 of 3 emit-feasible seats observed -> 100%, using the PINNED denominator of 3 (not 12)" \
  "100" "$(printf '%s' "$COV_FULL" | jq -r '.coverage_pct')"
check_eq "feasible_seats in the record is the PINNED denominator, 3" \
  "3" "$(printf '%s' "$COV_FULL" | jq -r '.feasible_seats')"
COV_PARTIAL="$(run coverage --observed-seats 1)"
check_eq "1 of 3 feasible seats -> 33.3% (a below-100% figure is EXPECTED and structural, never an error)" \
  "33.3" "$(printf '%s' "$COV_PARTIAL" | jq -r '.coverage_pct')"
COV_OVERRIDE="$(run coverage --observed-seats 4 --feasible-seats 6)"
check_eq "an explicit --feasible-seats overrides the pinned denominator: 4/6 -> 66.7%" \
  "66.7" "$(printf '%s' "$COV_OVERRIDE" | jq -r '.coverage_pct')"

# ===========================================================================
# 5. Every tunable is a config-named setting: registered in
#    setting-registry.tsv, defaulted in build.config.sh, no bare literal.
# ===========================================================================
echo "5. settings are registered, not literals:"
[ -f "$REGISTRY" ] || { echo "FATAL: setting-registry.tsv not found at $REGISTRY" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "FATAL: build.config.sh not found at $CONFIG" >&2; exit 1; }
for VAR in MODEL_COMPARISON_MIN_SAMPLE_N MODEL_COMPARISON_BOOTSTRAP_ITERATIONS \
           MODEL_COMPARISON_BOOTSTRAP_SEED MODEL_COMPARISON_CI_WIDTH_PCT \
           MODEL_COMPARISON_EMIT_FEASIBLE_SEATS; do
  check "$VAR has a registry row in setting-registry.tsv" \
    grep -q "^${VAR}	" "$REGISTRY"
  check "$VAR has a tracked-repo default in build.config.sh" \
    grep -q "\${${VAR}:=" "$CONFIG"
  check "stats.sh itself names $VAR symbolically (never a bare re-valued literal)" \
    grep -q "$VAR" "$STATS"
done

# ===========================================================================
# 6. Error / degradation paths — a malformed input is a clean exit 2 with a
#    message on stderr, never a silent wrong number or a crash traceback.
# ===========================================================================
echo "6. error paths:"
EMPTY_OUT="$(run bootstrap-ci --deltas '[]' 2>&1; echo "rc=$?")"
check "an empty deltas array exits 2 (not 0, not a crash)" bash -c "grep -q 'rc=2' <<<'$EMPTY_OUT'"
check "...and says why" bash -c "grep -qi 'non-empty' <<<'$EMPTY_OUT'"

BADJSON_OUT="$(run bootstrap-ci --deltas 'not-json' 2>&1; echo "rc=$?")"
check "malformed JSON exits 2" bash -c "grep -q 'rc=2' <<<'$BADJSON_OUT'"

NONNUM_OUT="$(run bootstrap-ci --deltas '[1,2,"three"]' 2>&1; echo "rc=$?")"
check "a non-numeric element in the deltas array exits 2" bash -c "grep -q 'rc=2' <<<'$NONNUM_OUT'"

run >/dev/null 2>&1; NOSUBCMD_RC=$?
check_eq "no subcommand at all exits 2 with usage" "2" "$NOSUBCMD_RC"

BADSUBCMD_OUT="$(run frobnicate 2>&1; echo "rc=$?")"
check "an unrecognized subcommand exits 2" bash -c "grep -q 'rc=2' <<<'$BADSUBCMD_OUT'"

# NOTE: exit code captured directly (never via a grepped 'rc=' sentinel
# embedded in captured prose) — the usage text itself contains apostrophes
# ("it's given"), which would break the <<<'...' quoting used elsewhere in
# this file if the raw text were interpolated that way.
run --help >/dev/null 2>&1; HELP_RC=$?
check_eq "--help exits 0" "0" "$HELP_RC"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_stats: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_stats: OK — all %d checks passed\n' "$pass"
