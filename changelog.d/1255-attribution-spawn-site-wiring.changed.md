- **The model-usage attribution stream (#1253, epic #1225 "model comparison
  harness") is now actually wired into every emit-feasible spawn seat**
  (#1255). The L0 usage-capture-feasibility spike named three seats that can
  emit a token-bearing record today — `pipeline-drive.sh`'s level-5b safe
  driver (A7) and level-5c merge driver (A8), and
  `pipeline-retro-judge-spawn.sh`'s retro judge (A9) — and all three now
  call `emit-model-usage.sh` after every spawn, via a new shared extraction
  helper (`workflows/scripts/lib/model-usage-envelope.sh`) that turns the
  captured `claude -p --output-format json` envelope into one attribution
  record: resolved model, provider, token counts, duration, and an
  `issue:<n>` or board-scoped `issue:board-<n>` outcome ref for a batch
  spawn covering several issues at once. `validate-model-usage-emit.sh`
  gains a spawn-site coverage check (`--scan-dir` test seam): it fails CI if
  a wired seat's emit call is removed, or if a NEW spawn site captures the
  same `--output-format json` envelope shape without wiring emission — so
  future spawn sites owe an emission mechanically, not by convention. Every
  structurally un-emittable seat (the `.mjs` `agent()` class, harness-native
  `Task`/agent-frontmatter fan-out, interactive command sessions, and the
  `try.sh`/`configure.sh` text-output seats tracked by #1264) is named in
  the validator's own exclusion list with the spike's reason, rather than
  silently absent from the denominator.
