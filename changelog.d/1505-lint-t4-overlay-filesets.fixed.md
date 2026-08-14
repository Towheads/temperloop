- **`test_lint_pipe_grep_q.sh` T4 no longer false-fails on a composed overlay
  checkout** (#1505). T4 asserted that the lint's default file set includes
  five kernel-native paths (`bin/temperloop`, `bin/foundation`,
  `.temperloop/report.d/tokens`, `workflows/scripts/report-producers/tokens`,
  `workflows/scripts/lib/issue-marker-probe.sh`) by exact `git ls-files`
  granularity. On a consumer that vendors `kernel/` as a subtree behind
  compat directory symlinks (`bin -> kernel/bin`, etc.), git tracks each such
  top-level directory as ONE symlink entry, so `git ls-files` structurally
  cannot enumerate a path underneath it — the five checks failed for a
  reason unrelated to lint coverage. T4 now self-scopes: it detects a
  composed overlay (the same two signals `validate-onramp-anchors.sh` and
  `sandbox_skip_if_composed_tree` already use, temperloop#1490) and emits a
  NAMED skip there, while still running the five checks for real and
  strictly on a kernel-native checkout. A new T4-overlay case proves both
  directions on a synthetic fixture: the symptom reproduces, and the
  detection neither over- nor under-fires.
