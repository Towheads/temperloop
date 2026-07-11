# Kernel repo layout + release-tag convention

Companion doc to `seed-kernel-repo.sh` (foundation F#803, epic #762 "kernel
split"). Read this before consuming the seeded `temperloop` repo — in
particular before the sibling **overlay-subtree-cutover** item vendors it
back into a private overlay repo via `git subtree`.

## What got seeded

`workflows/scripts/kernel/seed-kernel-repo.sh --dest DIR [--root DIR]`
materializes:

1. Every path `list-kernel-set.sh` classifies `kernel` (per
   `kernel-manifest.txt`), copied **1:1** — same relative path in the kernel
   repo as in foundation. See "Path mapping" below for why.
2. Four repo-identity files that don't exist in foundation's own tree:
   `LICENSE` (Apache-2.0, verbatim upstream text), `NOTICE`, `SECURITY.md`
   (GitHub private-vulnerability-reporting pointer, no hardcoded org/email),
   `CHANGELOG.md` (Keep a Changelog + SemVer stub).
3. A standalone `Makefile` — the subset of foundation's Makefile targets
   whose full dependency closure is itself kernel-classified: every target
   `scripts/quality-gates.sh`'s `KERNEL_GATES` array invokes, plus the docs
   generator (`docs` / `test-docs-generator`). Every recipe body is copied
   verbatim from foundation's Makefile. Install/deploy targets (`install`,
   `install-env`, `install-claude`, ...) are deliberately **not** included —
   they depend on `env/*` and machine-specific paths that are overlay-only
   and don't exist in this repo; wiring them in would look like a working
   install path that silently does nothing. That's later integration work.

   **Superseded, narrowly (temperloop#264, ADR K164 D7):** the exclusion
   above is about the *Makefile* recipes specifically, and stays true
   unchanged — `install`/`install-env`/`install-claude` still depend on
   `env/*` dotfiles that genuinely don't exist in a kernel-only checkout.
   The "later integration work" this paragraph once deferred has since
   landed as a **CLI** subcommand instead: `temperloop install`
   (`bin/subcommands/install.sh`) installs the `env/*`-independent slice of
   the machine surface — `links_enumerate()`'s `claude/*`, board-command,
   and gh-shim entries under `~/.claude/` and `~/.local/bin/` — recording
   every touched path via the install manifest
   (`workflows/scripts/install/manifest.sh`) so a later `temperloop
   uninstall` can cleanly reverse it. See `VERSIONING.md` § "Vendored" vs.
   "installed" — two different senses for how this CLI, machine-scoped
   sense of "install" differs from (and doesn't contradict) the
   repo-integration ("vendored") sense this doc's own seeding description
   otherwise uses.
4. `.github/workflows/ci.yml` — a dual-OS (`ubuntu-latest` + `macos-latest`)
   matrix, job named `checks`, running the one command
   `bash scripts/quality-gates.sh`. Same script foundation's own CI runs, so
   "local gate = CI gate" holds in the kernel repo too. The macOS leg
   installs `shellcheck` via `brew` first — unlike `ubuntu-latest`,
   GitHub's `macos-latest` runner doesn't ship it preinstalled (confirmed by
   this item's own CI run). No other OS-specific step was needed: the
   kernel scripts are deliberately bash-3.2-compatible (no
   `declare -A`/`mapfile`/`readarray`) with BSD-vs-GNU fallbacks already in
   place for the handful of `stat`/`date` calls that differ.

The seeder is a **pure, idempotent tree-materializer**: it never runs `git`
(no init/commit/tag/push) and never deletes a path in `--dest` it didn't
just write. A first seed goes into an empty `--dest`; the one-time git
init/commit/tag/push over the materialized tree is a separate, manual step
(see "Producing a fresh seed" below).

## Path mapping: 1:1, no flattening

The kernel repo mirrors foundation's paths exactly — `workflows/scripts/board/lib/board.sh`
in foundation is `workflows/scripts/board/lib/board.sh` in the kernel repo, not
flattened to e.g. `board/lib/board.sh`. This is the layout call this item
owns (per the F#803 contract): a 1:1 mirror is what makes the
overlay-subtree-cutover item's `git subtree` vendor-back trivial — `git
subtree add/pull --prefix=<same-path>` only works cleanly when the source
and destination trees share the same relative paths. A flattened layout
would need a path-rewrite step on every future sync, which is exactly the
kind of drift-prone mechanism the kernel/overlay split is trying to avoid.

## Release-tag convention

- Tags are `v0.x.y` (SemVer, pre-1.0) on the commit that produced them,
  annotated (`git tag -a`). See [`VERSIONING.md`](../../../VERSIONING.md) for
  the canonical bump rules — when a bump is breaking vs additive vs a fix, and
  the `BREAKING` CHANGELOG-marker convention that carries the breaking signal
  pre-1.0.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/):
  one `## [x.y.z] - YYYY-MM-DD` section per release, `### Added` /
  `### Changed` / `### Fixed` / `### Removed` subsections as needed.
- The **first** seed is `v0.1.0` on the single "Initial fresh-history seed"
  commit — deliberately one commit, not a rebuild of foundation's commit
  history (this item seeds fresh history, not a filtered mirror of
  foundation's git log; see kernel-manifest.txt's own header for why the
  kernel/overlay split is a file-classification exercise, not a history
  rewrite).
- This is the precondition Epic C's Pages versioning consumes: a Pages-published
  docs site version-switcher keys off these tags, so the tag needs to exist
  before that item can wire version selection in.

## Producing a fresh seed (manual, one-time per re-seed)

```sh
# 1. Materialize into a scratch clone of the (already-created, empty) repo.
git clone <kernel-repo-url> /tmp/temperloop-seed
bash workflows/scripts/kernel/seed-kernel-repo.sh --dest /tmp/temperloop-seed

# 2. One seed commit + tag.
cd /tmp/temperloop-seed
git add -A
git commit -m "Initial fresh-history seed of the kernel file set"
git tag -a v0.1.0 -m "v0.1.0 — initial kernel seed"

# 3. Push.
git push -u origin main
git push origin v0.1.0
```

Re-running the seeder against the same `--root` always produces a
byte-identical tree (verified: `diff -rq` between two fresh `--dest` runs
is empty) — the only reason to re-run and re-commit is a real change to the
kernel-classified source tree in foundation.

**Caveat hit while producing this item's own seed commit**: the seeder
never deletes a path in `--dest` — by design, per its header (a first seed
always starts from an empty `--dest`, so there's nothing to delete). But a
**re-seed onto a clone of an already-pushed kernel repo** does have existing
tracked files, and if the kernel set has since *shrunk* (a file
reclassified out of `kernel`, e.g. this item's own
`test_rework_snapshot.sh` fix — see § "Manifest fix..." above), the seeder
silently leaves that now-stale file in place; it's neither re-copied nor
removed. Caught by diffing `git ls-tree -r --name-only HEAD` against
`list-kernel-set.sh`'s current output before committing a re-seed;
`git rm` the stale path(s) by hand if the diff shows any. Worth hardening
into the seeder itself (an explicit prune pass) if a re-seed onto a live
repo becomes routine rather than a one-time bootstrap.

## Manifest fix made alongside this item: `test_rework_snapshot.sh`

While wiring the standalone Makefile's `test-build` target, this item found
that `test_rework_snapshot.sh` (kernel-classified, under
`workflows/scripts/build/tests/`) tests `workflows/scripts/rework-snapshot.sh`
(classified `overlay` — the personal telemetry pipeline), which a
kernel-only checkout has nothing to exercise. Fixed at the source: a
single-file override in `kernel-manifest.txt` reclassifies just that test
file `overlay` (narrowing the `workflows/scripts/build/*` catch-all,
mirroring the existing `migrate-to-org.sh` precedent) — so
`list-kernel-set.sh` no longer lists it, `seed-kernel-repo.sh` never copies
it, and the standalone `test-build` target's verbatim
`$(BUILD_SRC)/tests/test_*.sh` glob simply doesn't find it. No workaround
needed in the seeder or its generated Makefile.

## Known adaptation: `validate-live-drain.sh` kernel-only mode

`workflows/scripts/validate-live-drain.sh` gained a small portability seam
in this item: when it finds `claude/CLAUDE.kernel.md` but no
`claude/CLAUDE.overlay.md` (the kernel repo's shape — the overlay half is
never shipped there), it checks live anchors against the kernel half alone
and downgrades an absent anchor to a **skip** (unverifiable — it may
legitimately live only in the unshipped overlay half) rather than a hard
fail. This only activates in a kernel-only checkout; foundation's own CI
(both files present) is unaffected — verified zero-regression against the
full foundation checkout before this item's PR.
