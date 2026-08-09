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
# / build / install / telemetry / sessions test suites, the Capture/Backstop +
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
#     integration, the pipeline cost-rollup, or the workflow-eval corpus).
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
# DIFF-SCOPED SELECTION (temperloop#1024): on a GitHub `pull_request` event with
# a resolvable base SHA, the run is narrowed to the gates the diff can affect,
# per workflows/scripts/config/gate-paths.tsv. Everywhere else — merge_group,
# push:main, nightly, /build's 3e.5 gate, any local run — the FULL set runs
# exactly as before, so what gates `main` is unchanged. See the "Diff-scoped
# gate selection" block below and workflows/scripts/lib/gate-selection.sh.
# PARALLELISM (temperloop#1025): the gate set is ~109 INDEPENDENT suites, and
# the `checks` job's ~5.5 min wall time was almost entirely the cost of running
# them one after another (measured 2026-08-02: test-cli-subcommands 56s, test-build 55s,
# the whole-tree shell lint 29s, test-board 21s, prose-budget ~20s, then a long
# tail of 1–5s suites — no dominant gate, only concurrency recovers it). They run
# through a bounded worker pool (workflows/scripts/lib/gate-pool.sh) instead of
# a bare `for` loop. Three things are deliberately unchanged:
#
#   * the gate LIST and the pass/fail SEMANTICS — the same commands run, every
#     failure is still collected (no fail-fast), and the run still exits
#     non-zero iff at least one gate failed;
#   * the LOG SHAPE — each gate's output is replayed whole, in list order, under
#     the same `=== <gate> ===` header, so a failing suite is exactly as easy to
#     find as before;
#   * the CI JOB — still ONE job. This is a within-job pool, NOT a build matrix:
#     splitting `checks` into a matrix would rename/multiply the required status
#     context (`checks (ubuntu-latest)`) and silently un-gate the branch.
#
# $QUALITY_GATES_JOBS controls the worker count (`auto` = detected cores, capped;
# `1` restores the exact pre-parallel serial loop, which is what a bisect or a
# flake hunt should use).
#
# CHANGED-FILE SCOPING FOR A LOCAL, MID-WORK RUN (temperloop#957): `--scoped`
# applies the same selector to the LOCAL working tree — committed, staged,
# unstaged and untracked changes vs. the default-branch merge-base — so a
# /build item worker's ITERATIVE verification runs only the gates its own
# changes can reach. It is a fast-feedback mode ONLY: /build's §3e.5 parent-side
# acceptance gate and every pre-push/CI invocation stay BARE and repo-wide, and
# a `--scoped` run says loudly, in three places, that it is not a full run.
#
# Usage:
#   scripts/quality-gates.sh          run the applicable gate set; exit non-zero if any fail
#   scripts/quality-gates.sh --list   print "[layer] command" for every gate (always the FULL set)
#   scripts/quality-gates.sh --list-selected
#                                     print the gate set THIS invocation would run,
#                                     with the one-line selection reason (dry run)
#   scripts/quality-gates.sh --scoped run only the gates the LOCAL working-tree
#                                     changes reach, plus the always-run floor
#                                     (combinable with --list-selected)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The kernel static gate set — the ONE place this list is typed. Order
# mirrors CI's `checks` job (pre-layering order, minus the now-overlay
# entries). Each entry is a full command line (a `make` target).
KERNEL_GATES=(
  "make test-board"
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
  # Write-jail guard COVERAGE-LOSS gate (foundation#1367). Runs
  # build-worktree-guard.sh's working copy and origin/main's copy over the same
  # synthetic PreToolUse payloads and fails on any `old=DENY new=allow`. This is
  # a different question from `make test-hooks`: the DENY/ALLOW corpus proves the
  # guard does what the corpus SAYS, and provably cannot prove it still does what
  # it USED to do — a refactor that loses coverage arrives with a corpus that
  # ratifies the loss. Not hypothetical: the first cut of the operand-model table
  # shipped 80/80 corpus-green over SIX un-denied shapes, one of which the corpus
  # pinned as intended ALLOW, and among them was the F#932 command that wiped
  # ~/dev, wearing a `find` hat.
  #
  # A DIRECT `bash` gate, not a `make` target, per the kernel-Makefile-is-
  # generator-owned convention the gates below already follow; and deliberately
  # NOT renamed into `make test-hooks`'s `test_*.sh` glob, so a coverage-loss
  # failure gets its own attributable gate line instead of vanishing inside one
  # `[ok] test-hooks`. It compares against `origin/main` — for this repo that IS
  # the PR base (every PR targets main, merge-queue included), so no CI-aware ref
  # selection is needed. The ref is present because check_checkout_freshness
  # (below) fetches it before any gate runs, CI checks out with fetch-depth: 0,
  # and the harness carries its own bounded fetch fallback.
  "bash claude/hooks/tests/differential-guard-vs-ref.sh"
  "make test-install"
  # Compose-plane T0 inventory (temperloop#235, ADR §2.5 capture point 3):
  # workflows/scripts/install-claude-md.sh's regenerated set of
  # knowledge-store notes reachable from the composed CLAUDE.md's own
  # rules — wikilink + backtick-literal store-path extraction, dedup,
  # sort, idempotence, and the empty-store no-error path. Same direct-
  # `bash` form as the setting-registry gates below (kernel Makefile is
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
  # Knowledge-store root split-brain guard (foundation#1332):
  # workflows/scripts/install/doctor.sh's check_knowledge_root() — resolves
  # two independent planes (script-plane via build.config.sh, bare-env via
  # knowledge_store.sh alone) and fails when they disagree, replacing a
  # prior self-comparison whose MISMATCH branch was unreachable dead code.
  # Same direct-`bash` form as the sibling doctor/reviewer gates above
  # (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_doctor_knowledge_root.sh"
  # Cross-checkout install-source split guard (temperloop#777): doctor.sh's
  # check_cross_checkout_split() — the CROSS-checkout counterpart to
  # check_knowledge_root() above. #774's plane-A/plane-B comparison is
  # scoped to the checkout doctor runs from and cannot see ~/.claude itself
  # resolving into a DIFFERENT checkout; this resolves the representative
  # installed surface (~/.claude/hooks/session-start-drain.sh) to its real
  # path, asks git which checkout owns it, and reports a MISMATCH naming
  # both real paths and both .kernel-pin tags when it differs from
  # $FOUNDATION. Same direct-`bash` form as the sibling doctor gates above
  # (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_doctor_cross_checkout_split.sh"
  # Legacy host-config preflight (temperloop#908): workflows/scripts/install/
  # legacy-host-preflight.sh's registry-driven HOST-STATE check — asserts the
  # CONSUMABLE ON THE HOST for a legacy path a release has removed, never the
  # repo artifact that merely describes it — plus its wiring into doctor.sh's
  # check_legacy_host_config(). Covers both instances that motivated it
  # (foundation#1419's stranded funnel-cron.plist, temperloop#165's
  # unmigrated legacy boards.conf) via RECONSTRUCTED fixtures, the graceful
  # ABSENT degradation, and a regression case (a header comment naming the
  # installer script must not false-positive the content match). Same
  # direct-`bash` form as the sibling doctor gates above (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_legacy_host_preflight.sh"
  "make test-install-links"
  "make test-install-worktree-guard"
  # Machine-scoped testbed artifact record (temperloop#1117 Produces 4,
  # temperloop#1227): workflows/scripts/testbed/record.sh's append-only,
  # per-step-atomic-flush record of everything a `temperloop testbed` run
  # creates, including the source_kind/source_repo/promotable provenance
  # fields promotion reads two levels later. Library-only, no CLI caller yet
  # — same shape as install-manifest-lib above, but a real `make` target
  # rather than the sibling gates' direct-`bash` form.
  "make test-testbed-record"
  "make test-prune-branches"
  "make validate-capture-backstop"
  "make validate-command-run-emit"
  # command-run emitter BEHAVIOUR (temperloop#1084) — validate-command-run-emit
  # above lints PRESENCE only. This covers the `--resolved` disposition count,
  # the `merged + resolved + parked == items_processed` assertion (loud
  # non-zero exit, record still appended), the warn-and-exit-0 infrastructure
  # arm, the absent-means-UNKNOWN caveat in the sink spec, and the
  # presence-lint's own red/green behaviour against a tampered fixture tree.
  # Same direct-`bash` form as the sibling emitter gates (the kernel Makefile
  # is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_command_run_emit.sh"
  "make validate-issue-touch-emit"
  # model-usage attribution-stream emit + its CONTENT-LEVEL validator
  # (temperloop#1253, epic #1225, ADR 0026/0028): emit-model-usage.sh is the
  # per-spawned-seat record (seat/model/provider/token counts/duration/
  # outcome ref); validate-model-usage-emit.sh schema-validates records at
  # CONTENT level — model-family and ADR-0028-provider-allowlist ENUMS, not
  # merely presence — via a STRICT (NaN/Infinity-rejecting) python3 parse,
  # never jq (which silently coerces non-finite constants). GATE SCOPE: this
  # item ships the emit/validate pair and its schema ONLY — spawn-site
  # coverage (wiring the three emit-feasible seats) is the LATER
  # attribution-spawn-site-wiring item (temperloop#1255); an absent/empty
  # stream is legal here, exactly like validate-provider-disclosure.sh's
  # own "absent disclosure log is legal" precedent. Direct `bash` form, no
  # Makefile target, matching the validate-provider-disclosure.sh gate
  # below (kernel Makefile is generator-owned).
  "bash workflows/scripts/validate-model-usage-emit.sh"
  "bash workflows/scripts/tests/test_model_usage_emit.sh"
  "make validate-diagnose-queue-emit"
  # diagnose-queue lake-stream emit (temperloop#1192) — gate.sh's
  # cmd_diagnose_queue computes a merge-queue verdict /build and /fix branch
  # merge decisions on, then routes every exit path (including its own
  # internal die() error paths) through the sibling emit script
  # (emit-diagnose-queue.sh). validate-diagnose-queue-emit above lints
  # PRESENCE of the wiring (library code, no markdown orchestration — the
  # validate-knowledge-search-emit mold, not the validate-issue-touch-emit
  # one). This covers the emit script's own record shape, arg validation,
  # and warn-and-exit-0 infrastructure arm, plus the presence-lint's
  # red/green behaviour against a tampered gate.sh. Same direct-`bash` form
  # as the sibling emitter gates.
  "bash workflows/scripts/tests/test_diagnose_queue_emit.sh"
  # Kernel telemetry-brief renderer (temperloop#431): the five-question brief
  # rendered from kernel-only raw streams, wired into claude/commands/
  # check-in.md Part 1 — fixture-lake render reconciliation, empty-stream
  # "no data yet" degradation, stale-window honesty, torn-line resilience,
  # and the check-in.md wiring presence check. Same direct-`bash` form as
  # the T0-inventory/manifest gates above (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_telemetry_brief.sh"
  # model-comparison: restricted candidate-session overlay + provider-key
  # health check (temperloop#1252, epic #1225 "model comparison harness").
  # Asserts the settings overlay's EFFECTIVE tool surface via real
  # deny-over-allow glob matching (not a grep for JSON key presence) —
  # every knowledge-store/vault MCP namespace and every path/command
  # reaching the host-secrets file denied, the ordinary replay surface
  # still reachable; a provider key present at spawn reaches the spawned
  # child and is absent from the parent process and from everything this
  # script itself emits; an unset non-default provider key fails LOUDLY at
  # pre-flight, naming the exact env var and the host-supply file; the
  # default (no candidate provider) path is a no-op. `make
  # test-candidate-session` so the activation-registry proof
  # (`grep -q 'test-candidate-session' scripts/quality-gates.sh`) matches.
  "make test-candidate-session"
  # check-in.md Part 2 Status-line trailing-newline safety (temperloop#853,
  # the agent-plane half of foundation#1308 — the store-seam half, ks_append's
  # own fresh-line-on-append guarantee, is covered by test_knowledge_store.sh
  # below and deliberately untouched here). Pins the guard command check-in.md
  # now requires after every Status-line Edit: it restores a missing trailing
  # newline, is a true no-op on an already-terminated file, and — composed
  # with a subsequent append — prevents the named corruption (a `### heading`
  # glued mid-line onto an unterminated Status line, invisible to any
  # `^### `-anchored scan). Same direct-`bash` form as the sibling test gates
  # above (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_checkin_status_trailing_newline.sh"
  # /build Step 0a's two-arm plan-approval drain + /check-in's strand probe
  # (foundation#1496). Pins the narrowed hybrid over the full 2x2 of
  # {attended, operator-absent} x {answered, unanswered}: both arms apply an
  # answered `approve` and set the plan's `status: approved`, but ONLY the
  # operator-absent arm may invoke `/build --unattended` — an attended tick
  # reports and stops (docs/principles.md § 7 Bound the blast radius). A
  # replay under the PRE-FIX absent-only gate reproduces the reported strand,
  # so the suite fails if the gate is ever narrowed back. Same direct-`bash`
  # form as the sibling test gates above (kernel Makefile is generator-owned;
  # no new target added here).
  "bash workflows/scripts/tests/test_plan_approval_drain.sh"
  "make validate-lexicon"
  # Message-template reference-integrity + registry-completeness lint
  # (temperloop#94, plan item `template-lints`): every by-name template
  # reference in claude/CLAUDE.kernel.md / claude/commands/*.md resolves to a
  # template claude/message-schema.md § Templates actually defines; any
  # overlay override name (when an overlay message-schema is present) does
  # too; and every contract-frozen row in claude/presentation-plane.md's
  # kernel table names a resolvable owner file/section — the
  # validate-capture-backstop.sh mold applied to the presentation-plane registry.
  "make validate-template-refs"
  # Its fixture suite (temperloop#928, plan item
  # `decision-presentation-template`): proves the NON-OVERRIDABLE template set
  # in BOTH states — RED on an overlay redeclaring an excluded template
  # (`### Decision presentation`), GREEN on the tree and on an overlay
  # redeclaring a sanctioned one. The gate above only ever runs the green
  # arm (this repo ships no overlay), so without this suite the exclusion
  # that makes claude/CLAUDE.kernel.md's overlay carve-out bounded would be
  # shipped unproven. Same direct-`bash` form as the sibling test gates above
  # (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/tests/test_validate_template_refs.sh"
  # Class-A "static-second-surface" activation-registry lint (temperloop
  # plan item activation-registry-validator, Class-A subset of the
  # activation-completeness contract, temperloop#317 Level 1): the
  # validate-capture-backstop.sh mold applied to Plans-archive/*.md's `activation:`
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
  # bash-3.2 hidden-apostrophe guard + its regression (temperloop#1098). Same
  # direct-`bash` form and same reason as the zsh-tie pair above. An apostrophe in
  # a `#` comment inside a `$( ... )` makes bash 3.2 — every macOS /bin/bash —
  # swallow the closing paren; doctor.sh shipped exactly that to `main` and was
  # completely non-functional on macOS while staying green here. Nothing already
  # in this list could have caught it: shellcheck exits 0 on the pattern, and a
  # `bash -n` gate would too, because bash 4.0 fixed the bug and the pre-merge leg
  # is ubuntu-only (temperloop#963) with no bash 3.2 installable from apt. Hence a
  # STATIC lint that recognises the pattern textually, so it fires the same on
  # ubuntu bash 5.2 as on macOS. Its test asserts the lint rejects the actual
  # pre-fix doctor.sh — a lint never shown to fire on the known-bad input is the
  # very failure #1098 is about.
  "bash scripts/lint-bash32-cmdsubst-comment.sh"
  "bash scripts/tests/test_lint_bash32_cmdsubst_comment.sh"
  # Piped `grep -q` guard + its regression (temperloop#1050). Same direct-`bash`
  # form and same reason as the two pairs above. `grep -q` exits at its FIRST
  # match without draining the pipe, so the writer upstream takes SIGPIPE and,
  # under `set -o pipefail`, the pipeline reports 141 even though grep matched —
  # a RACE, so such a line passes for months and then fails once under a longer
  # input. Nothing already in this list covers it: shellcheck has no check for
  # the shape (SC2143 is the adjacent `$(... | grep -c)` smell) and no runtime
  # test can reliably observe a race. Hence a STATIC lint, over the WHOLE tracked
  # shell set with NO pipefail predicate — a sourced lib sets no `set` line and
  # inherits pipefail from its caller, which is precisely how
  # workflows/scripts/lib/issue-marker-probe.sh hid a live site. Its test asserts
  # the lint rejects the actual pre-sweep bin/subcommands/init.sh line, and that
  # it stays silent on a comment that merely names the shape.
  "bash scripts/lint-pipe-grep-q.sh"
  "bash scripts/tests/test_lint_pipe_grep_q.sh"
  # Main knowledge_store interface + plain-files backend suite (foundation
  # #771) — root resolution, doc-id normalization, write/read round-trip,
  # --no-clobber, atomic write, list, and (temperloop#1308) the ks_append
  # trailing-newline guarantee's conditional insert/no-op cases. Previously
  # ungated on its own (only reachable indirectly via test_stranger_config.sh's
  # clean-subshell rerun). Zero network, throwaway tmpdir. Same direct-`bash`
  # form as the zsh-tie gate above (kernel Makefile is generator-owned).
  "bash workflows/scripts/lib/tests/test_knowledge_store.sh"
  # Obsidian backend suite for the same interface (foundation #775) — mocked
  # curl subprocess (_ks_backend_obsidian_curl override), zero network, never
  # a real vault/REST endpoint. Gated alongside test_knowledge_store.sh above
  # so the trailing-newline guarantee's backend split (enforced in
  # plain-files, inherited/documented-not-enforced in obsidian per
  # knowledge_store.contract.md) is proven on both sides in the same run —
  # in particular this suite's byte-exact POST-payload assertion is what
  # confirms the guarantee lives in the plain-files backend only, never at
  # dispatch. Same direct-`bash` form as the gate above.
  "bash workflows/scripts/lib/tests/test_knowledge_store_obsidian.sh"
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
  # Presence-lint for ks_search's read-log OUTCOME-field emit (foundation#1449,
  # epic foundation#1443 "obs-outcome-emit"): validate-knowledge-search-emit.sh
  # — the validate-issue-touch-emit.sh mold applied to a pure-library emit (no
  # markdown orchestration step to guard here; see that script's own header).
  "make validate-knowledge-search-emit"
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
  # token_sum.sh (temperloop#828, epic #810 "realized-session-context
  # probe"): the ONE shared jq expression claude/status-line.sh's "Tokens:
  # NNk" display and workflows/scripts/emit-session-context.sh's SessionEnd
  # emit both call, so the displayed and recorded figures can't drift
  # apart. Covers the sum itself (missing fields default to 0; missing/
  # empty/malformed transcripts degrade to "0") plus the STRUCTURAL privacy
  # guarantee: a synthetic transcript with recognizable prose content still
  # sums to exactly the expected total, and a static grep proves the
  # filter's only selector is `.message.usage` (never `.message.content`/
  # `.message.role`). Same direct-`bash` form as the command-declared gate
  # above (kernel Makefile is generator-owned; no new target added here).
  "bash workflows/scripts/lib/tests/test_token_sum.sh"
  # emit-session-context.sh (temperloop#828, epic #810): the
  # realized-session-context probe's raw-lake emit — print-only one-off
  # reading vs. normal append-to-lake mode, record shape (schema_version/
  # ts/session_id/host/project/cwd/transcript_tokens_total/
  # context_window_size/context_window_remaining_pct), missing-transcript
  # and unknown-arg tolerance (warn, never fail, always exit 0), the
  # valueless/flag-shaped-value arg guard (a trailing `--transcript` used to
  # spin forever — `shift 2` fails silently when n > $#), and the same
  # STRUCTURAL privacy proof as token_sum.sh's own suite, at this script's
  # own call boundary. Same direct-`bash` form as the sibling lib-tests
  # gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/tests/test_emit_session_context.sh"
  # status-line.sh token_sum resolution (temperloop#828, epic #810): pins the
  # INSTALL SHAPE the two suites above structurally cannot see. They invoke
  # through real checkout paths; the production status line is a PER-FILE
  # symlink in the real ~/.claude (links.sh's `for f in claude/*` loop), where
  # a bare BASH_SOURCE climb escapes to $HOME/workflows/scripts/lib and pinned
  # the displayed "Tokens:" at 0 for every installed user while the recorded
  # figure stayed correct — the exact inversion of this feature's
  # can't-drift-apart contract. Covers the file-symlink and multi-hop cases,
  # the TOKEN_SUM_LIB_DIR override, and that an unreachable helper renders
  # "--" while a genuine zero still renders "0".
  "bash workflows/scripts/tests/test_status_line_token_resolution.sh"
  # Pipeline spend profiler + its kernel-side `tokens` report.d producer
  # implementation at workflows/scripts/report-producers/tokens (temperloop#958;
  # temperloop#980 "producer-kernel-side-relocation" moved the implementation
  # here from .temperloop/report.d/tokens, which is now a locator + exec shim
  # tested separately by bin/subcommands/tests/test_tokens_producer.sh, part
  # of the make test-cli-subcommands gate below). The load-bearing check is the requestId
  # DEDUPE fixture: one API response split across three transcript lines that
  # each repeat the same `usage` block must yield ONE call and the undoubled
  # total — summing per line inflated the temperloop#953 corpus 2.16x, and a
  # regression there would silently double every spend figure this tool feeds
  # `temperloop report`. Also pins the two "never do this" traps by static
  # grep (no weight literal in the script body — the weights are settings; no
  # tool-call-parallelism metric, which the transcript format structurally
  # cannot support) and the producer's exit-0 `skipped -- tokens: producer
  # unavailable` degradation. Synthetic fixtures in a tmpdir; never reads the
  # operator's real ~/.claude corpus, zero network. Same direct-`bash` form
  # as the sibling gates above (kernel Makefile is generator-owned; no new
  # target added here).
  "bash workflows/scripts/tests/test_pipeline_spend_report.sh"
  # Per-merged-item efficiency emit (temperloop#943):
  # workflows/scripts/emit-item-efficiency.sh — the overhead-per-shipped-change
  # record written at build.md's 4d merge seam (tokens by phase, wall-clock by
  # leg, agent counts by role), plus the per-class raw_tokens/wall_ms/api_calls
  # fields it reads out of the spend profiler above. The load-bearing check is
  # COMPOSITION: each token figure in a record must equal the corresponding
  # field of `pipeline-spend-report.sh --format json` over the same run filter,
  # asserted against live profiler output AND re-proved through the profiler's
  # own duplicated-usage fixture — so the dedupe-by-requestId trap is shown to
  # survive composition rather than being silently re-derived (and re-broken)
  # here. Also pins the "an unmeasured leg is null, never 0" contract, the
  # exit-0 degradations (no profiler / no gh / no slug), and the build.md 4d
  # wiring presence check (folded in here rather than shipped as a fourth
  # near-identical validate-*-emit.sh script). Synthetic fixtures in a tmpdir;
  # never reads the operator's real ~/.claude corpus; `gh` is stubbed, never
  # called. Same direct-`bash` form as the sibling gates above.
  "bash workflows/scripts/tests/test_item_efficiency.sh"
  # Comparison-statistics library (temperloop#1249, epic #1225 "model
  # comparison harness"): bootstrap CI known-answer fixture, the minimum
  # detectable effect at two N (kept distinct from the CI margin of error),
  # the inconclusive floor asserted at the threshold boundary in BOTH
  # directions and on BOTH subcommands, non-finite input rejection, and
  # coverage % against the emit-feasible seat denominator (temperloop#1246).
  # Zero network, zero model calls. The fixtures are cross-version
  # reproducible because stats.py draws from Random.random() (the only
  # CPython method documented as sequence-stable) and accumulates with
  # math.fsum — NOT merely because the RNG is seeded: builtin sum() switched
  # to compensated summation in CPython 3.12 (gh-100425), which moved the
  # reported bound and failed this suite on 3.9 until fsum replaced it.
  "make test-model-comparison-stats"
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
  # `changelog.d/` per-entry fragments + the release-time assembler
  # (temperloop#1321, epic #1299): scripts/assemble-changelog.sh folds one
  # file per changelog entry into CHANGELOG.md's `## [Unreleased]` at the cut,
  # so two concurrent PRs write DISJOINT files and can no longer collide on
  # the single hotspot file 25 of the last 25 commits touched. The suite's
  # load-bearing legs run against the REPO'S OWN CHANGELOG.md: no fragments
  # leaves it byte-identical, and a merge over the real (non-empty)
  # `[Unreleased]` body removes not one line and leaves
  # changelog_breaking_sections()/_sections_in_range()/_version_headings()
  # byte-stable — the downstream BREAKING acknowledgment contract. Same
  # direct-`bash` form as the changelog-lib gate above.
  "bash scripts/tests/test_assemble_changelog.sh"
  # Setting registry (temperloop#164/#169 D2): parse/union tests for
  # workflows/scripts/config/setting-registry-lib.sh — parses the real kernel
  # TSV clean, unions a synthetic overlay fixture (add + redefault rows),
  # and rejects malformed rows (bad field count, unknown type, an overlay
  # add/kernel-name collision, an orphaned redefault). Same direct-`bash`
  # form as the knowledge_search gates above (new workflows/scripts/<dir>
  # lib, no Makefile target needed — the kernel Makefile is generator-owned).
  "bash workflows/scripts/config/tests/test_setting_registry.sh"
  # Registry-driven config lints (temperloop#164/#169, item
  # registry-config-lints, D2/D3). Two live lints + their fixture suites,
  # mirroring test-kernel-denylist's live-check-then-fixture-tests shape as
  # direct `bash` gates (kernel Makefile is generator-owned, same as the
  # setting-registry gate above):
  #   - check-setting-registry.sh: layer-aware registry↔shell equality lint +
  #     unregistered-setting sweep. NO baseline — strictly green on the
  #     committed tree by construction (the registry records the literals
  #     verbatim); a red run is real drift or a missing registry row.
  #   - check-setting-prose.sh: D3 "prose names settings, never values" lint over
  #     claude/commands/*.md + claude/CLAUDE.kernel.md, with the
  #     <!-- setting-prose:allow --> marker and a burn-down baseline
  #     (setting-prose-baseline.tsv) the prose-tunables-migration item empties.
  "bash workflows/scripts/config/check-setting-registry.sh"
  "bash workflows/scripts/config/tests/test_check_setting_registry.sh"
  "bash workflows/scripts/config/check-setting-prose.sh"
  "bash workflows/scripts/config/tests/test_check_setting_prose.sh"
  # v0.17.0 terminology-rename legacy window, CLOSED in v0.19.0
  # (temperloop#767): the env shim, the forwarding stubs at the old script
  # paths, the source-forwarder, and the pre-rename overlay-filename read are
  # deleted. This gate is the window-STAYS-SHUT regression test — a
  # pre-rename env name must bind nothing and say nothing, and no window file
  # may reappear. Its lockstep sibling is `make test-kernel-terminology`
  # below, which owns the identifier-leak half.
  "bash workflows/scripts/tests/test_terminology_rename_compat.sh"
  # Reviewer-routing extension/glob-axis drift lint (ADR 0008,
  # docs/adr/0008-reviewer-routing-tsv-extension-axis-scope.md): compares the
  # extension/glob SET between workflows/scripts/config/reviewer-routing.tsv
  # (the single source of truth for that axis, including docs/**) and
  # claude/commands/build.md's 3e routing prose — a tsv key's literal
  # backtick-quoted form reappearing in the prose fails, catching a silent
  # reintroduction of the old inline extension list. Same direct-`bash`
  # form, same check-setting-prose.sh shape, as the two gates above.
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
  # setting-registry gates above (kernel Makefile is generator-owned).
  "bash workflows/scripts/validate-feature-docs.sh"
  "bash workflows/scripts/tests/test_validate_feature_docs.sh"
  # Provider allowlist / disclosure-log pairing gate (temperloop#1250, epic
  # #1225, ADR 0028): validate-provider-disclosure.sh owns log-format
  # validity and allowlist-membership checking — the committed ceiling is
  # git-tracked and repo-scoped, a personal override may only narrow it
  # (never widen), and the append-only disclosure log's hash chain must be
  # intact. The send-vs-log coverage cross-check is deliberately NOT here
  # (owned by the later replay-execute-and-score item — see that script's
  # own header). Direct `bash` form, no Makefile target, matching the
  # validate-feature-docs.sh gate immediately above.
  "bash workflows/scripts/validate-provider-disclosure.sh"
  # ...and its fixture suite. BOTH halves are registered, exactly as the
  # validate-feature-docs.sh pair two lines above does: this repo enumerates
  # its test-suite gates explicitly (there is no auto-discovery here), so a
  # suite that is not typed in this list NEVER RUNS IN CI — which is how the
  # first cut of this module shipped a green fixture suite that gated nothing
  # at all, and let eight mutations of the very guarantees it claimed to
  # cover survive untouched.
  "bash workflows/scripts/model-comparison/tests/test_allowlist.sh"
  # Replay corpus selection + isolated replay worktree (temperloop#1254,
  # epic #1225 "model comparison harness"): replay.sh selects eligible
  # closed-issue + merged-PR pairs from this repo's own history (real `gh`
  # reads at run time; the fixture suite stubs `gh` and builds its own
  # throwaway git fixture repo — zero network, per kernel principle 3) and
  # prepares/tears down the isolated replay worktree on top of
  # workflows/scripts/build/worktree.sh's UNMODIFIED lifecycle (create, then
  # rewind — see Context/temperloop - replay ground-truth seam.md). This
  # item ships corpus selection + isolation + the scored-record schema only;
  # replay EXECUTION and scoring are the later replay-execute-and-score item
  # (#1258). Same direct-`bash` form, no Makefile target, as the
  # test_allowlist.sh gate immediately above.
  "bash workflows/scripts/model-comparison/tests/test_replay_isolation.sh"
  # Replay pre-flight estimate + per-comparison ceiling (temperloop#1256,
  # epic #1225 "model comparison harness"): replay.sh's `preflight`
  # subcommand — the spend gate that prints eligible-N, a batch-cap-bounded
  # cost estimate (token_count cost basis; this module states no dollar
  # figure), and significance reachability via stats.sh's own `mde`
  # primitive (never a second, hand-rolled computation of it), BEFORE any
  # replay token is spent. Fails CLOSED (CANNOT_EVALUATE, non-zero) on an
  # absent/unreadable/empty/malformed corpus file or an unreachable stats
  # primitive; STOPS (non-zero) a batch whose projected cost exceeds
  # REPLAY_PREFLIGHT_CEILING_TOKENS or while
  # workflows/scripts/build/quota-gate.sh reports "pause" — the explicit
  # quota-gate consult this item requires, proven by a fixture, never
  # assumed. A companion fixture proves no scheduled/cron/autonomous entry
  # point (pipeline-cron.sh/pipeline-tick.sh/pipeline-drive.sh/
  # pipeline-schedule-gate.sh) references replay.sh — replay batches stay
  # operator-initiated only. Zero network, zero live model call (kernel
  # principle 3). Ships corpus-file-driven ESTIMATION and the ceiling only;
  # replay EXECUTION and scoring remain replay-execute-and-score (#1258).
  # Same direct-`bash` form, no Makefile target, as the
  # test_replay_isolation.sh gate immediately above.
  "bash workflows/scripts/model-comparison/tests/test_replay_preflight.sh"
  # Live candidate tagging provenance (temperloop#1257, epic #1225 "model
  # comparison harness"): tagging.sh's three artifacts — the bounded window
  # record, the telemetry tag (a real emit-model-usage.sh raw-lake record,
  # temperloop#1253/#1255, reused verbatim), and the PR provenance stamp —
  # plus the mechanical THREE-WAY cross-check between them (stamp / window
  # record / telemetry-lake record; provider rides the window record only,
  # since emit-model-usage.sh's own schema forbids a `provider` value under
  # `usage_source: unavailable` — see tagging.sh's own header). Asserts the
  # single most important guarantee directly: a doctored PR stamp that
  # disagrees with the recorded provenance makes crosscheck FAIL, in every
  # direction a disagreement can occur. Also proves NO second
  # model-selection lever exists (`tag` has no `--model` flag; the model is
  # always `SWEEP_WORKER_MODEL`) and that live-tagging designation is
  # governed by the SAME committed provider allowlist file every other
  # provider check in this module reads. Fail-closed on every absent /
  # unreadable / malformed / ambiguous input shape. Same direct-`bash` form,
  # no Makefile target, as the test_replay_preflight.sh gate immediately
  # above.
  "bash workflows/scripts/model-comparison/tests/test_live_tagging.sh"
  # Replay EXECUTION + SCORING (temperloop#1258, epic #1225): `replay.sh
  # execute` running a candidate headlessly inside a prepared replay
  # worktree, `score.sh` turning the result into a schema-complete
  # `replay-record-v1` record (diff, gate outcome, tokens, duration), and the
  # send-vs-log cross-check validate-provider-disclosure.sh gained here — a
  # non-default-provider send with no matching disclosure entry FAILS that
  # validator, the half #1250's own acceptance deferred to this item.
  # Fully HERMETIC: every candidate run is driven through a RECORDED runner
  # seam, `--live` is never passed, and the suite prepends a canary `claude`
  # to PATH and asserts at the end that nothing ever invoked it — with a
  # mutation proof that removing `execute`'s no-runner refusal DOES reach
  # that canary, so the assertion is a measurement rather than a tautology.
  # Also proves the integration-error exclusion (adding integration errors
  # moves NO quality figure) and that every absent / unreadable / empty /
  # malformed input is CANNOT EVALUATE + non-zero rather than a score that
  # was never computed. Same direct-`bash` form, no Makefile target, as the
  # test_live_tagging.sh gate immediately above.
  "bash workflows/scripts/model-comparison/tests/test_replay_score.sh"
  # Prose-plane baseline counter (temperloop#719, item
  # prose-baseline-measurement / #722): count-prose.sh reports the tier-1
  # composed-kernel-authored-render line count (through
  # install-claude-md.sh's INSTALL_CLAUDE_MD_KERNEL_ONLY render-only seam —
  # never a duplicated compose implementation, ADR 0015) plus per-file
  # counts across claude/**/*.md. Its own baseline numbers seed the
  # forthcoming two-tier CI budget gate's caps (item prose-budget-gate);
  # this item ships the counter alone, no gate yet. Fixture suite proves
  # host-determinism — a machine-conf/repo-local-conf fixture that perturbs
  # EPIC_MIN_SUBUNITS/DISPLAY_TZ must not move the tier-1 count — running on
  # both the ubuntu-latest and macos-latest CI legs, same direct-`bash` form
  # as the setting-registry/feature-docs gates above.
  "bash workflows/scripts/count-prose.sh"
  "bash workflows/scripts/tests/test_count_prose.sh"
  # Contributor-manifest structural lint (temperloop#827, epic #810 P1):
  # check-contributor-manifest.sh reconciles workflows/scripts/config/
  # contributor-manifest.tsv (the tracked registry count-prose.sh's
  # SESSION-START CONTRIBUTORS section reads) against the real tree — no
  # duplicate/untracked/malformed row, every frontmatter:description row's
  # file actually carries that field, and every tracked
  # claude/commands/*.md + claude/agents/**/*.md file (plus the root
  # CLAUDE.md pointer) has a row. This is STRUCTURAL only, never a byte
  # budget — Phase A (this epic) ships no cap and nothing here can fail a
  # PR merely for growing the surface; it only fails a manifest that has
  # drifted out of sync with the tree (a new command/agent file added with
  # no row, a row pointing at a path that no longer exists or was never
  # tracked). Same direct-`bash` form as the count-prose gate above.
  "bash workflows/scripts/config/check-contributor-manifest.sh"
  "bash workflows/scripts/config/tests/test_check_contributor_manifest.sh"
  # Two-tier prose-budget gate (temperloop#719, item prose-budget-gate /
  # #725; ADR 0015): validate-prose-budget.sh fails a PR that grows the
  # composed kernel-authored render (tier-1) or any single tracked
  # claude/**/*.md file (tier-2, one uniform per-file cap — never a per-file
  # table) past its cap, via count-prose.sh's own report (never a second,
  # duplicated counting implementation). Caps are seeded as
  # PROSE_BUDGET_TIER1_CAP/PROSE_BUDGET_TIER2_FILE_CAP settings in
  # build.config.sh + their setting-registry.tsv rows, at the FRESH baseline
  # this item measured (338 / 1057 lines) rather than the epic's earlier
  # recorded artifact — main had already drifted a few lines past that
  # artifact by landing time, and seeding from a stale number would have
  # landed this gate red on an unrelated PR on day one. The same gate also
  # owns the CITATION-MARKER presence check (item citation-markers / #724):
  # every registered standing kernel rule's same-line citation marker is
  # reconciled 1:1 against workflows/scripts/config/citation-registry.tsv
  # (grammar/placement: claude/citation-schema.md) — missing, duplicate,
  # unregistered, and malformed markers all fail. Fixture suite proves
  # both a demonstrated tier-2 overage AND the tier-1-only-breach case (a
  # real compose-seam fixture: a scratch clone's install-claude-md.sh
  # patched to inflate the composed render with the per-file table proven
  # byte-identical to the real tree's), plus the failure-message contract
  # (file/count/cap/both remediation paths named). Same direct-`bash` form
  # as the count-prose gate above.
  "bash workflows/scripts/validate-prose-budget.sh"
  "bash workflows/scripts/tests/test_validate_prose_budget.sh"
  # Semantic-redundancy chunker (temperloop#854, half (a) of the P9
  # semantic-redundancy probe split from #830; epic #810 contract amendment
  # P9): chunks the manifest-driven always-loaded surface into rule-sized
  # units and prints them as a JSONL stream (workflows/scripts/
  # chunk-redundancy-surface.md is the format contract half (b), #855,
  # consumes). Phase A scope discipline: no cap, no threshold, no verdict —
  # this gate only proves the chunker itself runs and segments correctly
  # (real-tree happy path, determinism, the boundary rule over a synthetic
  # fixture: headings never become chunks, consecutive top-level bullets
  # with no blank line still split, an indented sub-bullet does not, a
  # fenced code block is opaque), never a judgment about the prose it
  # chunks. Same direct-`bash` form as the count-prose gate above.
  "bash workflows/scripts/chunk-redundancy-surface.sh"
  "bash workflows/scripts/tests/test_chunk_redundancy_surface.sh"
  # Labelled fixture corpus for the same probe (workflows/scripts/config/
  # redundancy-fixtures.json): the structural lint mechanically enforces
  # temperloop#854's own acceptance bullet — every `positive`-labelled pair
  # shares NO common 10-consecutive-word run — rather than leaving it a
  # comment-only claim. `negative` pairs are exempt from that property (a
  # deliberate-pointer/hard-topical-near-miss pair may legitimately share
  # surface language; what matters there is the rationale, not a shingle
  # count). Same direct-`bash` form as the gates above.
  "bash workflows/scripts/config/check-redundancy-fixtures.sh"
  "bash workflows/scripts/config/tests/test_check_redundancy_fixtures.sh"
  # Declared-expiry check (temperloop#831, epic #810 P10, Phase A: measurement
  # only): declared-expiry-check.sh resolves whether a standing rule's own
  # declared expiry — an absolute date, or a named retirement issue, per
  # claude/citation-schema.md's `expires:` marker extension — has PASSED, over
  # the in-scope surface (citation-registry.tsv rows whose file is also a
  # contributor-manifest.tsv row). REPORTS COVERAGE, NOT PRECISION and NEVER
  # FAILS on its own findings (no cap, no gate) — this line runs it every
  # `checks` pass purely so the report stays visible, same convention as the
  # count-prose.sh gate above (a report, not a lint). Degrades legibly (an
  # explicit UNRESOLVED bucket, never a silent drop or a crash) when an
  # issue-form expiry's `gh` call is offline; the date form always resolves
  # with zero network. Fixture suite proves all three of the acceptance's
  # required demonstrations (a date-form and an issue-form known-positive,
  # both flagged EXPIRED; a known-negative future-dated rule, NOT flagged),
  # the surface-scoping intersection, the reads-as-temporary heuristic
  # bucket, the coverage/adoption arithmetic against the pre-registered
  # DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT threshold, and the genuine
  # offline-gh-failure degrade path via a PATH-shadowing fake `gh` binary.
  # Same direct-`bash` form as the count-prose/validate-prose-budget gates
  # above.
  "bash workflows/scripts/declared-expiry-check.sh"
  "bash workflows/scripts/tests/test_declared_expiry_check.sh"
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
  # foundation; see its header), same as the setting-registry/knowledge_search
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
  # ready-pr sweep (temperloop#721): the read-only complete-but-unmerged-PR
  # classifier /tidy's § Ready-but-unmerged PRs step invokes — the backstop half
  # of the orphaned-PR net. Hermetic (stub gh replaying JSON fixtures, stub
  # board lib for the registry seam, no network); also covers the fail-open
  # erroring-repo, nothing-when-clean, and read-only (pr-list-only) contracts.
  "bash workflows/scripts/tests/test_ready_pr_sweep.sh"
  "make lint-pr-body-test"
  # CHANGELOG `## [Unreleased]` completeness gate (temperloop#960): the second
  # diff-scoped gate in this set, alongside test-pr-leak-guard above. Fails a
  # change that touches CONTRACT SURFACE (parsed live out of VERSIONING.md
  # § The contract surface's own table — never a second copy of that
  # definition) but adds nothing under CHANGELOG.md's `## [Unreleased]`, with
  # an EXPLICIT, reason-bearing opt-out (a `no-changelog` PR label, a
  # `Changelog: none` PR-body line, or the same line as a commit trailer).
  # Riding KERNEL_GATES makes it part of the already-required `checks` status,
  # so it gates the PR with no branch-protection reconfiguration and no second
  # required job. Inside CI it enforces on the `pull_request` event only (the
  # opt-out channels are absent from the merge_group/push payloads) and prints
  # a legible skip otherwise; with no resolvable base it skips cleanly, so a
  # push:main / worker / local run stays green. Detection is proven
  # deterministically by the fixture suite on the next line regardless of base
  # — the same live-check-then-fixture-tests shape as the leak-guard and
  # setting-registry gates.
  "bash workflows/scripts/check-changelog-entry.sh"
  "bash workflows/scripts/tests/test_check_changelog_entry.sh"
  "make test-stranger-config"
  # Testbed seed-content tests (temperloop#1230, epic #1117): coherence gate
  # for kernel/workflows/scripts/demo/seed/ — the in-tree fixture project +
  # issue definitions `materialize-from-seed` materializes into the operator's
  # own account (ADR 0025). Zero network; asserts the layout, the issue-file
  # grammar, that every defect the seed's issues claim is still present, and
  # that the seed's own suite ships green. Glob-based, mirroring test-board's
  # kernel coverage (F#836) — it tracks whatever demo tests are vendored.
  "make test-demo"
  # Proposal-PR generator tests (foundation #853, Epic D): subprocess suite
  # for kernel/workflows/scripts/proposal/proposal-pr.sh, fake `gh` on PATH,
  # zero network — mirrors test-board's glob-based kernel coverage (F#836).
  "make test-proposal-pr"
  # Testbed source-provider seam tests (temperloop#1228, epic #1117 Produces
  # 2): sourced-library suite for
  # kernel/workflows/scripts/testbed/source.sh — the four-function seam
  # driven with a double, plus mirror-from-repo against real local git
  # repos (produce_git) and a fake `gh` on PATH (produce_issues), zero
  # network — mirrors test-board's glob-based kernel coverage (F#836).
  "make test-testbed-source"
  # `temperloop testbed` subcommand tests (temperloop#1229, epic #1117
  # Produces 1/3): subprocess suite for bin/subcommands/testbed.sh — the
  # FIRST consumer of both Level 0 testbed seams, so it is where a seam
  # mismatch surfaces. Fake `gh` AND fake `git` on PATH log every call
  # (test_try.sh's wrapper pattern, extended to git because this command's
  # mutating step is a `git push --mirror`), plus a before/after file-tree
  # diff of the source checkout and the XDG state dir for the --dry-run
  # zero-write proof, and record-file snapshots taken AT the push and AT the
  # issue copy for the per-step-flush proof. Zero network. It carries its own
  # gate-paths.tsv row (scoped to bin/subcommands/testbed*.sh AND
  # workflows/scripts/testbed/**) rather than riding test-cli-subcommands' glob, so a
  # change to either consumed seam re-runs its only call site's suite.
  "make test-testbed-command"
  # /promote's commit-carrying branch push (temperloop#1233, epic #1117
  # Produces 6): subprocess suite for
  # workflows/scripts/promote/push-testbed-branch.sh. This is where promotion's
  # OWN structural guarantee lives — it cannot be inherited from
  # test-proposal-pr, because proposal-pr.sh rebuilds a branch off the base tip
  # from a files manifest while promotion transfers real objects. The suite
  # logs every `git` invocation the script makes and asserts the single push's
  # refspec is refs/heads/<branch> and never the target's default branch, on
  # top of a real local-bare-repo push proving commits and authorship survive.
  # Fake `gh` on PATH, zero network — mirrors test-board's glob-based kernel
  # coverage (F#836).
  "make test-promote-push"
  # Provider-equivalence guard (temperloop#1232, epic #1117 Produces 2/3):
  # the epic's central structural claim made mechanical — both source
  # providers, driven THROUGH bin/subcommands/testbed.sh's own driver via two
  # test doubles (never the two real providers; their content differences
  # are test-testbed-source's job), must produce ONE identical seam-call
  # sequence and ONE identical driver step/pre-flight/flush/handoff trace,
  # modulo the source-identity fields that legitimately differ (kind,
  # provenance_capable, promotable) — asserted excluded BY NAME, with a
  # sanity check proving the exclusion is real, not vacuous. This is the
  # guard that stops `materialize-from-seed` from drifting into a second
  # orchestration path, and it deliberately proves identical MECHANISM only,
  # never identical evaluation value (the two sources differ in content,
  # promotability, and privacy exposure by design — see the test's own
  # header and docs/features/testbed.md § Provider equivalence). Zero
  # network. Same rationale as test-testbed-command for a named target
  # (scoped to both the driver AND the seam) rather than riding
  # test-testbed-source's glob alone.
  "make test-testbed-equivalence"
  "make test-kernel-manifest"
  # Subtree-root support for check-kernel-manifest.sh (temperloop#680,
  # derived from foundation#870): synthetic-fixture suite proving the guard
  # accepts a KERNEL_MANIFEST_ROOT that is a subdirectory of an ENCLOSING
  # git checkout with no `.git` of its own (a downstream overlay's vendored
  # kernel/ subtree) — green on a fully-classified subtree, red+named-path
  # on an unclassified one — while the classic own-.git-root invocation
  # (make test-kernel-manifest above) stays unaffected. Same direct-`bash`
  # form as the setting-registry/knowledge_search gates above (kernel Makefile
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
  # DUAL-SHELL portability + fail-closed suite for kernel_lib_classify
  # (temperloop#1177). lib.sh is SOURCED, so its shebang is inert and it runs
  # under whatever shell the caller is — on macOS the agent's Bash tool is zsh,
  # where the pre-#1177 implementation returned EMPTY + rc 1 (bit-identical to
  # "no pattern matched") for EVERY path, silently passing /assess's
  # seam-straddling check and /build 3b's kernel backstop. This suite runs
  # byte-identical asserts under bash, zsh, and macOS bash 3.2 against a
  # KNOWN-KERNEL CONTROL (claude/commands/build.md), and pins the three-way rc
  # contract: 0 classified / 1 no-match / 2 CANNOT EVALUATE. Same direct-`bash`
  # form (kernel Makefile is generator-owned; a new tests/ file needs no new
  # Makefile target).
  "bash workflows/scripts/kernel/tests/test_kernel_lib_portability.sh"
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
  # v0.17.0 terminology-rename leak gate (temperloop#729): the same closed-set
  # discipline for the coined-identifier renames — the legacy env prefixes,
  # old script paths, and coined severity/pairing tokens cannot
  # silently re-enter; only the reviewed exempt set may carry them. Since the
  # window closed in v0.19.0 (temperloop#767) that set is records + this
  # gate's own family alone — the `window` and `registry` exempt classes went
  # away with the files they covered.
  "make test-kernel-terminology"
  # Diff-scoped public-repo leak guard (temperloop #74): the sibling of the two
  # whole-tree kernel scrubs above. Scans the ADDED lines of a PR's diff (all
  # tracked files, not just the kernel manifest) for personal/private tokens +
  # secrets and fails the merge — the mechanical backstop to the kernel/overlay
  # authoring rule, the way validate-capture-backstop backstops the capture/backstop rule.
  # Riding KERNEL_GATES (not a new CI job) makes it part of the already-required
  # `checks` status, so it gates pull_request AND merge_group with no
  # branch-protection reconfiguration. On a feature-branch checkout it diffs the
  # branch's own additions; on push:main / no resolvable base it skips the live
  # scan cleanly; the bundled fixture test always gates detection.
  "make test-pr-leak-guard"
  # Mechanical egress lint over Epic E's before/after value-loop producers
  # (foundation #766, privacy/egress audit item): greps baseline-snapshot.sh,
  # report.sh, bin/temperloop's auto-offer check, and (in the composed-tree
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
  # The bin/subcommands/ CLI suites — init, eject, config, configure, report,
  # feedback, uninstall, update, baseline-snapshot, dispatch-rename,
  # prereq-scoping, report-offer, tokens-producer — run as one globbed gate
  # (F#836: kernel coverage can never trail whichever tests/test_*.sh files are
  # actually vendored). Renamed from `make test-try` when `try` was retired
  # (temperloop#1117); the glob and therefore the covered set are unchanged.
  "make test-cli-subcommands"
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
  # Consumer-parity shellcheck (temperloop#915, follow-up to the SYSTEMIC half
  # of temperloop#905, which fixed one file and left the class open): the
  # `make shellcheck` gate above EXCLUDES */tests/* and passes -e SC1091
  # repo-wide, which is exactly the blind spot stageFind/ssmobile/subsetwiki
  # fall into — they vendor workflows/scripts/board/ verbatim (`make
  # sync-*-board`) and lint their WHOLE tree at plain shellcheck defaults. On
  # 2026-07-29 the identical SC1091 at test_board_cache.sh:66 was live
  # simultaneously in all three consumers' checks while this repo's own gate
  # stayed green throughout — it structurally could not see it. This gate
  # reproduces the consumer's command against the exact synced file set (no
  # tests/ exclusion, no -e SC1091), scoped to workflows/scripts/board/** so
  # it never fights the kernel's own whole-tree posture above. Same
  # direct-`bash` form as the sibling gates above (kernel Makefile is
  # generator-owned; no new target added here).
  "bash workflows/scripts/board-consumer-shellcheck.sh"
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
  # form as the setting-registry/feature-docs gates above (kernel Makefile is
  # generator-owned).
  "bash workflows/scripts/validate-design-brief.sh"
  "bash workflows/scripts/tests/test_validate_design_brief.sh"
  # Positive on-ramp anchor-registry gate (ADR 0024, temperloop#1117): the
  # validate-capture-backstop.sh / validate-activation-registry.sh mold
  # applied to the four cross-surface on-ramp anchors (bin/temperloop's
  # first-run banner, README.md's quickstart, bin/README.md,
  # docs/features/install-cli.md) that drifted silently once already
  # (temperloop#1116) — asserts what each registered anchor MUST say
  # (workflows/scripts/config/onramp-anchors.tsv), never a tree-wide sweep
  # for a retired name. See the registry's own header for why: a sweep
  # ships with an exemption list on day one (CHANGELOG.md/docs/adr/**/
  # Plans-archive/** name the retired command legitimately, as history),
  # and the exemption list becomes the thing people edit to make the build
  # green. Same direct-`bash` form as the sibling validator gates above
  # (kernel Makefile is generator-owned; a `make` target exists too —
  # `make validate-onramp-anchors` — for a human running it locally).
  "bash workflows/scripts/validate-onramp-anchors.sh"
  "bash workflows/scripts/tests/test_validate_onramp_anchors.sh"
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
# Per-gate retry POLICY (temperloop#403 cap, temperloop#976 classification,
# Towheads/foundation#1297 backoff): the loop this very script runs its gates
# through — workflows/scripts/lib/gate-retry.sh. Proves a deterministically-
# failing gate (a static-lint signature, or output byte-identical to the previous
# attempt) is NOT re-run, that a genuine flake still is, and that the retries
# which do fire are actually SPACED. Hermetic: throwaway scripted "gates" under a
# tmpdir, never this file's real gate list. Same direct-`bash` form as the
# freshness gate above (kernel Makefile is generator-owned).
KERNEL_GATES+=("bash scripts/tests/test_quality_gates_retry.sh")
# SLICED execution (temperloop#1021): the QUALITY_GATES_START_AT /
# QUALITY_GATES_BUDGET_SECS seam this very script implements below — the exit-75
# partial protocol and `QUALITY_GATES_RESUME_AT=` / `QUALITY_GATES_FAILED=`
# markers /build's §3e.5 gate resumes on. Proves a bare run is unchanged, that a
# slice loop covers every gate exactly once, and that a genuinely RED suite still
# exits non-zero. Hermetic: a patched copy of this file with synthetic one-second
# "gates" under a tmpdir, never this file's real gate list. Same direct-`bash`
# form as the retry gate above (kernel Makefile is generator-owned).
KERNEL_GATES+=("bash scripts/tests/test_quality_gates_slice.sh")
# Diff-scoped gate SELECTION (temperloop#1024) — the path->gate map that lets a
# `pull_request` run of this script execute only the suites its diff can affect,
# plus the two suites that keep it honest:
#   * check-gate-paths.sh — the map's own COMPLETENESS + REACHABILITY lint. Every
#     kernel gate must have exactly one row, no row may name a gate that no
#     longer exists, and every row's globs must match at least one tracked path.
#     That last check IS the anti-silent-green guarantee: a gate orphaned behind
#     a glob that can never match would otherwise be skipped on every scoped run
#     forever, and nothing else in the tree would notice.
#   * test_gate_selection.sh — the selector's own fixture suite (default-to-full
#     on an unmapped path / unresolvable base / malformed map, the ALL
#     escalation, the ALWAYS floor, an unmapped GATE still running).
# Same direct-`bash` form as the sibling gates above (kernel Makefile is
# generator-owned; no new target added here).
KERNEL_GATES+=("bash workflows/scripts/config/check-gate-paths.sh")
KERNEL_GATES+=("bash workflows/scripts/config/tests/test_check_gate_paths.sh")
KERNEL_GATES+=("bash workflows/scripts/lib/tests/test_gate_selection.sh")
# CHANGED-FILE-SCOPED local runs (temperloop#957) — the `--scoped` flag this
# very script implements below, i.e. the mid-work mode a /build item worker runs
# instead of the minutes-scale full suite. Proves the properties that make it
# safe to trust: the BARE invocation (CI `checks`, /build §3e.5) is unchanged, a
# scoped run NAMES every gate it skipped (twice, and on the verdict line
# itself), an uncommitted/untracked file is in scope, every resolution failure
# widens to the full set, and a red gate is still red. Hermetic: a patched copy
# of this file over four synthetic gates in a throwaway git repo, never this
# file's real gate list. Same direct-`bash` form as the slice/parallel gates
# above (kernel Makefile is generator-owned).
KERNEL_GATES+=("bash scripts/tests/test_quality_gates_scoped.sh")
# Bounded-concurrency SCHEDULER (temperloop#1025): the pool this very script now
# runs its gate list through — workflows/scripts/lib/gate-pool.sh. Proves the
# properties a parallel runner has to earn before it may replace a serial loop:
# a failing gate still returns non-zero and is attributed to the right gate, a
# worker that writes no verdict (or dies outright) is recorded as a FAILURE
# rather than silently passing, output replays in list order, serial-lane pins
# never overlap each other, and an abruptly-dying worker cannot hang the run.
# Hermetic: scripted throwaway "gates" under a tmpdir, never this file's real
# gate list. Same direct-`bash` form as the retry gate above (kernel Makefile is
# generator-owned).
KERNEL_GATES+=("bash scripts/tests/test_quality_gates_parallel.sh")

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

# ─── Concurrency classification (temperloop#1025) ─────────────────────────────
# Two hand-audited pin lists, matched by EXACT command line (never a regex — a
# pattern that silently stops matching a renamed gate would un-pin it without a
# word). Both are read by the scheduler in workflows/scripts/lib/gate-pool.sh;
# both are applied to WHATEVER gate list is being run, so a future diff-scoped
# subset (temperloop#1024) inherits the classification for free — the lists key
# off the gate's own command line, not off a position in the full set.
#
# SERIAL_LANE_PINS — gates that contend over ONE shared, mutable resource and so
# must never run concurrently WITH EACH OTHER. They are not serialized against
# the whole run: the pool gives them a single dedicated lane that still overlaps
# every other gate, so pinning costs (almost) no wall time. This list is the
# product of a real audit of the ~109-gate set, not an assumption of
# independence — the rest of that audit's findings (why the other gates are
# safe) are recorded in docs/features/quality-gates.md § Parallel execution.
SERIAL_LANE_PINS=(
  # Both resolve the PINNED shellcheck through scripts/ensure-shellcheck.sh,
  # which downloads and `mv`s the binary into ONE shared cache path
  # (<repo>/.cache/shellcheck/<version>/shellcheck). On a cold cache — which is
  # every CI run, since nothing restores that cache — two concurrent resolvers
  # would race to `mv` over the same file, and the loser can observe a
  # half-installed or busy binary. Same lane = never concurrent. The
  # consumer-parity shellcheck gate (temperloop#915) resolves the SAME pinned
  # binary the same way, so it joins this lane too.
  "make shellcheck"
  "bash scripts/tests/test_ensure_shellcheck.sh"
  "bash workflows/scripts/board-consumer-shellcheck.sh"
  # `make docs` rmtree's and rebuilds workflows/scripts/docs/_site in the live
  # checkout, while the whole-tree shell lint above walks every *.sh under the
  # repo root with find(1). A whole-tree write racing a whole-tree walk is the
  # classic transient "No such file or directory" — and docs is the ONLY
  # tree-mutating gate in the set, so sharing a lane with the only
  # whole-tree-walking gate closes it completely.
  "make docs"
)
# SLOW_DISPATCH_HINTS — pure scheduling hints, no correctness meaning. Makespan
# is max(total/jobs, longest-gate-start + its length), so a ~1 min gate sitting
# near the END of the list straggles long after every other worker went idle.
# These are the measured long poles (2026-08-02 baseline in the header above);
# the pool dispatches them first. A stale entry here costs nothing but a little
# scheduling efficiency — it can never change a verdict.
SLOW_DISPATCH_HINTS=(
  "make test-cli-subcommands"
  "make test-build"
  "make test-board"
  "bash workflows/scripts/validate-prose-budget.sh"
  "bash workflows/scripts/tests/test_validate_prose_budget.sh"
  "bash workflows/scripts/tests/test_install_lifecycle.sh"
  "bash workflows/scripts/tests/test_install_cli.sh"
)

# gate_lane_of <gate> — echo the scheduler lane for one gate command line.
gate_lane_of() {
  local gate="$1" pin
  for pin in "${SERIAL_LANE_PINS[@]}"; do
    [[ "$gate" == "$pin" ]] && { printf 'serial\n'; return 0; }
  done
  for pin in "${SLOW_DISPATCH_HINTS[@]}"; do
    [[ "$gate" == "$pin" ]] && { printf 'slow\n'; return 0; }
  done
  printf 'pool\n'
}

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

LIST_SELECTED=0
SCOPED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-selected) LIST_SELECTED=1; shift ;;
    --scoped)        SCOPED=1; shift ;;
    *)
      echo "usage: $(basename "$0") [--list|--list-selected] [--scoped]" >&2
      exit 2
      ;;
  esac
done

# --- SLICED EXECUTION (temperloop#1021) --------------------------------------
# The suite's caller may be under a HARD wall-clock ceiling it cannot raise —
# /build's §3e.5 acceptance gate runs this script inside one executor-agent Bash
# invocation, and that tool's own maximum is ~10 minutes. Before this seam the
# gate's only lever was a bigger timeout number, which decayed twice (2min ->
# 8min at temperloop#115, then 8min -> exceeded again at temperloop#1021) as the
# gate list grew; a third raise would hit the agent's ceiling and stop working
# permanently. So the budget stops being a deadline for the WHOLE suite and
# becomes the length of ONE SLICE: this script runs gates until its own budget is
# spent, then stops CLEANLY BETWEEN GATES and tells the caller where to resume.
# Total suite runtime is then unbounded by any single invocation's ceiling, so
# gate-list growth cannot re-create the false-GATE_FAIL failure.
#
# The interface is ENV VARS, deliberately NOT flags: a consuming repo vendoring an
# OLDER quality-gates.sh simply ignores an unknown env var and runs the whole
# suite in one go — today's exact behavior — whereas an unknown FLAG would exit 2
# ("usage") and read to the caller as a gate failure. Same degrade-silently
# rationale as the existing QUALITY_GATES_SKIP_FRESHNESS knob.
#
#   QUALITY_GATES_START_AT     0-based index into the unioned gate list to begin
#                              at (default 0 = the whole list, unchanged).
#   QUALITY_GATES_BUDGET_SECS  soft per-invocation budget in seconds; once a
#                              whole gate (serially) or a whole CHUNK of gates
#                              (under the pool) has finished, if elapsed >=
#                              budget and gates remain, stop (default 0 = no
#                              budget, unchanged).
#   QUALITY_GATES_STEP_SUMMARY set to 1 to additionally APPEND a full per-gate
#                              wall-clock table to $GITHUB_STEP_SUMMARY
#                              (temperloop#968). A no-op unless BOTH this is
#                              "1" AND GitHub Actions has set
#                              $GITHUB_STEP_SUMMARY — so any local run, `make
#                              quality-gates`, and every OTHER caller that
#                              leaves the var unset are unaffected. Default 0
#                              (off), and deliberately never set by ci.yml
#                              (the merge-gating leg) — only
#                              nightly-macos.yml's macOS job and its ubuntu
#                              comparison job opt in, so the two runners' own
#                              per-gate breakdowns land in the SAME workflow
#                              run's summary page, directly comparable,
#                              without adding any per-PR cost or behavior
#                              change to the job that actually gates `main`.
#                              Requires the bounded-concurrency pool (the path
#                              that already records per-gate seconds); a
#                              serial fallback run (QUALITY_GATES_JOBS=1, or no
#                              mktemp) has no per-gate timing to publish and
#                              stays silent on this var.
#
# HOW THE BUDGET COMPOSES WITH THE POOL (temperloop#1025). A budgeted run
# dispatches in chunks of QUALITY_GATES_JOBS and checks the deadline BETWEEN
# chunks; an unbudgeted run is a single chunk (full overlap, the CI path). The
# stop is therefore still on a gate boundary and never mid-gate, and the resume
# index is still a whole number of gates into the list. Checking between chunks
# rather than teaching the pool a deadline of its own is deliberate: the pool's
# fail-closed guarantee is "exactly one verdict per gate handed in", and a
# deadline inside the pool would have to weaken that to "per gate DISPATCHED" —
# the assertion standing between a silently-dropped gate and a green CI run.
# A budgeted run therefore trades one sync barrier per chunk for keeping it.
#
# Partial-run protocol (only ever emitted when a budget is set AND gates remain):
#   stdout marker  QUALITY_GATES_RESUME_AT=<next 0-based index>
#   stdout marker  QUALITY_GATES_FAILED=<failures seen in THIS slice>
#   exit code      75   (EX_TEMPFAIL — distinct from 0 pass and 1 fail, so a
#                        caller can never confuse "budget spent" with "red")
# The caller accumulates QUALITY_GATES_FAILED across slices; a slice that found
# failures still exits 75 rather than 1, so the remaining gates still run and the
# script keeps its collect-all-failures property across the sliced run.
#
# BARE INVOCATION IS BYTE-IDENTICAL: with both vars unset the start index is 0,
# the budget check is disabled, no marker is printed and the exit codes are the
# unchanged 0/1. CI, `make quality-gates` and a human run are untouched.
qg_uint() { case "$1" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }
QG_START_AT="$(qg_uint "${QUALITY_GATES_START_AT:-0}")"
QG_BUDGET_SECS="$(qg_uint "${QUALITY_GATES_BUDGET_SECS:-0}")"
# …then DROP them from the environment, so no gate this run spawns inherits the
# harness's own slicing state. The caller sets them as a command-prefix
# assignment (`QUALITY_GATES_START_AT=50 … quality-gates.sh`), which exports them
# to every descendant — and a gate that itself exercises this seam would then run
# against the parent's indices instead of its own fixture. Caught live: under a
# sliced run, scripts/tests/test_quality_gates_slice.sh inherited
# START_AT=50/BUDGET=240 and failed. Same hermeticity concern the build.config.sh
# scrub addresses at the other end (temperloop#1241).
unset QUALITY_GATES_START_AT QUALITY_GATES_BUDGET_SECS

# Run gates from the repo root so the `make` targets resolve regardless of the
# caller's CWD (build 3e.5 runs this from a throwaway worker checkout).
cd "$REPO_ROOT" || exit 1

# --- Diff-scoped gate selection (temperloop#1024) -----------------------------
# The `checks` job ran this whole list on every `pull_request` AND again on
# `merge_group` — ~5.5 min flat (measured 2026-08-02 across the last 20 runs),
# so every merged PR paid >=11 min of CI even for a one-file docs change.
#
# On a `pull_request` event with a resolvable base SHA, the selector below
# narrows the run to the gates the diff can actually affect, per the
# workflows/scripts/config/gate-paths.tsv map. EVERYWHERE ELSE the full set runs
# byte-for-byte as before: `merge_group` (the run that actually gates `main`),
# `push:main`, the nightly macOS workflow, /build's 3e.5 acceptance gate, and
# every local run. Full-set coverage of the default branch is therefore
# unchanged — see .github/workflows/ci.yml's header for the arrangement.
#
# The base SHA is REUSED, not re-derived: ci.yml already exports
# $LEAK_GUARD_BASE for the PR leak guard, and both diff-scoped consumers now
# diff `<base>...HEAD` from that same value.
#
# Every degradation path (no base, an unresolvable base, an empty diff, a
# missing/malformed map, an unmapped changed path, an unmapped gate) resolves
# TOWARD MORE coverage, never less — see gate-selection.sh's header for the
# four structural defenses against the silent-green class.
# shellcheck source=workflows/scripts/lib/gate-selection.sh
source "$REPO_ROOT/workflows/scripts/lib/gate-selection.sh"
GATE_SELECTION_ROOT="$REPO_ROOT"
GATE_SELECTION_MAP_FILE="$REPO_ROOT/workflows/scripts/config/gate-paths.tsv"
GATE_SELECTION_ALL_GATES="$(printf '%s\n' "${GATES[@]}")"
GATE_SELECTION_BASE="${LEAK_GUARD_BASE:-}"  # setting:exempt — reused verbatim from ci.yml's existing export (owning script: check-pr-leak-guard.sh)
# --- `--scoped`: the LOCAL, mid-work changed-file mode (temperloop#957) -------
# The CI path above needs a pushed head and an exported base. A /build item
# worker has neither — it is mid-work in a throwaway worktree — which is why its
# self-verification had to be a hand-picked subset of `--list` output, chosen by
# a model's judgment about which gates its files touch (claude/commands/build.md
# §3c). `--scoped` replaces that judgment call with THIS map: the same selector,
# the same silent-green defenses, fed the local working-tree changed set instead
# of a PR diff. Everything it cannot resolve degrades to the full set.
GATE_SELECTION_LOCAL_BASE=""
if (( SCOPED )); then
  QUALITY_GATES_SCOPE="diff"   # setting:exempt — the flag's whole meaning is "force a scoped attempt"; a caller's own value is deliberately overridden by the explicit flag
  # A caller-supplied GATE_SELECTION_CHANGED wins (the fixture seam), so a test
  # can exercise this mode without a git tree to stage changes in.
  if [[ -z "${GATE_SELECTION_CHANGED+x}" ]]; then
    if _qg_local_changed="$(gate_selection_local_changed "$REPO_ROOT")"; then
      GATE_SELECTION_CHANGED="$_qg_local_changed"
    else
      printf 'NOTE: --scoped could not resolve a local changed set — running the FULL set.\n' >&2
    fi
    unset _qg_local_changed
  fi
fi
gate_selection_resolve

# qg_print_skipped_gates — name every gate the selection left out, and why.
# A no-op on a full run (nothing was skipped) and on an older gate-selection.sh
# that predates the _SKIPPED out-param, so the two files can be vendored out of
# lockstep without this turning into an error.
qg_print_skipped_gates() {
  local skipped="${GATE_SELECTION_SKIPPED:-}" n gate  # setting:exempt — internal call-interface global set by gate-selection.sh, not an operator setting
  [[ "$GATE_SELECTION_MODE" == "diff" ]] || return 0
  [[ -n "$skipped" ]] || return 0
  n="$(printf '%s\n' "$skipped" | grep -c . || true)"
  printf 'SCOPED RUN — %s gate(s) NOT run: no changed path reaches them per workflows/scripts/config/gate-paths.tsv.\n' "$n"
  while IFS= read -r gate; do
    [[ -n "$gate" ]] || continue
    printf '  not run (out of scope): %s\n' "$gate"
  done <<<"$skipped"
  printf 'A green SCOPED run is NOT a green full run — the authority is the BARE, repo-wide invocation (CI checks job, /build 3e.5).\n'
}

if [[ "$GATE_SELECTION_MODE" == "diff" && -n "$GATE_SELECTION_SELECTED" ]]; then
  SELECTED_GATES=()
  while IFS= read -r _sel_gate; do
    [[ -n "$_sel_gate" ]] || continue
    SELECTED_GATES+=("$_sel_gate")
  done <<<"$GATE_SELECTION_SELECTED"
  GATES=("${SELECTED_GATES[@]}")
  unset _sel_gate
fi

if [[ $LIST_SELECTED -eq 1 ]]; then
  printf 'selection: %s\n' "$GATE_SELECTION_REASON"
  printf '%s\n' "${GATES[@]}"
  qg_print_skipped_gates
  exit 0
fi

# Always SAY which set is running, next to the run itself — a scoped run that
# did not announce itself is indistinguishable from a full one that silently
# lost gates (the legible-degradation rule).
printf 'gate selection: %s\n' "$GATE_SELECTION_REASON"
if (( SCOPED )) && [[ -n "$GATE_SELECTION_LOCAL_BASE" ]]; then
  printf 'scoped against local working tree (base %s): %s changed path(s).\n' \
    "${GATE_SELECTION_LOCAL_BASE:0:12}" \
    "$(printf '%s\n' "${GATE_SELECTION_CHANGED:-}" | grep -c . || true)"  # setting:exempt — internal call-interface global (this script's own scoped-mode input), not an operator setting
fi
# NAME WHAT WAS SKIPPED, AND WHY (temperloop#957). A scoped run that reports
# only what it RAN is one scroll away from being read as a green full run; the
# whole safety case for scoping rests on the reader being unable to make that
# mistake. So the un-run gates are listed by name, with the one reason that
# applies to all of them, BEFORE the run and again at the verdict.
qg_print_skipped_gates

# --- Checkout-freshness guard (temperloop#591) --------------------------------
# This script runs whatever gate LIST the checked-out tree contains, and the
# diff-scoped gates (the PR leak guard) diff against origin/<default>. So a
# checkout that is BEHIND origin/<default> silently runs a SMALLER gate set than
# CI (which checks out the PR's merge with current main) and scans a stale/empty
# leak-guard diff — a green run here then does NOT imply green CI. That exact
# trap cost a 12-item /sweep four post-push CI round-trips (the setting-registry /
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
# Slice 2..N of a sliced run skips it: the freshness of a checkout cannot change
# between slices of one gate run, so re-fetching per slice buys nothing and costs
# a network round-trip plus a repeated banner. Slice 1 (START_AT 0) — and every
# bare, unsliced invocation — checks it exactly as before.
if (( QG_START_AT == 0 )); then
  check_checkout_freshness "$REPO_ROOT"
fi

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
# Bounded, CLASSIFIED, BACKED-OFF per-gate retry. The policy itself lives in
# workflows/scripts/lib/gate-retry.sh (sourced below, same seam as
# checkout-freshness.sh above) so it can be exercised by a test without running
# this file's ~100-target gate list — see scripts/tests/test_quality_gates_retry.sh.
# In one line each:
#   * CAP        $GATE_MAX_ATTEMPTS attempts, absorbing transient macOS-runner
#                flakiness (temperloop#403 — the GitHub macos-latest runner
#                intermittently fails unrelated hermetic gates under load).
#   * CLASSIFY   a DETERMINISTIC failure (a static-lint signature, or output
#                byte-identical to the previous failed attempt) is NOT retried at
#                all — re-running it cannot change the outcome (temperloop#976;
#                the epic #1443 gate re-ran a failing shellcheck three times).
#   * BACK OFF   the retries that ARE legitimate are spaced by
#                $GATE_RETRY_BACKOFF * attempt seconds, instead of firing
#                back-to-back too fast to outlast anything
#                (Towheads/foundation#1297).
# Every attempt, every retry and every deterministic short-circuit is LOGGED
# (per-attempt on stderr + an end-of-run summary below), so neither a flake nor a
# saved retry is silently masked.
# shellcheck source=workflows/scripts/lib/gate-retry.sh
source "$REPO_ROOT/workflows/scripts/lib/gate-retry.sh"
gate_retry_init

# Bounded-concurrency SCHEDULER (temperloop#1025) — see the § PARALLELISM note in
# this file's header for what it does and does not change. Sourced AFTER
# gate-retry.sh on purpose: bash traps are per-signal rather than stacked, so
# gate_pool_init's EXIT trap replaces gate_retry_init's and takes over cleaning
# up BOTH scratch dirs (gate-pool.sh's own header pins that ordering).
# shellcheck source=workflows/scripts/lib/gate-pool.sh
source "$REPO_ROOT/workflows/scripts/lib/gate-pool.sh"

# LAYER 6 of the six-layer config ladder — a byte-identical fallback to the
# QUALITY_GATES_JOBS declaration in
# workflows/scripts/build/build.config.sh, because this script must run
# standalone in a consuming repo that never sources that file (and because
# /build's 3e.5 acceptance gate deliberately scrubs it). Keep the two in sync —
# the setting registry pins them.
QUALITY_GATES_JOBS="${QUALITY_GATES_JOBS:-auto}"
# Degrade to serial OUT LOUD if the scheduler lib did not load. This script runs
# under `set -uo pipefail` with no `-e`, so a failed `source` above leaves
# gate_pool_resolve_jobs undefined and every later call is a bare `command not
# found` on stderr — the run still completes, serially and correctly, but it
# does so silently enough that a test fixture which forgot to copy the lib
# passed for a while while exercising none of the parallel path (caught by
# temperloop#1025's own slice-fixture bug). Same say-it-out-loud rule the
# mktemp-failure fallback below already follows.
if ! type -t gate_pool_resolve_jobs >/dev/null 2>&1; then
  printf 'NOTE: workflows/scripts/lib/gate-pool.sh did not load — running the gate set SERIALLY.\n' >&2
  gate_jobs=1
else
  gate_jobs="$(gate_pool_resolve_jobs "$QUALITY_GATES_JOBS")"
fi

failures=()
retried=()
deterministic=()
qg_started="$(date +%s)"
qg_resume_at=""

# The SLICE WINDOW (temperloop#1021) and the bounded-concurrency POOL
# (temperloop#1025) compose by SELECTION, not by either one knowing about the
# other: the window picks the run set, and whichever executor runs below is
# handed exactly that array. #1024's diff-scoped selection narrows this same
# array, which is why the classification is keyed off each gate's own command
# line rather than its position in the full list.
qg_run_gates=()
for ((gi = QG_START_AT; gi < ${#GATES[@]}; gi++)); do
  qg_run_gates+=("${GATES[$gi]}")
done

# qg_pool_worker <gate> — the pool's per-gate child body.
#
# Runs one gate through the SAME gate_run_with_retry policy the serial loop
# uses (there is exactly one retry implementation, not one per mode), then
# hands the verdict back over the pool's meta-file channel. $GATE_POOL_LOG_TAG
# is the per-gate unique tag that keeps concurrent gates from sharing one
# attempt-capture file — without it the byte-identical-output classifier would
# compare one gate's output against a DIFFERENT gate's.
qg_pool_worker() {
  local gate="$1" rc=0
  gate_run_with_retry "$gate" "$GATE_POOL_LOG_TAG" || rc=$?
  printf '%s\t%s\t%s\n' "$GATE_RUN_STATUS" "$GATE_RUN_ATTEMPTS" "$GATE_RUN_NOTE" \
    >"$GATE_POOL_META"
  return "$rc"
}

# qg_write_step_summary_timing — append a full per-gate wall-clock table to
# $GITHUB_STEP_SUMMARY (temperloop#968). See the QUALITY_GATES_STEP_SUMMARY
# entry in the ENV VAR interface note above for the opt-in contract; the
# caller (the TIMING block below) already gates the call on that var being
# "1" and $GITHUB_STEP_SUMMARY being set, so this function assumes both.
#
# Reads the run's own qg_run_gates / qg_pool_secs / qg_pool_wall_total /
# qg_pool_serial_total / gate_jobs globals — the EXACT figures the stdout
# TIMING line is built from, so the published table can never diverge from
# what a human watching the log already saw. This is what makes the macOS and
# ubuntu legs comparable: both runners execute this same function over their
# own gate_pool timings, so the table's shape (and the arithmetic that fills
# it) is identical on both, and only the numbers and the "%s" OS label differ.
#
# `RUNNER_OS` is a GitHub-Actions-supplied env var ("macOS" / "Linux" / …);
# falls back to `uname -s` for a human running with QUALITY_GATES_STEP_SUMMARY
# forced on outside Actions.
qg_write_step_summary_timing() {
  local i os_label
  os_label="${RUNNER_OS:-$(uname -s)}" # setting:exempt — GitHub Actions injects RUNNER_OS; a harness-provided fact, not a tunable this repo owns (uname -s is the off-CI fallback)
  {
    printf '## Quality gates — per-gate wall-clock (%s)\n\n' "$os_label"
    printf 'Total: %ds wall, %d worker(s), %ds serial-equivalent (%s.%sx speedup).\n\n' \
      "$qg_pool_wall_total" "$gate_jobs" "$qg_pool_serial_total" \
      "$(( qg_pool_serial_total / qg_pool_wall_total ))" \
      "$(( (qg_pool_serial_total * 10 / qg_pool_wall_total) % 10 ))"
    printf '| Seconds | Gate |\n'
    printf '|---:|:---|\n'
    for ((i = 0; i < ${#qg_pool_secs[@]}; i++)); do
      printf '%d\t%s\n' "${qg_pool_secs[$i]}" "${qg_run_gates[$i]}"
    done | sort -rn | while IFS=$'\t' read -r secs name; do
      # shellcheck disable=SC2016  # literal Markdown backticks, not command substitution
      printf '| %s | `%s` |\n' "$secs" "$name"
    done
    printf '\n'
  } >>"$GITHUB_STEP_SUMMARY"
}

# Serial when asked for (QUALITY_GATES_JOBS=1 — the bisect/flake-hunt mode), and
# serial when the pool cannot allocate its scratch dir. The fallback direction is
# deliberate: serial execution is ALWAYS correct, so a scheduler that cannot set
# itself up degrades to the slower-but-right path rather than to a weaker
# guarantee — and it says so out loud rather than silently.
gate_pool_ready=0
if [[ "$gate_jobs" -gt 1 ]] && (( ${#qg_run_gates[@]} > 0 )); then
  if gate_pool_init; then
    gate_pool_ready=1
  else
    printf 'NOTE: could not allocate scheduler scratch (mktemp failed) — running the gate set SERIALLY.\n' >&2
  fi
fi

# gate_pool_run RESETS its GATE_POOL_* result arrays on every call, and a
# budgeted run calls it once per chunk — so the figures the TIMING line reports
# are accumulated here rather than read off the last chunk.
qg_pool_wall_total=0
qg_pool_serial_total=0
qg_pool_secs=()
qg_ran=0

if [[ "$gate_pool_ready" -eq 1 ]]; then
  lane_pinned=0
  for gate in "${qg_run_gates[@]}"; do
    [[ "$(gate_lane_of "$gate")" == "serial" ]] && lane_pinned=$((lane_pinned + 1))
  done

  # CHUNKING — how the budget seam and the pool compose.
  #
  # UNBUDGETED (CI, `make quality-gates`, a human run) is ONE chunk: the whole
  # window dispatched at once, the maximum-overlap case the measured speedup is
  # about. Nothing about that path changes.
  #
  # A BUDGETED caller (/build's §3e.5 slice loop) instead gets chunks of
  # `gate_jobs`, with the deadline checked BETWEEN chunks. That keeps #1021's
  # guarantee literally — no gate is ever killed mid-run; the run stops cleanly
  # at a gate boundary — while leaving gate-pool.sh's fail-closed invariant
  # untouched: every gate handed to a chunk is one that chunk actually runs, so
  # "exactly one verdict per gate handed in" still holds verbatim. The cost is
  # one sync barrier per chunk, paid ONLY on budgeted runs.
  #
  # Deliberately NOT done by teaching the pool a deadline of its own: that would
  # mean relaxing that assertion to "one verdict per gate DISPATCHED", and that
  # assertion is precisely what stands between a silently-dropped gate and a
  # green CI run. The barrier is the cheaper thing to spend.
  qg_chunk=${#qg_run_gates[@]}
  if (( QG_BUDGET_SECS > 0 )); then
    qg_chunk=$gate_jobs
    printf 'Running %d gate(s) with %d parallel worker(s) in chunks of %d (budget %ss); %d pinned to the serial lane.\n' \
      "${#qg_run_gates[@]}" "$gate_jobs" "$qg_chunk" "$QG_BUDGET_SECS" "$lane_pinned"
  else
    printf 'Running %d gate(s) with %d parallel worker(s); %d pinned to the serial lane.\n' \
      "${#qg_run_gates[@]}" "$gate_jobs" "$lane_pinned"
  fi
  if [[ "$lane_pinned" -gt 0 ]]; then
    for gate in "${SERIAL_LANE_PINS[@]}"; do
      printf '  serial lane: %s\n' "$gate"
    done
  fi

  while (( qg_ran < ${#qg_run_gates[@]} )); do
    GATE_POOL_GATES=()
    GATE_POOL_LANE=()
    for ((gi = qg_ran; gi < qg_ran + qg_chunk && gi < ${#qg_run_gates[@]}; gi++)); do
      GATE_POOL_GATES+=("${qg_run_gates[$gi]}")
      GATE_POOL_LANE+=("$(gate_lane_of "${qg_run_gates[$gi]}")")
    done
    gate_pool_run "$gate_jobs" qg_pool_worker || true
    qg_pool_wall_total=$(( qg_pool_wall_total + GATE_POOL_WALL ))
    qg_pool_serial_total=$(( qg_pool_serial_total + GATE_POOL_SERIAL_SUM ))
    for ((ci = 0; ci < ${#GATE_POOL_GATES[@]}; ci++)); do
      gate="${GATE_POOL_GATES[$ci]}"
      qg_pool_secs+=("${GATE_POOL_SECONDS[$ci]}")
      case "${GATE_POOL_STATUS[$ci]}" in
        pass)
          if [[ -n "${GATE_POOL_NOTE[$ci]}" ]]; then
            retried+=("$gate (${GATE_POOL_NOTE[$ci]})")
          fi
          ;;
        deterministic)
          failures+=("$gate")
          deterministic+=("$gate (${GATE_POOL_NOTE[$ci]})")
          ;;
        *)
          failures+=("$gate")
          ;;
      esac
    done
    qg_ran=$(( qg_ran + ${#GATE_POOL_GATES[@]} ))
    # Soft budget, checked only BETWEEN chunks — every gate inside a chunk runs
    # to completion. Stop only if gates actually remain: a budget spent on the
    # LAST chunk is a completed run, not a partial one.
    if (( QG_BUDGET_SECS > 0 )) && (( qg_ran < ${#qg_run_gates[@]} )); then
      if (( $(date +%s) - qg_started >= QG_BUDGET_SECS )); then
        qg_resume_at=$(( QG_START_AT + qg_ran ))
        break
      fi
    fi
  done
elif (( ${#qg_run_gates[@]} > 0 )); then
  for gate in "${qg_run_gates[@]}"; do
    printf '\n=== %s ===\n' "$gate"
    gate_run_with_retry "$gate" || true
    case "$GATE_RUN_STATUS" in
      pass)
        # A note is set only when the pass took more than one attempt.
        if [[ -n "$GATE_RUN_NOTE" ]]; then
          retried+=("$gate ($GATE_RUN_NOTE)")
        fi
        ;;
      deterministic)
        failures+=("$gate")
        deterministic+=("$gate ($GATE_RUN_NOTE)")
        ;;
      *)
        failures+=("$gate")
        ;;
    esac
    qg_ran=$(( qg_ran + 1 ))
    # Soft budget, checked only BETWEEN gates so no gate is ever killed mid-run
    # (that is what made the old hard-timeout design report a green suite as red).
    # Stop only if gates actually remain — a budget spent on the LAST gate is a
    # completed run, not a partial one.
    if (( QG_BUDGET_SECS > 0 )) && (( qg_ran < ${#qg_run_gates[@]} )); then
      if (( $(date +%s) - qg_started >= QG_BUDGET_SECS )); then
        qg_resume_at=$(( QG_START_AT + qg_ran ))
        break
      fi
    fi
  done
fi

echo
# Measured speedup, printed next to the verdict (temperloop#1025, kernel
# § Measure the delta, don't assume it). qg_pool_serial_total is the sum of the
# per-gate wall times — which IS what a serial run of the same set costs, since
# the serial loop's only other cost is the loop itself — so the ratio below is a
# measurement of this run, never an estimate. The slowest-gate list is the
# actionable half: it names whatever is currently setting the makespan floor.
#
# All three figures are the accumulators, not the last gate_pool_run's globals:
# a budgeted run chunks, and gate_pool_run resets those globals per chunk. They
# are indexed over the RUN SET (the slice window), never the full gate list, so
# a sliced run reports its own slice's timings rather than mis-indexing them.
if [[ "$gate_pool_ready" -eq 1 ]] && (( qg_pool_wall_total > 0 )); then
  printf 'TIMING: %ds wall with %d worker(s); %ds of gate time (a serial run of the same set) => %s.%sx.\n' \
    "$qg_pool_wall_total" "$gate_jobs" "$qg_pool_serial_total" \
    "$(( qg_pool_serial_total / qg_pool_wall_total ))" \
    "$(( (qg_pool_serial_total * 10 / qg_pool_wall_total) % 10 ))"
  printf '  slowest gates (these set the floor):\n'
  for ((gi = 0; gi < ${#qg_pool_secs[@]}; gi++)); do
    printf '%6d\t%s\n' "${qg_pool_secs[$gi]}" "${qg_run_gates[$gi]}"
  done | sort -rn | head -5 | while IFS=$'\t' read -r secs name; do
    printf '    %4ss  %s\n' "$secs" "$name"
  done
  echo
  # Opt-in full-table publication for the macOS/ubuntu comparison
  # (temperloop#968) — see QUALITY_GATES_STEP_SUMMARY in the ENV VAR
  # interface note above and qg_write_step_summary_timing's own header.
  # setting:exempt — GITHUB_STEP_SUMMARY is GitHub-injected (the step-summary
  # sink path), not a tunable; QUALITY_GATES_STEP_SUMMARY on the same line IS
  # registered in setting-registry.tsv, so nothing here is silently unowned.
  if [[ "${QUALITY_GATES_STEP_SUMMARY:-0}" == "1" ]] && [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then # setting:exempt
    qg_write_step_summary_timing || true
  fi
fi
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
# Deterministic short-circuits are surfaced next to the verdict too
# (temperloop#976): a gate that failed the same way twice, or matched a
# static-lint signature, spent NO further attempts on an outcome that could not
# change — say so, so the saved retries are visible rather than silent.
if (( ${#deterministic[@]} > 0 )); then
  printf 'NOTE: %d gate failure(s) classified DETERMINISTIC and NOT retried (temperloop#976):\n' "${#deterministic[@]}"
  printf '  - %s\n' "${deterministic[@]}"
  echo
fi
# Re-surface the SCOPE next to the verdict too, for the same reason the
# staleness banner is repeated above: "all gates passed" means something
# different on a diff-scoped run, and the reader decides at the verdict.
# Printed BEFORE the partial-run block below so a budget-spent slice
# (temperloop#1021, which exits 75 right there) still announces its scope
# rather than exiting silently on it.
if [[ "$GATE_SELECTION_MODE" == "diff" ]]; then
  printf 'NOTE: this was a DIFF-SCOPED run — %s. The full set still runs on merge_group (temperloop#1024).\n' \
    "$GATE_SELECTION_REASON"
  # The skip list, repeated at the verdict for the same reason the staleness
  # banner is (temperloop#957): the reader decides here, and "all gates passed"
  # means something different on a scoped run.
  qg_print_skipped_gates
  echo
fi

qg_elapsed=$(( $(date +%s) - qg_started ))

# --- Partial (budget-spent) run: hand the caller a resume point --------------
# Emitted ONLY on a sliced run that still has gates left. Failures found in this
# slice are reported as a COUNT the caller accumulates — the slice still exits 75
# rather than 1, so the remaining gates still run and the sliced run keeps this
# script's collect-all-failures property. The per-gate failure names are already
# in this slice's own output above; the caller's log is the union of the slices.
if [[ -n "$qg_resume_at" ]]; then
  if (( ${#failures[@]} > 0 )); then
    printf 'FAILED %d quality gate(s) in this slice:\n' "${#failures[@]}"
    printf '  - %s\n' "${failures[@]}"
  fi
  printf 'PARTIAL — ran gates %s..%s of %s in %ss (budget %ss); resuming at %s\n' \
    "$QG_START_AT" "$(( qg_resume_at - 1 ))" "${#GATES[@]}" "$qg_elapsed" "$QG_BUDGET_SECS" "$qg_resume_at"
  printf 'QUALITY_GATES_FAILED=%d\n' "${#failures[@]}"
  printf 'QUALITY_GATES_RESUME_AT=%s\n' "$qg_resume_at"
  exit 75
fi

qg_scope_suffix=""
if [[ "$GATE_SELECTION_MODE" == "diff" ]]; then
  # The verdict LINE ITSELF carries the scope, so even a one-line grep of a
  # worker's log ("OK — all N quality gate(s) passed") cannot be mistaken for a
  # full-suite pass (temperloop#957).
  qg_scope_suffix=" [SCOPED SUBSET — NOT a full-suite pass]"
fi
if (( ${#failures[@]} > 0 )); then
  printf 'FAILED %d/%d quality gate(s)%s:\n' "${#failures[@]}" "${#GATES[@]}" "$qg_scope_suffix"
  printf '  - %s\n' "${failures[@]}"
  printf 'QUALITY_GATES_FAILED=%d\n' "${#failures[@]}"
  exit 1
fi
# The elapsed figure is the DECAY SIGNAL (temperloop#1021): it is what makes the
# suite's growth against any caller's budget observable on every green run,
# instead of only becoming visible the day it blows a deadline.
if (( QG_START_AT > 0 )); then
  # Final slice of a sliced run — say so, so the line is never misread as "the
  # whole suite passed" when earlier slices ran (and may have failed) elsewhere.
  printf 'OK — gates %s..%s of %s passed in %ss (final slice)%s\n' \
    "$QG_START_AT" "$(( ${#GATES[@]} - 1 ))" "${#GATES[@]}" "$qg_elapsed" "$qg_scope_suffix"
else
  printf 'OK — all %d quality gate(s) passed in %ss%s\n' "${#GATES[@]}" "$qg_elapsed" "$qg_scope_suffix"
fi
