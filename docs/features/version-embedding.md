---
title: version-embedding
slug: version-embedding
---

## Problem

A release must contain its own version. Before this, `temperloop version`
resolved only `${TEMPERLOOP_VERSION:-${FOUNDATION_VERSION:-dev}}` and nothing
set that variable on a real install: there was no `VERSION` file, no
`git describe`, and while `bin/bootstrap.sh` pins a fresh install to the latest
release tag it never records which version that is. So a tag-pinned install
reported `temperloop dev` — the shipped files did not carry the version they
were released as. A version derived from git at runtime (a `git describe`
fallback) would not fix this: copy the files without their `.git`, or read them
on a non-tag commit, and the number is wrong or gone. The release artifact
itself has to hold the number.

## How it works

A committed repo-root **`VERSION`** file (a bare `x.y.z`, no `v` prefix) is the
source of truth. `temperloop_resolve_version` in `bin/lib/common.sh` resolves
the reported version with the precedence:

    TEMPERLOOP_VERSION env  >  FOUNDATION_VERSION env (rename window)
      >  the VERSION file  >  "dev"

The file is read relative to `common.sh`'s own real location (repo root is two
levels up from `bin/lib/`), so it resolves whether the dispatcher or a
subcommand sourced the helper, and through the bootstrap symlink. The
dispatcher (`bin/temperloop`) calls the helper once and **exports**
`TEMPERLOOP_VERSION`, so subcommand child processes (e.g. `feedback.sh`'s
payload stamp) inherit the embedded value; `feedback.sh` keeps its own literal
`${TEMPERLOOP_VERSION:-…}` seam as the standalone fallback and as the
knob-registry owning-script default for both names. An explicit env override
still wins, so CI and test fixtures that set `TEMPERLOOP_VERSION` are unchanged.

The version is embedded **as part of the release cut**: the ritual bumps
`VERSION` in the same commit that gets tagged (`kernel-repo-layout.md`
§ Release-tag convention). `workflows/scripts/tests/test_version_embedding.sh`
guards the contract — VERSION is well-formed, `temperloop version` reports it
(not `dev`), an env override still wins, and, the drift guard, **when HEAD is
exactly a `vX.Y.Z` tag the build fails unless `VERSION` equals `X.Y.Z`**. Off a
tag that leg is a legible no-op, so the guard fires only where drift is
possible.

## Integration

- **`bin/lib/common.sh`** owns the resolver; **`bin/temperloop`** reads and
  exports it; **`bin/subcommands/feedback.sh`** inherits it (and keeps the
  registry-recorded literal seam).
- **`scripts/quality-gates.sh`** runs `test_version_embedding.sh` as a
  `KERNEL_GATES` entry, so the drift guard is part of the required `checks`
  status — a stale `VERSION` on a tagged commit fails CI, not review.
- **`VERSIONING.md`** records `VERSION` as the "shipped version stamp" contract
  surface; **`kernel-repo-layout.md` § Release-tag convention** documents the
  bump-in-the-tagged-commit step.
- **`.github/workflows/install-tier2.yml`** gains a `version` leg asserting the
  *installed* CLI (bootstrapped onto PATH) reports its embedded version, not
  `dev` — the real-round-trip proof a hermetic unit gate can't give, since the
  gate only sees the in-tree checkout.

## Resource impact

None. A single-line file read (`sed`/`head`) at CLI startup; no network, no
GitHub API, no measurable added CI time beyond the one new fast gate. The
`install-tier2` version leg is a `temperloop version` invocation plus a file
read inside the existing weekly/manual round-trip job — no new job or runner.

## Telemetry

None dedicated. The resolved version already rides `bin/subcommands/feedback.sh`'s
feedback payload (the `temperloop version:` line) and prints on `temperloop
version` / `--version`; there is no separate counter or dashboard for the
embedding itself. Its health is asserted mechanically by the `checks` gate and
the `install-tier2` `version` leg rather than observed at runtime.
