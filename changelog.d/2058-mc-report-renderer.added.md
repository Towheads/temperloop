- **`model-comparison/render.sh` — a decision-first Markdown rendering of the
  comparison report** (#2058, epic #1225). The report producer's JSON was the
  harness's only human surface: both validation runs (#1262, #1656) were read
  by hand through `jq`. `render.sh` lays that same object out for a reader —
  the verdict and the winner (or exactly why no winner is named: the sample
  floor, an order-confounded quality comparison, or no significant difference)
  in the first lines, one at-a-glance table across quality, cost, gates,
  rework, compatibility and duration, the honesty block (floor, intervals,
  minimum detectable effect, order effect, corpus window, gate versions, cost
  basis, emit coverage), and a "what would change this verdict" list. It
  derives no statistic and reads the `winner` key as minted, never inferring
  one from a verdict string or an interval — proved by mutation in
  `tests/test_render.sh`. A withheld figure renders `n/a` with its reason,
  never 0. Fail-closed like its siblings: a `skipped --` producer line, an
  absent/empty/unreadable/non-JSON input, or an unknown `schema_version` is
  CANNOT EVALUATE (rc 2) with no Markdown written. `--summary-out` writes a
  small `model-comparison-summary-v1` sidecar for the /telemetry surfacing
  item (#2061). `batch.sh run` now ends by printing the render command for the
  arms it just wrote. Inert per ADR 0027: nothing runs it for you.
