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

REQUIRES CPython >= 3.8 (`statistics.NormalDist` landed in 3.8). stats.sh
enforces this floor explicitly before invoking this module, because the
reproducibility guarantee below is only stated for interpreters at or above
it.

── The reproducibility guarantee, and what it actually rides on ────────────
The SAME deltas + iterations + seed + ci-width produce the SAME lower/upper
bound on every supported CPython — the property the known-answer fixture
tests depend on. That guarantee rests on two deliberate choices, neither of
which is "the RNG is stable" alone:

  * RESAMPLING draws indices via `random.Random(seed).random()`, NOT
    `randrange()`. CPython documents sequence stability across versions for
    `Random.random()` only; every other `Random` method is explicitly
    subject to change. `randrange()` happens to agree on 3.9 and 3.14 today,
    but a fixture whose whole premise is cross-version reproducibility must
    not ride an unguaranteed surface.

  * SUMMATION uses `math.fsum`, NOT the builtin `sum()`. CPython 3.12
    switched builtin `sum()` to Neumaier compensated summation (gh-100425),
    so the identical delta array yields a bound of -0.3875 on 3.12+ and
    -0.38749999999999996 on 3.11 and earlier. `math.fsum` is exactly rounded
    on every version, so it agrees everywhere — and is strictly better for
    accumulation error at any N besides.

Subcommands (each prints one JSON object on stdout, exit 0; a usage or input
error prints to stderr and exits 2):

  bootstrap-ci   Percentile bootstrap confidence interval over a list of
                 per-outcome cost deltas (candidate cost minus baseline cost
                 for the same merged outcome — negative means the candidate
                 was cheaper). Subject to the SAME inconclusive floor
                 `verdict` applies (see below): below `--min-sample` outcomes
                 the bounds are null and `below_min_sample` is true, so no
                 caller — on ANY subcommand — can read a winner-shaped
                 record off a too-small sample.

  mde            Two DISTINCT effect sizes at a given N and observed sample
                 standard deviation, because conflating them is how a
                 comparison gets under-powered:

                   margin_of_error = z(ci_width) * stddev / sqrt(n)
                     The CI half-width — how wide the interval will be. A
                     true effect exactly this size is detected only ~50% of
                     the time, so this is NOT a detectability threshold.

                   mde = (z(ci_width) + z(power)) * stddev / sqrt(n)
                     The genuine minimum detectable effect: the smallest
                     true mean delta a comparison at this N would detect
                     with probability `--power` (default 0.80, the
                     conventional bar). This is the number to size N
                     against; it is ~43% LARGER than the margin of error at
                     80% power.

                 Both use the EXACT inverse-normal quantile from
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
                 A DEGENERATE sample (zero observed variance, or a bootstrap
                 distribution collapsed to a single point) is reported as
                 "no_significant_difference" with `degenerate: true`, never
                 as a maximally-confident winner on a zero-width interval.

  coverage       Emit-coverage percentage against the STRUCTURAL denominator
                 the L0 usage-capture-feasibility spike (temperloop#1246)
                 defined: the emit-FEASIBLE seat subset, never the full seat
                 inventory. `coverage_pct = 100 * observed_seats /
                 feasible_seats`, feasible_seats supplied by the caller
                 (stats.sh resolves it from MODEL_COMPARISON_EMIT_FEASIBLE_SEATS,
                 per the spike's "3 of 12 spawn seats" finding). Observed may
                 never EXCEED feasible: the failure this subcommand exists to
                 prevent is confusing the two seat counts, and its most likely
                 form is passing the full inventory as the numerator, so that
                 case is an error rather than a >100% figure.

Input hygiene: every delta must be a FINITE JSON number. `json.loads` accepts
bare `NaN`/`Infinity`/`-Infinity` and overflows `1e400` to `inf`, and
`json.dumps` re-emits those as bare `NaN`/`Infinity` — tokens RFC 8259 does
not permit, which jq silently coerces to `null`. Since jq orders `null < 0`,
a NaN-corrupted record reads to a downstream `select(.upper < 0)` as "the
candidate is significantly cheaper": a routing decision made out of garbage,
at exit 0. Non-finite input is therefore rejected at the door (exit 2), and
the writer additionally passes `allow_nan=False` so a non-finite value that
ever reached the emitter would raise BEFORE anything is printed rather than
emit invalid JSON.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from statistics import NormalDist

# Conventional statistical-power bar for the minimum-detectable-effect
# calculation. Not an operator setting (stats.sh registers no config-named
# seam for it): it is the textbook default that makes `mde` mean the standard
# thing, overridable per-invocation via --power for a caller who wants a
# different bar.
DEFAULT_POWER = 0.80

# Floor on the bootstrap resample count. Below ~2/alpha resamples the
# percentile indices degenerate: `lo_idx` rounds to 0 and `hi_idx` to B-1, so
# the reported "95% interval" is silently the full min-max range of the
# resampled means and --ci-width has NO effect at all. 100 is the absolute
# floor; a narrower CI needs proportionally more resamples for its percentile
# indices to be meaningful, hence the alpha-derived term.
MIN_ITERATIONS_FLOOR = 100


def _mean(xs: list[float]) -> float:
    # math.fsum, never builtin sum() — see the module docstring's
    # reproducibility section: builtin sum() changed accumulation strategy in
    # CPython 3.12 and does NOT agree across versions.
    return math.fsum(xs) / len(xs)


def _sample_stdev(xs: list[float]) -> float:
    n = len(xs)
    if n < 2:
        return 0.0
    m = _mean(xs)
    return math.sqrt(math.fsum((x - m) ** 2 for x in xs) / (n - 1))


def _z_for_ci_width(width_pct: float) -> float:
    if not (0.0 < width_pct < 100.0):
        raise ValueError("--ci-width must be strictly between 0 and 100 (got %r)" % (width_pct,))
    alpha = (100.0 - width_pct) / 100.0
    return NormalDist().inv_cdf(1.0 - alpha / 2.0)


def _z_for_power(power: float) -> float:
    if not (0.0 < power < 1.0):
        raise ValueError("--power must be strictly between 0 and 1 (got %r)" % (power,))
    return NormalDist().inv_cdf(power)


def _min_iterations(ci_width: float) -> int:
    """The smallest resample count at which the percentile indices for this CI
    width are actually distinguishable from the min/max of the distribution."""
    alpha = (100.0 - ci_width) / 100.0
    return max(MIN_ITERATIONS_FLOOR, int(math.ceil(2.0 / alpha)))


def _check_iterations(iterations: int, ci_width: float) -> None:
    floor = _min_iterations(ci_width)
    if iterations < floor:
        raise ValueError(
            "--iterations must be >= %d at --ci-width %g (got %r): below that the "
            "percentile indices collapse to the min/max of the resampled means and "
            "--ci-width has no effect" % (floor, ci_width, iterations)
        )


def _read_deltas(raw: str | None) -> list[float]:
    if raw is None:
        # A blocking sys.stdin.read() on a terminal is an indefinite hang with
        # no message — and, with no timeout wrapper, a hung CI job if a future
        # producer ever invokes this without a redirect.
        if sys.stdin.isatty():
            raise ValueError(
                "no --deltas given and stdin is a terminal; pass --deltas or pipe a JSON array"
            )
        text = sys.stdin.read()
    else:
        text = raw
    data = json.loads(text)
    if not isinstance(data, list) or not data:
        raise ValueError("deltas must be a non-empty JSON array of numbers")
    out = []
    for v in data:
        if not isinstance(v, (int, float)) or isinstance(v, bool):
            raise ValueError("every delta must be a JSON number (got %r)" % (v,))
        fv = float(v)
        # json.loads accepts bare NaN/Infinity/-Infinity, and overflows a
        # too-large literal like 1e400 to inf — both pass the isinstance guard
        # above. Reject here so they land in the exit-2 path rather than
        # producing invalid JSON and a plausible-looking verdict.
        if not math.isfinite(fv):
            raise ValueError(
                "every delta must be a FINITE JSON number; got %r "
                "(bare NaN/Infinity, or a literal that overflows to infinity)" % (v,)
            )
        out.append(fv)
    return out


def _bootstrap_means(deltas: list[float], iterations: int, seed: int) -> list[float]:
    n = len(deltas)
    rng = random.Random(seed)
    means = []
    for _ in range(iterations):
        # rng.random(), not rng.randrange(n): Random.random() is the ONLY
        # method CPython documents as sequence-stable across versions, and the
        # known-answer fixtures ride on that stability. random() < 1.0 always,
        # so int(random() * n) is in [0, n-1].
        resample = [deltas[int(rng.random() * n)] for _ in range(n)]
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
    # allow_nan=False is belt-and-suspenders behind _read_deltas' finite check:
    # it raises ValueError (-> the exit-2 path) BEFORE print() is reached, so a
    # non-finite value can never be emitted as the bare `NaN`/`Infinity` tokens
    # RFC 8259 forbids, and there is no partial-stdout risk either way.
    print(json.dumps(_clean(out), allow_nan=False))


def _percentile_bounds(sorted_means: list[float], ci_width: float) -> tuple[float, float]:
    iterations = len(sorted_means)
    alpha = (100.0 - ci_width) / 100.0
    lo_idx = max(0, min(iterations - 1, round((alpha / 2.0) * (iterations - 1))))
    hi_idx = max(0, min(iterations - 1, round((1.0 - alpha / 2.0) * (iterations - 1))))
    return sorted_means[lo_idx], sorted_means[hi_idx]


def _check_min_sample(min_sample: int) -> None:
    if min_sample < 1:
        raise ValueError("--min-sample must be >= 1 (got %r)" % (min_sample,))


def cmd_bootstrap_ci(args: argparse.Namespace) -> int:
    deltas = _read_deltas(args.deltas)
    n = len(deltas)
    _check_min_sample(args.min_sample)

    # THE INCONCLUSIVE FLOOR applies here too, not only on `verdict`. A CI over
    # two outcomes can sit entirely below zero and read, to any downstream
    # `select(.upper < 0)`, as a real winner. The floor is a property of the
    # MODULE, not of the one subcommand that spells the word "verdict".
    if n < args.min_sample:
        _emit({
            "n": n,
            "min_sample": args.min_sample,
            "below_min_sample": True,
            "iterations": args.iterations,
            "seed": args.seed,
            "ci_width_pct": args.ci_width,
            "mean": _mean(deltas),
            "lower": None,
            "upper": None,
        })
        return 0

    _check_iterations(args.iterations, args.ci_width)
    means = _bootstrap_means(deltas, args.iterations, args.seed)
    lower, upper = _percentile_bounds(means, args.ci_width)
    _emit({
        "n": n,
        "min_sample": args.min_sample,
        "below_min_sample": False,
        "iterations": args.iterations,
        "seed": args.seed,
        "ci_width_pct": args.ci_width,
        "mean": _mean(deltas),
        "lower": lower,
        "upper": upper,
        # A collapsed interval is not a confident answer, it is an absence of
        # observed variance — flagged so a caller never reads a zero-width CI
        # excluding zero as certainty.
        "degenerate": lower == upper,
    })
    return 0


def cmd_mde(args: argparse.Namespace) -> int:
    if args.n < 1:
        raise ValueError("--n must be >= 1 (got %r)" % (args.n,))
    if args.stddev < 0:
        raise ValueError("--stddev must be >= 0 (got %r)" % (args.stddev,))
    if not math.isfinite(args.stddev):
        raise ValueError("--stddev must be finite (got %r)" % (args.stddev,))
    z = _z_for_ci_width(args.ci_width)
    z_power = _z_for_power(args.power)
    se = args.stddev / math.sqrt(args.n)
    _emit({
        "n": args.n,
        "stddev": args.stddev,
        "ci_width_pct": args.ci_width,
        "power": args.power,
        "z": z,
        "z_power": z_power,
        # The CI half-width. A true effect exactly this size is detected only
        # ~50% of the time — NOT a detectability threshold.
        "margin_of_error": z * se,
        # The genuine minimum detectable effect at `power`.
        "mde": (z + z_power) * se,
    })
    return 0


def cmd_verdict(args: argparse.Namespace) -> int:
    deltas = _read_deltas(args.deltas)
    n = len(deltas)
    _check_min_sample(args.min_sample)

    # THE INCONCLUSIVE FLOOR (temperloop#1249 acceptance bullet 3): below the
    # threshold the verdict is ALWAYS "inconclusive" and NO winner-shaped
    # field is populated — never a bootstrap CI that happens to exclude zero
    # on a too-small sample being reported as a real winner. `bootstrap-ci`
    # enforces the same floor (see cmd_bootstrap_ci), so this is a property of
    # the whole module and not of this one code path.
    if n < args.min_sample:
        _emit({
            "n": n,
            "min_sample": args.min_sample,
            "below_min_sample": True,
            "verdict": "inconclusive",
            "mean": _mean(deltas),
            "lower": None,
            "upper": None,
            "margin_of_error": None,
            "mde": None,
            "power": args.power,
        })
        return 0

    _check_iterations(args.iterations, args.ci_width)
    means = _bootstrap_means(deltas, args.iterations, args.seed)
    lower, upper = _percentile_bounds(means, args.ci_width)
    mean = _mean(deltas)
    stddev = _sample_stdev(deltas)
    z = _z_for_ci_width(args.ci_width)
    z_power = _z_for_power(args.power)
    se = stddev / math.sqrt(n)

    # A sample with zero observed variance, or a bootstrap distribution
    # collapsed to a single point, carries NO evidence of a difference — it is
    # the absence of variation, not certainty about a winner. Reporting it as
    # "candidate_better" on a zero-width CI (with mde 0, reading as
    # "arbitrarily small effects are detectable") is the exact opposite of
    # what the data says.
    degenerate = stddev == 0.0 or lower == upper
    if degenerate:
        verdict = "no_significant_difference"
    elif lower > 0.0:
        verdict = "baseline_better"  # CI entirely above zero: candidate cost MORE
    elif upper < 0.0:
        verdict = "candidate_better"  # CI entirely below zero: candidate cost LESS
    else:
        verdict = "no_significant_difference"  # CI straddles zero

    _emit({
        "n": n,
        "min_sample": args.min_sample,
        "below_min_sample": False,
        "verdict": verdict,
        "degenerate": degenerate,
        "mean": mean,
        "lower": lower,
        "upper": upper,
        "stddev": stddev,
        "margin_of_error": z * se,
        "mde": (z + z_power) * se,
        "power": args.power,
    })
    return 0


def cmd_coverage(args: argparse.Namespace) -> int:
    if args.feasible_seats < 1:
        raise ValueError("--feasible-seats must be >= 1 (got %r)" % (args.feasible_seats,))
    if args.observed_seats < 0:
        raise ValueError("--observed-seats must be >= 0 (got %r)" % (args.observed_seats,))
    if args.observed_seats > args.feasible_seats:
        # The failure this subcommand exists to prevent is confusing the
        # emit-FEASIBLE subset with the full seat inventory, and the most
        # likely form of that mistake is passing the inventory as the
        # numerator. Returning a nonsense >100% figure at exit 0 would hide it.
        raise ValueError(
            "--observed-seats (%d) may not exceed --feasible-seats (%d): coverage is "
            "measured against the emit-FEASIBLE seat subset (temperloop#1246), so an "
            "observed count above the denominator means the two seat counts were "
            "confused" % (args.observed_seats, args.feasible_seats)
        )
    _emit({
        "observed_seats": args.observed_seats,
        "feasible_seats": args.feasible_seats,
        "coverage_pct": round(100.0 * args.observed_seats / args.feasible_seats, 1),
    })
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
    b.add_argument("--min-sample", type=int, default=1, dest="min_sample",
                   help="inconclusive floor; below this N the bounds are null")
    b.set_defaults(func=cmd_bootstrap_ci)

    m = sub.add_parser("mde", help="minimum detectable effect at N and an observed stddev")
    m.add_argument("--n", type=int, required=True)
    m.add_argument("--stddev", type=float, required=True)
    m.add_argument("--ci-width", type=float, required=True, dest="ci_width")
    m.add_argument("--power", type=float, default=DEFAULT_POWER,
                   help="statistical power for the MDE (default %(default)s)")
    m.set_defaults(func=cmd_mde)

    v = sub.add_parser("verdict", help="inconclusive floor + bootstrap-CI winner call")
    v.add_argument("--deltas", default=None, help="JSON array of numbers; omit to read stdin")
    v.add_argument("--iterations", type=int, required=True)
    v.add_argument("--seed", type=int, required=True)
    v.add_argument("--ci-width", type=float, required=True, dest="ci_width")
    v.add_argument("--min-sample", type=int, required=True, dest="min_sample")
    v.add_argument("--power", type=float, default=DEFAULT_POWER,
                   help="statistical power for the MDE (default %(default)s)")
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
