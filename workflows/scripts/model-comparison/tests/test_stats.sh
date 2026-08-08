#!/usr/bin/env bash
#
# test_stats.sh — tests for workflows/scripts/model-comparison/stats.sh (and
# its numeric core, stats.py). temperloop#1249, "comparison statistics
# library" (epic #1225, model comparison harness).
#
# Every assertion here runs against KNOWN-ANSWER FIXTURES computed by actually
# running the deterministic core — never a live model call, never a network
# read. The determinism those fixtures ride on is NOT "the RNG is stable"
# alone: stats.py draws resample indices via `Random.random()` (the only
# CPython method documented as sequence-stable across versions) and sums via
# `math.fsum` (builtin `sum()` changed accumulation strategy in CPython 3.12,
# gh-100425, and does NOT agree across versions). Both fixtures below are
# verified byte-identical on CPython 3.9 and 3.14.
#
# Settings are PINNED by env for every invocation (same convention
# test_item_efficiency.sh's PINNED_ENV uses) so these assertions never
# silently move when build.config.sh's defaults are re-tuned; a real drift is
# caught by a *different*, explicit test (§ 5 below), not by this suite's own
# numbers shifting underfoot. Every pinned value is deliberately DISTINCT from
# its shipped default, so § 5's functional-discrimination checks can actually
# tell "the setting drove this output" from "the built-in default happened to
# agree".
#
# Covers every temperloop#1249 acceptance bullet:
#   1. bootstrap CI for a cost-per-merged-outcome delta, known-answer fixture
#   2. minimum detectable effect at two different N — and the MDE proper kept
#      distinct from the CI margin of error
#   3. the inconclusive floor — below threshold NEVER returns a winner, on
#      EITHER subcommand, and the threshold boundary is asserted in BOTH
#      directions
#   4. coverage % against the emit-FEASIBLE seat denominator (not the full
#      seat inventory)
#   5. every tunable is registered in setting-registry.tsv with a default in
#      build.config.sh — asserted FUNCTIONALLY (override it, watch the output
#      move), never by a presence-grep that a comment header would satisfy
#   6. error/degradation paths: empty deltas, non-numeric deltas, NON-FINITE
#      deltas, degenerate samples, bad flags

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

# A STRICT RFC 8259 parser, deliberately NOT jq. jq accepts the bare `NaN`
# token and silently coerces it to `null` — and since jq orders `null < 0`, a
# NaN-corrupted record reads to a downstream `select(.upper < 0)` as "the
# candidate is significantly cheaper". A jq-based "is it valid JSON?" check
# therefore CANNOT catch the very corruption § 6 exists to pin, so validity is
# asserted with a parser that rejects the non-finite tokens outright.
STRICT_JSON_PY='import json,sys; json.load(sys.stdin, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))'
check_strict_json() { # <desc> <text>
  if printf '%s' "$2" | python3 -c "$STRICT_JSON_PY" >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1" "not strict RFC-8259 JSON (bare NaN/Infinity, or malformed): [$2]"
  fi
}
jqr() { printf '%s' "$1" | jq -r "$2"; }

# PINNED settings — the same convention test_item_efficiency.sh's PINNED_ENV
# uses: fix every tunable this suite depends on so a later re-tune of
# build.config.sh's defaults can never silently move these assertions. NOTE
# every pinned value differs from the shipped default (20/2000/1729/95/3) —
# except CI width, which § 5 discriminates with its own explicit override
# instead, since the fixtures below want a conventional 95% interval.
PINNED_ENV=(MODEL_COMPARISON_BOOTSTRAP_ITERATIONS=500 MODEL_COMPARISON_BOOTSTRAP_SEED=42
            MODEL_COMPARISON_CI_WIDTH_PCT=95 MODEL_COMPARISON_MIN_SAMPLE_N=5
            MODEL_COMPARISON_EMIT_FEASIBLE_SEATS=3)

run() { env "${PINNED_ENV[@]}" bash "$STATS" "$@"; }
# Same, with ONE setting overridden past the pinned value (env applies its
# assignments left to right, so the later one wins).
run_with() { local ov="$1"; shift; env "${PINNED_ENV[@]}" "$ov" bash "$STATS" "$@"; }

FIX8='[-0.4,-0.2,-0.3,-0.1,-0.5,-0.2,-0.3,-0.4]'
FIX5='[-0.4,-0.2,-0.3,-0.1,-0.5]'

# ===========================================================================
# 1. Bootstrap CI — known-answer fixture. Never a live model call or network
#    read: the "cost-per-merged-outcome delta" is a plain JSON array of
#    numbers (candidate cost minus baseline cost per matched outcome).
# ===========================================================================
echo "1. bootstrap CI (known-answer fixture):"
CI_CANDIDATE_BETTER="$(run bootstrap-ci --deltas "$FIX8")"
check_strict_json "the record is a single valid (strict RFC 8259) JSON object" "$CI_CANDIDATE_BETTER"
check_eq "n is carried" "8" "$(jqr "$CI_CANDIDATE_BETTER" '.n')"
check_eq "iterations/seed/ci_width_pct echo the PINNED settings" "500 42 95" \
  "$(jqr "$CI_CANDIDATE_BETTER" '"\(.iterations) \(.seed) \(.ci_width_pct)"')"
check_eq "mean is the plain sample mean: -0.3" "-0.3" "$(jqr "$CI_CANDIDATE_BETTER" '.mean')"
# check_close, not an exact string compare: an exact compare on a float bound
# is what pinned this suite to one CPython's summation strategy and failed on
# 3.9 (-0.38749999999999996 vs -0.3875). The tolerance is far tighter than any
# real regression and no longer depends on the interpreter's float formatting.
CI_LOWER="$(jqr "$CI_CANDIDATE_BETTER" '.lower')"
CI_UPPER="$(jqr "$CI_CANDIDATE_BETTER" '.upper')"
check_close "KNOWN-ANSWER lower bound: -0.3875" "-0.3875" "$CI_LOWER" "0.0000001"
check_close "KNOWN-ANSWER upper bound: -0.2125" "-0.2125" "$CI_UPPER" "0.0000001"

# Fixture-INDEPENDENT invariants — these hold for any sample, so they keep
# holding after a re-baseline and catch a bound that drifts loose of its own
# point estimate.
CI_MEAN="$(jqr "$CI_CANDIDATE_BETTER" '.mean')"
check "invariant: lower <= mean <= upper" \
  awk -v lo="$CI_LOWER" -v m="$CI_MEAN" -v hi="$CI_UPPER" 'BEGIN{exit !(lo<=m && m<=hi)}'
CI_NARROW="$(run_with MODEL_COMPARISON_CI_WIDTH_PCT=80 bootstrap-ci --deltas "$FIX8")"
NARROW_W="$(awk -v a="$(jqr "$CI_NARROW" '.lower')" -v b="$(jqr "$CI_NARROW" '.upper')" 'BEGIN{print b-a}')"
WIDE_W="$(awk -v a="$CI_LOWER" -v b="$CI_UPPER" 'BEGIN{print b-a}')"
check "invariant: a WIDER --ci-width yields a WIDER interval (95% > 80%)" \
  awk -v n="$NARROW_W" -v w="$WIDE_W" 'BEGIN{exit !(w>n)}'

# Determinism: same deltas + same PINNED settings -> byte-identical output,
# every time (the property the known-answer fixture above depends on).
CI_REPEAT="$(run bootstrap-ci --deltas "$FIX8")"
check_eq "re-running the SAME fixture reproduces the SAME CI exactly" \
  "$CI_CANDIDATE_BETTER" "$CI_REPEAT"

# stdin form (a report producer piping deltas in, never a --deltas flag).
CI_STDIN="$(printf '%s' "$FIX8" | run bootstrap-ci)"
check_eq "reading deltas from stdin reproduces the same known answer" \
  "$CI_CANDIDATE_BETTER" "$CI_STDIN"

# ===========================================================================
# 2. Minimum detectable effect — at TWO different N, so a permanently-
#    unreachable verdict is visible before spend rather than after it. The
#    MDE proper is kept DISTINCT from the CI margin of error: z*sd/sqrt(n) is
#    the interval half-width, detected only ~50% of the time, so reporting it
#    as "the smallest detectable effect" understates the N a team needs by
#    ~43% at the conventional 80% power.
# ===========================================================================
echo "2. minimum detectable effect at N (power-aware, distinct from margin of error):"
MDE_N10="$(run mde --n 10 --stddev 1.0)"
MDE_N40="$(run mde --n 40 --stddev 1.0)"
check_strict_json "the mde record is strict JSON" "$MDE_N10"
check_eq "power is echoed so the number is self-describing" "0.8" "$(jqr "$MDE_N10" '.power')"
# Epsilon 0.00001, not 0.0001: a hand-rolled 1.96 in place of the exact
# inverse-normal quantile misses by ~4e-5, which a 1e-4 tolerance would wave
# through — making the "EXACT NormalDist quantile" claim untestable.
check_close "margin of error at n=10, sd=1.0, 95%: z*1.0/sqrt(10) = 0.61979503" \
  "0.61979503" "$(jqr "$MDE_N10" '.margin_of_error')" "0.00001"
check_close "margin of error at n=40, sd=1.0, 95%: z*1.0/sqrt(40) = 0.30989752" \
  "0.30989752" "$(jqr "$MDE_N40" '.margin_of_error')" "0.00001"
check_close "TRUE MDE at n=10, 80% power: (z+z_power)*1.0/sqrt(10) = 0.88593903" \
  "0.88593903" "$(jqr "$MDE_N10" '.mde')" "0.00001"
check_close "TRUE MDE at n=40, 80% power: (z+z_power)*1.0/sqrt(40) = 0.44296952" \
  "0.44296952" "$(jqr "$MDE_N40" '.mde')" "0.00001"
MDE10_VAL="$(jqr "$MDE_N10" '.mde')"
MDE40_VAL="$(jqr "$MDE_N40" '.mde')"
MOE10_VAL="$(jqr "$MDE_N10" '.margin_of_error')"
check "the MDE is strictly LARGER than the margin of error (the ~43% a 50%-power figure understates)" \
  awk -v m="$MOE10_VAL" -v d="$MDE10_VAL" 'BEGIN{exit !(d>m*1.4)}'
check "MDE at the LARGER N is smaller — more N makes smaller deltas detectable" \
  awk -v a="$MDE10_VAL" -v b="$MDE40_VAL" 'BEGIN{exit !(b<a)}'
check_close "quadrupling N halves MDE (sqrt(4)=2): mde(n=40) ~= mde(n=10)/2" \
  "$(awk -v a="$MDE10_VAL" 'BEGIN{printf "%.10f", a/2}')" "$MDE40_VAL" "0.00001"
# --power is a real knob, not a frozen constant baked into the label.
MDE_P50="$(run mde --n 10 --stddev 1.0 --power 0.5)"
check_close "at 50% power the MDE collapses onto the margin of error (z_power=0)" \
  "$MOE10_VAL" "$(jqr "$MDE_P50" '.mde')" "0.00001"

# ===========================================================================
# 3. THE INCONCLUSIVE FLOOR — a run below the threshold NEVER returns a
#    winner, and the threshold boundary is asserted in BOTH directions.
#    MODEL_COMPARISON_MIN_SAMPLE_N is PINNED to 5 above.
# ===========================================================================
echo "3. inconclusive floor (threshold boundary, both directions):"
BELOW="$(run verdict --deltas '[-0.4,-0.2,-0.3,-0.1]')"   # n=4, threshold=5
check_eq "n=4 (BELOW the threshold of 5) is echoed" "4" "$(jqr "$BELOW" '.n')"
check_eq "n=4: verdict is inconclusive" "inconclusive" "$(jqr "$BELOW" '.verdict')"
check_eq "n=4: lower is null — NO winner-shaped field is populated" "null" "$(jqr "$BELOW" '.lower')"
check_eq "n=4: upper is null too" "null" "$(jqr "$BELOW" '.upper')"
check_eq "n=4: mde is null (an inconclusive run reports no detectable-effect claim)" \
  "null" "$(jqr "$BELOW" '.mde')"
check_eq "n=4: below_min_sample flags WHY, so a caller need not infer it from nulls" \
  "true" "$(jqr "$BELOW" '.below_min_sample')"

AT="$(run verdict --deltas "$FIX5")"  # n=5, threshold=5 (AT the boundary)
check_strict_json "the verdict record is strict JSON" "$AT"
check_eq "n=5 (AT the threshold of 5) is echoed" "5" "$(jqr "$AT" '.n')"
check_eq "n=5: verdict is NOT inconclusive — the boundary itself clears the floor" \
  "candidate_better" "$(jqr "$AT" '.verdict')"
check "n=5: lower IS populated (a real CI, not null)" \
  test "$(jqr "$AT" '.lower')" != "null"
check "n=5: mde IS populated" test "$(jqr "$AT" '.mde')" != "null"
# The VALUE, not merely non-nullness. Asserting only `.mde != null` is what let
# two real defects sit green: a POPULATION divisor in _sample_stdev (/n rather
# than /(n-1)), and an sqrt(n-1) in the standard error. Both move these
# numbers; neither moves a null check.
check_close "n=5: sample stddev is the SAMPLE (n-1) divisor: 0.15811388" \
  "0.15811388" "$(jqr "$AT" '.stddev')" "0.00001"
check_close "n=5: margin of error = z*0.15811388/sqrt(5) = 0.13859038" \
  "0.13859038" "$(jqr "$AT" '.margin_of_error')" "0.00001"
check_close "n=5: MDE = (z+z_power)*0.15811388/sqrt(5) = 0.19810199" \
  "0.19810199" "$(jqr "$AT" '.mde')" "0.00001"
AT_LO="$(jqr "$AT" '.lower')"; AT_HI="$(jqr "$AT" '.upper')"; AT_MEAN="$(jqr "$AT" '.mean')"
check "n=5 invariant: lower <= mean <= upper" \
  awk -v lo="$AT_LO" -v m="$AT_MEAN" -v hi="$AT_HI" 'BEGIN{exit !(lo<=m && m<=hi)}'

# The other two winner shapes, over the SAME n=8 sample.
POS8="$(run verdict --deltas '[0.4,0.2,0.3,0.1,0.5,0.2,0.3,0.4]')"
check_eq "all-positive deltas (candidate cost MORE): baseline_better" \
  "baseline_better" "$(jqr "$POS8" '.verdict')"
MIXED8="$(run verdict --deltas '[0.1,-0.1,0.05,-0.05,0.2,-0.2,0.15,-0.15]')"
check_eq "a CI straddling zero: no_significant_difference (never a fabricated winner)" \
  "no_significant_difference" "$(jqr "$MIXED8" '.verdict')"

# THE FLOOR IS A MODULE PROPERTY, NOT A `verdict` PROPERTY. bootstrap-ci over
# two outcomes puts both bounds below zero; a downstream `select(.upper < 0)`
# reads that as a real winner unless the same floor applies here too.
BC_BELOW="$(run bootstrap-ci --deltas '[-0.9,-0.8]')"   # n=2, threshold=5
check_eq "bootstrap-ci below the floor: below_min_sample is true" \
  "true" "$(jqr "$BC_BELOW" '.below_min_sample')"
check_eq "bootstrap-ci below the floor: lower is null, NOT a winner-shaped bound" \
  "null" "$(jqr "$BC_BELOW" '.lower')"
check_eq "bootstrap-ci below the floor: upper is null too" \
  "null" "$(jqr "$BC_BELOW" '.upper')"

# ===========================================================================
# 4. Coverage % — against the emit-FEASIBLE seat denominator the L0
#    usage-capture spike defined (temperloop#1246), never the full 12-seat
#    inventory.
# ===========================================================================
echo "4. coverage % (emit-feasible denominator, not the full seat inventory):"
COV_FULL="$(run coverage --observed-seats 3)"
check_eq "3 of 3 emit-feasible seats observed -> 100%, using the PINNED denominator of 3 (not 12)" \
  "100" "$(jqr "$COV_FULL" '.coverage_pct')"
check_eq "feasible_seats in the record is the PINNED denominator, 3" \
  "3" "$(jqr "$COV_FULL" '.feasible_seats')"
COV_PARTIAL="$(run coverage --observed-seats 1)"
check_eq "1 of 3 feasible seats -> 33.3% (a below-100% figure is EXPECTED and structural, never an error)" \
  "33.3" "$(jqr "$COV_PARTIAL" '.coverage_pct')"
COV_OVERRIDE="$(run coverage --observed-seats 4 --feasible-seats 6)"
check_eq "an explicit --feasible-seats overrides the pinned denominator: 4/6 -> 66.7%" \
  "66.7" "$(jqr "$COV_OVERRIDE" '.coverage_pct')"
# Passing the FULL seat inventory as the numerator is the most likely form of
# the exact confusion this subcommand exists to prevent — it must be an error,
# not a nonsense 400% at exit 0.
COV_OVER_OUT="$(run coverage --observed-seats 12 --feasible-seats 3 2>/dev/null)"; COV_OVER_RC=$?
check_eq "observed ABOVE feasible exits 2, never a >100% figure" "2" "$COV_OVER_RC"
check_eq "...and prints nothing on stdout" "" "$COV_OVER_OUT"

# ===========================================================================
# 5. Every tunable is a config-named setting: registered in
#    setting-registry.tsv, defaulted in build.config.sh, no bare literal.
#
#    ASSERTED FUNCTIONALLY. A presence-grep over stats.sh cannot fail: the
#    script's own comment header names all five settings in prose, so the
#    grep matches even after a setting is deleted from the executable body
#    outright (proved by mutation — deleting both the forwarding and the
#    default for two settings left this suite 49/49 green). Each setting is
#    therefore OVERRIDDEN to a value distinct from both its default and its
#    pinned value, and the OUTPUT is asserted to move.
# ===========================================================================
echo "5. settings are registered, and functionally drive the output:"
[ -f "$REGISTRY" ] || { echo "FATAL: setting-registry.tsv not found at $REGISTRY" >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "FATAL: build.config.sh not found at $CONFIG" >&2; exit 1; }

registry_default() { awk -F'\t' -v v="$1" '$1 == v { print $2; exit }' "$REGISTRY"; }
stats_sh_fallback() { # the `: "${VAR:=X}"` literal in stats.sh
  local line; line="$(grep -F ": \"\${$1:=" "$STATS" | head -1)"
  line="${line#*:=}"; printf '%s' "${line%\}\"}"
}

for VAR in MODEL_COMPARISON_MIN_SAMPLE_N MODEL_COMPARISON_BOOTSTRAP_ITERATIONS \
           MODEL_COMPARISON_BOOTSTRAP_SEED MODEL_COMPARISON_CI_WIDTH_PCT \
           MODEL_COMPARISON_EMIT_FEASIBLE_SEATS; do
  check "$VAR has a registry row in setting-registry.tsv" \
    grep -q "^${VAR}	" "$REGISTRY"
  check "$VAR has a tracked-repo default in build.config.sh" \
    grep -q "\${${VAR}:=" "$CONFIG"
  # stats.sh keeps a `:=` fallback for a NON-VENDORING caller (one that has
  # this script but no build.config.sh). check-setting-registry.sh's EQUALITY
  # pass only pins a default against its row's OWN owning-script — which is
  # build.config.sh — so that fallback is checked by no lint at all, and drift
  # to (say) a laxer inconclusive floor would stay green. Pin it here instead.
  check_eq "stats.sh's non-vendoring fallback for $VAR equals the registry default" \
    "$(registry_default "$VAR")" "$(stats_sh_fallback "$VAR")"
done

# The resolution chain end to end: with NOTHING pinned in the environment,
# stats.sh must source build.config.sh and pick the registered default up from
# there. Compared against the registry row rather than a hardcoded number, so
# a legitimate re-tune moves both sides together.
UNPINNED="$(unset MODEL_COMPARISON_MIN_SAMPLE_N; bash "$STATS" verdict --deltas "$FIX8")"
check_eq "with no env override, min_sample resolves from build.config.sh to the registry default" \
  "$(registry_default MODEL_COMPARISON_MIN_SAMPLE_N)" "$(jqr "$UNPINNED" '.min_sample')"

# --- functional discrimination, one setting at a time ---------------------
# MIN_SAMPLE_N: pinned 5. Override to 3 and a 4-sample run must FLIP from
# inconclusive to a real verdict — the single most consequential setting here.
MS_OUT="$(run_with MODEL_COMPARISON_MIN_SAMPLE_N=3 verdict --deltas '[-0.4,-0.2,-0.3,-0.1]')"
check_eq "MIN_SAMPLE_N drives the floor: at 3, an n=4 run is no longer inconclusive" \
  "candidate_better" "$(jqr "$MS_OUT" '.verdict')"
check_eq "...and the record echoes the overridden threshold (3, not the pinned 5)" \
  "3" "$(jqr "$MS_OUT" '.min_sample')"

# BOOTSTRAP_ITERATIONS: pinned 500, default 2000. Override to 777.
IT_OUT="$(run_with MODEL_COMPARISON_BOOTSTRAP_ITERATIONS=777 bootstrap-ci --deltas "$FIX8")"
check_eq "BOOTSTRAP_ITERATIONS drives the resample count (777, not 500 or the built-in 2000)" \
  "777" "$(jqr "$IT_OUT" '.iterations')"

# BOOTSTRAP_SEED: pinned 42, default 1729. Seed 7 yields a DIFFERENT known
# bound, so this discriminates the value and not merely its echo.
SEED_OUT="$(run_with MODEL_COMPARISON_BOOTSTRAP_SEED=7 bootstrap-ci --deltas "$FIX8")"
check_eq "BOOTSTRAP_SEED is forwarded (7, not the pinned 42)" "7" "$(jqr "$SEED_OUT" '.seed')"
check_close "...and actually reseeds the resampling: seed 7's known lower bound is -0.375" \
  "-0.375" "$(jqr "$SEED_OUT" '.lower')" "0.0000001"
check "...which differs from seed 42's bound, so the seed is not inert" \
  awk -v a="$CI_LOWER" -v b="$(jqr "$SEED_OUT" '.lower')" 'BEGIN{exit !(a!=b)}'

# CI_WIDTH_PCT: pinned 95, default 95 — so this is the ONE setting whose pin
# cannot discriminate it. Override to 80 and assert both the echo and a
# genuinely narrower interval ($CI_NARROW, computed in § 1).
check_eq "CI_WIDTH_PCT is forwarded (80, not the pinned/default 95)" \
  "80" "$(jqr "$CI_NARROW" '.ci_width_pct')"
check "...and actually narrows the interval, so the width is not inert" \
  awk -v n="$NARROW_W" -v w="$WIDE_W" 'BEGIN{exit !(n<w)}'

# EMIT_FEASIBLE_SEATS: pinned 3, default 3 — same situation. Override to 4 and
# watch the DENOMINATOR move: 2 of 4 is 50%, 2 of 3 would be 66.7%.
COV_ENV="$(run_with MODEL_COMPARISON_EMIT_FEASIBLE_SEATS=4 coverage --observed-seats 2)"
check_eq "EMIT_FEASIBLE_SEATS drives the denominator (4, not the built-in 3)" \
  "4" "$(jqr "$COV_ENV" '.feasible_seats')"
check_eq "...and the percentage follows it: 2 of 4 is 50%, not 2 of 3 = 66.7%" \
  "50" "$(jqr "$COV_ENV" '.coverage_pct')"

# Cheap belt-and-suspenders only — NOT the assertion doing the work above.
# shellcheck disable=SC2016  # matching the LITERAL $REPO_ROOT text in stats.sh, not expanding it
check "stats.sh sources build.config.sh rather than owning a second copy of the defaults" \
  grep -q 'source "\$REPO_ROOT/workflows/scripts/build/build.config.sh"' "$STATS"

# ===========================================================================
# 6. Error / degradation paths — a malformed input is a clean exit 2 with a
#    message on stderr, never a silent wrong number or a crash traceback.
#
#    NOTE the exit code is captured DIRECTLY throughout, never via a grepped
#    'rc=' sentinel embedded in captured prose: stats.py formats offending
#    values with %r (which emits single quotes) and the usage text contains
#    apostrophes, either of which breaks a `<<<'$VAR'` here-string the moment
#    the interpolated text contains whitespace.
# ===========================================================================
echo "6. error paths:"
EMPTY_ERR="$(run bootstrap-ci --deltas '[]' 2>&1 >/dev/null)"
run bootstrap-ci --deltas '[]' >/dev/null 2>&1; EMPTY_RC=$?
check_eq "an empty deltas array exits 2 (not 0, not a crash)" "2" "$EMPTY_RC"
check "...and says why" grep -qi 'non-empty' <<<"$EMPTY_ERR"

run bootstrap-ci --deltas 'not-json' >/dev/null 2>&1; BADJSON_RC=$?
check_eq "malformed JSON exits 2" "2" "$BADJSON_RC"

run bootstrap-ci --deltas '[1,2,"three"]' >/dev/null 2>&1; NONNUM_RC=$?
check_eq "a non-numeric element in the deltas array exits 2" "2" "$NONNUM_RC"

# --- NON-FINITE input ------------------------------------------------------
# json.loads accepts bare NaN/Infinity/-Infinity, and overflows 1e400 to inf;
# isinstance(float('nan'), float) is True, so a plain type guard passes them
# straight through. json.dumps then re-emits them as bare NaN/Infinity, which
# RFC 8259 does not permit — and jq coerces NaN to null, where jq's `null < 0`
# makes a corrupted record read to `select(.upper < 0)` as "the candidate is
# significantly cheaper". A routing decision, out of garbage, at exit 0.
for BADNUM in '[NaN,1,2,3,4]' '[Infinity,1,2]' '[-Infinity,1,2]' '[1e400,1,2]'; do
  NF_OUT="$(run verdict --deltas "$BADNUM" 2>/dev/null)"; NF_RC=$?
  check_eq "non-finite deltas $BADNUM exit 2, never a plausible verdict" "2" "$NF_RC"
  check_eq "...and print NOTHING on stdout (no half-garbage record)" "" "$NF_OUT"
  NF_OUT2="$(run bootstrap-ci --deltas "$BADNUM" 2>/dev/null)"; NF_RC2=$?
  check_eq "bootstrap-ci rejects $BADNUM the same way" "2" "$NF_RC2"
  check_eq "...with empty stdout too" "" "$NF_OUT2"
done

# --- degenerate samples ----------------------------------------------------
# Five identical deltas have zero observed variance. That is an ABSENCE of
# evidence, not certainty: reported as a winner it becomes a zero-width CI
# excluding zero plus an mde of 0, reading as "certain winner, arbitrarily
# small effects detectable".
DEGEN="$(run verdict --deltas '[-0.3,-0.3,-0.3,-0.3,-0.3]')"
check_eq "a zero-variance sample is NOT a maximally-confident winner" \
  "no_significant_difference" "$(jqr "$DEGEN" '.verdict')"
check_eq "...and is flagged degenerate so the caller can see why" \
  "true" "$(jqr "$DEGEN" '.degenerate')"
check_eq "a normal sample is NOT flagged degenerate" "false" "$(jqr "$AT" '.degenerate')"

# --- the --iterations floor ------------------------------------------------
# Below ~2/alpha resamples the percentile indices collapse (lo_idx rounds to 0,
# hi_idx to B-1), so the reported "95% interval" is silently the full min-max
# range and --ci-width has no effect whatsoever.
for BADIT in 1 10 99; do
  run_with "MODEL_COMPARISON_BOOTSTRAP_ITERATIONS=$BADIT" bootstrap-ci --deltas "$FIX8" >/dev/null 2>&1
  check_eq "--iterations $BADIT is refused (percentile indices would be meaningless)" "2" "$?"
done
run_with MODEL_COMPARISON_BOOTSTRAP_ITERATIONS=100 bootstrap-ci --deltas "$FIX8" >/dev/null 2>&1
check_eq "--iterations 100 is accepted at a 95% CI (the floor itself)" "0" "$?"

# --- stdin with no data ----------------------------------------------------
# The stdin path must not hang. (On a TERMINAL stdin the module refuses
# outright rather than blocking forever; here stdin is /dev/null, so it reads
# an empty string and fails as malformed JSON.)
run bootstrap-ci </dev/null >/dev/null 2>&1
check_eq "an empty stdin exits 2 rather than hanging" "2" "$?"

run >/dev/null 2>&1; NOSUBCMD_RC=$?
check_eq "no subcommand at all exits 2 with usage" "2" "$NOSUBCMD_RC"

run frobnicate >/dev/null 2>&1; BADSUBCMD_RC=$?
check_eq "an unrecognized subcommand exits 2" "2" "$BADSUBCMD_RC"

run --help >/dev/null 2>&1; HELP_RC=$?
check_eq "--help exits 0" "0" "$HELP_RC"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_stats: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_stats: OK — all %d checks passed\n' "$pass"
