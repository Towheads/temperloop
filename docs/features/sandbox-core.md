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
  no-op fake `claude` (needed only because `bin/temperloop`'s dispatcher
  prereq gate requires `claude` on PATH before any subcommand dispatches)
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
suite. Nothing else currently sources `sandbox.sh`; it is designed to be
reused by any future install-surface test (a `try --dry-run` leg, a
`doctor`/`update-kernel` hermetic test) without reshaping what already
exists — a separate, out-of-scope follow-up item ("sandbox-integrity")
will add write-preflight / drift-tripwire / tree-diff helpers to this same
file rather than a second one.

## Resource impact

Local filesystem only: a `mktemp -d` throwaway root per test run, removed
by `sandbox_down` (or the test script's own `trap ... EXIT`). No network
calls (the stubbed `gh`/`claude`, and `bin/bootstrap.sh` pointed at a
`file://` remote, make the whole cycle offline). `git clone --bare` of a
local checkout onto the same filesystem is a fast, hardlinked local
operation, not a real network clone.

## Telemetry

None.
