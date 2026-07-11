---
title: sandbox-integrity
slug: sandbox-integrity
---

## Problem

`workflows/scripts/tests/lib/sandbox.sh` ("sandbox-core", temperloop#263, ADR
K164 D6) proves a sandboxed run's `HOME`/XDG vars are correctly re-pointed at
a throwaway root — but that is a single point-in-time check. It doesn't
prove three other things any belt-and-suspenders install-surface test
eventually needs: that the FULL set of paths a real install would touch
(`workflows/scripts/install/links.sh`'s `links_enumerate`) actually resolves
inside the sandbox *before* any write happens; that a full sandboxed run
left the REAL machine's own `~/.claude` and `~/.local/bin/temperloop`
byte-for-byte untouched, not just "looked right" in the one no-residue test
sandbox-core happens to run; and a reusable, symlink-aware way to compare
two directory trees at all (the kind of check both of the above need, and
any future install/eject/update-kernel test will too). ADR K164 D6's own
isolation model is "no container, `env`-scoped HOME/XDG" — these three
helpers are the mechanical belt-and-suspenders on that choice: they don't
change the isolation model, they add cheap, independent checks that it's
actually holding.

## How it works

Three more `sandbox_*` functions, appended onto the same
`workflows/scripts/tests/lib/sandbox.sh` sandbox-core already owns (not a
second file — see that file's own header for the extension note):

- **`sandbox_preflight_links <foundation_root> [<links_lib_override>]`** —
  the write PREFLIGHT. Sources `links.sh` and runs its `links_enumerate`
  *inside* the sandbox env (via `sandbox_run`, so `links_enumerate`'s own
  `$HOME`-relative target computation resolves against `$SANDBOX_HOME`),
  then asserts every emitted target path falls under `$SANDBOX_ROOT`. Call
  it before the first write of a simulated install; it does no writing
  itself.

- **`sandbox_tripwire_snapshot <label> [path...]`** /
  **`sandbox_tripwire_check <label>`** — the post-run drift TRIPWIRE.
  `snapshot` hashes each given REAL (non-sandboxed) path — default
  `$HOME/.claude` and `$HOME/.local/bin/temperloop` — via
  `sandbox_tree_manifest` and stores the manifests under
  `$SANDBOX_ROOT/tripwire/<label>/`, read-only. `check` re-hashes the same
  paths and diffs each against its stored manifest, failing on any drift —
  including an absent-to-present flip (an absent watched path is recorded
  as a distinct manifest state, not skipped or errored). Call `snapshot`
  before a sandboxed run and `check` after.

- **`sandbox_tree_manifest <root>`** / **`sandbox_tree_diff <manifest_a>
  <manifest_b> [<exclusions>]`** — the symlink-aware tree-manifest + diff
  primitive the tripwire is built on, and independently reusable. A
  manifest is one tab-separated `<relpath>\t<type>\t<hash-or-target>`
  record per file/symlink under `<root>` (`type` one of
  `file`/`symlink`/`absent`); a symlink's own target string is recorded via
  `readlink`, never followed or descended into. `sandbox_tree_diff` compares
  two such manifests, applying a CALLER-SUPPLIED exclusion set (a file of
  newline-separated case-glob patterns, or an inline whitespace-separated
  pattern list — nothing hardcoded) to both sides before comparing, and
  prints a unified diff of whatever remains.

All three groups are pure additions — no existing sandbox-core function
changed shape — and all read real (non-sandboxed) paths strictly read-only;
only `sandbox_tripwire_snapshot`'s own bookkeeping writes, and that stays
under `$SANDBOX_ROOT`.

Tests live in a sibling suite,
`workflows/scripts/tests/lib/tests/test_sandbox_integrity.sh` (kept separate
from sandbox-core's own `test_sandbox.sh` rather than folded in): preflight
positive (this repo's real `links.sh`) + negative (a fixture `links.sh`
hardcoding an out-of-sandbox target); tree-diff identical/added/excluded/
retargeted-symlink; tripwire no-drift/drift/absent-path-then-appears. Every
"real path" fixture in that suite lives under its own `mktemp` scratch root
— the suite never reads or writes the machine's actual `~/.claude` or
`~/.local/bin/temperloop`.

## Integration

`test_sandbox_integrity.sh` is wired into `scripts/quality-gates.sh`
directly beside sandbox-core's own two gates (same direct-`bash` form, no
new Makefile target — the kernel Makefile is generator-owned), so local gate
= CI gate for this layer exactly like every other kernel suite. Nothing yet
calls these three helpers from a production test (sandbox-core's own
`test_sandbox_dry_run_legs.sh` doesn't need them — its own no-residue test
already covers its narrower scope); they're designed for the NEXT
install-surface test (a `try --dry-run` leg, a `doctor`/`update-kernel`
hermetic test) to reach for without reinventing a write-preflight, a
real-HOME tripwire, or a tree-diff a fourth time.

## Resource impact

Local filesystem only, same posture as sandbox-core: every helper here
either reads (the preflight's `links_enumerate` walk, the tripwire's
snapshot/check hashing, the tree-manifest walk) or writes strictly under
`$SANDBOX_ROOT` (the tripwire's own manifest bookkeeping). No network. No
container. `sandbox_tree_manifest` shells to `find` + a portable
`sha256sum`/`shasum -a 256` per file — cheap for the tree sizes this harness
targets (a `~/.claude` config tree, a handful of installed binaries), not
designed for a multi-GB tree.

## Telemetry

None.
