- **The macOS-vs-ubuntu CI slowdown is now measured and attributed to named
  gates** (#968, measurement phase only). `nightly-macos.yml` already published
  per-gate wall-clock on both legs; this adds a `Runner characterization` step
  to both (raw core count beside the pool's clamped width, plus process-spawn
  and filesystem throughput — asserts nothing, cannot fail the run), records
  five nights of both legs under
  `docs/validation/data/macos-ci-gate-timing/`, and writes up the verdict in
  `docs/validation/macos-ci-gate-timing.md`. `make macos-gate-timing-report`
  recomputes every table in that document from the committed data — zero
  network, and it refuses to print if a recorded file disagrees with the
  totals its own run reported.

  The finding: the gap is two independent multipliers — 3 workers vs 4 (a
  fixed 1.33x) and 1.36-1.71x more CPU-seconds for the same gates — whose
  product predicts the observed wall ratio within 0.05x on every night. The
  CPU half is concentrated: 12 of 180 gates carry 73% of a 1036s delta, 53
  gates are identical, and 15 (including `make shellcheck`) are *faster* on
  macOS. No reintroduction target is set and macOS is not restored to
  pre-merge gating; both are the follow-up's call.
