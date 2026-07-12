---
tags: [plan, project/temperloop]
date: 2026-07-07
source_kind: claude-stamped
source_session: ca97f83b
last_verified: 2026-07-12
sources:
  - "#131"
epic: 131
status: done
---

# temperloop - documentation-first epic

## Run status
run started 2026-07-10 16:11 · session a4aba5fc · level 0/4 active · items: 0 done / 0 parked / 1 in-flight / 0 skipped

## Problem
TemperLoop's documentation is below the bar for a public kernel repo when judged from the stranger's standpoint. CI enforces registry *integrity* (live-drain pairs, template refs, a docs-site build) but nothing forces documentation to *exist* — a new feature merges with no doc, most existing features live only in script headers, and decision rationale hides behind vault wikilinks a stranger can't resolve. There is also no architecture overview, no audience definition, no stated principles, and no surface an AI agent can use to discover or administer the system.

## Summary
- **Nothing forces documentation to exist (the enforcement seam).**
  - **L0** — Pre-claim every new doc path in kernel-manifest.txt so sibling PRs never collide on it. (#147)
  - **L1** — Feature-docs coverage gate: full-coverage path-claims manifest, 5-section validator, shrink-only exemption ratchet, wired into quality-gates. (#132)
  - **L1** — Docs-site rendering for feature docs and ADRs (zero-files → zero-pages, lands before any doc exists). (#133)
- **A stranger can't see how the pieces fit or who it's for.**
  - **L1** — Architecture overview with mermaid diagrams: pipeline flow, actor/guard map, telemetry lake. (#134)
  - **L1** — Guiding-principles page: the scaling-AI-development thesis + 12 principles with mechanism receipts. (#135)
  - **L1** — Audience page: designed-for and not-a-fit personas — the canonical definition of "the stranger". (#136)
- **AI agents can't discover or administer it.**
  - **L1** — AGENTS.md + llms.txt + root CLAUDE.md + repo topics. (#137)
- **The ~19 existing features are undocumented (drain the ratchet).**
  - **L2** — Backfill: board-adapter, branch-hygiene. (#138)
  - **L2** — Backfill: build-spine, merge-gate, quality-gates. (#139)
  - **L2** — Backfill: triage, assess, sweep, next. (#140)
  - **L2** — Backfill: tidy, check-in, telemetry, funnel-driver. (#141)
  - **L2** — Backfill: hooks, gh-perf, review-agents. (#142)
  - **L2** — Backfill: install-cli, knowledge-store, docs-generator, presentation-plane. (#143)
- **Doc prose quality has no reviewer.**
  - **L2** — docs-reviewer advisory agent (rule-cited findings; reads as the stranger defined by #136) + /build 3e wiring. (#144)
- **Rationale is invisible to strangers.**
  - **L2** — In-repo ADRs: ADR-0000 (process) + ADR-0001 (the documentation system + migration plan). (#145)
- **Nothing links it together.**
  - **L3** — README/CONTRIBUTING integration: positioning line, links, backfill-exempt list at zero. (#146)

Build order: L0 first → L3 last; items in the same level ship together.

## Sequencing notes
- L0 (#147) is a five-line seed PR — merge it immediately; every L1 item's CI fails `test-kernel-manifest` without it (that's why the edges are `depends-on`, not `after`).
- The six L2 backfills all delete lines from the shared `docs/features/backfill-exempt.txt`. #132 seeds that file grouped per backfill sub-issue with comment separators to keep the deletions in separate hunks; the merge queue's serial branch-updates absorb the rest — expect occasional trivial rebases, not failures.
- Within L1, merge order between #132 and the doc-page items (#134–#137) is coupled: once the coverage gate merges, an unclaimed sibling page landing after it in the same level (`docs/architecture.md`, `docs/principles.md`, `docs/who-its-for.md`, `AGENTS.md`, `llms.txt`) fails the new unclaimed-path check at the merge queue. #132's seed manifest therefore pre-claims those paths (see its notes + acceptance — the feature-manifest mirror of #147's kernel pre-claims), so L1 merge order stays free; #137's reconcile-at-merge note is the fallback if implementation diverges. *(added 2026-07-10 re-verification)*
- README.md is owned exclusively by #146; #135 and #137 were explicitly de-scoped from touching it (issue bodies amended).
- #137's repo-topics change is a repo-settings mutation (`gh repo edit --add-topic`), not a file in the PR — apply it at merge time.
- Within L1, the audience page (#136, S) is the cheapest item and defines the lens #144 uses later — no reason to hold it back.

## Re-triage signals
- **Resolved 2026-07-07 (operator):** #132 stays **atomic** — no mechanism/authoring split. (Original question: split validator+fixtures from manifest/ratchet authoring; declined — half a split ships a dark, unwired validator.)
- Auditor's other logical findings were applied at source, not deferred: README-§1 ownership dedup (#135/#137 → #146), fixture-based acceptance on #144 (no dependency on unbuilt backfill docs), and #146's tracker `blocked-by` synced to the plan's `after:` edges.
- Epic parking state: K131 sits in **Backlog, milestone `pending`** (operator-parked 2026-07-07) with sub-issues #132–#147 Ready; un-park by moving K131 back to Ready when approving. *(un-parked 2026-07-10 at approval)*

## Items

- [x] **Kernel-manifest pre-claims for all documentation paths** `slug: manifest-preclaims` — seed PR adding kernel-manifest.txt globs for every doc path this epic creates
  - branch: `chore/manifest-preclaims`
  - size: S
  - model: sonnet
  - source: #147
  - gh_issue: 147
  - files: `workflows/scripts/kernel/kernel-manifest.txt`
  - acceptance:
    - Adds exactly: `kernel docs/features/*`, `kernel docs/adr/*`, `kernel docs/architecture.md`, `kernel docs/principles.md`, `kernel docs/who-its-for.md`, `kernel AGENTS.md`, `kernel llms.txt` — no other changes
    - `make test-kernel-manifest` and `bash scripts/quality-gates.sh` green (unused globs are inert — check-kernel-manifest.sh only classifies tracked files)
    - Root `CLAUDE.md` needs no line (already classified `split`); `claude/agents/*` already covered
  - notes: exists so the six L1 items never touch kernel-manifest.txt (no docs/ catch-all exists, deliberately — the manifest avoids one so overlay content can't silently classify kernel; keep the claims explicit, not `docs/*`).
  - Run-status: run started 2026-07-10 16:11 · session a4aba5fc · level 1/4 active · items: 1 done / 0 parked / 6 in-flight / 0 skipped

- [x] **Feature-docs coverage gate: manifest, validator, ratchet** `slug: feature-docs-gate` — full-coverage path-claims registry + 5-section feature-doc validator + shrink-only exemption ratchet, wired into quality-gates
  - branch: `feat/feature-docs-gate`
  - size: L
  - depends-on: manifest-preclaims
  - source: #132
  - gh_issue: 132
  - files: `workflows/scripts/validate-feature-docs.sh`, `docs/features/feature-manifest.txt`, `docs/features/backfill-exempt.txt`, `scripts/quality-gates.sh`, `workflows/scripts/tests/`
  - acceptance:
    - `bash scripts/quality-gates.sh` green with the full ~19-slug ratchet seeded (gate lands green on day one)
    - Validator fails on: unclaimed tracked path, missing doc for non-exempt slug, missing/empty required section (`## Problem`, `## How it works`, `## Integration`, `## Resource impact`, `## Telemetry`), orphan doc, frontmatter/filename slug mismatch, stale exemption, exempt-but-documented
    - Fixture tests cover every failure mode above; bash-3.2-portable; shellcheck-clean
    - backfill-exempt.txt seeded grouped per backfill sub-issue (#138–#143) with comment separators
    - Seed manifest pre-claims the L1 sibling paths this epic creates (`docs/architecture.md`, `docs/principles.md`, `docs/who-its-for.md`, `AGENTS.md`, `llms.txt` — under `none` or an appropriate slug), so no L1 sibling PR needs a feature-manifest edit and L1 merge order stays free; a claim matching a not-yet-tracked path must be legal and inert
    - kernel-manifest.txt untouched (pre-claimed by #147)
  - notes: model the coverage walk on `workflows/scripts/kernel/check-kernel-manifest.sh` + `kernel/lib.sh` (longest-match wins, reserved slug `none`), the message/summary style on `workflows/scripts/validate-live-drain.sh`, env-override fixture seams on `KERNEL_MANIFEST_ROOT/_FILE`. Do NOT extend kernel-manifest.txt — orthogonal taxonomy, and its loader hard-rejects extra classes. Direct-bash KERNEL_GATES entries (Makefile is seeder-owned). The sibling pre-claim bullet above is the feature-manifest mirror of #147's kernel pre-claims (added 2026-07-10): it removes the #132↔#134–#137 within-level merge-order coupling; #137's "whichever lands second reconciles" note remains the fallback.
  - Run-status: level 1/4 merging · items: 6 done / 1 parked / 0 in-flight / 0 skipped

- [x] **Docs-site rendering for feature docs and ADRs** `slug: docs-site-features-source` — features.py + ADR source module registered in the generator, zero-docs no-op proven
  - branch: `feat/docs-site-features-source`
  - size: M
  - model: sonnet
  - depends-on: manifest-preclaims
  - source: #133
  - gh_issue: 133
  - files: `workflows/scripts/docs/sources/features.py`, `workflows/scripts/docs/generate.py`, `workflows/scripts/docs/tests/`
  - acceptance:
    - `make docs` green with zero feature docs/ADRs present (pinned-glob zero-pages convention, no conditionals)
    - Generator test renders a fixture feature doc and a fixture ADR with frontmatter titles under "Features" / "ADRs" nav groups
    - Build stays stdlib-only, zero-network, byte-deterministic; registry `.txt` files in docs/features/ ignored by the `*.md` glob
  - notes: clone `workflows/scripts/docs/sources/chapters.py`; single-line frontmatter only (markdown_lite parses no real YAML). (2026-07-10 re-verification: this item's own paths are already glob-claimed by the existing `kernel workflows/scripts/docs/*` manifest line, so its edge to the seed is belt-and-suspenders, kept for the no-sibling-touches-kernel-manifest invariant.)

- [x] **Architecture overview with mermaid diagrams** `slug: architecture-overview` — docs/architecture.md: pipeline flow, actor/guard map, telemetry lake
  - branch: `docs/architecture-overview`
  - size: M
  - model: sonnet
  - depends-on: manifest-preclaims
  - source: #134
  - gh_issue: 134
  - files: `docs/architecture.md`
  - acceptance:
    - Three mermaid diagrams render on GitHub: (1) issue → /triage → epic → /assess → plan → /build|/sweep → PR → checks → merge gate → Done cascade; (2) human/agents/hooks/CI/board actor map with the guard at each seam; (3) telemetry emit sites → monthly JSONL streams → /telemetry + /check-in
    - `make docs` green; docs-site handling of mermaid decided in-item (view-time JS or link to GitHub-rendered page) with the build staying zero-network
    - No vault wikilinks, no personal specifics; consistent with README §1/§4/§9
  - notes: first imagery in the repo — GitHub-native mermaid is the canonical render target.

- [x] **Guiding principles page** `slug: principles-page` — docs/principles.md: the scaling-AI-development thesis + 12 principles with mechanism receipts
  - branch: `docs/principles-page`
  - size: M
  - model: sonnet
  - depends-on: manifest-preclaims
  - source: #135
  - gh_issue: 135
  - files: `docs/principles.md`
  - acceptance:
    - Thesis and claimed axes (cheaper in tokens + cognitive load, aligned, maintainable, parallel throughput, auditable, bounded blast radius) stated up top
    - All 12 principles from the issue body present, each naming the in-repo mechanism that embodies it (falsifiable, not aspirational)
    - Public-safe (no vault wikilinks); README linking NOT done here (owned by #146)
  - notes: the distilled principle list is embedded in the issue body so no vault access is needed; operator-side source material: [[Projects/surfacing/03 - Insights and threads]], [[Patterns/Subtraction over mechanism]], [[Priorities/stagefind]] § Principles — rewrite public-safe, never copy.

- [x] **Audience page: who it's for and who it isn't** `slug: audience-page` — docs/who-its-for.md: the canonical "stranger" definition
  - branch: `docs/audience-page`
  - size: S
  - model: sonnet
  - depends-on: manifest-preclaims
  - source: #136
  - gh_issue: 136
  - files: `docs/who-its-for.md`
  - acceptance:
    - Designed-for persona (developer/small team, Claude Code-driven, org-grade process without an org, works on free-plan GitHub) and explicit not-a-fit personas (chat-first workflows, hosted-service seekers, non-GitHub trackers, no branch/PR discipline) both concrete
    - Usable as an evaluation lens by the docs-reviewer (#144), not marketing copy
  - notes: operator-side source: [[Context/temperloop - Interface-fit analysis (how devs work with AI, 2026-07)]] — rewrite public-safe.

- [x] **AI-agent discoverability surfaces** `slug: agent-discoverability` — AGENTS.md + llms.txt + root CLAUDE.md + repo topics
  - branch: `docs/agent-discoverability`
  - size: M
  - model: sonnet
  - depends-on: manifest-preclaims
  - source: #137
  - gh_issue: 137
  - files: `AGENTS.md`, `llms.txt`, `CLAUDE.md`
  - acceptance:
    - AGENTS.md covers what TemperLoop is + how an agent administers it (CLI, make targets, board-adapter rules + API budget, gates, contract locations) + safety rails (adapter-only board access, protected main, merge-queue flow)
    - llms.txt spec-conformant (H1, summary blockquote, curated link lists) and copied into the docs-site output
    - Root CLAUDE.md is a thin pointer to AGENTS.md + claude/CLAUDE.kernel.md; `validate-live-drain` stays green with it present (it resolves `$REPO/CLAUDE.md` as an anchor source — verify)
    - README untouched (positioning owned by #146); kernel-manifest untouched (pre-claimed by #147; root CLAUDE.md already `split`)
  - notes: repo topics (`gh repo edit --add-topic`) are a repo-settings op outside the PR — apply at merge. Feature-manifest claims for these paths are pre-seeded by #132 (see its acceptance); the issue-body "whichever lands second reconciles" is the fallback only.
  - Run-status: level 1/4 complete (6/6 merged) · paused for 5h quota at 02:12 UTC, remaining 7%, resuming ~05:20 UTC · items: 7 done / 9 pending

- [x] **Feature-doc backfill: board adapter + branch hygiene** `slug: bf-board-hygiene` — docs for board-adapter, branch-hygiene; delete their exemptions
  - branch: `docs/bf-board-hygiene`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #138
  - gh_issue: 138
  - files: `docs/features/board-adapter.md`, `docs/features/branch-hygiene.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - Both docs carry the five required sections; board-adapter covers the 5,000 pt/hr GraphQL budget, the 90s/24h cache TTL split, single-item vs whole-board resolve, the issues-only backend + board 7, claim-lock semantics
    - branch-hygiene covers prune-merged-branches modes, auto-delete-on-merge, the session-start sweep
    - This group's exemption lines deleted; `validate-feature-docs` and `make docs` green

- [x] **Feature-doc backfill: build spine + merge gate + quality gates** `slug: bf-build-merge-gates` — docs for build-spine, merge-gate, quality-gates; delete their exemptions
  - branch: `docs/bf-build-merge-gates`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #139
  - gh_issue: 139
  - files: `docs/features/build-spine.md`, `docs/features/merge-gate.md`, `docs/features/quality-gates.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - build-spine covers worktree isolation + level gating, REST ci-poll rationale, quota gate, plan-note-as-run-record; merge-gate covers the NATIVE/MANAGED seam, EJECTED semantics, landed-merge confirmation; quality-gates covers the one-gate-set contract + kernel/overlay drop-ins
    - Five required sections each; exemptions deleted; `validate-feature-docs` and `make docs` green

- [x] **Feature-doc backfill: pipeline commands** `slug: bf-pipeline-commands` — docs for triage, assess, sweep, next; delete their exemptions
  - branch: `docs/bf-pipeline-commands`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #140
  - gh_issue: 140
  - files: `docs/features/triage.md`, `docs/features/assess.md`, `docs/features/sweep.md`, `docs/features/next.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - triage's decision tree (cull → collapse → group → value) + Ready-flip semantics; assess's seam decomposition + plan-schema pointer; sweep as /build's singleton peer; next as the advisory read-only conductor with per-session cache
    - Five required sections each; exemptions deleted; `validate-feature-docs` and `make docs` green

- [x] **Feature-doc backfill: learning loop + telemetry + funnel** `slug: bf-telemetry-funnel` — docs for tidy, check-in, telemetry, funnel-driver; delete their exemptions
  - branch: `docs/bf-telemetry-funnel`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #141
  - gh_issue: 141
  - files: `docs/features/tidy.md`, `docs/features/check-in.md`, `docs/features/telemetry.md`, `docs/features/funnel-driver.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - Covers the Live/Drain pairing + its CI validator; the raw-lake stream inventory (command-run, issue-touches, claims, funnel, findings, gh-perf, knowledge-search-fallback) with the session-id join key; check-in as the read side; funnel 5a/5b/5c tiers, the structural safe/merge split, FUNNEL_DRIVE_MERGE + per-tick cap
    - Five required sections each; exemptions deleted; `validate-feature-docs` and `make docs` green
  - Run-status: level 2/4 complete (8/8 merged) · items: 15 done / 0 parked / 1 pending (readme-integration)

- [x] **Feature-doc backfill: hooks + gh-perf + review agents** `slug: bf-hooks-perf-agents` — docs for hooks, gh-perf, review-agents; delete their exemptions
  - branch: `docs/bf-hooks-perf-agents`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #142
  - gh_issue: 142
  - files: `docs/features/hooks.md`, `docs/features/gh-perf.md`, `docs/features/review-agents.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - hooks covers the guard inventory (write-lane, stale-branch, board-adapter, build-worktree, subtree-edit), fail-open philosophy, EVAL_RUN self-suppression, session lifecycle; gh-perf covers the gh shim, per-call TSV, budget-drain symptoms; review-agents covers the advisory family, capability probe, legible degradation
    - Five required sections each; exemptions deleted; `validate-feature-docs` and `make docs` green

- [x] **Feature-doc backfill: install + knowledge store + docs generator + presentation plane** `slug: bf-install-store-docs` — docs for install-cli, knowledge-store, docs-generator, presentation-plane; delete their exemptions
  - branch: `docs/bf-install-store-docs`
  - size: M
  - model: sonnet
  - depends-on: feature-docs-gate
  - after: docs-site-features-source
  - source: #143
  - gh_issue: 143
  - files: `docs/features/install-cli.md`, `docs/features/knowledge-store.md`, `docs/features/docs-generator.md`, `docs/features/presentation-plane.md`, `docs/features/backfill-exempt.txt`
  - acceptance:
    - install-cli covers the try → try --demo → init ladder + safety contract + doctor link states + kernel/overlay compose; knowledge-store covers the backend seam + corpus pinning; docs-generator covers source-rendered/zero-drift + determinism + overlay drop-ins; presentation-plane covers the message/template layer, frozen surfaces, the template-refs gate
    - Five required sections each; exemptions deleted; `validate-feature-docs` and `make docs` green

- [x] **docs-reviewer advisory agent** `slug: docs-reviewer-agent` — read-only agent scoring clarity/conciseness/tone/stranger-fit with rule-cited findings, wired into /build 3e for docs PRs
  - branch: `feat/docs-reviewer-agent`
  - size: M
  - model: sonnet
  - after: audience-page
  - source: #144
  - gh_issue: 144
  - files: `claude/agents/docs-reviewer.md`, `claude/commands/build.md`
  - acceptance:
    - Every finding cites a named rule from claude/message-schema.md (BLUF, reference-token rule, shorthand, legend policy) or claude/measurement-proxies.md — never taste; the reader persona is docs/who-its-for.md
    - Sample review of a fixture feature doc (authored inside this item — do not depend on backfill docs existing) produces rule-cited findings
    - /build 3e runs it for PRs touching docs/** or prose *.md; unavailable path emits `skipped — docs-reviewer unavailable`
    - Advisory only — not added to the deterministic CI checks job
  - notes: fourth member of the read-only advisory family; availability per [[Decisions/foundation - Project capability probes]]. Maturity ladder: harden beyond advisory only on evidence of leak.

- [x] **In-repo ADRs: process + documentation system** `slug: adr-doc-system` — docs/adr/0000 (MADR-lite process) + 0001 (the documentation system + migration plan)
  - branch: `docs/adr-doc-system`
  - size: M
  - model: sonnet
  - after: feature-docs-gate, docs-site-features-source
  - source: #145
  - gh_issue: 145
  - files: `docs/adr/0000-adr-process.md`, `docs/adr/0001-documentation-system.md`
  - acceptance:
    - ADR-0000: MADR-lite format, numbering + supersession convention, routing rule (kernel-public decisions → in-repo ADRs; personal/overlay → operator vault)
    - ADR-0001 describes the LANDED mechanism (generator sources, gate list, feature-doc schema, ratchet semantics) — verified against merged reality, not the plan — plus the migration path to an unconditional coverage gate
    - Both render on the docs site; ADR-0001 follows ADR-0000's own convention
  - notes: written after the gate merges so it documents reality — that's what the `after:` edge encodes.
  - Run-status: level 2/4 · 7/8 merged, #279 re-queued after final ratchet fix · items: 14 done / 1 parked / 0 in-flight / 0 skipped

- [x] **README/CONTRIBUTING integration** `slug: readme-integration` — positioning line, links to all new surfaces, exemption list at zero
  - branch: `docs/readme-integration`
  - size: S
  - model: sonnet
  - after: bf-board-hygiene, bf-build-merge-gates, bf-pipeline-commands, bf-telemetry-funnel, bf-hooks-perf-agents, bf-install-store-docs, docs-reviewer-agent, adr-doc-system, architecture-overview, principles-page, agent-discoverability
  - source: #146
  - gh_issue: 146
  - files: `README.md`, `docs/CONTRIBUTING.md`
  - acceptance:
    - README §1 carries the positioning line ("an opinionated process kernel for scaling AI development") + links to principles/architecture/who-its-for; §6 gains Features + ADRs entries
    - CONTRIBUTING documents the feature-doc flow (unclaimed-path CI failure → claim in feature-manifest → write the 5-section doc → merge atomically)
    - `docs/features/backfill-exempt.txt` empty, or its remainder tracked as filed follow-up issues
    - Stranger walkthrough: from README, principles/architecture/audience/any feature doc/ADRs reachable in ≤2 clicks; quality-gates green
  - Run-status: run complete · 16/16 items terminal (15 merged + 1 seed) · epic #131 closing

## Questions
- [x] `step: 3e` `slug: docs-reviewer-agent` — workflow-reviewer LOW finding: no paired vault/config note documents the review-agent family gaining its fourth member (docs-reviewer); add a Patterns/configurations note for the family? **default: no action this run** (kernel repo carries the agent def itself; a vault note is overlay-side operator work)
  - auto-proceed: unanswered at gate → skip; the finding rides the Step 6 summary for operator review
  - → answered: write the vault note now — written to Patterns/temperloop - review-agent advisory family.md (2026-07-11 modal gate)

## Merge gate log
- level 2 · 2026-07-11T17:20Z · modal-approved · PRs #276 #277 #278 #279 #280 #281 #282 #283 (operator: merge all 8, orchestrator fixes trivial adjacent-deletion conflicts as they surface)
