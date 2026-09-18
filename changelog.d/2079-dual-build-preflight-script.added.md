- **`workflows/scripts/build/dual-build-preflight.sh`** (#2079, epic #2065
  "new-work dual-build harness"), the orchestrator-side spend gate a future
  `/build --dual-build <tier>=<candidate>` will consult before a level ever
  spawns a second arm. Resolves the level's items whose plan `model:` stamp
  matches the named tier, projects 2x-worker + judge spend against the
  replay harness's own shared `REPLAY_PREFLIGHT_CEILING_TOKENS` (never a
  second, dual-build-specific ceiling), declines a level with fewer
  in-scope items than `DUAL_BUILD_MIN_INSCOPE_ITEMS`, and refuses by name
  when the candidate's provider has no usable credential per
  `candidate-session.sh`'s own `preflight` (the one host-supply seam).
  Emits the `dualBuild` workflow-input JSON (`{tier,baseline,candidate,
  inScope}`) plus a cumulative-spend line only when none of that refuses.
  Nothing invokes this script yet — `/build`'s own `--dual-build` flag
  (#2081) is a later item in the same epic — so this entry ships inert,
  dormant machinery with its own hermetic fixture suite
  (`workflows/scripts/build/tests/test_dual_build_preflight.sh`).
