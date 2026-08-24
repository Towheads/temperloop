- **The `make test-build-workflow` gate's K1071 step-ceiling case no longer
  depends on host load, and now ships a negative control** (#1335). The stalled
  step's verdict is read entirely off the bound's own structured result — the
  `STEP_TIMEOUT` payload plus the 137 (128+SIGKILL) exit status the driver acts
  on — rather than off a duration this harness measures, so a loaded parallel
  gate runner can no longer report a working watchdog as broken. To keep that
  from being a loosened bound, the case now also runs the same emitted shell on
  the same 60s stall body with **only the watchdog removed** and requires it to
  come out unbounded (no `STEP_TIMEOUT`, no kill); the rewrite that removes the
  watchdog is itself verified, so a control that silently stopped controlling
  fails the gate. A static guard pins the foundation#861 subshell-boundary
  redirect that the adjacent pipe-leak probe detects only by latency; it is
  anchored to the emitted watchdog line — first selecting that line, then
  requiring the redirect on it — so the prose comment that quotes the same
  redirect verbatim cannot satisfy it, and deleting the redirect from the
  emitted line alone turns the gate red.
