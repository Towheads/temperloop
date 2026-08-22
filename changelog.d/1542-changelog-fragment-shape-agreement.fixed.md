- **`check-changelog-entry.sh` now rejects a fragment shape
  `scripts/assemble-changelog.sh` will reject too** (temperloop#1542). A
  fragment body carrying its own `#`/`##`/`###` heading, or one of the
  assembler's control tokens (`##BEGIN##`, `##CATEGORY##`), used to pass the
  PR-time gate and only fail at release-cut time — the observed break:
  cutting v0.31.0 hit a hard stop on `changelog.d/1508-…fixed.md`, whose body
  opened with `### Fixed`, a shape this gate had already accepted.

  The two gates now share the SAME validation — `check-changelog-entry.sh`
  runs the exact functions `assemble-changelog.sh` calls
  (`changelog_fragment_body_offenders`, `changelog_fragment_empty` in
  `workflows/scripts/lib/changelog.sh`) against every fragment a PR adds or
  modifies, so the two copies of the rule this bug came from are now one. A
  malformed fragment is a cheap PR-time fix instead of a hard stop that writes
  nothing at the release cut.
