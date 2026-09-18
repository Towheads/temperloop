- **Eight new `DUAL_BUILD_*` settings in `workflows/scripts/build/build.config.sh`**
  (#2071, epic #2065 "new-work dual-build harness"), ahead of the
  `--dual-build` flag itself: `DUAL_BUILD_BASELINE_MODEL` /
  `DUAL_BUILD_CANDIDATE_MODEL` name the two models a dual-built level compares
  (literal defaults, never inherited from `$HOME` or the invoking session, so
  a run's disclosed models stay fixed regardless of environment);
  `DUAL_BUILD_MIN_INSCOPE_ITEMS` floors how small a level may be before the
  harness declines to double-build it; `DUAL_BUILD_ARCHIVE_RETENTION_DAYS`
  bounds how long a dual-build ledger row and its patch archive are kept;
  `DUAL_BUILD_UNRESOLVED_THRESHOLD_PCT` sets the tied/unjudged/infra rate
  above which the comparison report withholds a verdict;
  `DUAL_BUILD_CALIBRATE_PAIRS_PER_LEVEL` sets how many pairs the blind
  calibration mode samples per level; `DUAL_BUILD_CALIBRATION_BAR_PCT` /
  `DUAL_BUILD_CALIBRATION_BAR_N` set the judge-human agreement bar a report
  must clear before naming a winner. All eight are registered in
  `workflows/scripts/config/setting-registry.tsv`. `/build`'s behavior is
  unchanged by this entry alone — nothing reads these settings yet.
- **`PROSE_BUDGET_TIER2_FILE_CAP` raised 1201 → 1261** (#2071, epic #2065),
  ahead of two later items that add prose to `claude/commands/build.md` for
  the dual-build harness — `build.md` was already at the cap with zero
  headroom, so this raise ships as its own change rather than a mid-build
  config edit.
