# Kernel repo layout + release-tag convention

The two conventions that govern the standalone `temperloop` kernel repo's
on-disk shape and its releases (foundation F#803, epic #762 "kernel split").
Kernel content is authored directly in this repo and vendored downstream via
`update-kernel.sh`'s `git subtree` pull; the original fresh-history bootstrap
seeder has been retired (`Decisions/temperloop - Retire seed-kernel-repo.sh`).

## Path mapping: 1:1, no flattening

The kernel repo mirrors foundation's paths exactly — `workflows/scripts/board/lib/board.sh`
in foundation is `workflows/scripts/board/lib/board.sh` in the kernel repo, not
flattened to e.g. `board/lib/board.sh`. This is the layout call this repo owns
(per the F#803 contract): a 1:1 mirror is what makes the overlay's `git
subtree` vendor-back trivial — `git subtree add/pull --prefix=<same-path>` only
works cleanly when the source and destination trees share the same relative
paths. A flattened layout would need a path-rewrite step on every future sync,
which is exactly the kind of drift-prone mechanism the kernel/overlay split is
trying to avoid.

## Release-tag convention

- Tags are `v0.x.y` (SemVer, pre-1.0) on the commit that produced them,
  annotated (`git tag -a`). See [`VERSIONING.md`](../../../VERSIONING.md) for
  the canonical bump rules — when a bump is breaking vs additive vs a fix, and
  the `BREAKING` CHANGELOG-marker convention that carries the breaking signal
  pre-1.0.
- **Bump the shipped `VERSION` file in the commit you tag** (temperloop#677).
  The repo-root `VERSION` file (a bare `x.y.z`, no `v`) is the source of truth
  `temperloop version` reports, so the release *artifact contains its own
  version* rather than deriving it from git at runtime. Set `VERSION` to
  `x.y.z`, commit, then `git tag -a vx.y.z` **that** commit — the tag and the
  file must agree. `test_version_embedding.sh` (a `checks` gate) enforces this
  mechanically: when HEAD is exactly a `vX.Y.Z` tag it fails the build unless
  `VERSION` equals `X.Y.Z`, so a cut cannot silently ship a stale number.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/):
  one `## [x.y.z] - YYYY-MM-DD` section per release, `### Added` /
  `### Changed` / `### Fixed` / `### Removed` subsections as needed.
- This is the precondition Epic C's Pages versioning consumes: a Pages-published
  docs site version-switcher keys off these tags, so the tag needs to exist
  before that item can wire version selection in.
