# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/) —
pre-1.0, so a minor version bump (`0.x.0`) may include breaking changes.

## [Unreleased]

### Changed

- Daily-ritual command restructure (temperloop epic #86): the drain/review loop
  is split into a nightly unattended half and a daily human half, and the
  disposition surfaces are renamed store-global.
  - `claude/commands/drain-mind.md` → **`claude/commands/tidy.md`**: reframed to
    run **nightly, unattended** (`claude -p "/tidy"`) — never issues an
    interactive `AskUserQuestion`, parks anything needing human judgment on the
    durable review surfaces, and is now the **sole `mind_snapshot.sh` runner** (a
    new Step 8; the snapshot moved out of the SessionStart hook and the retired
    evening ritual). A mandatory sensitivity scan parks possible secrets to a new
    surface (stub + kind + location only — never the value).
  - **`claude/commands/check-in.md`** (new kernel command): the daily
    human-driver review — renders the telemetry brief (graceful-degrade: only if
    the overlay renderer is present), disposes the six overnight surfaces, and
    reviews/sets the `/next` priorities per project. Sole `Status` mutator of the
    append-only surfaces.
  - The five store-global disposition surfaces are renamed
    `Context/foundation - <name>` → **`Context/pipeline - <name>`** (pending
    decisions, proposed supersessions, retro review surface, candidate tells,
    vault hygiene report) — they were never foundation-specific. Genuine
    foundation notes (e.g. `Context/foundation - AskUserQuestion severity
    taxonomy`) keep their prefix.
  - Kernel-manifest, docs generator, live/drain validator, hooks, and the
    `drain/` helpers/tests updated to the new names.

### Fixed

- Unattended funnel-run silent-failure hardening (foundation epic #1041):
  - `workflows/scripts/build/funnel-drive.settings.json` +
    `funnel-drive-merge.settings.json`: grant `mcp__obsidian-builtin__*` in the
    headless permission overlays. The overlays previously allowed only
    `mcp__obsidian__*` (the mcp-tools *semantic-search* server) while every vault
    read/write/append routes through the *built-in* REST server — so every
    unattended `/funnel-drive` / `/assess` / retro session was permission-denied on
    `vault_read`/`vault_write`/`vault_append`. (foundation#973)
  - `claude/commands/funnel-drive.md`: a blocked or failed vault write is now
    recorded `failed` (never `executed`) in the Step-3 JSON summary. A headless 5b
    run whose retro append was permission-denied previously still returned
    `{"executed":2,"failed":0}`, silently losing the artifact. (foundation#978)
  - `workflows/scripts/build/funnel-cron.sh`: self-provision `FUNNEL_OPERATOR` on
    an isolated cron checkout. The gitignored `build.config.local.sh` does not
    propagate to `~/dev/foundation.cron` on self-update, so `FUNNEL_OPERATOR`
    stayed the `@REPLACE_WITH_YOUR_GH_LOGIN` placeholder and every route-foundational
    drive silently refused to assign (F#835: ~12h of `routed=0`). A live tick now
    resolves the real login (injectable `FUNNEL_OPERATOR_RESOLVE_BIN`, default
    `gh api user --jq .login`), writes `build.config.local.sh` (chmod 600) and
    exports it for the tick; if the login can't be resolved it emits ONE loud
    `config-gap` escalation instead of a silent 0-routed window. Skipped on
    `--dry-run`. New provisioning tests in `tests/test_funnel_cron.sh`. (foundation#1011)

- `claude/hooks/session-end-log.sh`: SessionEnd stub no longer loses
  post-compact session history — a compact rollover moves the live
  conversation into a new transcript jsonl while the hook is handed the stale
  original path; the hook now follows the rollover chain (same first
  top-level record timestamp, largest sibling wins) and dumps the live end,
  stamping `transcript_given:` with the handed-in path. Repeat fires for the
  same session id now overwrite the existing stub in place instead of
  accumulating near-duplicates. New `claude/hooks/tests/test_session_end_log.sh`
  covers basic dump, chain-follow, decoy rejection, dedupe, and the no-user /
  EVAL_RUN suppressions. (foundation#984)

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
