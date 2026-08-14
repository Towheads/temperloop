- **`/sweep` and `/fix` now pass the two `build-level.mjs` hand-offs they were
  silently dropping.** Both commands drive the shared
  `claude/workflows/build-level.mjs`, but only `claude/commands/build.md`
  resolved and passed `machineryBinDir` and
  `principlesSummaries`/`principlesDefaultRepo`. The two omissions degraded
  silently: without `machineryBinDir`, `machineryBin()` fell back to the nested
  `$(dirname "$(readlink -f …)")` command-substitution the auto-mode classifier
  denies as an obfuscated-command bypass on `--unattended` runs (temperloop#72)
  — and `--unattended` is `/sweep`'s default posture, so every push/worktree
  machinery step drew a denial burst; without the principles pair, every
  `/sweep` and `/fix` worker permanently ran `workerPrompt()`'s static
  kernel-only `DEGRADED` fallback with no project `## Principles` extension
  applied. Each command now resolves `machineryBinDir` in its own Step 0 with
  the same plain `cd`+`pwd` form `/build` uses, and resolves the effective
  (kernel ∪ project) principle set by pointing at `build.md` § Step 1.8 (the
  single implementation) with the one-pair simplification their single-repo
  scope allows. The existing three-caller guard in
  `workflows/scripts/build/tests/test_workflow.sh` — which already iterated
  build/fix/sweep for `gateSliceSecs` — now covers both new fields, and
  `build.md`'s prose no longer names the two commands as the un-wired
  exceptions.
