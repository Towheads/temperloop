- **Test sandbox roots can no longer leak on a failed, timed-out or cancelled
  run** (#1723). `sandbox_up` (`workflows/scripts/tests/lib/sandbox.sh`) now
  installs the cleanup traps **itself** — `EXIT`, `HUP`, `INT`, `TERM` — so all
  six existing caller suites became safe with **no edit**, and no future suite
  can forget. Previously every suite removed its ~1GB throwaway root with a
  single `sandbox_down` on its **last line**, reached only on the happy path
  (`fail()` is `exit 1`), so a failed assertion, a timeout kill, a CI
  cancellation or an ENOSPC walked straight past it. Measured: `$TMPDIR` held
  **215 leaked roots totalling ~180GB**, filling a 460GB disk and killing a
  validation batch at record 25/28.

  Three properties the guard holds. It is **registered, not latest-only** —
  every root the shell created is reclaimed, not just the one `$SANDBOX_ROOT`
  names at the moment of death (`test_uninstall.sh` calls `sandbox_up` 13
  times). It is **chained, never clobbering** — a caller's own handler is
  captured via `trap -p` (bash's own re-runnable quoting, so nothing is
  hand-unescaped) and runs **first**, while the root it may still need exists;
  traps are re-armed on every `sandbox_up`, so a trap installed *between* two
  `sandbox_up` calls is re-chained rather than left clobbered, and a signal the
  caller deliberately ignores (`trap '' TERM`) is left alone. And it is
  **idempotent** with the explicit trailing `sandbox_down` the suites already
  carry, so `test_install_lifecycle.sh`'s "the root is gone" assertion still
  means what it did.

  **`SANDBOX_KEEP=1`** retains every root (loudly, on stderr) for diagnosing a
  red suite; it applies to the explicit `sandbox_down` too, so *keep* means
  keep.

  **SIGKILL is not covered and is not claimed to be** — `kill -9`, an OOM kill
  and the SIGKILL leg of a candidate timeout are untrappable by construction.
  For that path, and for roots already stranded before this guard existed, the
  new sweeper `workflows/scripts/tests/lib/sandbox-sweep.sh` is the remedy: it
  recognises a root by the `.sandbox-root` marker `sandbox_up` now writes, or
  by `sandbox_up`'s exact directory signature for the pre-guard leaks — never a
  `mktemp`-prefix glob — skips roots newer than `--older-than` (default 60m) and
  roots whose recorded pid is still alive, and is a **dry run until `--apply`**.

  `workflows/scripts/tests/lib/tests/test_sandbox_trap.sh` (new
  `KERNEL_GATES` entry) asserts all of it from the OUTSIDE: each scenario runs a
  generated fixture suite as a separate process with `$TMPDIR` re-pointed at a
  throwaway scan dir, and checks that directory once the fixture is dead — mid-run
  `fail()`, SIGTERM (exit 143), `SANDBOX_KEEP` in **both** directions, trap
  chaining before and after `sandbox_up`, a deliberately-ignored signal staying
  ignored, `sandbox_down`+trap idempotence, and the sweeper's find/skip/apply
  behaviour.
