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
#   KERNEL_GATES  — board / build / install / hooks / PR-hygiene / tidy
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
  # test-ci-poll-retry (temperloop#386): ci-poll.sh's gh_retry() transient-
  # API-hiccup absorption — a bounded, backoff-retried gh api call rather
  # than an immediate false-escalating ERROR on a transient non-JSON/HTTP-5xx
  # response. Lives at workflows/scripts/build/tests/test_ci_poll_retry.sh,
  # sibling of test_ci_poll.sh, and is auto-covered by the glob-based
  # `make test-build` recipe below (same "kernel Makefile is generator-owned,
  # no per-file target" convention every workflows/scripts/build/tests/
  # test_*.sh file already follows) — this comment is the explicit
  # by-name registration the activation proof greps for.
  "make test-build"
  "make test-build-workflow"
  "make test-hooks"
  "make test-install"
  # Compose-plane T0 inventory (temperloop#235, ADR §2.5 capture point 3):
  # workflows/scripts/install-claude-md.sh's regenerated set of
  # knowledge-store notes reachable from the composed CLAUDE.md's own
  # rules — wikilink + backtick-literal store-path extraction, dedup,
  # sort, idempotence, and the empty-store no-error path. Same direct-
  # `bash` form as the knob-registry gates below (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_install_claude_md_t0_inventory.sh"
  # Machine-surface install manifest library (temperloop#261, ADR K164 D7):
  # workflows/scripts/install/manifest.sh's backup/record/restore/read-compat/
  # marker-stamp helpers. Same direct-`bash` form as the T0-inventory gate
  # above (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_install_manifest.sh"
  # Project-scoped review-agent/command deploy (temperloop#290):
  # workflows/scripts/install/project-agents.sh — the kernel-safe install path
  # that wires claude/agents/* + claude/commands/* into a live .claude/ so the
  # capability probe resolves them on a fresh clone. Same direct-`bash` form as
  # the manifest/T0-inventory gates above (kernel Makefile is generator-owned;
  # no new target added here).
  "bash workflows/scripts/tests/test_install_project_agents.sh"
  "make test-install-links"
  "make test-install-worktree-guard"
  "make test-prune-branches"
  "make validate-live-drain"
  "make validate-command-run-emit"
  "make validate-issue-touch-emit"
  "make validate-lexicon"
  # Message-template reference-integrity + registry-completeness lint
  # (temperloop#94, plan item `template-lints`): every by-name template
  # reference in claude/CLAUDE.kernel.md / claude/commands/*.md resolves to a
  # template claude/message-schema.md § Templates actually defines; any
  # overlay override name (when an overlay message-schema is present) does
  # too; and every contract-frozen row in claude/presentation-plane.md's
  # kernel table names a resolvable owner file/section — the
  # validate-live-drain.sh mold applied to the presentation-plane registry.
  "make validate-template-refs"
  # Class-A "static-second-surface" activation-registry lint (temperloop
  # plan item activation-registry-validator, Class-A subset of the
  # activation-completeness contract, temperloop#317 Level 1): the
  # validate-live-drain.sh mold applied to Plans-archive/*.md's `activation:`
  # blocks — for each `class: A` block whose `proof:` reduces to a
  # recognized static file-check idiom (grep/test/[/stat/ls/cat/find), both
  # the item's declared `files:` surface and the proof's activating-surface
  # file must exist in-tree; anything else (class B/C, or a class-A proof
  # that isn't a static second-file check) is out of scope and reported as
  # a skip, not a failure. Reads Plans-archive/ (git-tracked) only, never
  # the live vault Plans/ — see the script's own header.
  "make validate-activation-registry"
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
  # Read-log telemetry (temperloop#229, Epic #226 "script-plane read
  # telemetry"): ks__read_log_emit + its two call sites (knowledge_store.sh's
  # ks__dispatch — every ks_read/ks_write/ks_append/ks_list, plain-files
  # backend — and knowledge_search.sh's ks_search entrypoint). Zero network
  # (fake `uvx` for the ks_search case, mirrors test_knowledge_search.sh).
  # Same direct-`bash` form as the knowledge_search gates above.
  "bash workflows/scripts/lib/tests/test_knowledge_read_log.sh"
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
  # Corpus-first, gh-search-fallback exact body-marker probe (plan item
  # "cache-search-routing", sibling of "cache-search-corpus" above): the
  # helper triage.md/build.md route their idempotency probes through. Fake
  # `_cache_gh` (mirrors test_cache_store.sh) + a fake `_issue_marker_probe_
  # gh_cmd` seam (this file's own live-fallback injection point), zero
  # network. Same direct-`bash` form as the issue-corpus gate above.
  "bash workflows/scripts/lib/tests/test_issue_marker_probe.sh"
  # Portable-timeout shared shim (temperloop#256): run_with_timeout's
  # backend selection (native `timeout` -> `gtimeout` -> the bash-3.2-safe
  # background+kill fallback), the 124->137 exit-code normalization across
  # backends, argument/output passthrough, and the foundation #861
  # pipe-leak-fix regression. The ONE guard baseline-snapshot.sh, report.sh,
  # try.sh, configure.sh, and conventions-probe.sh now source instead of
  # each re-deriving their own copy. Same direct-`bash` form as the
  # knowledge_search gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_portable_timeout.sh"
  # Knob registry (temperloop#164/#169 D2): parse/union tests for
  # workflows/scripts/config/knob-registry-lib.sh — parses the real kernel
  # TSV clean, unions a synthetic overlay fixture (add + redefault rows),
  # and rejects malformed rows (bad field count, unknown type, an overlay
  # add/kernel-name collision, an orphaned redefault). Same direct-`bash`
  # form as the knowledge_search gates above (new workflows/scripts/<dir>
  # lib, no Makefile target needed — the kernel Makefile is generator-owned).
  "bash workflows/scripts/config/tests/test_knob_registry.sh"
  # Registry-driven config lints (temperloop#164/#169, item
  # registry-config-lints, D2/D3). Two live lints + their fixture suites,
  # mirroring test-kernel-denylist's live-check-then-fixture-tests shape as
  # direct `bash` gates (kernel Makefile is generator-owned, same as the
  # knob-registry gate above):
  #   - check-knob-registry.sh: layer-aware registry↔shell equality lint +
  #     unregistered-knob sweep. NO baseline — strictly green on the
  #     committed tree by construction (the registry records the literals
  #     verbatim); a red run is real drift or a missing registry row.
  #   - check-knob-prose.sh: D3 "prose names knobs, never values" lint over
  #     claude/commands/*.md + claude/CLAUDE.kernel.md, with the
  #     <!-- knob-prose:allow --> marker and a burn-down baseline
  #     (knob-prose-baseline.tsv) the prose-tunables-migration item empties.
  "bash workflows/scripts/config/check-knob-registry.sh"
  "bash workflows/scripts/config/tests/test_check_knob_registry.sh"
  "bash workflows/scripts/config/check-knob-prose.sh"
  "bash workflows/scripts/config/tests/test_check_knob_prose.sh"
  # Feature-docs coverage gate (temperloop#132, docs-site epic #131): the
  # documentation counterpart to test-kernel-manifest. Live validator walks
  # every git-tracked path against docs/features/feature-manifest.txt
  # (full-coverage `<slug> <glob>` claims, longest-match-wins, pseudo-slug
  # `none`), requires docs/features/<slug>.md with the five required sections
  # for every non-exempt slug, and enforces the shrink-only
  # docs/features/backfill-exempt.txt ratchet (stale / exempt-but-documented
  # lines fail). Path claims are never exempted — new unclaimed code fails
  # from day one. Fixture suite alongside. Same direct-`bash` form as the
  # knob-registry gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/validate-feature-docs.sh"
  "bash workflows/scripts/tests/test_validate_feature_docs.sh"
  # workflow-reviewer coverage rollup (temperloop#1007): hermetic gh-double suite
  # for the reporting script that measures the workflow-reviewer gate's coverage
  # over merged command-doc PRs. Reporting rollup, not a merge gate — its own
  # test just proves the numerator/denominator/rate math and fail-open behavior.
  "bash workflows/scripts/tests/test_workflow_reviewer_coverage.sh"
  "make test-scan-stub"
  # Vault-hygiene probe (foundation #959): fixture-vault suite for
  # drain/vault_hygiene_report.sh — the detect-and-propose maintenance detector
  # /tidy runs. Hermetic (mktemp fake vaults, no real vault, no network).
  "make test-vault-hygiene"
  # Generated navigation MOCs (temperloop#231, epic #226): fixture-vault
  # suite for drain/generate_moc.sh — the Index.md + Projects/<name>/Home.md
  # generator /tidy runs, covering detection (filename prefix + project/<name>
  # tag), idempotency, the absent-root/empty-store no-ops, and the
  # refuse-and-propose conflict path for hand-authored content. Hermetic
  # (mktemp fake vaults, no real vault, no network). Direct `bash` form (no
  # Makefile target) — the kernel Makefile is generator-owned (seeded from
  # foundation; see its header), same as the knob-registry/knowledge_search
  # gates above.
  "bash workflows/scripts/drain/tests/test_generate_moc.sh"
  # Recent-findings tally (foundation #960): the drain "Recurrence → promotion"
  # heredoc extracted to drain/tally_recent_findings.py — fixture-seeded, hermetic.
  "make test-tally-findings"
  # env-hygiene-report wrapper (temperloop#176, epic #168 L2): the thin
  # passthrough over env-reconcile.sh --format entry that /tidy's forthcoming
  # § Environment hygiene step (temperloop#177) will invoke — the environment
  # counterpart to the vault-hygiene gate above. Hermetic (throwaway git repos,
  # stubbed gh/launchctl on PATH, no network); also covers the
  # env-reconcile.sh-missing and not-executable fail-open paths.
  "make test-env-hygiene-report"
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
  # Diff-scoped public-repo leak guard (temperloop #74): the sibling of the two
  # whole-tree kernel scrubs above. Scans the ADDED lines of a PR's diff (all
  # tracked files, not just the kernel manifest) for personal/private tokens +
  # secrets and fails the merge — the mechanical backstop to the kernel/overlay
  # authoring rule, the way validate-live-drain backstops the live/drain rule.
  # Riding KERNEL_GATES (not a new CI job) makes it part of the already-required
  # `checks` status, so it gates pull_request AND merge_group with no
  # branch-protection reconfiguration. On a feature-branch checkout it diffs the
  # branch's own additions; on push:main / no resolvable base it skips the live
  # scan cleanly; the bundled fixture test always gates detection.
  "make test-pr-leak-guard"
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
  # Hermetic env-sandbox test harness (temperloop#263, "sandbox-core", ADR
  # K164 D6) + the install-surface dry-run legs it wires: sandbox.sh's own
  # unit suite (env-scoping, gh/claude stubs, bootstrap-over-file://,
  # no-residue), then `temperloop init --dry-run` / `temperloop eject
  # --dry-run` run end to end through a REAL bootstrapped install. NO
  # container — a throwaway HOME + all four XDG vars, scoped to the
  # invoked subprocess only, never exported into this gate's own shell.
  # Same direct-`bash` form as the other kernel/workflows/scripts/tests
  # entries above (kernel Makefile is generator-owned).
  "bash workflows/scripts/tests/lib/tests/test_sandbox.sh"
  "bash workflows/scripts/tests/test_sandbox_dry_run_legs.sh"
  # Sandbox-integrity layer (temperloop#266, "sandbox-integrity", belt-and-
  # suspenders on ADR K164 D6): sandbox_preflight_links (write preflight),
  # sandbox_tripwire_snapshot/check (post-run drift tripwire on the REAL
  # $HOME/.claude + $HOME/.local/bin/temperloop, never mutated by the test —
  # all fixtures live under mktemp scratch), and sandbox_tree_manifest/diff
  # (symlink-aware tree-manifest + caller-supplied-exclusion diff), all
  # appended onto sandbox.sh above. Sibling suite to test_sandbox.sh (kept
  # separate rather than folded in) — same direct-`bash` form.
  "bash workflows/scripts/tests/lib/tests/test_sandbox_integrity.sh"
  # `temperloop install` (temperloop#264, ADR K164 D7): the CLI half of the
  # install manifest library (workflows/scripts/install/manifest.sh) landed
  # above — installs the machine surface (links_enumerate() desired state)
  # via bin/subcommands/install.sh, recording every touched path. Same
  # sandbox_bootstrap_checkout idiom as the dry-run-legs gate above, but
  # exercises a REAL (non-dry-run) install end to end: dry-run zero-writes,
  # default-deny consent, fresh install + manifest state=created, gh-shim
  # marker-stamp, idempotent re-install convergence, a pre-seeded path's
  # backup-then-replace, and a green doctor.sh run afterward.
  "bash workflows/scripts/tests/test_install_cli.sh"
  # Tier-1 hermetic install-lifecycle suite (temperloop#267, ADR K164 D6):
  # the END-TO-END lifecycle leg on top of the per-CLI suites above —
  # bootstrap from the local checkout over file:// -> `temperloop install`
  # -> doctor green -> idempotent re-install (manifest byte-comparable, no
  # spurious backups) -> `temperloop uninstall` -> sandbox_tree_diff of the
  # machine surface (before-install vs after-uninstall) against a declared,
  # commented exclusion set proves no unexplained residue; wrapped in the
  # sandbox-integrity layer (preflight + real-machine tripwire). Self-scopes
  # to a kernel-only checkout: on a composed overlay tree it prints a
  # legible SKIP and exits 0 (downstream propagation is temperloop#255's
  # decision). Same direct-`bash` form as the install-cli gate above.
  "bash workflows/scripts/tests/test_install_lifecycle.sh"
  "make shellcheck"
  # Design-brief-conformance lint (temperloop#216, plan item
  # design-brief-lint): a mechanical check that a /design brief carries a
  # valid disposition for every kernel dimension (claude/design-schema.md
  # § Disposition grammar's no-silent-skips rule), plus a resolution check
  # of claude/design-schema.md's own "Enforcing gate" column citations
  # (the gap that file's own § Kernel dimension list names this lint as
  # chartered to close). Bare invocation checks only the real schema file's
  # citations (briefs live in the knowledge store, outside this repo — CI
  # has no vault to read); the fixture suite alongside exercises the
  # brief-conformance path against in-repo fixtures. Same direct-`bash`
  # form as the knob-registry/feature-docs gates above (kernel Makefile is
  # generator-owned).
  "bash workflows/scripts/validate-design-brief.sh"
  "bash workflows/scripts/tests/test_validate_design_brief.sh"
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
# Bounded per-gate retry to absorb transient macOS-runner flakiness
# (temperloop#403): the GitHub macos-latest runner intermittently fails
# unrelated hermetic gates (fork/exec/IO under runner load) that pass locally
# and on ubuntu — e.g. test_eject.sh and test_validate_design_brief.sh, which
# share no code. A real breakage fails all attempts and still gates; a flake
# clears on a retry. Retries are LOGGED (per-attempt + an end-of-run summary)
# so a flake stays visible rather than silently masked. Set GATE_MAX_ATTEMPTS=1
# to disable (e.g. when hunting a real intermittent bug).
GATE_MAX_ATTEMPTS="${GATE_MAX_ATTEMPTS:-3}"
failures=()
retried=()
for gate in "${GATES[@]}"; do
  printf '\n=== %s ===\n' "$gate"
  # Each GATES entry is a full command line; split it into argv (no eval).
  read -ra cmd <<< "$gate"
  attempt=1
  while true; do
    if "${cmd[@]}"; then
      if (( attempt > 1 )); then
        retried+=("$gate (green on attempt $attempt/$GATE_MAX_ATTEMPTS)")
      fi
      break
    fi
    if (( attempt >= GATE_MAX_ATTEMPTS )); then
      failures+=("$gate")
      break
    fi
    printf '\n::: gate failed on attempt %d/%d — retrying (transient-flake tolerance, temperloop#403): %s\n' \
      "$attempt" "$GATE_MAX_ATTEMPTS" "$gate" >&2
    attempt=$(( attempt + 1 ))
  done
done

echo
if (( ${#retried[@]} > 0 )); then
  printf 'NOTE: %d gate(s) passed only after a retry (transient flake — see temperloop#403):\n' "${#retried[@]}"
  printf '  - %s\n' "${retried[@]}"
  echo
fi
if (( ${#failures[@]} > 0 )); then
  printf 'FAILED %d/%d quality gate(s):\n' "${#failures[@]}" "${#GATES[@]}"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
printf 'OK — all %d quality gate(s) passed\n' "${#GATES[@]}"
