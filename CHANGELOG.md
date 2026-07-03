# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) —
pre-1.0, so a minor version bump (`0.x.0`) may include breaking changes.

## [0.1.2] - 2026-07-03

Re-seed from foundation `main` after PR #833 (foundation F#800, issues-only
tracker split 2/3) merged, plus a CI-coverage fix to the seeder itself
(foundation F#836).

### Added

- `workflows/scripts/board/tests/test_issues_claim_edges.sh` — claim-lock /
  sub-issues-edge / cascade tests for the issues-only backend (foundation
  F#800, merged via #833).

### Changed

- `workflows/scripts/board/lib/board.sh`, `workflows/scripts/board/claim.sh`,
  `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`,
  `workflows/scripts/board/tests/test_issues_backend.sh`: issues-only
  `board_stamp`, `board_claim_contended`, `board_sub_issues` + docs
  (foundation #833).

### Fixed

- Generated `Makefile` `test-board` recipe now runs every `tests/test_*.sh`
  via a glob instead of a stale static list — v0.1.0/v0.1.1 CI silently
  skipped `test_issues_backend.sh` (foundation F#836); the same fix lands in
  `workflows/scripts/kernel/seed-kernel-repo.sh`.

## [0.1.1] - 2026-07-03

Re-seed of the kernel file set from current foundation `main` — the v0.1.0
seed tree was materialized before foundation PRs #828/#829 merged and before
the F#819/Epic-C docs work landed, so the tag was stale relative to the
source repo at publish time (16 drifted + 9 new kernel-classified files).

### Added

- Issues-only tracker backend (`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`,
  `workflows/scripts/board/tests/test_issues_backend.sh`) — foundation F#799,
  merged via #829.
- Curated failure-mode chapters (`docs/failure-modes/01`–`04`) and
  `docs/CONTRIBUTING.md` — foundation F#764/F#819.
- Docs Pages publish workflow (`.github/workflows/docs-pages.yml`) and
  `workflows/scripts/docs/sources/adapter_contracts.py` — foundation Epic C.

### Changed

- `claude/plan-schema.md`: `repo:` field for cross-repo-targeted plan items
  (foundation #828).
- `workflows/scripts/board/lib/board.sh` + board tests/conf: issues-only
  backend integration (foundation #829).
- `scripts/quality-gates.sh`: `make docs` gate added (foundation F#764).
- `claude/commands/{assess,build,drain-mind,triage}.md`,
  `workflows/scripts/build/pr.sh` (+ test), docs generator (+ test, README),
  `workflows/scripts/kernel/kernel-manifest.txt`: brought current with
  foundation main.

## [0.1.0] - 2026-07-02

### Added

- Initial fresh-history seed of the kernel file set from the foundation
  repo's `kernel`-classified tree (see
  `workflows/scripts/kernel/kernel-manifest.txt` in the source repo, and
  `workflows/scripts/kernel/seed-kernel-repo.sh`, the re-runnable seeder that
  produced this commit). Board toolkit, build spine, funnel driver, quality
  gates, and the Claude Code commands/skills/hooks that drive them.
