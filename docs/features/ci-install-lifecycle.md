---
title: ci-install-lifecycle
slug: ci-install-lifecycle
---

## Problem

The per-CLI suites prove each install-surface piece in isolation —
`workflows/scripts/tests/test_install_cli.sh` proves `temperloop install`
(consent, backup-verbatim, manifest recording, a green doctor),
`bin/subcommands/tests/test_uninstall.sh` proves `temperloop uninstall`
(manifest scoping, partial-failure retry, schema refusal) — but nothing
proved the FULL round trip end to end: that a machine which bootstraps,
installs, re-installs, and uninstalls ends up byte-for-byte where it
started, with every piece of residue either gone or explicitly accounted
for. "Install then uninstall leaves no unexplained trace" is a whole-
lifecycle property; it can only be asserted by a test that runs the whole
lifecycle and diffs the machine surface across it (ADR K164 D6's tier-1
per-PR validation suite).

## How it works

One suite, `workflows/scripts/tests/test_install_lifecycle.sh`, entirely
inside the sandbox harness (`workflows/scripts/tests/lib/sandbox.sh`):

1. **Bootstrap** this repo's committed HEAD over a `file://` bare clone
   (`sandbox_bootstrap_checkout`) — the hermetic stand-in for the
   curl-pipe-sh newcomer install — yielding a real `temperloop` binary.
2. **Preflight** (`sandbox_preflight_links`) — every `links_enumerate`
   target must resolve inside the sandbox root before any write happens.
3. **Install** — `temperloop install --yes` through the real CLI;
   `doctor.sh` must then be green (exit 0, `Non-OK: 0`).
4. **Idempotent re-install** — a second `install --yes` must leave the
   install manifest byte-comparable (`jq -S` canonical JSON identical),
   the recorded-path count unchanged, and create zero new backups.
5. **Uninstall** — `temperloop uninstall --yes`; an operator-authored
   machine conf seeded under `$XDG_CONFIG_HOME/temperloop/` before the
   lifecycle (never manifest-recorded) must survive byte-for-byte.
6. **No-residue proof** — `sandbox_tree_manifest` snapshots of the five
   machine-analog roots (HOME + the four XDG dirs), taken before install
   and after uninstall, are diffed per root via `sandbox_tree_diff`
   against a DECLARED exclusion set the suite owns, each entry commented
   with why: `$HOME`, `$XDG_CONFIG_HOME`, and `$XDG_DATA_HOME` get ZERO
   exclusions (byte-identical is the claim); `$XDG_STATE_HOME` excludes
   exactly `temperloop/install-manifest.json` (a full uninstall
   legitimately leaves the empty manifest file — manifest.sh removes
   entries, never the file); `$XDG_CACHE_HOME` declares `temperloop/*`
   (install's best-effort cache-store root provisioning is deliberately
   not manifest-tracked, so uninstall correctly never removes it).
7. **Tripwire** (`sandbox_tripwire_snapshot`/`_check`) around the whole
   run — over a TARGETED real-machine watch set: every `links_enumerate`
   target resolved against the REAL `$HOME` plus the real
   `~/.local/bin/temperloop`, i.e. exactly the paths an isolation escape
   ("wrote to real HOME instead of sandbox HOME") would hit. The
   wholesale `~/.claude` default is deliberately not used: on a live dev
   machine that tree is tens of GB and continuously mutated by concurrent
   Claude sessions, which would make a per-PR gate both hours-slow and
   false-positive-prone; the targeted set keeps the same
   real-machine-untouched claim deterministic and near-free.

The suite **self-scopes to a kernel-only checkout**: on a composed overlay
tree — detected by `claude/CLAUDE.overlay.md` beside
`claude/CLAUDE.kernel.md` (the `validate-live-drain.sh` idiom), a
recognizable `kernel/` subtree at the repo root, or the suite's own tree
being a vendored subtree inside a larger repo (its `$REPO_ROOT` is not its
own git toplevel, which is also a hard bootstrap precondition) — it prints
a legible SKIP notice and exits 0. Its exclusion set is sized for the
kernel-only managed surface (no `env/*`, no `settings.json`, no composed
CLAUDE.md); whether/how a lifecycle leg propagates downstream into
composed trees is temperloop#255's decision.

Portability: bash 3.2 clean; every possibly-large-variable check reads via
herestrings (never a pipe into an early-exiting `grep -q` under
`pipefail`); no assertion depends on a time-derived value (content hashes
and canonical-JSON/path-count comparisons only).

## Integration

Wired into `scripts/quality-gates.sh` (`KERNEL_GATES`) directly after the
`test_install_cli.sh` gate, same direct-`bash` form (the kernel Makefile
is generator-owned) — so local gate = CI gate, per-PR, on both CI OSes.
Consumes, and adds no parallel copy of: the sandbox core + integrity layer
(`sandbox.sh`), the install/uninstall CLIs, `links.sh`/`manifest.sh`/
`doctor.sh`. It deliberately does not duplicate the per-CLI suites' unit
coverage (consent legs, backup-verbatim detail, schema refusals).

## Resource impact

Local filesystem only; the only "network" is the `file://` bare clone.
One throwaway sandbox root (removed by `sandbox_down`, verified). The
heaviest step is hashing the sandbox HOME (which contains the
bootstrapped checkout) twice for the before/after manifests — seconds,
not minutes, at this tree's size. The real-machine tripwire hashes only
the ~25 targeted paths, so it stays near-free even on an operator machine
with a very large live `~/.claude`.

## Telemetry

None.
