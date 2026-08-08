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
# settings and forwards everything else to the numeric core,
# workflows/scripts/model-comparison/stats.py (python3 stdlib only).
#
# ── Usage ───────────────────────────────────────────────────────────────
#   stats.sh bootstrap-ci --deltas '[-0.4,-0.2,...]' [--iterations N] [--seed N] [--ci-width PCT] [--min-sample N]
#   stats.sh bootstrap-ci < deltas.json               # or pipe the JSON array in
#   stats.sh mde --n 40 --stddev 1.2 [--ci-width PCT] [--power P]
#   stats.sh verdict --deltas '[...]' [--min-sample N] [--iterations N] [--seed N] [--ci-width PCT]
#   stats.sh coverage --observed-seats N [--feasible-seats N]
#
# Every flag has a config-named default (below); passing the same flag again
# on the command line overrides it (argparse last-value-wins).
#
# ── Settings — RESOLVED, never re-valued here ───────────────────────────
# The five tunables below are registered in
# workflows/scripts/config/setting-registry.tsv, and their defaults live in
# their registered owning-script, workflows/scripts/build/build.config.sh —
# which this script SOURCES when present, exactly as
# workflows/scripts/pipeline-spend-report.sh, telemetry-brief.sh and
# board/reconcile.sh do. That single source of truth is the point: a second,
# independently-editable copy of a default in this file would be checked by
# NOTHING (check-setting-registry.sh's EQUALITY pass only pins a default
# against its row's own owning-script, and its UNREGISTERED sweep is
# name-only), so this file could silently drift to a laxer inconclusive
# floor while the lint stayed green.
#
# The `:=` fallbacks below therefore exist for ONE case only — a non-vendoring
# caller that has this script but no build.config.sh — and they are NOT an
# unpinned duplicate: test_stats.sh § 5 asserts each literal below equals its
# registry row's `default` column, so drift between the two is a mechanical
# test failure rather than a silent divergence.
#
#   MODEL_COMPARISON_MIN_SAMPLE_N          sample-size threshold below which
#                                          `verdict` and `bootstrap-ci` refuse
#                                          to report a winner-shaped result.
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
# Dependencies: python3 >= 3.8 (stdlib only). No network, no model call, ever.
# The floor is enforced below rather than assumed: stats.py's cross-version
# reproducibility guarantee is only stated for interpreters at or above it,
# and `statistics.NormalDist` (the exact inverse-normal quantile the MDE and
# CI figures use) does not exist before 3.8.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CORE="$SCRIPT_DIR/stats.py"
self="$(basename "$0")"

# Minimum CPython this module's guarantees hold for. A hard floor, not an
# operator tunable — there is deliberately no config-named seam for it.
PY_MIN_MAJOR=3
PY_MIN_MINOR=8

# Settings: build.config.sh (the registered owning-script) when it is present,
# else the pinned fallbacks below. An already-exported value wins over both,
# since every layer uses the `:=` assign-only-if-unset idiom.
if [ -f "$REPO_ROOT/workflows/scripts/build/build.config.sh" ]; then
  # shellcheck source=workflows/scripts/build/build.config.sh
  source "$REPO_ROOT/workflows/scripts/build/build.config.sh"
fi

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
if ! python3 -c "import sys; sys.exit(0 if sys.version_info[:2] >= ($PY_MIN_MAJOR, $PY_MIN_MINOR) else 1)" 2>/dev/null; then
  PY_FOUND="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo unknown)"
  echo "$self: python3 is $PY_FOUND, but this library requires >= $PY_MIN_MAJOR.$PY_MIN_MINOR" >&2
  echo "$self: (statistics.NormalDist — the exact inverse-normal quantile the MDE and CI" >&2
  echo "$self:  figures use — landed in 3.8, and the cross-version reproducibility guarantee" >&2
  echo "$self:  stats.py states is only claimed at or above that floor)" >&2
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
      --min-sample "$MODEL_COMPARISON_MIN_SAMPLE_N" \
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
