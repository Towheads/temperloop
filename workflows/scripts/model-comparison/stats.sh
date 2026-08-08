#!/usr/bin/env bash
#
# stats.sh — the comparison-statistics library (temperloop#1249, epic #1225
# "model comparison harness"): bootstrap confidence intervals, the minimum-
# detectable-effect disclosure, the inconclusive floor, and emit-coverage %.
# This is the module's report-facing MATH — it never calls a model and never
# touches the network; every subcommand is a pure function of the numbers
# it's given.
#
# This script is a thin CLI wrapper, exactly the same shape as
# workflows/scripts/score-redundancy.sh: it owns the operator-facing
# settings (resolved from workflows/scripts/config/setting-registry.tsv /
# workflows/scripts/build/build.config.sh, kernel `:=` fallback below for a
# non-vendoring caller) and forwards everything else to the numeric core,
# workflows/scripts/model-comparison/stats.py (python3 stdlib only).
#
# ── Usage ───────────────────────────────────────────────────────────────
#   stats.sh bootstrap-ci --deltas '[-0.4,-0.2,...]' [--iterations N] [--seed N] [--ci-width PCT]
#   stats.sh bootstrap-ci < deltas.json               # or pipe the JSON array in
#   stats.sh mde --n 40 --stddev 1.2 [--ci-width PCT]
#   stats.sh verdict --deltas '[...]' [--min-sample N] [--iterations N] [--seed N] [--ci-width PCT]
#   stats.sh coverage --observed-seats N [--feasible-seats N]
#
# Every flag has a config-named default (below); passing the same flag again
# on the command line overrides it (argparse last-value-wins).
#
# ── Settings (registered in workflows/scripts/config/setting-registry.tsv;
#    named here, never re-valued in prose — the literals below ARE those
#    rows' owning-script seams; build.config.sh sources this same var name
#    for the tracked-repo default) ──────────────────────────────────────
#   MODEL_COMPARISON_MIN_SAMPLE_N          sample-size threshold below which
#                                          `verdict` returns "inconclusive"
#                                          and never a winner.
#   MODEL_COMPARISON_BOOTSTRAP_ITERATIONS  resample count for the percentile
#                                          bootstrap.
#   MODEL_COMPARISON_BOOTSTRAP_SEED        seed for the deterministic
#                                          resampling RNG — fixed so the same
#                                          deltas always reproduce the same
#                                          CI (the known-answer fixture test
#                                          depends on this).
#   MODEL_COMPARISON_CI_WIDTH_PCT          confidence interval width, e.g. 95
#                                          for a 95% CI.
#   MODEL_COMPARISON_EMIT_FEASIBLE_SEATS   `coverage`'s denominator: the
#                                          emit-FEASIBLE seat subset the L0
#                                          usage-capture-feasibility spike
#                                          (temperloop#1246) defined, never
#                                          the full seat inventory.
#
# Dependencies: python3 (stdlib only). No network, no model call, ever.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SCRIPT_DIR/stats.py"
self="$(basename "$0")"

: "${MODEL_COMPARISON_MIN_SAMPLE_N:=20}"
: "${MODEL_COMPARISON_BOOTSTRAP_ITERATIONS:=2000}"
: "${MODEL_COMPARISON_BOOTSTRAP_SEED:=1729}"
: "${MODEL_COMPARISON_CI_WIDTH_PCT:=95}"
: "${MODEL_COMPARISON_EMIT_FEASIBLE_SEATS:=3}"

usage() {
  sed -n '1,/^set -uo pipefail/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "$self: python3 not found on PATH — required for the numeric core" >&2
  exit 1
fi
if [ ! -f "$CORE" ]; then
  echo "$self: numeric core not found: $CORE" >&2
  exit 1
fi

[ $# -ge 1 ] || { usage >&2; exit 2; }
SUBCMD="$1"; shift

case "$SUBCMD" in
  bootstrap-ci)
    exec python3 "$CORE" bootstrap-ci \
      --iterations "$MODEL_COMPARISON_BOOTSTRAP_ITERATIONS" \
      --seed "$MODEL_COMPARISON_BOOTSTRAP_SEED" \
      --ci-width "$MODEL_COMPARISON_CI_WIDTH_PCT" \
      "$@"
    ;;
  mde)
    exec python3 "$CORE" mde \
      --ci-width "$MODEL_COMPARISON_CI_WIDTH_PCT" \
      "$@"
    ;;
  verdict)
    exec python3 "$CORE" verdict \
      --iterations "$MODEL_COMPARISON_BOOTSTRAP_ITERATIONS" \
      --seed "$MODEL_COMPARISON_BOOTSTRAP_SEED" \
      --ci-width "$MODEL_COMPARISON_CI_WIDTH_PCT" \
      --min-sample "$MODEL_COMPARISON_MIN_SAMPLE_N" \
      "$@"
    ;;
  coverage)
    exec python3 "$CORE" coverage \
      --feasible-seats "$MODEL_COMPARISON_EMIT_FEASIBLE_SEATS" \
      "$@"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "$self: unrecognized subcommand: $SUBCMD (want bootstrap-ci|mde|verdict|coverage)" >&2
    exit 2
    ;;
esac
