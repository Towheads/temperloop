- **`/build` workers are now told to add their own `changelog.d/` fragment for
  contract-surface changes** (#1530). Previously nothing told a worker about
  the fragment requirement, so a contract-surface PR passed every local gate
  (the changelog gate skips cleanly with no resolvable base outside a PR
  event) and then failed CI once, by design, on `check-changelog-entry.sh`
  alone — observed live on three separate PRs in one session. `workerPrompt()`
  (`claude/workflows/build-level.mjs`) now embeds a self-contained
  `## Changelog fragment` section pointing the worker at
  `changelog.d/README.md` for the filename shape and naming the
  `Changelog: none — <reason>` commit-trailer opt-out (the one escape hatch
  that works before a PR exists); `build.md` §3c carries the identical
  instruction, and a static guard in `test_workflow.sh` keeps the two in
  lockstep.
