- **The acceptance gate's environment scrub now also covers settings that
  `workflows/scripts/build/build.config.sh` exports without declaring**
  (#1709). `workflows/scripts/build/build-config-settings.sh` prints the
  setting names the build pipeline `unset`s before running
  `scripts/quality-gates.sh` against a worker's worktree, so that suite runs
  at tracked defaults rather than inheriting the driving session's exported
  settings. It previously parsed only `: "${NAME:=default}"` declarations, so
  a name the config file exports but deliberately never declares matched
  nothing and survived the scrub, leaking the operator's live environment into
  the gate — `KNOWLEDGE_STORE_ROOT`, which points at the operator's real
  knowledge store, was the live instance. The helper now emits the union of
  the declared names and the names in the config file's top-level `export`
  statements, following multi-line backslash continuations, deduplicated and
  sorted. Every name it emitted before is still emitted.
