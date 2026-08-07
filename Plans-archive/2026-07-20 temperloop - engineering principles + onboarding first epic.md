---
tags: [plan, project/temperloop]
date: 2026-07-20
source_kind: claude-stamped
source_session: f73c60f8
last_verified: 2026-07-20
sources:
  - "#606"
  - "#605"
  - "Designs/temperloop - kernel starter engineering principles.md"
epic: 606
status: done
---

# temperloop - engineering principles + onboarding first epic

## Run status
run started 2026-07-20 15:13 · session a27f4557 · ALL LEVELS COMPLETE · items: 8 done / 0 parked / 0 in-flight / 0 skipped

## Problem
On a fresh kernel install the review gates (`/assess` Step 3, `/build` 3e) and the build workers run with **zero engineering criteria** — the `§ Principles` seam ships as a mechanism with no content — and the branch/PR contract assumes GitHub substrate (protected main, required `checks`, merge queue, auto-delete) that nobody has arranged. The adopter also meets their first epic with no worked example of the funnel. Epic #606 (materialized from the ratified K#599 design walk) closes both: a kernel-shipped principles layer resolved point-of-use, and onboarding delivered as the adopter's first executed epic — "Set up \<project\> with temperloop" — so the demo and the setup are the same work.

## Summary
- **Empty principles seam — reviews and workers judge against nothing.**
  - **L0** — Ship `claude/engineering-principles.md` (seven genericized criteria + canonical header) with its kernel-manifest, VERSIONING, and feature-manifest registrations atomic, plus ADRs 0009/0010.
  - **L1** — Wire point-of-use resolution + semantic merge (kernel ∪ project § Principles) into `assess.md` Step 3 / `build.md` 3e, feed the same set to `build.md` 3c workers, and retire every no-principles degradation branch in one sweep.
- **Unconfigured substrate + no worked example — onboarding as the first executed epic.**
  - **L0** — Fix the zero-CI poll hang: a distinct, legible "no CI configured" outcome in `ci-poll.sh` / `build.md` 3g instead of an hour-long `TIMEOUT`. (#605)
  - **L1** — Author the kernel-shipped first-epic template (interview-first → compose → disclose → apply, structural congruence, non-admin packet, walk-backs), pinned outside `claude/commands/`.
  - **L2** — Offer the epic at init/first-run with decline floors, a durable re-offer pointer, and a non-interactive skip notice.
  - **L2** — Verify consent + effect on a disposable admin fixture (consented writes land, declined writes don't, transition-window invariant, non-admin packet).
- **Verification and documentation tails.**
  - **L3** — Zero-CI execution check: pre-CI epic items complete with the legible skip, no poll hang (externally gated on the #605 consumable).
  - **L3** — Expand the feature doc to full (uninstall/undo paths, reviewer-catalog cross-ref, complete first-epic flow).

Build order: L0 first → L3 last; items in the same level ship together.

## Sequencing notes
- **L0 merge is blocking-now on operator sign-off** — Contract (d): the genericized principle text is operator-approved against the six source stageFind vault notes before merge. (temperloop is hand-driven with explicit per-build approval anyway.)
- **Feature-manifest atomicity** (architecture-review HIGH): `validate-feature-docs.sh` is full-coverage — an unclaimed tracked file fails CI the moment it lands, and a claimed slug demands its doc in the same state. So L0 carries a *minimal-but-valid* five-section `docs/features/engineering-principles.md` + the feature-manifest claim; the template PR adds its own path claim under the same slug; the L3 doc item is content **expansion only**.
- ADRs 0009/0010 are already authored (untracked working-tree files) and ride the L0 PR; the existing `docs/adr/*` claims cover them.
- Both L1 items touch `workflows/scripts/kernel/kernel-manifest.txt` — it is `merge=union` (`.gitattributes`), so parallel appends are safe; no merge edge needed between them.
- The seam PR's CHANGELOG entry classifies as **minor** (a Pipeline-command-contract change — the documented no-principles degradation branch is retired; behavior is a superset), not patch.
- **#605 (zero-CI poll) is IN this plan** — pulled in by operator decision at the approval gate (2026-07-20): the ratified Contract's "or the spec-level skip until it lands" fallback turned out not to exist (requirements-audit HIGH), and the plan was #605's only consumer. `zero-ci-poll-fix` lands at L0 (disjoint files from the principles item; its `build.md` 3g edit precedes the L1 seam's 3c/3e edits by level, so no parallel conflict), its PR carries `Closes #605` via `gh_issue:`, and the L3 leg's former external `gate_check:` is now an ordinary in-plan `depends-on:` edge. #605 stays its own standalone issue (closed by the PR), not a minted child of epic #606.

## Re-triage signals
- *Resolved at the approval gate (2026-07-20):* the #605 pull-in question — the epic's Contract listed #605 under *Consumes* with a "spec-level skip" fallback the requirements audit showed doesn't exist. Operator decided **pull it in**: added as `zero-ci-poll-fix` (L0, `gh_issue: 605`); the `zero-ci-run-check` leg's external `gate_check:` was replaced by an in-plan `depends-on:` edge. Recorded here as a deliberate scope amendment to the ratified epic, made by the operator, not by `/assess`.
- No other signals — none re-queued.

## Items

- [x] **Ship claude/engineering-principles.md — seven kernel engineering principles** `slug: kernel-principles-file` — add the kernel principles contract file with all registrations atomic
  - branch: `feat/kernel-principles-file`
  - gh_issue: 607
  - pr: 617
  - pushed_sha: 54ca588
  - size: M
  - kind: code
  - model: sonnet
  - source: #606
  - files: `claude/engineering-principles.md`, `docs/features/engineering-principles.md`, `docs/features/feature-manifest.txt`, `workflows/scripts/kernel/kernel-manifest.txt`, `VERSIONING.md`, `docs/adr/0009-kernel-engineering-principles-layer.md`, `docs/adr/0010-onboarding-as-first-executed-epic.md`
  - acceptance:
    - Seven principles (every-behavior-every-state testing w/ no coverage-% gate; strict-from-day-one; recorded-fixtures-never-live-network; verify-at-the-human-AI-seam; counter-AI-failure-modes-structurally; blast-radius boundaries; advisory-over-enforced), each phrased as a flaggable review criterion with a one-line rationale.
    - Header canonically carries: (a) the four-way surfaces relationship incl. the both-active rule; (b) merge semantics — the single statement site; (c) the advisory posture (findings advise, never mechanically gate); (d) project-section markers: extend default, `mode: replace`, named exclusions.
    - Content fidelity (Contract d): the genericized text is operator-approved against the source vault notes **before merge**.
    - Registrations atomic in this PR: kernel-manifest entry, VERSIONING.md contract-surface row, feature-manifest claim + a minimal-but-valid five-section `docs/features/engineering-principles.md` (`validate-feature-docs.sh` green — the claim/doc pair cannot defer to L3).
    - ADRs 0009/0010 land in this PR; full `checks` green (Contract h slice).
  - activation:
    - class: A
    - proof: "grep -q 'claude/engineering-principles.md' workflows/scripts/kernel/kernel-manifest.txt && grep -q 'engineering-principles' docs/features/feature-manifest.txt"
  - notes: Source notes to genericize — [[Decisions/stageFind - Quality bars]], [[Decisions/stageFind - Testing baseline]], [[Patterns/stageFind - Verify at the human-AI seam]], [[Patterns/stageFind - Counter AI failure modes structurally]], [[Patterns/stageFind - Limit blast radius through boundaries]], [[Decisions/stageFind - Advisory over enforced AI-discipline]]. Design: [[Designs/temperloop - kernel starter engineering principles]] (dim 4); ADR 0009 is the public record. Per-language content is deliberately excluded — the reviewer catalog (ADR-0007/0008) owns that axis.

- [x] **ci-poll: distinct zero-CI outcome — legible skip, not TIMEOUT** `slug: zero-ci-poll-fix` — a SHA with no check-runs gets a named zero-CI verdict and a legible 3g skip, never an hour-long TIMEOUT
  - branch: `fix/zero-ci-poll-fix`
  - size: S
  - kind: code
  - model: sonnet
  - gh_issue: 605
  - pr: 619
  - pushed_sha: d8a8106
  - source: #605
  - files: `workflows/scripts/build/ci-poll.sh`, `claude/commands/build.md`
  - acceptance:
    - `ci-poll.sh` distinguishes "no check-runs ever appeared on the head SHA" from "checks appeared but haven't finished": the zero-CI case yields a distinct, named verdict (not `TIMEOUT`) well before the full poll window elapses.
    - The zero-CI verdict fires only after a bounded grace window, so slow-starting CI (checks that appear seconds after push) is never misclassified as no-CI.
    - `build.md` 3g maps the verdict to the legible "no CI configured" skip notice — the item proceeds with the skip recorded, never a false failure and never a poll-window hang.
    - CI-present behavior is unchanged: when check-runs exist, polling, verdicts, and timeouts behave exactly as today.
  - activation:
    - class: A
    - proof: "grep -qiE 'no CI configured' workflows/scripts/build/ci-poll.sh claude/commands/build.md"
  - notes: Pulled into this plan at the approval gate (2026-07-20) — a deliberate operator scope amendment to the ratified epic: the Contract listed #605 under *Consumes* with a "spec-level skip" fallback that the requirements audit (HIGH) showed doesn't exist, and this plan was #605's only consumer. PR carries `Closes #605`. This is the consumable the `zero-ci-run-check` leg (L3) depends on.

- [x] **Wire point-of-use principle resolution + merge into review and worker feeds** `slug: principles-merge-seam` — assess.md Step 3 + build.md 3e/3c consume kernel ∪ project § Principles; no-principles branches retired
  - branch: `feat/principles-merge-seam`
  - gh_issue: 608
  - pr: 624
  - pushed_sha: 9676798
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: kernel-principles-file
  - source: #606
  - files: `claude/commands/assess.md`, `claude/commands/build.md`
  - acceptance:
    - Contract (a): fresh kernel-only checkout, no Priorities note — reviews and workers receive the kernel set; provenance names the kernel source and the empty project slot.
    - Contract (b): project with § Principles — merged union; duplicates collapse once with project phrasing winning; contradictions named with kernel-principle overrides distinguished; `mode: replace`, named exclusions, and an explicit `none` opt-out honored; empty/malformed section → treated as absent + degradation notice.
    - Complete retirement sweep in this one PR: the obsolete no-principles branches in assess.md Step 3 AND their same-spec consumers — build.md 3e's "reviewed without declared principles" tally + its Step 6 summary line, and assess.md Step 5's "no declared principles — generic review" echo — replaced by source-naming provenance (no dangling internal references).
    - build.md 3c worker prompts carry the effective set (summary form) — the same merged set as reviewers, computed once per run.
    - Contract (c) efficacy: a planted violation of a named principle yields a review finding citing that principle; the citation disappears when the principle is excluded.
  - activation:
    - class: A
    - proof: "grep -q 'engineering-principles' claude/commands/assess.md && grep -q 'engineering-principles' claude/commands/build.md"
  - notes: Seam origin — [[Decisions/foundation - Project engineering principles declared in Priorities note, fed to review agents]]. `workflow-reviewer` pass is mandatory for `claude/commands/*.md` diffs (build 3e). CHANGELOG classification: minor (retiring a documented degradation branch is a Pipeline-command-contract change), not patch. Merge semantics stay stated ONLY in the L0 file's header — referenced here, never restated.

- [x] **Author the first-epic template — "Set up \<project\> with temperloop"** `slug: first-epic-template` — kernel-shipped pre-designed epic body: interview-first → compose → disclose → apply
  - branch: `feat/first-epic-template`
  - gh_issue: 609
  - pr: 623
  - pushed_sha: 5941597
  - size: M
  - kind: code
  - model: sonnet
  - after: kernel-principles-file
  - source: #606
  - files: `claude/templates/first-epic-setup.md`, `workflows/scripts/kernel/kernel-manifest.txt`, `docs/features/feature-manifest.txt`
  - acceptance:
    - Template ships at a path **outside `claude/commands/`** (pinned: `claude/templates/first-epic-setup.md` — a bare `.md` under `claude/commands/` is auto-discovered as a slash command, per the kernel-manifest's own warning), with its kernel-manifest entry + feature-manifest path claim (same `engineering-principles` slug) in the same PR.
    - Carries a well-formed `## Contract` that `/assess` epic-decomposition mode decomposes **without reshaping** (Contract e slice); the `design-brief:` provenance marker targets the repo-resident ADR 0010 (stranger-resolvable).
    - Phase A (interview, no writes): upfront probes — `gh` auth/repo resolution, admin-rights, `gate.sh backend` — price every question; each external-write question carries its consequence line.
    - Phase B (composed change-set): structural congruence — the required-`checks` context enters the set only with a configured producer; no-Actions → protection without required contexts + managed-merge `--non-strict` posture recorded; any write whose later decline would strand earlier state carries its walk-back item; static `checks`-name agreement (Contract g, static half).
    - Phase C (apply as funnel levels: L0 principles / L1 consented GitHub writes / L2 CI scaffold) + the non-admin path (rights probe → admin packet, never a silent skip or unconsented write). Gate scope: zero-CI *execution* (Contract g2) is excluded — owned by `zero-ci-run-check`.
  - activation:
    - class: A
    - proof: "grep -q 'claude/templates/first-epic-setup.md' workflows/scripts/kernel/kernel-manifest.txt"
  - notes: Design: [[Designs/temperloop - kernel starter engineering principles]] (dim 4, Produces 4); ADR 0010. Template is static kernel-shipped data — the offer (next item) is the control flow that consumes it. References `gate.sh backend` / managed-merge — consumed, never reimplemented (`docs/managed-merge-queue.md`).

- [x] **Offer the first epic at init/first-run with decline floors** `slug: first-epic-offer` — init/first-run offers the setup epic; declines leave working floors + a durable re-offer pointer
  - branch: `feat/first-epic-offer`
  - gh_issue: 610
  - pr: 632
  - pushed_sha: 1b792c9
  - size: M
  - kind: code
  - model: sonnet
  - after: first-epic-template
  - source: #606
  - files: `bin/subcommands/init.sh`
  - acceptance:
    - The offer appears at init/first-run on a fresh kernel-only checkout; accepting files the epic from the template; a re-run does not duplicate it.
    - Whole-epic decline → inline principles interview + a durable re-offer pointer (a Backlog item naming the unconfigured substrate); each level independently declinable with the skip recorded (Contract e decline slice).
    - Non-interactive runs get a legible skip notice, never a hang; point-of-use principle defaults and the managed-merge floor apply regardless of decline.
    - The inline fallback interview **references** the question set from the template/principles file (single-statement-site discipline) — it never restates it.
  - activation:
    - class: A
    - proof: "grep -qiE 'first[-_ ]?epic|first-epic-setup' bin/subcommands/init.sh"
  - notes: Drift guard per architecture review — two hand-maintained copies of the interview question set would diverge; the offer points at the template's copy.

- [x] **Verify consent + effect on a disposable admin fixture** `slug: first-epic-consent-fixtures` — drive the composed change-set through a real fixture repo: consented writes land, declined writes don't
  - branch: `test/first-epic-consent-fixtures`
  - gh_issue: 611
  - pr: 641
  - pushed_sha: 262bfab
  - size: M
  - kind: code
  - model: sonnet
  - after: first-epic-template
  - source: #606
  - files: `workflows/scripts/build/fixtures/verify-first-epic-consent.sh`, `workflows/scripts/config/knob-registry.tsv`
  - acceptance:
    - Gate scope: this item owns Contract (f), (f2), (f3), and the fixture half of (g); it EXCLUDES (g2) zero-CI execution — owned by `zero-ci-run-check`, whose failure does not count against this item.
    - Contract (f): on a disposable admin fixture repo, each consented write verifiably lands and each declined write provably does not; a scope-blocked write yields the admin packet; `gate.sh backend` is consumed, not reimplemented.
    - Contract (f2) transition-window invariant: a PR is driven through every intermediate state the composed change-set creates; at no point does a required status context exist without a configured producer; the no-Actions composition never arms the requirement.
    - Contract (f3): on a non-admin fixture, the rights probe fires, L1 composes into the admin packet, no write is attempted, and the epic still completes its non-admin levels through the funnel.
    - Contract (g), fixture half: the scaffolded workflow's job is named `checks` and matches the composed protection; the no-Actions choice records the local-gates/`--non-strict` posture and scaffolds nothing.
  - activation:
    - class: A
    - proof: "grep -q 'confirm-live-writes' workflows/scripts/build/fixtures/verify-first-epic-consent.sh"
  - notes: Deliverable is a committed, repeatable fixture harness + a recorded run (evidence in the PR body per the PR-verification-surface rule). Harness landed at `workflows/scripts/build/fixtures/verify-first-epic-consent.sh` — outside `tests/` and unnamed `test_*.sh` on purpose, so it is never swept into the automated, zero-network gate set (it makes REAL live `gh` writes against a disposable `tl-fixture-*` repo, gated behind an explicit `--confirm-live-writes` flag). Already covered by the existing broad manifest globs (`build-spine workflows/scripts/build/*` / `kernel workflows/scripts/build/*`) — no manifest edit needed. Requires live `gh` writes against disposable fixture repos only — never a real adopter repo. Recorded run: PASS 24 / FAIL 0 against `towhead/tl-fixture-admin-kt611b`, repeated once more to confirm idempotency (same result). MANUAL CLEANUP NEEDED — `towhead/tl-fixture-admin-kt611` and `towhead/tl-fixture-admin-kt611b` (both disposable `tl-fixture-*`; `gh repo delete` lacks the `delete_repo` scope, confirmed failing as expected).

- [x] **Zero-CI execution check — legible skip, no poll hang** `slug: zero-ci-run-check` — extend the fixture harness with the pre-CI leg once the zero-CI outcome exists in the poll path
  - branch: `test/zero-ci-run-check`
  - gh_issue: 612
  - pr: 643
  - pushed_sha: 132c63c
  - size: S
  - kind: code
  - model: sonnet
  - depends-on: zero-ci-poll-fix
  - after: first-epic-consent-fixtures
  - source: #606
  - acceptance:
    - Gate scope: this item owns Contract (g2) ONLY — pre-CI epic items complete with the legible "no CI configured" skip notice, no poll-window hang; it excludes (f)/(f2)/(f3)/(g), owned by `first-epic-consent-fixtures`.
    - On a fixture repo with no CI configured, the first-epic L0 PR path completes with the legible zero-CI verdict — not `TIMEOUT` after the full poll window.
    - The zero-CI leg is added to the committed fixture harness; run evidence recorded in the PR body.
  - notes: Consumes the zero-CI verdict `zero-ci-poll-fix` (L0) ships — a merge-safety `depends-on:` (the verdict contract is the shared schema; an `after:` would be satisfied by a skip, and this leg cannot run without the fix merged). The former external `gate_check:` on #605 was retired when the fix was pulled into this plan at the approval gate.

- [x] **Expand the feature doc to full** `slug: principles-feature-doc` — grow the minimal L0 doc into the complete feature doc: uninstall/undo paths, catalog cross-ref, full first-epic flow
  - branch: `docs/principles-feature-doc`
  - gh_issue: 613
  - pr: 644
  - pushed_sha: 98f533a
  - size: M
  - kind: code
  - model: sonnet
  - after: principles-merge-seam, first-epic-offer
  - source: #606
  - files: `docs/features/engineering-principles.md`
  - acceptance:
    - The minimal L0 doc expands to full: uninstall edit-site list including the adopter-side undo paths (unprotect, delete workflow, flip backend); reviewer-catalog cross-reference (WHAT/HOW split); the complete first-epic flow with its consent posture.
    - `validate-feature-docs.sh` + both manifests stay green — claims landed with their files in earlier PRs; this PR is content-only (Contract h slice).
    - Contract (i) removal: kernel-side deletions leave the lint family green; adopter-side state is documented as the adopter's own, with undo paths.
  - notes: Expansion only — the five-section skeleton + claim shipped at L0 (feature-manifest atomicity). `docs-reviewer` routes via the prose fallback.


## Merge gate log
- level 0 · 2026-07-20T22:58Z · modal-approved · PRs #617 #619 · operator signed off #617 principle content per acceptance (d); both armed --auto via native queue
- level 1 · 2026-07-20T23:36Z · modal-approved · PRs #623 #624 · operator approved (per-level gating continues; clean disjoint set via native queue)
- level 2 · 2026-07-21T01:12Z · modal-approved · PRs #632 #641 · operator approved + requested fixture-repo cleanup (per-level gating continues)
- level 3 · 2026-07-21T02:04Z · modal-approved · PRs #643 #644 · operator approved (final level; closes epic #606)
