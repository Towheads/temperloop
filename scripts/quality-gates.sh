#!/usr/bin/env bash
# Single source of truth for foundation's repo-wide STATIC quality-gate set
# (GH #360, mirroring the stageFind contract from GH #324).
#
# CI (.github/workflows/ci.yml `checks` job), the local dev gate (CLAUDE.md §
# Dev workflow), and /build's parent-side acceptance gate (Step 3e.5) all
# invoke THIS one script, so "local gates mirror CI" is mechanically true rather
# than three copies of the gate list kept in sync by discipline. Add or change a
# gate HERE and every consumer follows — see
# [[Decisions/stageFind - Process-invariant SSOT strategy]].
#
# Scope: the fast, repo-wide, zero-network gates CI runs on every PR — the board
# / build / install / telemetry / sessions test suites, the Live/Drain +
# PR-body-lint registries, the validator/corpus lints, and a whole-tree static
# shell lint. Each gate is a `make` target (the shell-lint pipeline lives behind
# the `make shellcheck` target) so this file stays a flat, splittable command
# list. They run BARE and repo-wide — no path scoping — so a failure is caught
# the way CI sees it (the PR #309 silent-red lesson).
#
# LAYERING (foundation #774, epic #762 "kernel split: seams in place"): the
# gate set is two layers unioned at run time, so the coming kernel/overlay
# repo split can't break "local gate = CI gate" in either repo.
#
#   KERNEL_GATES  — board / build / install / hooks / PR-hygiene / drain-mind
#     mechanical-owner suites. Classified by "would a stranger's kernel-only
#     install have this make target?" — yes: none of them reference
#     foundation-private subject matter (Travis's telemetry/dashboard, the
#     Obsidian-vault session archive, the Sentry crash-convergence
#     integration, the funnel cost-rollup, or the workflow-eval corpus).
#     Typed inline below — this IS the kernel repo's future gate list.
#
#   OVERLAY_GATES — appended by every scripts/quality-gates.d/*.sh file
#     (sourced in glob order, each one only ever `+=`-ing onto the array —
#     append-only, never replacing a sibling drop-in's entries). Chosen over
#     a single sourced GATES_EXTRA conf because a directory of small, freely
#     addable units mirrors this repo's existing extension-point convention
#     (claude/hooks/, claude/commands/) and lets more than one overlay
#     contributor union in without fighting over one file; it also degrades
#     for free — an absent/empty directory (a real kernel-only extraction)
#     just yields zero overlay gates, no conditional-file-existence dance.
#     scripts/quality-gates.d/foundation-overlay.sh carries today's
#     foundation-only gates.
#
# ZERO BEHAVIOR CHANGE today: KERNEL_GATES + OVERLAY_GATES is the exact same
# 21-gate set this script ran before layering, run with the same
# collect-all-failures-then-exit-nonzero semantics. The run ORDER differs
# (kernel gates now precede overlay gates, vs. the old interleaved order) —
# documented as order-irrelevant: every gate is an independently isolated
# `make` target (a test suite or lint script) with no shared fixture or
# generated artifact that a later gate in the list depends on, and the loop
# below already runs every gate regardless of earlier failures, so reordering
# changes nothing about which gates run or what fails.
#
# Usage:
#   scripts/quality-gates.sh          run every gate; exit non-zero if any fail
#   scripts/quality-gates.sh --list   print "[layer] command" for every gate

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The kernel static gate set — the ONE place this list is typed. Order
# mirrors CI's `checks` job (pre-layering order, minus the now-overlay
# entries). Each entry is a full command line (a `make` target).
KERNEL_GATES=(
  "make test-board"
  # Dual-adapter SAFE-TIER funnel integration suite (foundation #801, split
  # 3/3 of the issues-only tracker adapter, Epic B #763): runs funnel-tick.sh
  # LIVE against both the Projects-v2 and issues-only backends and proves
  # parity + zero merge-capable gh calls. A new kernel-side test_*.sh file is
  # auto-covered by kernel CI's own glob-based `test-board` recipe (F#836);
  # this line is the explicit registration in FOUNDATION's own gate set (the
  # one scripts/quality-gates.sh actually runs — see
  # workflows/scripts/board/ISSUES-ONLY-BACKEND.md § Funnel integration).
  "make test-board-dual-adapter"
  "make test-build"
  "make test-build-workflow"
  "make test-hooks"
  "make test-install"
  "make test-install-links"
  "make test-install-worktree-guard"
  "make test-prune-branches"
  "make validate-live-drain"
  "make validate-command-run-emit"
  "make validate-issue-touch-emit"
  "make validate-lexicon"
  # zsh special-parameter-tie guard + its behavioral regression (temperloop#40,
  # surfaced from foundation#987). These are DIRECT `bash` gates rather than
  # `make` targets because the kernel Makefile is generator-owned (seeded from
  # foundation — see its header); the gate loop runs each entry as a raw command
  # line (not eval), so a bash invocation is a first-class gate. The lint greps
  # every sourced lib for a `local path=`-style footgun (portable, no zsh
  # needed); the regression test shells to zsh (SKIPs where zsh is absent, e.g.
  # some CI runners) and proves the dispatch preserves PATH.
  "bash scripts/lint-zsh-param-tie.sh"
  "bash workflows/scripts/lib/tests/test_knowledge_search_zsh_path_tie.sh"
  # Main knowledge_search backend suite (interface + basic-memory adapter, mocked
  # uvx subprocess, offline). Previously ungated — gated here alongside the F#946
  # .bmignore / KNOWLEDGE_SEARCH_BM_EXTRA_IGNORES seam it now covers. Same direct-
  # `bash` form as the zsh-tie gate above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_knowledge_search.sh"
  # Issue-corpus renderer + ks_search reindex chain (plan item
  # "cache-search-corpus"): the first production caller of knowledge_search's
  # dormant ks_search seam. Fake `_cache_gh` (mirrors test_cache_store.sh) +
  # fake `uvx` (mirrors test_knowledge_search.sh) on PATH, zero network. Same
  # direct-`bash` form as the two knowledge_search gates above.
  "bash workflows/scripts/lib/tests/test_issue_corpus.sh"
  # WARM basic-memory-mcp backend suite (registration + selection + fail-open,
  # hermetic — no daemon/network/uvx). Gated here alongside the temperloop#54
  # operator-visible cold-fallback signal it now covers: the one-time-per-session
  # de-dup, the raw-lake telemetry emit, and the preserved fail-open contract.
  # Same direct-`bash` form as the two knowledge_search gates above.
  "bash workflows/scripts/lib/tests/test_knowledge_search_mcp.sh"
  "make test-scan-stub"
  "make lint-pr-body-test"
  "make test-stranger-config"
  # Demo-repo seed script tests (foundation #851, Epic D): subprocess suite
  # for kernel/workflows/scripts/demo/seed-demo-repo.sh, fake `gh` on PATH,
  # zero network — mirrors test-board's glob-based kernel coverage (F#836).
  "make test-demo"
  # Proposal-PR generator tests (foundation #853, Epic D): subprocess suite
  # for kernel/workflows/scripts/proposal/proposal-pr.sh, fake `gh` on PATH,
  # zero network — mirrors test-board's glob-based kernel coverage (F#836).
  "make test-proposal-pr"
  "make test-kernel-manifest"
  "make test-kernel-denylist"
  "make test-kernel-gitleaks"
  # Mechanical egress lint over Epic E's before/after value-loop producers
  # (foundation #766, privacy/egress audit item): greps baseline-snapshot.sh,
  # report.sh, bin/foundation's auto-offer check, and (in the composed-tree
  # invocation via the root Makefile) the .foundation/report.d/ overlay
  # drop-ins for network-call patterns beyond the one sanctioned `gh`
  # channel. See check-producer-egress.sh's header for the documented
  # (today: empty) opt-in egress surface.
  "make test-producer-egress"
  # Read-only repo-convention detector (foundation #765): zero-network
  # fixture-repo tests, plus a live PATH-trimmed case proving the `gh`-absent
  # degrade path (see workflows/scripts/probe/tests/test_conventions_probe.sh).
  "make test-conventions-probe"
  # `foundation try` — zero-config, zero-write taste (foundation #765 Epic D,
  # item foundation-try / #852): fake `gh`/`claude` on PATH (the
  # write-intercepting-wrapper proof), zero network, plus PATH-trimmed
  # gh-absent/claude-absent degrade-path cases (see
  # bin/subcommands/tests/test_try.sh).
  "make test-try"
  # Docs-build gate (F#764, Epic A): runs the docs-site generator
  # (workflows/scripts/docs/generate.py) BUILD ONLY, no publish step — a
  # doc-source break (e.g. a malformed workflows/scripts/kernel/kernel-
  # manifest.txt line, or an overlay docs.d/*.py drop-in missing
  # build_pages()) raises inside generate.py and `make docs` exits non-zero,
  # so it cannot merge. Stdlib-python, zero-network, zero-install on a stock
  # runner (see generate.py's own docstring). Publishing the built site is a
  # SEPARATE, sibling item's concern (the Pages workflow) — this gate only
  # proves the site still builds.
  "make docs"
  "make shellcheck"
)

# The overlay gate set — empty by default; populated only by drop-ins.
OVERLAY_GATES=()
if [[ -d "$REPO_ROOT/scripts/quality-gates.d" ]]; then
  for dropin in "$REPO_ROOT"/scripts/quality-gates.d/*.sh; do
    [[ -e "$dropin" ]] || continue
    # shellcheck disable=SC1090  # dynamic drop-in path, resolved at run time
    source "$dropin"
  done
fi

GATES=("${KERNEL_GATES[@]}")
# Bash 3.2 (macOS default) treats "${arr[@]}" on a zero-length array as an
# unbound-variable error under `set -u` — guard the expansion on count so an
# empty (or absent-directory) OVERLAY_GATES is a true no-op, not a crash.
if [[ ${#OVERLAY_GATES[@]} -gt 0 ]]; then
  GATES+=("${OVERLAY_GATES[@]}")
fi

if [[ "${1:-}" == "--list" ]]; then
  for gate in "${KERNEL_GATES[@]}"; do
    printf '[kernel]  %s\n' "$gate"
  done
  if [[ ${#OVERLAY_GATES[@]} -gt 0 ]]; then
    for gate in "${OVERLAY_GATES[@]}"; do
      printf '[overlay] %s\n' "$gate"
    done
  fi
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "usage: $(basename "$0") [--list]" >&2
  exit 2
fi

# Run gates from the repo root so the `make` targets resolve regardless of the
# caller's CWD (build 3e.5 runs this from a throwaway worker checkout).
cd "$REPO_ROOT" || exit 1

# Run all gates (don't fail-fast) so one run surfaces every failure, then exit
# non-zero if any failed — friendlier locally than CI's step-by-step halt while
# still giving CI a single non-zero exit to gate on.
failures=()
for gate in "${GATES[@]}"; do
  printf '\n=== %s ===\n' "$gate"
  # Each GATES entry is a full command line; split it into argv (no eval).
  read -ra cmd <<< "$gate"
  if ! "${cmd[@]}"; then
    failures+=("$gate")
  fi
done

echo
if (( ${#failures[@]} > 0 )); then
  printf 'FAILED %d/%d quality gate(s):\n' "${#failures[@]}" "${#GATES[@]}"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
printf 'OK — all %d quality gate(s) passed\n' "${#GATES[@]}"
