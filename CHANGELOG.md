# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/). See
[`VERSIONING.md`](VERSIONING.md) for the canonical bump rules and what each
tier signals.

Pre-1.0, the breaking signal rides the CHANGELOG, not the version number: a
release that changes the contract surface in a way an overlay must adapt to
**tags its section `BREAKING`** and includes a migration note. `update-kernel`
reads that marker; a stranger greps for it before pulling.

## [Unreleased]

## [0.9.0] - 2026-07-06

Epic temperloop#94 — the **communication-style / message-presentation layer**.
A kernel contract for how Claude presents work: durable artifacts (PR bodies,
commit messages, issues) and ephemeral surfaces (agent narration, unattended
digests, status reports) now share one evidence-grounded schema, with a
sanctioned overlay override seam and machine-checkable conformance lints. The
underlying HCI/SE claims were put through an adversarial primary-source
verification pass (25 Tier-2 claims → 21 confirmed / 4 refuted) before any
template slot was locked. **Additive for existing overlays** — the new kernel
`§ Communication conventions` refinements flow in via subtree and no overlay is
forced to adapt, so this section is deliberately **not** tagged `BREAKING`.

### Added

- `claude/message-schema.md` — the central message-presentation contract:
  reader-state axes (present / cold / absent × operator / stranger / parser),
  seven interaction modes, five artifact-shaped templates (PR-body skeleton,
  parking note, digest entry, question block, degradation notice), the
  reference-token rule (first-mention title hook; a trailing legend reserved for
  long mode-6 durable artifacts), and the Tier-1 findings the templates encode
  (BLUF; the Endsley perception → comprehension → projection shape for cold
  returns; calibrated-trust status reporting). (temperloop#94, #109)
- `claude/message-schema.md` § Overrides — the override seam. An overlay may
  redeclare a **named template** whole, by name (later-definition-wins; a
  byte-identical redeclaration is a no-op; a dangling override is flagged by the
  template lints). This is the single sanctioned exception to
  `CLAUDE.kernel.md`'s "overlay may extend, never contradict" default, scoped to
  named templates only. (temperloop#94, #114)
- `workflows/scripts/validate-template-refs.sh` — a kernel lint enforcing
  message-schema conformance: reference-integrity, dangling-override detection
  (parameterized over the overlay's override file via `MESSAGE_SCHEMA_OVERLAY`),
  and template-registry completeness. Wired into `scripts/quality-gates.sh` and
  the Makefile; `workflows/scripts/lint-pr-body.sh` gains an opt-in
  `--require-verification` flag. (temperloop#94, #119)
- `scripts/update-kernel.sh` — the sanctioned kernel-subtree puller now ships
  from the kernel itself (co-located with `VERSIONING.md`, so policy and the
  machinery that enforces it travel together) and carries a **breaking-delta
  gate**: before the subtree pull it scans the version/CHANGELOG delta between
  the current `.kernel-pin` tag and the target `KERNEL_TAG` and, on a breaking
  delta — a `BREAKING`-marked CHANGELOG section in range (pre-1.0) or a
  major-version increment (post-1.0) — **refuses the unattended path** and
  requires an explicit acknowledgment (`KERNEL_ALLOW_BREAKING=1` or an
  interactive confirm), printing the migration notes from the marked sections
  first. An additive/patch delta pulls without prompting. `kernel-drift-check`
  (byte-identity, orthogonal to semver) is untouched. Implements what
  `VERSIONING.md` § "Signal to the machinery" promises. (temperloop#89,
  follow-up to the versioning spike #79 / PR #88)

### Changed

- `claude/CLAUDE.kernel.md` § Communication conventions — reworked to defer to
  the message-schema. The trailing **refs-legend** rule is **superseded** by a
  first-mention title-hook (a legend is now reserved for long mode-6 durable
  artifacts); board identity is named-not-numbered in prose; completion-summary
  and resume-recap are grounded in BLUF + the Endsley cold-return shape; the
  PR-verification-surface section is named as the owner of the PR-body-skeleton
  template's Verification slot. A "named message templates" carve-out under the
  "never contradict" corollary sanctions the override seam. (temperloop#94,
  #109, #113)
- `claude/plan-schema.md` — readability port and the override-seam schema
  additions. (temperloop#94, #110, #114)

### Fixed

- `claude/commands/build.md` / `claude/workflows/build-level.mjs` — propagate the
  quality-gates exit code through the Step 3e.5 gate pipe (`pipefail`), so a
  failing acceptance gate is no longer masked by a later stage of the pipe.
  (temperloop#116)
- `workflows/scripts/board/tests/test_cache_store.sh` — removed a repo-wide
  `check-kernel-manifest.sh` assertion that coupled this isolated board-cache
  unit test to global manifest state, making it fail deterministically on any
  unclassified tracked file anywhere in the repo (and present as a "flake").
  `make test-kernel-manifest` already owns repo-wide coverage. (temperloop#120,
  #122)

## [0.8.2] - 2026-07-06

### Added

- `claude/presentation-plane.md` — indexes which message surfaces are
  contract-frozen / parsed (non-overridable) vs. style-free (overridable), the
  boundary the v0.9.0 override seam and template lints enforce. Foundation-layer
  scaffolding for epic temperloop#94; shipped here, documented retroactively.
  (temperloop#94, #104)
- `claude/measurement-proxies.md` — defines observable proxies for communication
  quality so the presentation rules are measurable rather than aspirational.
  Foundation-layer scaffolding for epic temperloop#94; shipped here, documented
  retroactively. (temperloop#94, #105)

### Fixed

- `funnel-drive.sh` / `funnel-drive.md`: route a refused `route-foundational` to the
  operator's decision queue (`_route_safe_refused`). The rung-5b driver refuses a
  `route-foundational` when the epic already has an approved/executing plan note, but
  the refusal applied **no marker** — so `funnel-tick.sh` re-emitted it every tick and
  a single Foundational epic spun for a full day. The refusal now applies the
  `decision` label + an operator assignee, landing the item in funnel-tick's existing
  `route-already-assigned` guard so it parks instead of re-firing. Reuses that guard
  (no new label/self-heal), so the funnel-tick "should not re-emit" half needs no
  separate change. (foundation#1053; subsumes foundation#1045)

## [0.8.1] - 2026-07-06

### Fixed

- `claude/hooks/write-lane-guard.sh`: set the executable bit. It shipped in v0.8.0
  as `0644`, which left the PreToolUse guard **installed but inert** — Claude Code
  runs the hook command path directly, so a non-executable hook never fires (every
  sibling guard is `0755`). The test suite now asserts the hook is executable so
  this cannot regress.

## [0.8.0] - 2026-07-06

### Added

- `claude/hooks/write-lane-guard.sh` — a PreToolUse guard enforcing session
  working-tree ownership: a state-mutating tool call (Write/Edit/…; Bash
  `git commit|checkout|merge|reset|push|…` or `make install`) whose target is the
  canonical checkout of a repo *other* than the session's launch dir
  (`$CLAUDE_PROJECT_DIR`) returns an `ask`, naming home vs. the foreign checkout
  and pointing at the `git worktree add` escape hatch. Home, any linked worktree,
  non-repo paths, `git worktree add`, and read-only ops stay silent; fails open;
  `EVAL_RUN`-suppressed. Prevents one session from moving a concurrent peer's
  `HEAD` by mutating its checkout in place (the epic #86 dev/foundation incident).
  New `## Working-tree ownership` section in `CLAUDE.kernel.md` documents the rule.
  NOTE for overlays: the hook ships here, but the `PreToolUse` matcher that wires
  it in lives in the overlay `settings.json` — register it there on pull.

## [0.7.1] - 2026-07-06

### Fixed

- `tidy.md`: restore the `### Knowledge-search parity misses` drain step that the
  v0.7.0 daily-ritual rewrite accidentally dropped — the kernel-resident backstop
  for the overlay's temporary Phase-1 parity comparison rule. A composed overlay
  checkout's `validate-live-drain` flagged the Live/Drain pair HALF-PRESENT; the
  kernel-only check never saw it (the overlay extension table is absent there).
  The step already self-skips in a standalone kernel checkout. (epic #86 follow-up)

## [0.7.0] - 2026-07-06 — BREAKING

### BREAKING — daily-ritual command restructure (epic #86)

Renames pipeline command contracts and changes the compose / kernel-manifest
seam; an overlay that vendors this kernel MUST adapt before pulling:

- `claude/commands/drain-mind.md` → `tidy.md`, plus a new `check-in.md`.
  Recompose the overlay's per-file kernel symlinks: drop the `drain-mind.md`
  symlink, add `tidy.md` and `check-in.md` symlinks into
  `kernel/claude/commands/`.
- The kernel-manifest reclassifies commands (`tidy`, `check-in` kernel). An
  overlay's `composed-tree-manifest.txt` must follow: `drain-mind.md`→`tidy.md`,
  add `check-in.md`.
- The five store-global disposition surfaces are renamed
  `Context/foundation - <name>` → `Context/pipeline - <name>` (pending decisions,
  proposed supersessions, retro review surface, candidate tells, vault hygiene
  report). Move the live files; anything appending to the old paths must repoint.
- `/tidy` is now the sole `mind_snapshot.sh` runner (the snapshot left the
  SessionStart hook), so a nightly `claude -p "/tidy"` invocation should be
  scheduled to keep the drain + snapshot running.

### Added

- `VERSIONING.md` — canonical versioning policy: bump rules defined against the
  kernel's contract surface (board adapter, pipeline commands, hooks, `checks`
  gate, CLI, compose/pin seam), the pre-1.0 `BREAKING` CHANGELOG-marker
  convention, the `update-kernel` breaking-delta gate (routed follow-up), and a
  1.0 criterion (three consecutive minor releases with no `BREAKING` marker).
  The CHANGELOG preamble and `kernel-repo-layout.md` § Release-tag convention
  now defer to it. (foundation temperloop#79)

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

## [0.6.2] - 2026-07-06

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
