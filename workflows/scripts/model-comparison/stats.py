#!/usr/bin/env python3
"""stats.py — the comparison-statistics numeric core (temperloop#1249).

Invoked by workflows/scripts/model-comparison/stats.sh, which owns the
operator-facing settings (workflows/scripts/config/setting-registry.tsv) and
their defaults (workflows/scripts/build/build.config.sh); this module owns
the math itself. Python 3 stdlib only (`statistics.NormalDist`, `random`,
`math`) — same "python3 stdlib only, already a tracked dependency" convention
workflows/scripts/score-redundancy.py uses. No network call, no model call:
every subcommand here is a pure function of the numbers it is given on the
command line or stdin.

Subcommands (each prints one JSON object on stdout, exit 0; a usage or input
error prints to stderr and exits 2):

  bootstrap-ci   Percentile bootstrap confidence interval over a list of
                 per-outcome cost deltas (candidate cost minus baseline cost
                 for the same merged outcome — negative means the candidate
                 was cheaper). Resampling uses `random.Random(seed)`, whose
                 Mersenne Twister sequence is stable across CPython versions
                 for a fixed seed, so the SAME deltas + iterations + seed +
                 ci-width always produce the SAME lower/upper bound — the
                 property a known-answer fixture test depends on.

  mde            Minimum detectable effect at a given N and observed sample
                 standard deviation: the half-width a bootstrap-style CI
                 would have at that N and variance, i.e. the smallest true
                 mean delta a comparison at this N could ever tell apart
                 from zero. `mde = z(ci_width) * stddev / sqrt(n)`, the
                 standard one-sample/paired margin-of-error formula, using
                 the EXACT inverse-normal quantile from
                 `statistics.NormalDist` rather than a hand-rolled table.

  verdict        The inconclusive floor + winner call in one step: below
                 `--min-sample` outcomes the verdict is ALWAYS "inconclusive"
                 and NO winner-shaped field is populated (no lower/upper/
                 mean-derived winner) — this is deliberate, not an
                 optimization, per temperloop#1249 acceptance bullet 3. At or
                 above the threshold, the same bootstrap CI as above decides
                 the verdict: CI entirely above zero -> "baseline_better"
                 (the candidate cost MORE), entirely below zero ->
                 "candidate_better", straddling zero -> "no_significant_difference".

  coverage       Emit-coverage percentage against the STRUCTURAL denominator
                 the L0 usage-capture-feasibility spike (temperloop#1246)
                 defined: the emit-FEASIBLE seat subset, never the full seat
                 inventory. `coverage_pct = 100 * observed_seats /
                 feasible_seats`, feasible_seats supplied by the caller
                 (stats.sh resolves it from MODEL_COMPARISON_EMIT_FEASIBLE_SEATS,
                 default 3 per the spike's "3 of 12 spawn seats" finding).
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from statistics import NormalDist


def _mean(xs: list[float]) -> float:
    return sum(xs) / len(xs)


def _sample_stdev(xs: list[float]) -> float:
    n = len(xs)
    if n < 2:
        return 0.0
    m = _mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def _z_for_ci_width(width_pct: float) -> float:
    if not (0.0 < width_pct < 100.0):
        raise ValueError("--ci-width must be strictly between 0 and 100 (got %r)" % (width_pct,))
    alpha = (100.0 - width_pct) / 100.0
    return NormalDist().inv_cdf(1.0 - alpha / 2.0)


def _read_deltas(raw: str | None) -> list[float]:
    text = raw if raw is not None else sys.stdin.read()
    data = json.loads(text)
    if not isinstance(data, list) or not data:
        raise ValueError("deltas must be a non-empty JSON array of numbers")
    for v in data:
        if not isinstance(v, (int, float)) or isinstance(v, bool):
            raise ValueError("every delta must be a JSON number (got %r)" % (v,))
    return [float(v) for v in data]


def _bootstrap_means(deltas: list[float], iterations: int, seed: int) -> list[float]:
    n = len(deltas)
    rng = random.Random(seed)
    means = []
    for _ in range(iterations):
        resample = [deltas[rng.randrange(n)] for _ in range(n)]
        means.append(_mean(resample))
    means.sort()
    return means


def _clean(obj):
    """Recursively fold a whole-number float (95.0) down to an int (95) for
    output readability — jq preserves a JSON number's original literal
    formatting verbatim, so an un-folded 95.0 prints as "95.0" downstream
    even though the value is exactly 95. Never touches a value that
    genuinely carries a fractional part (33.3 stays 33.3)."""
    if isinstance(obj, float) and obj.is_integer():
        return int(obj)
    if isinstance(obj, dict):
        return {k: _clean(v) for k, v in obj.items()}
    return obj


def _emit(out: dict) -> None:
    print(json.dumps(_clean(out)))


def _percentile_bounds(sorted_means: list[float], ci_width: float) -> tuple[float, float]:
    iterations = len(sorted_means)
    alpha = (100.0 - ci_width) / 100.0
    lo_idx = max(0, min(iterations - 1, round((alpha / 2.0) * (iterations - 1))))
    hi_idx = max(0, min(iterations - 1, round((1.0 - alpha / 2.0) * (iterations - 1))))
    return sorted_means[lo_idx], sorted_means[hi_idx]


def cmd_bootstrap_ci(args: argparse.Namespace) -> int:
    deltas = _read_deltas(args.deltas)
    if args.iterations < 1:
        raise ValueError("--iterations must be >= 1 (got %r)" % (args.iterations,))
    means = _bootstrap_means(deltas, args.iterations, args.seed)
    lower, upper = _percentile_bounds(means, args.ci_width)
    out = {
        "n": len(deltas),
        "iterations": args.iterations,
        "seed": args.seed,
        "ci_width_pct": args.ci_width,
        "mean": _mean(deltas),
        "lower": lower,
        "upper": upper,
    }
    _emit(out)
    return 0


def cmd_mde(args: argparse.Namespace) -> int:
    if args.n < 1:
        raise ValueError("--n must be >= 1 (got %r)" % (args.n,))
    if args.stddev < 0:
        raise ValueError("--stddev must be >= 0 (got %r)" % (args.stddev,))
    z = _z_for_ci_width(args.ci_width)
    mde = z * args.stddev / math.sqrt(args.n)
    out = {
        "n": args.n,
        "stddev": args.stddev,
        "ci_width_pct": args.ci_width,
        "z": z,
        "mde": mde,
    }
    _emit(out)
    return 0


def cmd_verdict(args: argparse.Namespace) -> int:
    deltas = _read_deltas(args.deltas)
    n = len(deltas)
    if args.min_sample < 1:
        raise ValueError("--min-sample must be >= 1 (got %r)" % (args.min_sample,))

    # THE INCONCLUSIVE FLOOR (temperloop#1249 acceptance bullet 3): below the
    # threshold the verdict is ALWAYS "inconclusive" and NO winner-shaped
    # field is populated — never a bootstrap CI that happens to exclude zero
    # on a too-small sample being reported as a real winner.
    if n < args.min_sample:
        out = {
            "n": n,
            "min_sample": args.min_sample,
            "verdict": "inconclusive",
            "mean": _mean(deltas),
            "lower": None,
            "upper": None,
            "mde": None,
        }
        _emit(out)
        return 0

    if args.iterations < 1:
        raise ValueError("--iterations must be >= 1 (got %r)" % (args.iterations,))
    means = _bootstrap_means(deltas, args.iterations, args.seed)
    lower, upper = _percentile_bounds(means, args.ci_width)
    mean = _mean(deltas)
    stddev = _sample_stdev(deltas)
    z = _z_for_ci_width(args.ci_width)
    mde = z * stddev / math.sqrt(n)

    if lower > 0.0:
        verdict = "baseline_better"  # CI entirely above zero: candidate cost MORE
    elif upper < 0.0:
        verdict = "candidate_better"  # CI entirely below zero: candidate cost LESS
    else:
        verdict = "no_significant_difference"  # CI straddles zero

    out = {
        "n": n,
        "min_sample": args.min_sample,
        "verdict": verdict,
        "mean": mean,
        "lower": lower,
        "upper": upper,
        "mde": mde,
    }
    _emit(out)
    return 0


def cmd_coverage(args: argparse.Namespace) -> int:
    if args.feasible_seats < 1:
        raise ValueError("--feasible-seats must be >= 1 (got %r)" % (args.feasible_seats,))
    if args.observed_seats < 0:
        raise ValueError("--observed-seats must be >= 0 (got %r)" % (args.observed_seats,))
    pct = round(100.0 * args.observed_seats / args.feasible_seats, 1)
    out = {
        "observed_seats": args.observed_seats,
        "feasible_seats": args.feasible_seats,
        "coverage_pct": pct,
    }
    _emit(out)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="stats.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="subcommand", required=True)

    b = sub.add_parser("bootstrap-ci", help="bootstrap CI over a JSON array of cost deltas")
    b.add_argument("--deltas", default=None, help="JSON array of numbers; omit to read stdin")
    b.add_argument("--iterations", type=int, required=True)
    b.add_argument("--seed", type=int, required=True)
    b.add_argument("--ci-width", type=float, required=True, dest="ci_width")
    b.set_defaults(func=cmd_bootstrap_ci)

    m = sub.add_parser("mde", help="minimum detectable effect at N and an observed stddev")
    m.add_argument("--n", type=int, required=True)
    m.add_argument("--stddev", type=float, required=True)
    m.add_argument("--ci-width", type=float, required=True, dest="ci_width")
    m.set_defaults(func=cmd_mde)

    v = sub.add_parser("verdict", help="inconclusive floor + bootstrap-CI winner call")
    v.add_argument("--deltas", default=None, help="JSON array of numbers; omit to read stdin")
    v.add_argument("--iterations", type=int, required=True)
    v.add_argument("--seed", type=int, required=True)
    v.add_argument("--ci-width", type=float, required=True, dest="ci_width")
    v.add_argument("--min-sample", type=int, required=True, dest="min_sample")
    v.set_defaults(func=cmd_verdict)

    c = sub.add_parser("coverage", help="emit-coverage %% against the feasible-seat denominator")
    c.add_argument("--observed-seats", type=int, required=True, dest="observed_seats")
    c.add_argument("--feasible-seats", type=int, required=True, dest="feasible_seats")
    c.set_defaults(func=cmd_coverage)

    return p


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, json.JSONDecodeError) as exc:
        print("stats.py %s: %s" % (args.subcommand, exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
