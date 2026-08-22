---
title: sandbox-core
slug: sandbox-core
---

## Problem

Every kernel test that needs to prove behavior against a real filesystem,
`gh`, or `HOME`-scoped state (the install/onboarding surface — `bin/
bootstrap.sh`, `temperloop init`, `temperloop eject`) has had to hand-roll
its own throwaway git tree plus a fake `gh` binary, inline, inside each
test file (`bin/subcommands/tests/test_init.sh`, `test_eject.sh`). That
duplication meant a THIRD caller wanting the same guarantees — a stubbed
`gh`, a real HOME/XDG-scoped sandbox, a way to exercise the curl-pipe-sh
newcomer install without touching the network — would have reinvented the
idiom a third time, and none of the three existing tests actually proves
the CLI's install surface end to end (bootstrap → dispatch → subcommand)
in one hermetic run.

## How it works

`workflows/scripts/tests/lib/sandbox.sh` is a sourceable harness (not a
container — see its own header for the isolation-model note) providing:

- `sandbox_up` / `sandbox_down` — a throwaway root (`mktemp -d`) with
  `HOME` and all four XDG vars (`XDG_CONFIG_HOME`/`XDG_STATE_HOME`/
  `XDG_DATA_HOME`/`XDG_CACHE_HOME`) re-pointed inside it, plus a
  sandbox-private `bin/` directory.
- `sandbox_run` / `sandbox_bash` — run a command (or an inline script)
  with that env applied via a plain `env NAME=VAL... cmd` invocation,
  scoped to that ONE subprocess tree — never `export`ed into the calling
  shell (proven by the harness's own test 1).
- `sandbox_stub_gh` / `sandbox_stub_claude` — install a logging fake `gh`
  (the exact FAKE_*-env-steered call shapes `test_init.sh`/`test_eject.sh`
  already use, extracted here rather than re-invented) and a minimal
  no-op fake `claude` (a stand-in for a subcommand that calls `claude`
  directly, e.g. `try.sh`'s shadow triage — per-subcommand prereq scoping,
  temperloop#412, means `bin/temperloop`'s dispatcher no longer requires
  `claude` on PATH just to dispatch a subcommand that never calls it)
  onto the sandbox-private PATH.
- `sandbox_bootstrap_checkout` — bare-clones a source checkout's committed
  HEAD into the sandbox and runs *that checkout's own* `bin/bootstrap.sh`
  against the clone over a `file://` remote — the hermetic stand-in for
  the curl-pipe-sh newcomer install, producing a real, working
  `temperloop` binary with zero network calls.

Two test suites consume it:

- `workflows/scripts/tests/lib/tests/test_sandbox.sh` — the harness's own
  unit suite (env-scoping, stub call logging, bootstrap-over-`file://`,
  no-residue).
- `workflows/scripts/tests/test_sandbox_dry_run_legs.sh` — the
  install-surface acceptance legs: bootstraps this repo, then runs
  `temperloop init --dry-run` and `temperloop eject --dry-run` through
  that bootstrapped binary against a throwaway target repo, asserting
  each makes no `gh` call beyond the dispatcher's own read-only `auth
  status` prereq probe.

## Integration

Both suites are wired into `scripts/quality-gates.sh` (the single
KERNEL_GATES source CI's `checks` job, the local dev gate, and `/build`'s
parent-side acceptance gate all run — see that script's own header), so
local gate = CI gate for this harness exactly like every other kernel
suite. Nothing else currently sources `sandbox.sh` for these core functions;
it is designed to be reused by any future install-surface test (a
`try --dry-run` leg, a `doctor`/`update-kernel` hermetic test) without
reshaping what already exists. A follow-up item, "sandbox-integrity"
(temperloop#266), has since added a write-preflight, a post-run drift
tripwire, and a symlink-aware tree-manifest-diff helper onto this same
file rather than a second one — see `docs/features/sandbox-integrity.md`.

## Root-leak guard (temperloop#1723)

A throwaway root is ~1GB for the install-surface suites, and every suite
removed it with a single `sandbox_down` on its **last line**. That line is
only reached on the happy path — `fail()` is `exit 1` — so a failed
assertion, a timeout kill, a CI cancellation, or an ENOSPC walked straight
past it. Measured cost: `$TMPDIR` holding **215 leaked roots totalling
~180GB**, which filled a 460GB disk and killed a validation batch mid-run.

`sandbox_up` now installs the cleanup traps **itself** (`EXIT`, `HUP`,
`INT`, `TERM`), so every existing caller became safe with no edit and no new
caller can forget:

- **Registered, not latest-only.** Every root created in the shell is
  reclaimed, not just the one `$SANDBOX_ROOT` names at the moment of death
  (`bin/subcommands/tests/test_uninstall.sh` calls `sandbox_up` 13 times).
- **Chained, never clobbering.** A caller's own `EXIT`/signal handler is
  captured via `trap -p` — whose output is bash's own re-runnable quoting,
  so nothing is hand-unescaped — and runs **first**, while the root it may
  still need exists. Traps are re-armed on every `sandbox_up`, so a caller
  that installs its trap *between* two `sandbox_up` calls (which
  `test_sandbox.sh` does) is re-chained rather than left clobbered. A signal
  the caller deliberately ignores (`trap '' TERM`) is left alone.
- **Idempotent.** The explicit trailing `sandbox_down` the suites already
  carry and the trap can both run; `sandbox_down` de-registers, and `rm -rf`
  on an absent root is a no-op — so `test_install_lifecycle.sh`'s trailing
  "the root is gone" assertion still means what it did.

**Debuggability escape:** `SANDBOX_KEEP=1` retains every root (loudly, on
stderr) so a developer can inspect one while diagnosing a red suite. It
applies to the explicit `sandbox_down` too, so *keep* means keep — a suite
that asserts its root was removed therefore fails under `SANDBOX_KEEP`, and
that is the flag working, not a regression.

**What the guard cannot cover: SIGKILL.** `kill -9`, an OOM kill, and the
SIGKILL leg of a candidate timeout are untrappable by construction, so no
in-process guard reaches them — and roots leaked *before* this guard existed
carry no marker. Both are the sweeper's job:

```sh
bash workflows/scripts/tests/lib/sandbox-sweep.sh              # dry run: list + total
bash workflows/scripts/tests/lib/sandbox-sweep.sh --apply      # reclaim
bash workflows/scripts/tests/lib/sandbox-sweep.sh --older-than 5 --dir /some/tmp
```

It scans `$TMPDIR` (or `--dir`) and recognises a root by two **positive,
structural** signals rather than a `mktemp`-prefix glob somebody would have
to remember to extend: the `.sandbox-root` marker `sandbox_up` now writes,
or — for the pre-guard leaks — `sandbox_up`'s exact directory signature
(`home/`, `bin/`, and all four `xdg/{config,state,data,cache}`). Two safety
valves keep it off a live suite: a root newer than `--older-than` (default
60 minutes) is skipped, and so is a marker-bearing root whose recorded pid
is still alive. It is a **dry run by default** — nothing is removed until
`--apply`.

`workflows/scripts/tests/lib/tests/test_sandbox_trap.sh` is the gate. Every
scenario runs a generated fixture suite as a **separate process** with
`$TMPDIR` re-pointed at a throwaway scan directory, then asserts on what
that directory holds once the fixture is dead — the only place "the root is
gone after the process died" is observable at all.

## Resource impact

Local filesystem only: a `mktemp -d` throwaway root per test run, removed
by `sandbox_down` (or the test script's own `trap ... EXIT`). No network
calls (the stubbed `gh`/`claude`, and `bin/bootstrap.sh` pointed at a
`file://` remote, make the whole cycle offline). `git clone --bare` of a
local checkout onto the same filesystem is a fast, hardlinked local
operation, not a real network clone.

## Telemetry

None.
