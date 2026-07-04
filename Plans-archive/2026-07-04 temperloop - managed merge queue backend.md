---
tags: [plan, project/temperloop]
date: 2026-07-04
source_kind: claude-stamped
source_session: 922cbf1c
last_verified: 2026-07-04
sources:
  - "#13"
epic: 13
status: done
---

# temperloop - managed merge queue backend

## Run status

run completed 2026-07-04 10:05 UTC · session 922cbf1c · all 3 levels merged · items: 4 done / 0 parked / 0 in-flight / 0 skipped · epic temperloop#13 closed

## Problem

TemperLoop's level merge gate — its most differentiating layer — currently assumes GitHub's native merge queue, which requires an org-owned repo on a paid plan. The target cohort (solo devs and 1–10-person teams, ~75% of Claude Code adoption) can't provision that, so the exact users the kernel is being packaged for hit a wall at the gate step. Design ratified 2026-07-04: a `merge_backend: native | managed` seam — native preferred and auto-detected, managed replicating queue semantics serially with existing primitives on a bare free repo.

## Summary

- **Give the spine a backend axis (selection).**
  - **L0** — `gate.sh backend` subcommand: closed-JSON NATIVE|MANAGED verdict from a rulesets probe, with a pure-string `BUILD_MERGE_BACKEND` override knob in build.config.sh. (#15)
- **Give the spine managed-queue mechanics.**
  - **L1** — `gate.sh managed-merge`: per-PR serial update-branch → SHA-pinned CI re-poll → merge → confirmed-MERGED, with an EJECTED outcome on red; `--strict|--non-strict` preserves the cheap non-strict path. (#16)
- **Make the orchestrator drive it and tell the story.**
  - **L2** — build.md Step 4 rewired onto the backend axis: scripted probe, managed-set serial loop, EJECTED disposition menu, pinned consent/resume state table (no new label). (#17)
  - **L2** — README/docs: the whole-ladder-on-a-free-repo story, selection rules, merge-around caveat. (#18)

Build order: L0 first → L2 last; items in the same level ship together.

## Sequencing notes

L0 → L1 is a hard merge chain (both add subcommand + dispatch arms to gate.sh — identical case-block lines). The two L2 items are parallel-safe (disjoint files: `claude/commands/build.md`+`claude/plan-schema.md` vs `README.md`+`docs/`); the docs item is written against the consent/resume state table pinned in this plan, so it need not trail the wiring item. All items land upstream in `Towheads/temperloop` (checkout: `~/dev/foundation-kernel`) and flow to foundation later via `make update-kernel` — nothing in this plan touches the foundation checkout.

## Re-triage signals

All three ephemeral signals were **confirmed by Travis at the approval gate (2026-07-04)** — recorded here for the audit trail; the decision note has been amended to match:

- **`tl:queued` label subtracted from the ratified design.** Both reviewers independently flagged it: a consent-time PR label is a third copy of queue state (plan-note `[m]` sentinels + live PR probe already cover it), duplicates the existing `FUNNEL_MERGE_PENDING_LABEL` idiom, and imports label-provisioning burden — the exact dual-state drift TemperLoop criticizes in competitors. Resume rides plan-note state ∩ live PR probe (item `build-step4-managed-wiring`). **Confirmed.**
- **Backend is the successor of the queue axis, not a third axis.** `native` ≡ old cells C/D; `managed` absorbs old cells A/B with `strict` demoted to a `--strict|--non-strict` sub-flag (non-strict keeps today's immediate cheap merge — no added CI cost on non-strict repos). Old cells retired by name. **Confirmed.**
- **Probe-failure direction = MANAGED + `probe_failed:true`.** Rationale: a managed merge on a queue-armed repo is rejected loudly by branch protection (visible, safe); the reverse (assuming native on a repo without a queue) arms auto-merge semantics nobody chose. **Confirmed.**
- none persistent — no dupes, no invalid members, no missing work routed to triage.

## Items

- [x] **gate.sh: add `backend` subcommand + BUILD_MERGE_BACKEND knob** `slug: gate-backend-probe` — merged in temperloop#19 (2026-07-04)
  - branch: `feat/gate-backend-probe`
  - repo: Towheads/temperloop
  - size: M
  - kind: code
  - model: sonnet
  - source: #13
  - gh_issue: 15
  - pr: 19
  - pushed_sha: 115d2ebb2f1ee30c5b68bd5a90b38d942dadf367
  - files: `workflows/scripts/build/gate.sh`, `workflows/scripts/build/build.config.sh`, `workflows/scripts/build/tests/test_gate.sh`
  - acceptance:
    - `gate.sh backend <owner>/<repo>` emits one-line closed JSON `{"outcome":"NATIVE"|"MANAGED",...}`, symmetric with `gate.sh strict`; under `auto` it probes `gh api repos/<owner>/<repo>/rules/branches/<default>` for a `merge_queue` rule (the `land__requires_pr` shape in `workflows/scripts/lib/land-on-protected-main.sh`)
    - `BUILD_MERGE_BACKEND` is a pure `: "${VAR:=auto}"` string default in build.config.sh (values `auto|native|managed`; `native`/`managed` honored as explicit override) — **no network call at config-source time**; the probe executes only inside the `gate.sh backend` invocation
    - Probe failure emits `{"outcome":"MANAGED","probe_failed":true}` — fail-safe direction documented in the subcommand header (managed on a queue-armed repo fails loudly at branch protection; the reverse silently arms auto-merge)
    - Offline tests via the `_gate_gh` seam cover: merge_queue rule present → NATIVE, absent → MANAGED, probe error → MANAGED+probe_failed, explicit override wins without probing; auto-globbed by `make test-build`; `make quality-gates` green
  - notes: resolver home per architecture review — probe lives in gate.sh (symmetric with `strict`), never in config code; knob is machine-scope override/test seam only, `auto` is the only path a multi-repo host should use. Backend-seam precedent: `board_backend()` in `workflows/scripts/board/lib/board.sh`. See [[Decisions/temperloop - Managed merge queue (backend seam) — proposed]].

- [x] **gate.sh: add `managed-merge` serial per-PR subcommand** `slug: gate-managed-merge` — merged in temperloop#21 (2026-07-04)
  - branch: `feat/gate-managed-merge`
  - repo: Towheads/temperloop
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: gate-backend-probe
  - source: #13
  - gh_issue: 16
  - pr: 21
  - pushed_sha: e56d6a2195acb3b35e4ae197e48444e0dca65036
  - files: `workflows/scripts/build/gate.sh`, `workflows/scripts/build/tests/test_gate.sh`
  - acceptance:
    - `gate.sh managed-merge <owner>/<repo> <pr> [--strict|--non-strict]` (strict default): strict path runs `gh pr update-branch` → SHA-pinned re-poll (`ci-poll.sh --sha`, #254 guard) → `gh pr merge --merge --delete-branch` → confirmed-MERGED poll (#130 guard: success only on `state==MERGED` + `mergedAt`); `--non-strict` skips update-branch + re-poll (preserves the old cell-A immediate-merge cost profile)
    - CI red after update-branch → `{"outcome":"EJECTED","failed_run_ids":[...]}` with a distinct exit code; no merge attempted; gate.sh writes **no** plan-note sentinels and **no** labels (header contract — consent and writeback stay orchestrator-side)
    - Closed-JSON outcome set extended compatibly; existing subcommands (`read`/`strict`/`risk`/`queue`/`nudge`/`poll`) byte-identical — an offline test asserts their argv/output unchanged (the no-behavior-change-on-native guarantee)
    - Offline tests via `_gate_gh`: green strict path, green non-strict path, eject path, and merge-rejected-by-protection surfacing as a distinct non-silent outcome
  - notes: per-PR composite only — the whole-set loop, ordering, and stop/continue-after-eject policy stay in the orchestrator (architecture review: a set-loop in gate.sh would move merge-order policy into the spine). See [[Decisions/foundation - Timed merge-gate auto-merge (supersedes never-auto-merge-main)]] for the consent regime this plugs into. Follow-up filed: temperloop#23 (managed-merge CI-repoll timeout die()s instead of TIMEOUT/exit 4).

- [x] **build.md: rewire Step 4 onto the merge-backend axis** `slug: build-step4-managed-wiring` — merged in temperloop#24 (2026-07-04)
  - branch: `feat/build-step4-managed-wiring`
  - repo: Towheads/temperloop
  - size: M
  - kind: code
  - after: gate-backend-probe, gate-managed-merge
  - source: #13
  - gh_issue: 17
  - pr: 24
  - pushed_sha: 0c72cc63e83a0a8d539a55012bc7846569e73edf
  - files: `claude/commands/build.md`, `claude/plan-schema.md`
  - acceptance:
    - Step 4a's prose-only queue probe is replaced by the scripted `gate.sh backend` call; the regime table documents backend as the **successor** of the queue axis — `native` ≡ old cells C/D, `managed` absorbs old cells A/B with strict as the `--strict|--non-strict` sub-axis — with a one-line migration note retiring the old cell names (no undeclared third axis over the 2×2)
    - The managed-set loop is specified orchestrator-side: per-PR `gate.sh managed-merge` calls in plan-item order; **EJECTED gets its own disposition set** (re-spawn worker to fix the failure / skip / leave for manual triage) — 4c's menu stays conflicts-only
    - Resume-without-re-consent is pinned mechanically: consent is recorded as an orchestrator-appended gate-log line on the plan note (level, timestamp, consented PR list — a small `plan-schema.md` addition, orchestrator-written like `pr:`/`pushed_sha:`); the resume state table (consent-line × `[m]`/`[~]` sentinel × live PR state → mark-merged / resume-loop / fresh-gate / escalate) is written into Step 4; **no new label** — the plan note stays the single source of truth, with `FUNNEL_MERGE_PENDING_LABEL` cross-referenced as the funnel-plane cross-tick marker, not duplicated
    - 4b's timed/modal gate regimes and 4d's sentinel writeback are unchanged (diff shows no edits to those subsections beyond cross-refs); workflow-reviewer pass run before commit (advisory — ran in-worktree; 2 blockers + 3 lesser findings fixed pre-return)
  - notes: partially supersedes [[Decisions/foundation - build native merge-queue adoption]] (the queue-absent cell is re-architected); 4b-train recorded as RETIRED — absorbed by the MANAGED backend (merge_group batches on NATIVE, the scripted managed loop replaces it on MANAGED). Spec-prose judgment → no model stamp, inherited session model.

- [x] **Docs: managed merge queue + free-repo ladder story** `slug: managed-queue-docs` — merged in temperloop#22 (2026-07-04)
  - branch: `docs/managed-queue-docs`
  - repo: Towheads/temperloop
  - size: S
  - kind: code
  - model: sonnet
  - after: gate-backend-probe, gate-managed-merge
  - source: #13
  - gh_issue: 18
  - pr: 22
  - pushed_sha: 53a68538b31966703b81a9bad11de69f1b3118cf
  - files: `README.md`, `docs/`
  - acceptance:
    - README + docs tell the ladder story: the full merge-gated ladder runs on a free personal repo (no org, no paid plan), with backend selection rules (auto probe preferred; `BUILD_MERGE_BACKEND` as explicit override/test seam)
    - The between-ticks merge-around caveat is documented with the recommendation to enable plain branch protection as the only-path enforcement
    - Cross-references failure-mode 03 (queued ≠ merged) and the consent/resume behavior as pinned by this plan's state table
  - notes: parallel-safe with `build-step4-managed-wiring` (disjoint files, state table pinned at assess time). One CI round-trip: the new docs/managed-merge-queue.md was unclassified in kernel-manifest.txt — fixed inline (one manifest line), force-pushed, re-greened.
