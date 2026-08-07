---
tags: [plan, project/temperloop]
date: 2026-07-23
source_kind: claude-stamped
source_session: 6f858960
last_verified: 2026-07-23
sources:
  - "#671"
epic: 671
status: done
---

# temperloop - sweep parallelization

## Run status

run complete 2026-07-24 · session 6f858960 · 3/3 levels · items: 3 done (#676, #683, #685 merged) / 0 parked / 0 in-flight / 0 skipped · epic #671 closed

## Problem
An attended `/sweep` run serializes every fix even though most issues need nothing from the operator, and the whole run blocks up front on the clarification batch — so the operator's presence (the one thing an attended run uniquely has) is wasted, and an answer given mid-run isn't consumed until the *next* run. Wall-clock is ~N × (worker + CI) when the machinery to parallelize (`build-level.mjs`'s multi-item `parallel()` path) already exists and is proven under `/build`.

## Summary
- **Name the tuning levers before the spec references them.**
  - **L0** — Add `SWEEP_FANOUT_WIDTH` (default 3; 1 = full legacy rollback) and `SWEEP_DETECT_MODEL` (default inherit-session) to `build.config.sh` + knob-registry rows. (#673)
- **Ship the proven half: chunked synchronous fanout, all run modes.**
  - **L1** — Rewrite `/sweep` Phase 2 to drive chunked multi-item `build-level.mjs` invocations with per-chunk merge pass + quota gate; rewrite the three legacy sequential-contract passages; make the park path's release call best-effort (K#275); fan Phase-1 detection out; CHANGELOG + supersession check + feature-doc update. (#674)
- **Ship the novel half: attended question overlap.**
  - **L2** — Launch chunk 1 in the background before the question batch; drive mid-run answers in a same-run tail chunk; legible degradation to the synchronous path; feasibility proof executed during the build. (#675)

Build order: L0 first → L2 last; items in the same level ship together.

## Sequencing notes
Fully sequential by nature — all three items converge on one spec file, so there is no denied parallelism (the auditor confirmed decomposing further would only manufacture more `depends-on` chains on the same lines). L0→L1 is logical order only (different files; the rewritten spec should not reference knobs that don't exist yet — doc-freshness, not lint-enforced and not a merge conflict). L1→L2 is a true merge-safety edge (same file, same Phase-2 sections). The Contract's "no change to `build-level.mjs`" is a standing constraint on all three items, not an item.

## Re-triage signals
- none

## Questions

- [x] `step: 2.5` — Create 3 tracking issues for the Contract-derived items (sweep-fanout-knobs, sweep-tier1-chunked-fanout, sweep-tier2-question-overlap)? **default: create** → default taken: create/keep (#673/#674/#675 stand; level-0 timed gate window elapsed 2026-07-23 with no objection)
  - auto-proceed: created #673/#674/#675 at run start (the default); retained at the level-0 gate.

## Items

- [x] **Add sweep fanout + detect-model knobs** `slug: sweep-fanout-knobs` — add `SWEEP_FANOUT_WIDTH` and `SWEEP_DETECT_MODEL` to the batch-pipeline config with registry rows
  - branch: `chore/sweep-fanout-knobs`
  - size: S
  - kind: code
  - model: sonnet
  - source: #671
  - gh_issue: 673
  - files: `workflows/scripts/build/build.config.sh`, `workflows/scripts/config/knob-registry.tsv`
  - acceptance:
    - `SWEEP_FANOUT_WIDTH` defined in `build.config.sh`, default `3`; `SWEEP_DETECT_MODEL` defined, default = inherit-session sentinel (empty), per the ratified Contract
    - `knob-registry.tsv` carries a row for each; `check-knob-registry.sh` passes
    - The `SWEEP_DETECT_MODEL` registry row's doc column states inline why the default is inherit-session, not a cheap tier (underspecification detection is judgment work; a missed ambiguity silently reaching Phase 2 is the costly failure — ratified brief REQ-5 disposal)
    - No consumer/spec changes in this item (the `sweep.md` revision lands in `sweep-tier1-chunked-fanout`)
  - activation:
    - class: A
    - proof: "bash -c 'source workflows/scripts/build/build.config.sh && [ -n \"$SWEEP_FANOUT_WIDTH\" ] && grep -q SWEEP_DETECT_MODEL workflows/scripts/build/build.config.sh'"
  - notes: design source [[Designs/temperloop - sweep parallelization]] § 4; decision record [[Decisions/temperloop - sweep two-tier parallelization]]. `SWEEP_DETECT_MODEL` empty = inherit is Contract-pinned — do not default it to a named cheap tier (auditor suggestion declined at assess; rationale in the brief's REQ-5 disposal).

- [x] **Rewrite /sweep Phase 2 as chunked synchronous fanout (tier 1)** `slug: sweep-tier1-chunked-fanout` — the proven half: multi-item chunked invocations replace the one-at-a-time loop, all run modes
  - branch: `feat/sweep-tier1-chunked-fanout`
  - size: M
  - kind: code
  - after: sweep-fanout-knobs
  - source: #671
  - gh_issue: 674
  - files: `claude/commands/sweep.md`, `CHANGELOG.md`, `docs/features/sweep.md`, `docs/adr/0012-sweep-two-tier-parallel-execution.md`
  - acceptance:
    - Phase 2 drives as chunked multi-item `build-level.mjs` invocations (width = `${SWEEP_FANOUT_WIDTH}`) with a per-chunk merge pass and per-chunk quota gate; the Step-3.5 terminal-state assertion accounts for every issue across all chunks
    - `SWEEP_FANOUT_WIDTH=1` reproduces today's behavior exactly (sequential drive, questions-first ordering); `--dry-run` remains zero-mutation
    - The three legacy passages are rewritten: "Sequential — never parallel" (operating principle), "Claim-first, per issue … so WIP stays at 1" (→ the multi-claim-window contract, kernel § Claim held until Done), and Step 3's "Do not pre-spawn or overlap issues"; the park path treats a `release.sh` non-latest-marker refusal as expected (K#275), never an error
    - Phase-1 underspecification detection fans out across parallel subagents at `${SWEEP_DETECT_MODEL}`
    - CHANGELOG carries an additive entry naming `SWEEP_FANOUT_WIDTH` as the opt-out lever and the concurrent-CI resource implication; the PR body links-and-supersedes a prior sequential-design `Decisions/` note or states none exists
    - `docs/features/sweep.md` behavior sections updated for the chunked model; `validate-command-run-emit.sh` still passes
  - activation:
    - class: A
    - proof: "grep -q SWEEP_FANOUT_WIDTH claude/commands/sweep.md && ! grep -q 'Sequential — never parallel' claude/commands/sweep.md"
  - notes: design source [[Designs/temperloop - sweep parallelization]] §§ 4-5, 15; decision record [[Decisions/temperloop - sweep two-tier parallelization]]. The ratified ADR draft is staged OUTSIDE the repo at `/private/tmp/claude-501/-Users-travis-dev-temperloop/6f858960-b26c-42e8-84cd-1c741c154272/scratchpad/0012-sweep-two-tier-parallel-execution.md` — the worker must copy it verbatim into the worktree at `docs/adr/0012-sweep-two-tier-parallel-execution.md` so it rides this PR (it was moved out of the parent tree to keep the checkout clean). The `after:` edge on the knobs item is doc-freshness/logical order only (no lint currently scans `claude/commands/*.md` for unregistered knob references; no merge conflict). `model:` deliberately absent despite size M + kind code — spec-prose semantics are verified only by advisory review (`workflow-reviewer`), so per tier-by-verification the item inherits the session model; the schema carve-out question is tracked as #672.
  - review: workflow-reviewer

- [x] **Add attended question-overlap tier (tier 2)** `slug: sweep-tier2-question-overlap` — the novel half: background chunk-1 launch before the question batch, same-run tail chunk for answered issues
  - branch: `feat/sweep-tier2-question-overlap`
  - size: M
  - kind: code
  - depends-on: sweep-tier1-chunked-fanout
  - source: #671
  - gh_issue: 675
  - files: `claude/commands/sweep.md`, `docs/features/sweep.md`
  - acceptance:
    - Attended run with width > 1: chunk 1 (the clean set) launches as a background Workflow invocation *before* the Phase-1 question batch renders
    - Issues answered mid-run drive in a same-run tail chunk
    - Background invocation unavailable or refused → legible degradation notice + the tier-1 synchronous path; the unattended arm never uses tier 2 (#626 — headless runs have no background-completion re-invoke loop)
    - Feasibility proof executed **during this item's build**: the worker demonstrates one background Workflow launch + completion-notification resume in the attended session and records that outcome in the PR body's verification surface — never deferred to future production use
    - `docs/features/sweep.md` updated for the overlap tier
  - activation:
    - class: A
    - proof: "grep -q 'tail chunk' claude/commands/sweep.md"
  - notes: design source [[Designs/temperloop - sweep parallelization]] §§ 2, 4-5, 15. **Mechanism pinned (assess):** the harness Workflow-tool contract documents background execution — the call returns immediately with a task id and a `<task-notification>` re-invokes the driver on completion (observed live in the authoring session). `build.md` §415's "backgrounded work silently dies" concerns a *subagent's* backgrounded shell process in a headless worker — a different execution context; it does not contradict this. If the capability is nonetheless refused at build time, the fallback shape is a `Bash run_in_background` wrapper (the proven sleep/ci-poll pattern) or the designed tier-1 degradation — never a silent stall.
  - review: workflow-reviewer
