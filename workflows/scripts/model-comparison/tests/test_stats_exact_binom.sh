#!/usr/bin/env bash
#
# test_stats_exact_binom.sh — tests for `stats.sh exact-binom`
# (temperloop#2065): the two-sided exact (Clopper-Pearson) confidence
# interval for a win proportion k/n against the fixed null p=0.5, computed
# by inverting the binomial CDF directly (never a normal approximation or a
# bootstrap resample). Sibling of test_stats.sh, split into its own file so
# `scripts/quality-gates.sh --list | grep -q test_stats_exact_binom` (the
# activation-reachability predicate, temperloop#1934) resolves to a real,
# by-name-registered gate line rather than a substring of a comment.
#
# Every assertion runs against KNOWN-ANSWER fixtures computed by actually
# inverting the binomial CDF (cross-checked against the textbook 7/10 95%
# Clopper-Pearson interval, [0.3475471, 0.9332605] — the commonly-cited
# reference value, e.g. R's `binom.test(7, 10)`). The bisection this
# subcommand runs is pure deterministic arithmetic (no RNG, no
# summation-order dependence beyond `math.fsum`), so no cross-CPython-version
# caveat applies here the way it does for stats.sh's bootstrap subcommands.
#
# Covers:
#   1. known-answer fixture (7/10, 95% CI) + the fixture-independent
#      lower <= phat <= upper invariant
#   2. excludes_null true/false in both directions (9/10 excludes the null,
#      7/10 does not)
#   3. the shared inconclusive floor (MODEL_COMPARISON_MIN_SAMPLE_N) —
#      the SAME refusal bootstrap-ci/verdict already enforce — asserted at
#      the boundary in both directions
#   4. edge k values (k=0, k=n) and a --ci-width override actually narrowing
#      the interval
#   5. error paths: bad --n, bad --k, bad --ci-width

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../../.." && pwd)"
STATS="$REPO/workflows/scripts/model-comparison/stats.sh"

[ -f "$STATS" ] || { echo "FATAL: stats.sh not found at $STATS" >&2; exit 1; }
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
check_strict_json() { # <desc> <text>
  if printf '%s' "$2" | python3 -c "import json,sys; json.load(sys.stdin, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))" >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1" "not strict RFC-8259 JSON: [$2]"
  fi
}
jqr() { printf '%s' "$1" | jq -r "$2"; }

# PINNED settings — same convention as test_stats.sh's PINNED_ENV: fix the
# tunables this suite depends on so a later re-tune of build.config.sh's
# defaults can never silently move these assertions. MIN_SAMPLE_N=5 is
# deliberately BELOW the default (20) and below every fixture's n=10, so the
# "at/above the floor" fixtures below clear it while still being a
# deliberately-non-default value.
PINNED_ENV=(MODEL_COMPARISON_MIN_SAMPLE_N=5 MODEL_COMPARISON_CI_WIDTH_PCT=95)
run() { env "${PINNED_ENV[@]}" bash "$STATS" exact-binom "$@"; }
run_with() { local ov="$1"; shift; env "${PINNED_ENV[@]}" "$ov" bash "$STATS" exact-binom "$@"; }

# ===========================================================================
# 1. Known-answer fixture: 7/10 at 95% CI.
# ===========================================================================
echo "1. known-answer fixture (7/10, 95% CI):"
R7="$(run --n 10 --k 7)"
check_strict_json "the record is a single valid (strict RFC 8259) JSON object" "$R7"
check_eq "n/k are carried" "10 7" "$(jqr "$R7" '"\(.n) \(.k)"')"
check_eq "min_sample/ci_width_pct echo the PINNED settings" "5 95" \
  "$(jqr "$R7" '"\(.min_sample) \(.ci_width_pct)"')"
check_eq "below_min_sample is false (n=10 clears the pinned floor of 5)" \
  "false" "$(jqr "$R7" '.below_min_sample')"
check_eq "null_p is the fixed 0.5, not an operator flag" "0.5" "$(jqr "$R7" '.null_p')"
check_eq "phat is the plain k/n: 0.7" "0.7" "$(jqr "$R7" '.phat')"
R7_LOWER="$(jqr "$R7" '.lower')"; R7_UPPER="$(jqr "$R7" '.upper')"
check_close "KNOWN-ANSWER lower bound: 0.3475471 (textbook Clopper-Pearson 7/10)" \
  "0.3475471" "$R7_LOWER" "0.0000005"
check_close "KNOWN-ANSWER upper bound: 0.9332605" \
  "0.9332605" "$R7_UPPER" "0.0000005"
check "invariant: lower <= phat <= upper" \
  awk -v lo="$R7_LOWER" -v p="0.7" -v hi="$R7_UPPER" 'BEGIN{exit !(lo<=p && p<=hi)}'
R7_REPEAT="$(run --n 10 --k 7)"
check_eq "re-running the SAME fixture reproduces the SAME interval exactly (deterministic bisection)" \
  "$R7" "$R7_REPEAT"

# ===========================================================================
# 2. excludes_null in both directions, over the SAME n.
# ===========================================================================
echo "2. excludes_null (vs the fixed null p=0.5):"
check_eq "7/10: 0.5 falls INSIDE [0.3475, 0.9333] -> excludes_null is false" \
  "false" "$(jqr "$R7" '.excludes_null')"
R9="$(run --n 10 --k 9)"
check_close "9/10 KNOWN-ANSWER lower bound: 0.5549839 (excludes 0.5)" \
  "0.5549839" "$(jqr "$R9" '.lower')" "0.0000005"
check_eq "9/10: 0.5 falls OUTSIDE [0.5550, 0.9975] -> excludes_null is true" \
  "true" "$(jqr "$R9" '.excludes_null')"

# ===========================================================================
# 3. THE SHARED INCONCLUSIVE FLOOR — the same refusal bootstrap-ci/verdict
#    already enforce. MODEL_COMPARISON_MIN_SAMPLE_N is PINNED to 5 above.
# ===========================================================================
echo "3. inconclusive floor (threshold boundary, both directions):"
BELOW="$(run --n 4 --k 3)"  # n=4, threshold=5
check_eq "n=4 (BELOW the threshold of 5) is echoed" "4" "$(jqr "$BELOW" '.n')"
check_eq "n=4: below_min_sample is true" "true" "$(jqr "$BELOW" '.below_min_sample')"
check_eq "n=4: lower is null — NO significance-shaped field is populated" \
  "null" "$(jqr "$BELOW" '.lower')"
check_eq "n=4: upper is null too" "null" "$(jqr "$BELOW" '.upper')"
check_eq "n=4: excludes_null is null (never a fabricated true/false on a too-small sample)" \
  "null" "$(jqr "$BELOW" '.excludes_null')"
check_eq "n=4: phat IS still reported (0.75) even though below the floor" \
  "0.75" "$(jqr "$BELOW" '.phat')"

AT="$(run --n 5 --k 5)"  # n=5, threshold=5 (AT the boundary)
check_eq "n=5 (AT the threshold of 5) is echoed" "5" "$(jqr "$AT" '.n')"
check_eq "n=5: below_min_sample is false — the boundary itself clears the floor" \
  "false" "$(jqr "$AT" '.below_min_sample')"
check "n=5: lower IS populated (a real bound, not null)" \
  test "$(jqr "$AT" '.lower')" != "null"
check "n=5: excludes_null IS populated" test "$(jqr "$AT" '.excludes_null')" != "null"

# The refusal is functionally driven by the setting, not merely a fixed n=5
# coincidence: override the floor DOWN and the same n=4 sample stops refusing.
MS_OUT="$(run_with MODEL_COMPARISON_MIN_SAMPLE_N=3 --n 4 --k 3)"
check_eq "MIN_SAMPLE_N drives the floor: at 3, an n=4 run is no longer below_min_sample" \
  "false" "$(jqr "$MS_OUT" '.below_min_sample')"
check_eq "...and the record echoes the overridden threshold (3, not the pinned 5)" \
  "3" "$(jqr "$MS_OUT" '.min_sample')"

# ===========================================================================
# 4. Edge k values (k=0, k=n) and a --ci-width override.
# ===========================================================================
echo "4. edge k values + ci-width override:"
K0="$(run --n 10 --k 0)"
check_eq "k=0: lower is exactly 0.0 (the Clopper-Pearson k=0 special case)" \
  "0" "$(jqr "$K0" '.lower')"
check "k=0: upper is > 0 (a real one-sided-looking bound, not degenerate)" \
  awk -v u="$(jqr "$K0" '.upper')" 'BEGIN{exit !(u>0)}'
KN="$(run --n 10 --k 10)"
check_eq "k=n: upper is exactly 1.0 (the Clopper-Pearson k=n special case)" \
  "1" "$(jqr "$KN" '.upper')"
check "k=n: lower is < 1 (a real bound, not degenerate)" \
  awk -v l="$(jqr "$KN" '.lower')" 'BEGIN{exit !(l<1)}'

R7_80="$(run_with MODEL_COMPARISON_CI_WIDTH_PCT=80 --n 10 --k 7)"
W80="$(awk -v a="$(jqr "$R7_80" '.lower')" -v b="$(jqr "$R7_80" '.upper')" 'BEGIN{print b-a}')"
W95="$(awk -v a="$R7_LOWER" -v b="$R7_UPPER" 'BEGIN{print b-a}')"
check "a NARROWER --ci-width (80 < 95) yields a NARROWER interval" \
  awk -v n="$W80" -v w="$W95" 'BEGIN{exit !(n<w)}'
check_eq "the override is echoed (80, not the pinned 95)" "80" "$(jqr "$R7_80" '.ci_width_pct')"

# ===========================================================================
# 5. Error paths — a malformed input is a clean exit 2, never a crash or a
#    plausible-looking-but-wrong record.
# ===========================================================================
echo "5. error paths:"
run --n 0 --k 0 >/dev/null 2>&1; N0_RC=$?
check_eq "--n 0 exits 2" "2" "$N0_RC"
run --n -1 --k 0 >/dev/null 2>&1; NNEG_RC=$?
check_eq "a negative --n exits 2" "2" "$NNEG_RC"
run --n 10 --k -1 >/dev/null 2>&1; KNEG_RC=$?
check_eq "a negative --k exits 2" "2" "$KNEG_RC"
run --n 10 --k 11 >/dev/null 2>&1; KOVER_RC=$?
check_eq "--k above --n exits 2 (never a nonsense >1.0 phat)" "2" "$KOVER_RC"
K11_OUT="$(run --n 10 --k 11 2>/dev/null)"
check_eq "...and prints nothing on stdout" "" "$K11_OUT"
run_with MODEL_COMPARISON_CI_WIDTH_PCT=0 --n 10 --k 7 >/dev/null 2>&1; CI0_RC=$?
check_eq "--ci-width 0 exits 2" "2" "$CI0_RC"
run_with MODEL_COMPARISON_CI_WIDTH_PCT=100 --n 10 --k 7 >/dev/null 2>&1; CI100_RC=$?
check_eq "--ci-width 100 exits 2" "2" "$CI100_RC"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_stats_exact_binom: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_stats_exact_binom: OK — all %d checks passed\n' "$pass"
