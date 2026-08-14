- **Six kernel gates that broke in a composed overlay checkout (a repo
  vendoring this kernel as a subtree, e.g. foundation) now self-scope or work
  correctly there, while still running for real in the kernel's own
  checkout** (#1490):
  - `scripts/lint-pipe-grep-q.sh` matched its two self-exempt files by a
    literal `$REPO_ROOT`-prefixed path, so a vendoring overlay's compat
    symlink (`scripts/lint-pipe-grep-q.sh -> ../kernel/scripts/lint-pipe-
    grep-q.sh`) resolved `REPO_ROOT` to the overlay root and the lint's own
    vendored originals under `kernel/` never matched — producing false
    positives against the lint's own deliberate fixtures. Self-exemption is
    now by RESOLVED (symlink-followed) path on both sides of the comparison,
    so only the two named files are exempt — a genuine violation elsewhere
    under a vendored `kernel/` tree is still flagged.
  - `scripts/tests/test_assemble_changelog.sh` demanded a root
    `CHANGELOG.md` unconditionally; a consumer may not use the changelog
    fragment workflow at its own root at all. It now emits a legible SKIP
    when no `CHANGELOG.md` is present.
  - `workflows/scripts/validate-onramp-anchors.sh` (and its test) demanded
    the consumer's own `README.md`/`bin/README.md`/`bin/temperloop`/
    `docs/features/install-cli.md` carry the kernel's adopter onramp
    narrative — kernel-product prose a vendoring consumer repo has no
    obligation to carry. Both now detect a composed overlay tree (the same
    two-signal detection `sandbox_skip_if_composed_tree` already uses) and
    emit a legible SKIP there.
  - `workflows/scripts/pipeline-spend-report.sh`'s `--by-agent-type` agent
    allowlist walked `claude/agents` with a bare `find`, which macOS/BSD
    `find` silently refuses to descend into when the directory is a
    SYMLINK (the compat-symlink shape every vendoring consumer uses for
    `claude/agents`) — collapsing `recognized_agent_definitions` to 0 and
    every seat assertion to unattributed. Now uses `find -L` so a symlinked
    `claude/agents` resolves exactly like a real one.
  - `workflows/scripts/board/tests/test_board_host_label.sh` resolved its
    search root with plain `pwd` (not `pwd -P`), so a vendoring consumer's
    compat symlink (`workflows/scripts/board -> ../../kernel/workflows/
    scripts/board`) kept the symlink in the path — and real macOS/BSD grep
    (unlike GNU grep) silently refuses to descend into a symlinked
    top-level directory argument, so the structural "exactly one inline
    site" check found nothing and failed. Now resolves physical
    (`pwd -P`) throughout.
  - `workflows/scripts/model-comparison/tests/test_comparison_report.sh`'s
    `mkmirror()` helper used a plain `cp -R` to relocate the
    `model-comparison/` directory into a throwaway mutation-testing scratch
    dir. On a consumer whose files under that directory are individual
    relative symlinks into the vendored `kernel/` copy, `cp -R` preserves
    those symlinks as symlinks rather than copying their content — so once
    relocated to a scratch dir with no `kernel/` sibling, they go dangling
    and the mirrored producer degrades ("comparison-statistics library is
    missing") before the mutation under test is ever reached. Now uses
    `cp -RL` to dereference.

  Each fix ships a regression test that reproduces the exact composed-overlay
  symlink shape (a synthetic `kernel/` subtree plus compat symlinks at the
  overlay path) and proves both directions: the gate still catches a real
  problem there, and the kernel's own checkout is unaffected.
