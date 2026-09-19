- **`test_live_tagging.sh` no longer measures the host it runs on** — the suite
  asserts what `tagging.sh resolve-model` prints when `SWEEP_WORKER_MODEL` is
  unset, but `tagging.sh` sources `build.config.sh`, which sources precedence
  layers 3 and 4: the machine conf under
  `${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/` and the untracked repo-local
  conf. Both are legitimate and correctly use the `:=` idiom, and neither
  exists on CI — so a developer box that has configured one failed the
  unset-state assertions while `main` stayed green. Observed with a machine
  conf setting `SWEEP_WORKER_MODEL:=opus`: `want [], got [opus]`, reproducible
  on a clean `origin/main` checkout and unaffected by `env -i`, which is what
  identified it as file-based rather than an exported variable. The suite now
  exports `BUILD_CONFIG_MACHINE` and `BUILD_CONFIG_LOCAL` at nonexistent paths,
  the seam the ladder's own comment documents as *"a test seam / explicit host
  override"*, and the same idiom `test_worker_model_settings.sh` already uses.
  This is the **file-based** half of the hermeticity problem that `/build`
  §3e.5's env scrub explicitly cannot reach (*"a file-based machine-local leak
  is a distinct mechanism (foundation#1055) an env scrub can't fix"*).
