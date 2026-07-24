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
  # Out-of-tree bulk deploy copy-default regression (temperloop#497):
  # project-agents.sh's bulk deploy_one() now mirrors deploy_only()'s
  # in-tree/out-of-tree mode decision — an out-of-tree adopter defaults to a
  # detached real-file copy instead of an absolute symlink back into the
  # operator's kernel checkout. Same direct-`bash` form as the sibling
  # project-agents gate above (kernel Makefile is generator-owned; no new
  # target added here).
  "bash workflows/scripts/tests/test_project_agents_out_of_tree_copy.sh"
  # Gitignore-precondition propagation at project-agents deploy time
  # (temperloop#560, ADR 0007): project-agents.sh now ensures the ADR 0007
  # gitignore precondition (.claude/agents/, .claude/commands/,
  # .claude/reviewer-state/) via the shared gitignore-safety.sh helper
  # BEFORE it writes into an adopter's .claude/ tree — reusing the same
  # helper reviewer-activate.sh already calls, never a second hand-rolled
  # append. Same direct-`bash` form as the sibling project-agents gates
  # above (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_project_agents_gitignore_propagation.sh"
  # Reviewer activation-coverage scan (temperloop#548, ADR 0007/0008):
  # workflows/scripts/install/reviewer-activation-coverage.sh — the pure,
  # non-interactive data path that computes the gap set (catalogued
  # reviewers present at/above REVIEWER_SCAN_MIN_FILES, not yet activated,
  # not durably declined) and the reviewer-routing.tsv<->catalog
  # referential-integrity check. Same direct-`bash` form as the
  # project-agents/manifest/T0-inventory gates above (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_reviewer_activation_coverage.sh"
  # Reviewer opt-in activation caller + durable-decline marker (temperloop#549,
  # ADR 0007/0008): workflows/scripts/install/reviewer-activate.sh — the
  # interactive layer between #548's gap-set data path and #543's --only
  # deploy path: one batched offer per gap set, activation via --only,
  # durable per-name decline markers under the gitignored
  # .claude/reviewer-state/declined/. Same direct-`bash` form as the
  # reviewer-activation-coverage/project-agents gates above (kernel Makefile
  # is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_reviewer_activate.sh"
  # Advisory `make doctor` reviewer-coverage check (temperloop#550, ADR
  # 0007/0008): workflows/scripts/install/doctor.sh's check_reviewer_
  # coverage() — WARN-level, strictly per-checkout, reusing #548's
  # non-interactive data path (never #549's interactive caller). Same
  # direct-`bash` form as the sibling reviewer gates above (kernel Makefile
  # is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_doctor_reviewer_coverage.sh"
  "make test-install-links"
  "make test-install-worktree-guard"
  "make test-prune-branches"
  "make validate-live-drain"
  "make validate-command-run-emit"
  "make validate-issue-touch-emit"
  # Kernel telemetry-brief renderer (temperloop#431): the five-question brief
  # rendered from kernel-only raw streams, wired into claude/commands/
  # check-in.md Part 1 — fixture-lake render reconciliation, empty-stream
  # "no data yet" degradation, stale-window honesty, torn-line resilience,
  # and the check-in.md wiring presence check. Same direct-`bash` form as
  # the T0-inventory/manifest gates above (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_telemetry_brief.sh"
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
  # Knowledge-store sync capability (temperloop#430, ADR 0003): ks_sync /
  # ks_sync_available — the plain-files git-backed manual sync (init/push/
  # pull/status, two-environment bootstrap against a local bare remote) and
  # the exit-3 "skipped — sync unavailable for backend <name>" degradation
  # on the obsidian backend. Zero network (the "remote" is a bare repo in a
  # tmpdir); never touches the real HOME/XDG/git config. Same direct-`bash`
  # form as the knowledge_search gates below.
  "bash workflows/scripts/lib/tests/test_knowledge_store_sync.sh"
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
  # Command-availability probe (ADR 0008, temperloop#537): `command_declared
  # <name>`, the shared "source-or-installed present" check for a slash
  # command across the three surfaces a headless `claude -p` invocation's
  # supporting tooling reads/writes (cwd .claude/commands/, this checkout's
  # own claude/commands/, and $HOME/.claude/commands/), plus the
  # COMMAND_DECLARED_OVERRIDE fixture escape hatch. Zero network, zero
  # mutation of the real HOME/checkout (a throwaway git repo under a tmpdir
  # stands in for the checkout-surface case). Same direct-`bash` form as the
  # issue-marker-probe gate above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_command_declared.sh"
  # Portable-timeout shared shim (temperloop#256): run_with_timeout's
  # backend selection (native `timeout` -> `gtimeout` -> the bash-3.2-safe
  # background+kill fallback), the 124->137 exit-code normalization across
  # backends, argument/output passthrough, and the foundation #861
  # pipe-leak-fix regression. The ONE guard baseline-snapshot.sh, report.sh,
  # try.sh, configure.sh, and conventions-probe.sh now source instead of
  # each re-deriving their own copy. Same direct-`bash` form as the
  # knowledge_search gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_portable_timeout.sh"
  # Shared CHANGELOG-range parsing lib (temperloop#429, ADR 0002 follow-on):
  # workflows/scripts/lib/changelog.sh's changelog_semver_major()/
  # changelog_sections_in_range()/changelog_breaking_sections() — lifted out
  # of scripts/update-kernel.sh's former private semver_major()/
  # breaking_sections() so bin/subcommands/update.sh (the managed-clone
  # updater) can reuse the exact same parsing without a bin/->scripts/
  # back-channel. Fast, no-git, literal-fixture unit tests; the end-to-end
  # proof (real git tags, a real checkout) is the update-subcommand gate
  # below. Same direct-`bash` form as the knowledge_search/portable-timeout
  # gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_changelog.sh"
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
  # Reviewer-routing extension/glob-axis drift lint (ADR 0008,
  # docs/adr/0008-reviewer-routing-tsv-extension-axis-scope.md): compares the
  # extension/glob SET between workflows/scripts/config/reviewer-routing.tsv
  # (the single source of truth for that axis, including docs/**) and
  # claude/commands/build.md's 3e routing prose — a tsv key's literal
  # backtick-quoted form reappearing in the prose fails, catching a silent
  # reintroduction of the old inline extension list. Same direct-`bash`
  # form, same check-knob-prose.sh shape, as the two gates above.
  "bash workflows/scripts/config/check-reviewer-routing.sh"
  "bash workflows/scripts/config/tests/test_check_reviewer_routing.sh"
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
  # Subtree-root support for check-kernel-manifest.sh (temperloop#680,
  # derived from foundation#870): synthetic-fixture suite proving the guard
  # accepts a KERNEL_MANIFEST_ROOT that is a subdirectory of an ENCLOSING
  # git checkout with no `.git` of its own (a downstream overlay's vendored
  # kernel/ subtree) — green on a fully-classified subtree, red+named-path
  # on an unclassified one — while the classic own-.git-root invocation
  # (make test-kernel-manifest above) stays unaffected. Same direct-`bash`
  # form as the knob-registry/knowledge_search gates above (kernel Makefile
  # is generator-owned; a new tests/ file needs no new Makefile target).
  "bash workflows/scripts/kernel/tests/test_check_kernel_manifest.sh"
  # Symlinked-vendored-kernel resolution for kernel_lib_resolve_for_classify
  # (foundation#1050): synthetic-fixture suite proving a plan item's `files:`
  # path that points at kernel content through a consumer's dir symlink into a
  # vendored `kernel/` subtree maps to the manifest-relative path and classifies
  # as kernel (both the surface-symlink and git-real vendored forms), while a
  # genuine overlay file and the kernel-repo self-case are left unchanged. Same
  # direct-`bash` form (kernel Makefile is generator-owned; a new tests/ file
  # needs no new Makefile target).
  "bash workflows/scripts/kernel/tests/test_kernel_lib_resolve.sh"
  "make test-kernel-denylist"
  "make test-kernel-gitleaks"
  # Pre-rename identifier leak-gate sweep (temperloop#433, gate-sweep item;
  # depends on the foundation->temperloop rename, temperloop#165 / PR #487):
  # the `prerename` gate. Extends the kernel/personal-token scrub family so a
  # pre-rename `foundation` identifier can't silently re-enter a stranger
  # surface — a pre-rename FOUNDATION_* env var or a legacy foundation/<leaf>
  # XDG subdir is allowed ONLY via a reviewed row in the sibling verdict
  # table (prerename-leak-verdicts.tsv, encoding the rename item's own
  # migrate-vs-allowlist verdicts); the compat shim's own two intentional
  # legacy literals (.foundation/<any leaf>, bin/foundation) are always
  # sanctioned. Same live-check-then-fixture-tests shape as
  # test-kernel-denylist above.
  "make test-kernel-prerename"
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
  # invocation via the root Makefile) the .temperloop/report.d/ overlay
  # drop-ins for network-call patterns beyond the one sanctioned `gh`
  # channel. See check-producer-egress.sh's header for the documented
  # (today: empty) opt-in egress surface.
  "make test-producer-egress"
  # Read-only repo-convention detector (foundation #765): zero-network
  # fixture-repo tests, plus a live PATH-trimmed case proving the `gh`-absent
  # degrade path (see workflows/scripts/probe/tests/test_conventions_probe.sh).
  # Also covers the portable-config regression test (test id
  # test-conventions-probe-portable, temperloop#416,
  # workflows/scripts/probe/tests/test_conventions_probe_portable.sh) that
  # asserts the emitted probe JSON's `repo.dir` never carries an absolute
  # local filesystem path — this is a NEW test_*.sh file picked up by the
  # SAME `make test-conventions-probe` glob below (F#836 rationale: kernel
  # coverage can never trail whichever tests/test_*.sh files are actually
  # vendored), not a second gate registration.
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
  # (The `temperloop update` managed-clone gate and the update-kernel
  # breaking-delta gate are surface-conditional — registered just below the
  # array, temperloop#488.)
  # (Kernel self-distribution gates — test_rename_compat.sh,
  # test_bootstrap_tag_pinning.sh, test_version_embedding.sh, and
  # test_update_subcommand.sh — are CLASS-gated on a vendoring-consumer signal
  # just below this array, not listed here: a bespoke-subtree consumer carries
  # none of their bin/bootstrap.sh + VERSION surface. See the self-distribution
  # block after SKIPPED_KERNEL_GATES, temperloop#691.)
  # Pinned-shellcheck resolver (temperloop#567): asserts scripts/ensure-shellcheck.sh
  # resolves a binary reporting EXACTLY the pinned version and fails loudly on an
  # unresolvable version — the guarantee that `make shellcheck` (the gate below)
  # runs the same shellcheck locally and in CI, closing the false-green skew that
  # let CI-ubuntu's 0.9.0 flag an SC2015 that local/brew 0.11.0 did not (#550).
  "bash scripts/tests/test_ensure_shellcheck.sh"
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

# Surface-conditional kernel gates (temperloop#488, class-gated per temperloop#691).
# Some gates test surfaces a consuming repo's composed tree may legitimately not
# carry, so they register only when the surface is present — with a legible skip
# line otherwise (never a silent no-op, per the legible-degradation rule). In the
# kernel's own checkout the surfaces exist and the gates run; the skips fire only
# in a composed consumer tree.
SKIPPED_KERNEL_GATES=()

# Kernel self-distribution / self-update gates — CLASS-gated (temperloop#691,
# generalizing the per-test temperloop#488 pattern to a per-CLASS one). These
# test how the kernel BOOTSTRAPS, RENAME-migrates, VERSION-embeds, and
# SELF-UPDATES a fresh install of ITSELF (bin/bootstrap.sh, the `foundation`
# rename shim, the repo-root VERSION file, bin/subcommands/update.sh). A
# bespoke-subtree vendoring consumer carries none of that surface — it pulls the
# kernel through its own `make update-kernel` subtree flow, and its composed tree
# presents the kernel's dirs as symlinks the self-update CLI's
# `git show <ref>:<path>` cannot traverse. Rather than guard each test on its own
# surface probe (which silently drifts the moment a new self-distribution test is
# added without one), gate the whole CLASS on ONE signal: a repo-root
# `.kernel-pin` marks a vendoring consumer (the kernel's own checkout has none),
# so a new self-distribution test joins this list and is excluded from every
# consumer for free.
SELF_DISTRIBUTION_GATES=(
  "bash workflows/scripts/tests/test_rename_compat.sh"
  "bash workflows/scripts/tests/test_bootstrap_tag_pinning.sh"
  "bash workflows/scripts/tests/test_version_embedding.sh"
  "bash workflows/scripts/tests/test_update_subcommand.sh"
)
if [[ ! -f "$REPO_ROOT/.kernel-pin" ]]; then
  # Kernel's own checkout (no .kernel-pin) — full self-distribution coverage.
  KERNEL_GATES+=("${SELF_DISTRIBUTION_GATES[@]}")
else
  # Vendoring consumer (repo-root .kernel-pin present) — no self-distribution surface.
  for _sd_gate in "${SELF_DISTRIBUTION_GATES[@]}"; do
    SKIPPED_KERNEL_GATES+=("${_sd_gate#bash workflows/scripts/tests/} — kernel self-distribution gate (vendoring consumer, .kernel-pin present)")
  done
  unset _sd_gate
fi
# scripts/update-kernel.sh's own breaking-delta gate (temperloop#89) —
# black-box regression proof that lifting semver_major()/breaking_sections()
# into workflows/scripts/lib/changelog.sh (temperloop#429) didn't change this
# script's behavior. Applies only to the kernel's seam-bearing version of the
# script (detected by its KERNEL_UPDATE_ROOT test seam); a consumer whose
# overlay replaces update-kernel.sh with its own vendoring flow is not the
# script under test.
if grep -q 'KERNEL_UPDATE_ROOT' "$REPO_ROOT/scripts/update-kernel.sh" 2>/dev/null; then
  KERNEL_GATES+=("bash scripts/tests/test_update_kernel.sh")
else
  SKIPPED_KERNEL_GATES+=("test_update_kernel.sh — scripts/update-kernel.sh is not the kernel's seam-bearing version (overlay-owned vendoring flow)")
fi
# Checkout-freshness guard (temperloop#591): the staleness warning this script
# itself emits (check_checkout_freshness below) — the one that turns a silent
# "green locally, red in CI" from a stale checkout into a loud, non-fatal banner.
# Hermetic: throwaway git repos with a bare origin, no network. Same direct-`bash`
# form as the update-kernel gate above (kernel Makefile is generator-owned).
KERNEL_GATES+=("bash scripts/tests/test_quality_gates_freshness.sh")

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
  if [[ ${#SKIPPED_KERNEL_GATES[@]} -gt 0 ]]; then
    for skip in "${SKIPPED_KERNEL_GATES[@]}"; do
      printf '[skipped] %s\n' "$skip"
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

# --- Checkout-freshness guard (temperloop#591) --------------------------------
# This script runs whatever gate LIST the checked-out tree contains, and the
# diff-scoped gates (the PR leak guard) diff against origin/<default>. So a
# checkout that is BEHIND origin/<default> silently runs a SMALLER gate set than
# CI (which checks out the PR's merge with current main) and scans a stale/empty
# leak-guard diff — a green run here then does NOT imply green CI. That exact
# trap cost a 12-item /sweep four post-push CI round-trips (the knob-registry /
# denylist / leak-guard gates the stale local run never exercised). The guard
# (in the sourced lib) turns that silent divergence into a LOUD but NON-FATAL
# banner: a stale checkout is sometimes legitimate (offline work, deliberately
# testing an old commit), so it never fails the run — it only refuses to let
# staleness pass unseen. build-level.mjs's own worker worktrees branch off a
# freshly-fetched origin/<default> (worktree.sh create), so they report 0-behind
# and the guard stays silent on that hot path. QUALITY_GATES_SKIP_FRESHNESS=1
# disables it. It sets CHECKOUT_BEHIND / CHECKOUT_BEHIND_REF (re-surfaced in the
# end-of-run summary below).
CHECKOUT_BEHIND=0
CHECKOUT_BEHIND_REF=""
# shellcheck source=workflows/scripts/lib/checkout-freshness.sh
source "$REPO_ROOT/workflows/scripts/lib/checkout-freshness.sh"
check_checkout_freshness "$REPO_ROOT"

# Name every surface-conditional gate that did not register (temperloop#488)
# up front, so a composed consumer tree's run shows the skip explicitly.
if [[ ${#SKIPPED_KERNEL_GATES[@]} -gt 0 ]]; then
  for skip in "${SKIPPED_KERNEL_GATES[@]}"; do
    printf 'skipped gate — %s\n' "$skip"
  done
fi

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
# Re-surface the staleness warning at the END too (temperloop#591): a 75-gate run
# scrolls the top banner far off-screen, and the whole point is that the operator
# does not trust a green result from a stale checkout — so repeat it next to the
# pass/fail verdict where the decision is actually made.
if (( CHECKOUT_BEHIND > 0 )); then
  printf 'REMINDER: this run was against a checkout %s commit(s) behind %s — a green result here does NOT guarantee green CI (temperloop#591). Rebase/pull before trusting it.\n\n' \
    "$CHECKOUT_BEHIND" "$CHECKOUT_BEHIND_REF" >&2
fi
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
