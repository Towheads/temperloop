- **A `/build` worker's own quality-gate run is now time-bounded on the
  `--no-workflow` path, so it can no longer stall the item it is working on**
  (#2145, worker gate budget). The
  worker instructions in `claude/commands/build.md` told every worker to verify
  its change with `scripts/quality-gates.sh --scoped` and, in the same breath,
  to keep each check to seconds. Those two instructions disagreed whenever the
  change touched a path that widens the scoped gate set back to the whole suite:
  the run took minutes, the harness auto-backgrounded it past its foreground
  limit, the backgrounded process was discarded when the worker's turn ended,
  and the item came back with no verdict and nothing committed — while the
  abandoned gate kept running, so the next run in that checkout failed on
  contention with its own predecessors rather than on the code. The worker now
  runs that gate under the same per-invocation time budget the orchestrator's
  own acceptance check already uses (`BUILD_GATE_SLICE_SECS`, defaulted in
  `workflows/scripts/build/build.config.sh`), so the call is bounded instead of
  open-ended. A budgeted run that stops early reports which gates it ran and
  hands the remainder to the orchestrator's check; it is not treated as a
  failure.

  **Scope — read this before assuming the bug is closed.** The budget reaches
  workers spawned by the conversational `--no-workflow` path, and any worker
  prompt you write by hand. Runs that take `/build`'s default path, driven by
  `claude/workflows/build-level.mjs`, still spawn their workers with an
  unbudgeted gate and remain exposed to the stall described above. That
  remaining half is tracked as #2147 (the same budget on the default path) and
  ships separately, because it has to wait for an in-flight rewrite of that
  file.
