- **`test_pipeline_retro_health.sh` tests 18 and 19 no longer read the real
  checkout's telemetry lake** (#1408). Both cases exercise the **retro-runs
  default** — so neither can pin `RETRO_RUNS_RAW_DIR` — and both ran
  `pipeline-retro-health.sh` *in place*, whose checkout-relative root resolution
  (`$here/../../..`) then pointed the assertion at the real `meta/data/raw/`.
  The verdict was therefore a function of whatever telemetry the host happened
  to hold: green on CI, which runs on a fresh clone where that lake is **always**
  empty, and red in any checkout that had ever collected a retro-runs row. Test
  18 flipped pass→fail with **no code change at all**, purely from the calendar
  advancing one real July row out of the 30-day window, making `make test-build`
  a deterministic local failure in any checkout old enough to have run a retro
  and then gone quiet. Because CI could never see it, the gate was structurally
  blind to its own non-hermeticity.

  Both cases now fabricate a **fixture checkout** (a copy of the script under
  `<fixture>/workflows/scripts/build/` plus a seeded `<fixture>/meta/data/raw/`,
  the technique test 14 already used for the symlink-climb case) and probe that
  copy, so the checkout-relative root they resolve is a directory the test owns.
  The suite's output is now byte-identical whether the real lake is empty,
  carries an out-of-window row, or carries an in-window one.

  The subject of each test is **sharpened, not hollowed out**. Each lake is
  seeded so the right root and every wrong root yield *different* verdicts: the
  fixture checkout root holds an in-window row (correct → `healthy`), while the
  decoy the test guards against — `$HOME/dev/foundation/meta/data/raw` for t18,
  `MODEL_USAGE_RAW_DIR` for t19 — holds an out-of-window one (leaked →
  `defect(stalled)`), and a `retro_dir` converged onto `$pipeline_dir` finds no
  stream at all (→ `defect(never-had-a-row)`). Where the old assertion could
  only observe that the retro-runs stream had *not* found the decoy, the new one
  proves it positively resolved the checkout root and read that root's row.
