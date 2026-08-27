---
tags: [plan, project/temperloop]
date: 2026-08-26
source_kind: claude-stamped
source_session: 0ee530fa
last_verified: 2026-08-26
epic: 1847
sources:
  - "#1847"
status: done
---

# 2026-08-26 temperloop - epic-as-metadata operational drain

## Run status

run started 2026-08-26 · session 0ee530fa · complete · items: 11 done / 0 parked / 0 in-flight / 0 skipped · epic #1847 closed 2026-08-27

## Questions

- [x] `step: 2.5` — Create 11 tracking issues for the Contract-derived items (baseline-metrics, edge-stamping-triage, blocked-chunk-formation, pool-admission-setting, assess-refusal-guard, member-scrutiny-phase1, member-merge-regimes, epic-closing-gate, funnel-class-conditional, policy-consumer-specs, feature-doc-adr-changelog)? **default: create**
  - auto-proceed: unanswered → the 11 issues stand as created
  - → default taken: create (the 11 issues stand) — level-1 timed gate, 2026-08-26

## Problem

Triage's group-by-meaning step reroutes related operational bug fixes onto
the heavyweight path — plan authoring, an operator approval round-trip,
`/build` — purely because a parent issue exists, even though the work-class
taxonomy already declares Operational work fully autonomous. Feedback
scatters across per-epic approval gates instead of one batched sitting, and
durable logical ordering stays trapped in per-run plan notes no other
consumer can read. The ratified design brief ([[Designs/temperloop -
epic-as-metadata for operational work]]) resolves this: Operational epics
become metadata (context, progress, completion narrative) while their
members drain through `/sweep`, ordered by native `blocked_by` edges.

## Summary

- **Ordering becomes board data (`blocked_by`), honored by the drive path**
  - **L1** — triage stamps durable logical order + `edges-considered` marker on Operational groups; supersession of the edges-off-board invariant at its repo statement sites; ADR 0031 lands
  - **L1** — sweep's pool build and chunk formation honor `blocked_by` for every pool item, with the deps-merged un-defer predicate (fixes #1835)
- **The partition re-keys on work-class, guarded from both sides**
  - **L2** — sweep pool admission for Operational-epic members behind `SWEEP_ADMIT_OPERATIONAL_EPICS` (default off; Foundational-wins live check; plan-note race guard; marker-required)
  - **L3** — `/assess` refuses an Operational epic while the setting is on (pipeline-invoked runs exempt; logged override; interleaved race test)
- **Member drives keep the scrutiny and consent the ceremony path had**
  - **L3** — Phase-1 secret-seam check for members + parent group summary in member worker prompts
  - **L3** — member-bearing chunks run merge-regime selection (correlated sets merge modal)
  - **L3** — the epic-closing gate: keep-open honored, closing comment, Done write, blocked frontier, pending-decisions probe-before-append, code-emitted tally
- **Measurement and propagation**
  - **L0** — baseline metrics spike (cycle times, park rate, structure-kind reclassification) before any cutover
  - **L4** — telemetry funnel goes class-conditional (metadata epics read drained-via-sweep, not stalled)
  - **L4** — work-class-policy widening + `/next` + vocabulary + diagrams
  - **L4** — feature doc + ADR 0030 + CHANGELOG BREAKING fragment

Build order: L0 first → L4 last; items in the same level ship together.

## Sequencing notes

- L0 is spike-only (the baseline must predate any behavior change); no
  build item shares its level.
- **Known same-file siblings in L3:** member-scrutiny-phase1,
  member-merge-regimes, and epic-closing-gate all edit
  `claude/commands/sweep.md` in different sections. Expected merge order
  6 → 7 → 8 (scrutiny → regimes → gate); a rebase conflict between them is
  an expected, deterministic park, not a surprise.
- Parent-side (orchestrator) work at merge time, workers cannot reach the
  knowledge store: (a) amend the ratifying vault note `Decisions/foundation
  - Triage stage and the logical-technical pipeline split` when
  edge-stamping-triage merges (the fourth supersession site); (b) complete
  the baseline spike's structure-kind reclassification over vault `Plans/`
  notes at verdict capture.
- ADR source texts are staged durably as a comment on epic #1847 (the
  untracked working-tree drafts are unreachable from a worker's clean
  worktree); the two items that land them consume that comment verbatim.
- The two epic deferrals (#1848 pipeline cutover, #1849 retro issue-body
  acceptance) are deliberately outside this plan.

## Re-triage signals

- none

## Items

- [v] **Capture the pre-cutover baseline** `slug: baseline-metrics`
  - branch: `chore/baseline-metrics`
  - gh_issue: 1850
  - size: S
  - kind: spike
  - source: #1847
  - acceptance:
    - A verdict records: (a) Ready→merged cycle time for recent Operational epic members driven via the assess/build ceremony path (gh issue/PR timestamps, ≥3 recent epics); (b) assess runs per month on Operational epics (last 60 days); (c) the current sweep singleton park rate.
    - The 71%-structured aggregated-epic cohort (86-plan-note probe, 2026-08-24) is reclassified by structure kind — `blocked_by`-shaped precedence vs other cross-member relationships — with per-epic counts. This half reads vault `Plans/` notes and is completed parent-side at verdict capture (workers cannot reach the knowledge store); the worker delivers the gh-derivable halves.
    - Numbers land in a Context note (orchestrator writes it at verdict capture) named as the kill-condition baseline for the admission-setting rollout.
  - notes: Measure-the-delta discipline — the brief's dim 9 kill conditions (park rate, revert/rework rate, mis-route) compare against this baseline. No behavior change may precede it, hence spike-only L0.

- [x] **Triage stamps durable logical order on Operational groups** `slug: edge-stamping-triage`
  - branch: `feat/edge-stamping-triage`
  - gh_issue: 1851
  - size: M
  - kind: code
  - model: sonnet
  - after: baseline-metrics
  - source: #1847
  - files: `claude/commands/triage.md`, `claude/commands/assess.md`, `docs/adr/0031-durable-logical-order-lives-on-the-board-as-blocked-by.md`
  - acceptance:
    - triage.md gains a Step-4 materialization sub-step, **Operational groups only** (a Foundational group's ordering stays plan-resident): stamp genuine logical order between members as native `blocked_by` edges via `board_blocked_by_add` (guarded-helper call — on a stale adapter the sub-step is a documented no-op with a legible notice and NO marker written, never a raw-REST fallback); one-line rationale comment on each blocked issue; a script-backed cycle check (walk existing edges via the adapter reader) before each write refuses an edge that closes a cycle; an `edges-considered` marker lands on the epic when the sub-step completes (stamped or legitimately none); a routing-note comment lands on the epic ("drains via /sweep (Operational)" / "routes via /assess (Foundational label present)").
    - Merge-safety/same-file ordering is explicitly NOT stamped — the sub-step's text states the logical-vs-merge-safety distinction and that the latter stays derive-at-drive-time.
    - The requirements-auditor prompt in triage.md Step 3 gains the member-class consistency check (mixed-class groups flagged at birth); the needs-clarification closing comment names `/sweep` Phase 1 as the member path's consumer when admission is on.
    - Repo-side supersession: the amended invariant (durable meaning-level order may live on the board; computed merge-safety edges/levels stay plan-resident) is stated once, and triage.md's prohibition line, triage.md's logical/technical-split line, and assess.md's recomputed-fresh line all point at it.
    - docs/adr/0031 committed verbatim from epic #1847's ADR comment.
    - The ratifying vault note (`Decisions/foundation - Triage stage and the logical-technical pipeline split`) is amended at merge — parent-side by the orchestrator (worker cannot reach the store); the orchestrator confirms before the item is recorded merged.
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -q 'edges-considered' claude/commands/triage.md"
  - notes: ADR text source is durable (epic comment), per the artifact-availability audit. Guarded-helper pattern per sweep.md's `board_close_done` precedent.

- [x] **Sweep honors blocked_by for every pool item** `slug: blocked-chunk-formation`
  - branch: `fix/blocked-chunk-formation`
  - gh_issue: 1852
  - size: M
  - kind: code
  - model: sonnet
  - after: baseline-metrics
  - source: #1847
  - also_closes: "#1835"
  - files: `claude/commands/sweep.md`
  - acceptance:
    - Step-1 pool build checks `board_blocked_by_open` for every pooled item (member or singleton), gated on the Ready slice only; an item with an open blocker is deferred, never co-chunked with or driven ahead of it (fixture test; subsumes #1835).
    - The un-defer predicate is explicit and mechanized: blocker issue closed AND its landing commit is an ancestor of `origin/<default>` — resolved issue→SHA via the blocker's linked merged PR (`gh pr list -R <repo> --search "Closes #<n>" --state merged --json mergeCommitOid`, or the closing event's commit), then `worktree.sh deps-merged`; re-checked at chunk boundaries. **Ambiguity case defined:** a blocker closed with no linked merged PR (e.g. closed-as-not-planned) releases its dependents — there is nothing to wait for on main (test).
    - A blocker whose sweep disposition is `parked` never releases its dependents (test).
    - The pool build walks the pooled items' edge graph; a cycle is surfaced (none of its members driven) — test.
    - The Step-4 report gains a blocked-frontier section (blocked item → open blockers, with multi-run stalls noted).
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -q 'board_blocked_by_open' claude/commands/sweep.md"

- [x] **Pool admission for Operational-epic members** `slug: pool-admission-setting`
  - branch: `feat/pool-admission-setting`
  - gh_issue: 1853
  - size: M
  - kind: code
  - model: sonnet
  - after: edge-stamping-triage
  - depends-on: blocked-chunk-formation
  - source: #1847
  - files: `claude/commands/sweep.md`, `workflows/scripts/build/build.config.sh`
  - acceptance:
    - `SWEEP_ADMIT_OPERATIONAL_EPICS` lands in build.config.sh (default off, header documents per-checkout scope); every spec read uses the belt-and-suspenders `${SWEEP_ADMIT_OPERATIONAL_EPICS:-0}` form; the operator flip lives in gitignored `build.config.local.sh` (the #711 pattern) so a routine vendored sync never changes the effective value — stated in the config header and tested (sync-survival: overwriting build.config.sh leaves the effective value unchanged).
    - Step-1 admission predicate: setting on AND parent epic `Operational` AND no `Foundational` label anywhere in the group (parent or member — **Foundational-wins, re-evaluated live every pool build**) AND no live (draft/approved, non-superseded) plan note for the epic (race guard) AND the `edges-considered` marker present (stale-writer guard; a marker-less Operational epic is refused with a legible notice). Fixture tests cover each conjunct including the marker-required and Foundational-wins refusals.
    - Rollback identity: with the setting off, pool selection is behavior-identical to legacy (test).
    - A mixed-class epic is surfaced (attended ask / unattended pending-decisions entry), never silently skipped; when `blocked_by` reader helpers are unavailable (stale vendored adapter), member admission is refused entirely — singleton-only pool — with the remedy-form degradation notice.
    - The attended pool report names admitted epics AND carries each admitted member's issue-body acceptance text (informed named-set consent); a run seeing Operational epics with the setting off emits a one-line advisory naming the setting and the feature doc.
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -q 'SWEEP_ADMIT_OPERATIONAL_EPICS' claude/commands/sweep.md && grep -q 'SWEEP_ADMIT_OPERATIONAL_EPICS' workflows/scripts/build/build.config.sh"
  - pr: 1863

- [x] **Assess-side mutual-exclusion guard** `slug: assess-refusal-guard`
  - branch: `feat/assess-refusal-guard`
  - gh_issue: 1854
  - size: S
  - kind: code
  - model: sonnet
  - after: edge-stamping-triage, pool-admission-setting
  - source: #1847
  - files: `claude/commands/assess.md`
  - acceptance:
    - assess.md Step 1 refuses an `Operational` epic when `${SWEEP_ADMIT_OPERATIONAL_EPICS:-0}` is on AND the run is not pipeline-drive-invoked (the carve-out that keeps the un-rewired autonomous router out of a refusal loop) — fixture test for refusal and for the pipeline-invoked pass-through.
    - The refusal message names the sweep path, links the live feature doc (`docs/features/sweep.md` — the Level-5 feature-doc item may retarget to a dedicated page when it lands), and states the setting is checkout-wide (not the teammate's personal misconfiguration).
    - The explicit operator override is logged in the run record, never silent.
    - Interleaved race test: an override racing a live sweep pool admission does not double-drive a member — claim-first parks one side (the probes alone do not close the window; the test exercises the interleaving, not just each rule's own precondition).
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -q 'SWEEP_ADMIT_OPERATIONAL_EPICS' claude/commands/assess.md"
  - notes: `after: pool-admission-setting` is load-bearing (auditor finding): the race test needs sweep's admission mechanism to exist to race against.
  - pr: 1868

- [x] **Member scrutiny in Phase 1** `slug: member-scrutiny-phase1`
  - branch: `feat/member-scrutiny-phase1`
  - gh_issue: 1855
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: pool-admission-setting
  - source: #1847
  - files: `claude/commands/sweep.md`, `claude/workflows/build-level.mjs`
  - acceptance:
    - Phase 1 runs the secret-seam check for admitted members: a member whose fix needs a credential with no confirmed supply seam parks (needs-clarification path), never merges — test mirrors `/assess`'s confirmed-set bar. **Composition stated in the spec text:** this Phase-1 check is the pre-work static gate; sweep Step 3's existing runtime host-config-deferral settlement (`isHostConfigDeferral`) remains the merge-time backstop for anything Phase 1 missed — the two compose, neither supersedes the other.
    - Member worker prompts carry the parent epic's group summary (build-level.mjs prompt assembly; machinery test/fixture asserts the parent body text reaches the worker prompt for a member item and is absent for a singleton).
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "tr '\n' ' ' < claude/commands/sweep.md | tr -s ' ' | grep -qi 'secret-seam'"
  - pr: 1867

- [x] **Merge regimes for member-bearing chunks** `slug: member-merge-regimes`
  - branch: `feat/member-merge-regimes`
  - gh_issue: 1856
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: pool-admission-setting
  - source: #1847
  - files: `claude/commands/sweep.md`
  - acceptance:
    - The per-chunk merge pass runs regime selection (the `gate.sh` risk partition) whenever the chunk contains epic members; a correlated/risky set is offered modally, never auto-merged on a timer (test: member-bearing chunk triggers regime selection; singleton-only chunk keeps today's posture).
    - The spec text names this as preserving the kernel merge-autonomy contract (only a clean, disjoint set is timed).
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "tr '\n' ' ' < claude/commands/sweep.md | tr -s ' ' | grep -qi 'regime selection'"
  - pr: 1866

- [x] **The epic-closing gate** `slug: epic-closing-gate`
  - branch: `feat/epic-closing-gate`
  - gh_issue: 1857
  - size: M
  - kind: code
  - model: sonnet
  - depends-on: pool-admission-setting
  - source: #1847
  - files: `claude/commands/sweep.md`, `workflows/scripts/config/mandatory-step-registry.tsv`, `workflows/scripts/emit-command-run.sh`
  - acceptance:
    - A new end-of-run step: epics whose members all reached closed state (merged or resolved-verdict; a `parked` member is never terminal for closing-gate purposes) are offered for parent close (default close) → adapter Done write (`board_close_done`) + a one-line closing comment (members drained via sweep + run-report pointer). Partially-drained epics reported as progress; the blocked frontier reported with blocker attribution.
    - A `keep-open`-labeled epic is reported, never offered for close (test); the close prompt names the epic's assignee/last-toucher. The `keep-open` label is provisioned idempotently (probe-and-create) before first use.
    - Unattended arm: parents left open; one pending-decisions `### open` entry per fully-drained epic EVER — probe-before-append keyed on the epic number (idempotency test: a re-run adds nothing).
    - The tally rides the `emit-command-run.sh` record as an explicit schema extension — new `epics_reviewed` / `epics_closed` / `epics_left_open` fields on the same single per-run record (never a second emit call; the existing `items_processed` arithmetic is untouched) — and the report line is the human surface. The mandatory-step registry row names these fields as the signal in its NOTE; `validate-mandatory-step-signal.sh` green.
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -q 'epic-closing-gate' workflows/scripts/config/mandatory-step-registry.tsv"
  - pr: 1869

- [x] **Class-conditional telemetry funnel** `slug: funnel-class-conditional`
  - branch: `feat/funnel-class-conditional`
  - gh_issue: 1858
  - size: M
  - kind: code
  - model: sonnet
  - after: pool-admission-setting, epic-closing-gate
  - source: #1847
  - files: `workflows/scripts/telemetry-brief.sh`
  - acceptance:
    - The funnel-health read becomes class-conditional: a Foundational epic keeps epic → plan (assessed) → built; an Operational epic's healthy path is epic → members-drained-via-sweep, so plan-note absence on an Operational epic no longer reads as stalled-unassessed (test/fixture over both classes).
    - No new telemetry stream: the change consumes the existing command-run records (including the epic-closing-gate fields) and issue/PR state already in the lake.
    - `scripts/quality-gates.sh` green.
  - activation:
    - class: A
    - proof: "grep -qi 'foundational' workflows/scripts/telemetry-brief.sh"
  - notes: If the funnel classification actually lives in a sibling script (issue-state.sh), the worker updates `files:`/proof target accordingly — the acceptance is the behavior, not the filename.
  - pr: 1870

- [x] **Work-class policy widening + consumer specs** `slug: policy-consumer-specs`
  - branch: `docs/policy-consumer-specs`
  - gh_issue: 1859
  - size: M
  - kind: code
  - model: sonnet
  - after: pool-admission-setting, epic-closing-gate
  - source: #1847
  - files: `claude/work-class-policy.md`, `claude/commands/next.md`, `claude/commands/triage.md`, `claude/commands/sweep.md`, `workflows/scripts/board/ISSUES-ONLY-BACKEND.md`
  - acceptance:
    - work-class-policy.md's policy table changes the Operational path to triage → sweep (auto-merge per chunk, modal for correlated sets), states the labels' scope widening (pipeline-driver autonomy policy → pipeline-wide routing key), and extends its § Precedence from per-item to per-group (Foundational-wins anywhere in a group), citing the existing rationale.
    - next.md recommends `/sweep` for Operational epics; ISSUES-ONLY-BACKEND documents the edge/marker vocabulary (`edges-considered`, `keep-open`, the durable-logical vs computed-merge-safety split); the pipeline diagrams in triage.md and sweep.md show the class-keyed partition.
    - `scripts/quality-gates.sh` green (template/reference lints cover the cross-references).
  - activation:
    - class: A
    - proof: "tr '\n' ' ' < claude/work-class-policy.md | tr -s ' ' | grep -qi 'routing key'"
  - pr: 1871

- [x] **Feature doc, ADR 0030, BREAKING fragment** `slug: feature-doc-adr-changelog`
  - branch: `docs/feature-doc-adr-changelog`
  - gh_issue: 1860
  - size: M
  - kind: code
  - source: #1847
  - after: policy-consumer-specs
  - files: `docs/features/operational-drain.md`, `docs/features/feature-manifest.txt`, `docs/adr/0030-work-class-routes-operational-epics-through-sweep.md`, `changelog.d/operational-drain.breaking.md`
  - acceptance:
    - `docs/features/operational-drain.md` exists with the five required sections, registered in feature-manifest.txt (`validate-feature-docs.sh` green); it states the single-board adopter's rollout plainly ("flip the setting, do one supervised sweep run") and the sync-survival re-flip note.
    - docs/adr/0030 committed verbatim from epic #1847's ADR comment.
    - A `changelog.d/` BREAKING fragment names the work-class label-scope widening and the triage-charter supersession as the contract changes.
    - `scripts/quality-gates.sh` green.
  - notes: Docs-only under `docs/`/`changelog.d/` — exempt from rule 14, no activation block. ADR text source is the durable epic comment.
  - pr: 1872


## Escalation resolution — edge-stamping-triage
review-blocking (workflow-reviewer, 1 HIGH + 1 MEDIUM + 1 LOW). Disposition: retry — fix all findings (HIGH: 9d marker-comment exit status unchecked, silent defeat of the edges-considered distinction; MEDIUM: no live work-class re-read before 9c/9d; LOW: 9d marker not idempotent). Full findings handed to the continuation worker verbatim.

## Escalation resolution — blocked-chunk-formation
review-blocking (workflow-reviewer, 2 HIGH). Disposition: retry — fix both findings (HIGH-1: un-defer predicate failure-mode coverage; HIGH-2: ambiguous input pool for the cycle walk). Full findings handed to the continuation worker verbatim.

## Merge gate log
- level 5 · 2026-08-27T13:45:09Z · timed-elapsed (300s window, no objection) · PR #1872
- level 4 · 2026-08-27T12:45:13Z · timed-elapsed (300s window, no objection) · PRs #1870 #1871
- level 3 · 2026-08-27T11:07:14Z · timed-elapsed (300s window, no objection) · PRs #1866 #1867 #1868 #1869
- level 2 · 2026-08-27T05:53:05Z · timed-elapsed (300s window, no objection) · PR #1863
- level 1 · 2026-08-26T22:00Z · timed-elapsed · PRs: #1861 (blocked-chunk-formation), #1862 (edge-stamping-triage)


## Escalation resolution — assess-refusal-guard (round 2)
Disposition: FIX on the intact worktree (all worker tests green; one quality gate red).
The failing gate is `workflows/scripts/config/check-setting-prose.sh`: `claude/commands/assess.md:101` writes `${SWEEP_ADMIT_OPERATIONAL_EPICS:-0}` at a site whose own parenthetical says the config is already in scope from Step 0 item 6 — the inline `:-0` restates the default, violating the Named-setting convention (prose names a setting, never states its value; the belt-and-suspenders form is only for a consuming repo that doesn't source the config). FIX: at that line reference the setting symbolically (`$SWEEP_ADMIT_OPERATIONAL_EPICS`), matching how the file's other post-Step-0 references and sweep.md's landed prose pass this checker. Verify with `bash workflows/scripts/config/check-setting-prose.sh` green, then re-run the scoped gate subset. Touch nothing else.

## Escalation resolution — member-scrutiny-phase1 (round 2)
Disposition: FIX the two findings on the intact worktree.

### [HIGH] Subagent dispatch missing the membership flag the new scrutiny keys on
"Admitted epic member" is ephemeral run-state computed by the orchestrator in Step 1 item 6 — not recoverable from an issue's title/body/labels/comments — yet the new Member secret-seam scrutiny (sweep.md ~line 96) tells the detection-subagent fanout to run an extra check for admitted members without ever passing membership into the dispatch. The scrutiny would silently never fire (the #637 confirmed-set silent-no-op class this feature exists to close). FIX: amend the fanout-dispatch paragraph (~line 94) and/or the scrutiny paragraph to REQUIRE each slice's dispatch prompt to name which of its issues are admitted epic members (e.g. "flag each admitted-epic-member issue# in the slice payload so the subagent knows to run the additional credential scan on it") — an explicit data-dependency precondition.

### [LOW] docs/features/sweep.md admission paragraph now stale
Add 1–2 sentences to the "Operational-epic members can opt into the same pool" paragraph (~line 115) naming the credential-scrutiny gate and the parent-context (group-summary) worker-prompt injection.

## Escalation resolution — member-merge-regimes (round 2)
Disposition: FIX the three findings on the intact worktree.

### [HIGH] No failure path for gate.sh risk's ERROR outcome
The new regime-selection call (sweep.md ~lines 201-206) branches only on CLEAN_DISJOINT_INDEPENDENT | RISKY, but `gate.sh risk` also emits `{"outcome":"ERROR",...}` + non-zero exit. FIX: add the explicit third branch — any non-CLEAN/non-RISKY outcome (ERROR, non-zero exit, malformed JSON) is treated as RISKY: hold every mergeable PR, never auto-merge — mirroring build.md §3h.5's "any failure or UNKNOWN leaves the item [m]" conservative default and this file's own Step 1 "an error is never the permissive branch" convention. Extend the paired test to pin the ERROR→conservative branch.

### [MEDIUM-HIGH] Held-PR recovery path is unreachable as written
Three sites claim "a future attended /sweep run re-offers it", but a risk-gate-held item stays In Progress by design and Step 1 pools only Ready items — no future run will ever see it. FIX honestly, no new mechanism: strike the "future attended /sweep run re-offers it" / "re-run /sweep attended to approve" language at all three sites and state the REAL resolution paths — a human merges the PR by hand, or the operator moves the issue back to Ready (releasing the claim) so a future pool re-considers it. Make the held-PR issue comment name those same two paths.

### [MEDIUM] AskUserQuestion option-count cap
The modal offers one option per mergeable PR + Abort, unbounded by SWEEP_FANOUT_WIDTH. FIX: apply Step 2's own house convention — ≤4 options per call, loop in groups for more (or a single Merge-all/Hold-some/Abort shape when the set exceeds the cap, mirroring build.md 4b's >4-PR fallback).

## Escalation resolution — epic-closing-gate (round 2)
Disposition: FIX the two findings on the intact worktree.

### [HIGH] Mandatory-step signal is conditionally-armed, so a dropped emit-flag reads as "not applicable"
The registry row's refusal signal (epics_closed + epics_left_open == epics_reviewed in emit-command-run.sh) only fires when the caller passes --epics-reviewed; a future sweep.md edit dropping the three --epics-* flags exits 0 indistinguishably from a command that never touches the extension. FIX: extend `workflows/scripts/validate-command-run-emit.sh` with a `check_epics_reviewed` mirroring the existing `check_resolved`/`check_reported_no_op` shape — content-derive the trigger off sweep.md declaring the epic-closing gate (match on `epics_reviewed`/the Step 3.6A anchor) and require the doc's emit-block window to contain `--epics-reviewed`. Update the mandatory-step-registry row to (also) anchor its SIGNAL on that static guard so the signal is unconditional. Cover with the validator's own test pattern; `validate-mandatory-step-signal.sh` and `validate-command-run-emit.sh` both green.

### [LOW] "Once per run" provisioning numbered inside the per-epic loop
Hoist the keep-open label provisioning call to a preamble line before the per-epic loop, or reword item 1 to "(no-op after the first epic this run)".


## Escalation resolution — assess-refusal-guard (round 3 — docs-reviewer reference-token fixes)
Disposition: FIX the two findings on your intact commits. Prose-only; touch nothing mechanical.

### [HIGH] First-mention title hook out of document order
assess.md line 32 (the `--override-operational-refusal` Arguments bullet) mentions `epic #1847 Produces #5` bare; the full hook only appears at line 98. FIX: put the hook at the earliest mention in document order — line 32 becomes `epic #1847 "epic-as-metadata for operational work" Produces #5` — and demote the later Step-1 restatement to a bare re-mention.

### [MEDIUM] #1848 unhooked in assess.md:102 and changelog.d/1854-assess-refusal-guard.added.md
Add a short title hook at the true first mention in each file, e.g. `#1848 (pipeline-drive sweep-cutover rewiring)` — draw the hook from issue #1848's own title (`gh issue view 1848`), ≤6 words.

## Escalation resolution — member-scrutiny-phase1 (round 3 — docs-reviewer mode-7 fixes)
Disposition: FIX the three findings on your intact commits. Prose-only; touch nothing mechanical.

### [HIGH] docs/features/sweep.md: epic ref unhooked + Produces-slot token undecodable
First mention becomes `epic #1847 (epic-as-metadata for operational work)` (matching the sibling changelog fragment), and either drop the bare `Produces #7` locator from this stranger-facing page or gloss it inline (e.g. "the epic's own credential-scrutiny commitment").

### [HIGH] docs/features/sweep.md: bare /assess and /build on a mode-7 page
Link both on first mention to their own docs pages (extend the paragraph's existing link pattern, as it already does for ../../claude/work-class-policy.md). If a linked target page does not exist for one of them, gloss inline instead of inventing a dead link.

### [MEDIUM] changelog.d/1847-member-scrutiny-phase1.added.md: unhooked refs
`epic #1847 (epic-as-metadata for operational work)` and `foundation#716 (host-config/secret-seam principle)` at first mention, matching the sibling fragment's convention.

## Escalation resolution — epic-closing-gate (round 3 — the state-casing bug)
Disposition: FIX the one finding on your intact commits.

### [HIGH] gh issue state casing mismatch silently disables the whole gate
sweep.md §3.6A item 1 reads members via `gh issue view <m> --json state` and the combinator's jq compares `.state == "closed"` — but gh returns UPPERCASE `"CLOSED"`/`"OPEN"`, so `closed_members` computes 0 for every epic, `fully_drained` can never fire, and every epic falls to the omitted-from-report `no-progress` verdict: the feature ships fully wired and never once closes or reports an epic. FIX: adopt one of the repo's two established conventions and apply it explicitly at both ends of the prose→script contract — either compare `"CLOSED"`/`"OPEN"` natively (matching `sweep-blocked-undefer.sh`'s documented input schema) or normalize with `ascii_downcase` before constructing the combinator input (matching `pipeline-tick.sh:769`). Land it WITH a test fixture that exercises the real uppercase casing (the current 30/30-green suite hand-authors lowercase strings and cannot catch this), and update §3.6A item 1's prose so the caller-side instruction states the same casing the script expects.


## Escalation resolution — assess-refusal-guard (round 4 — workflow-reviewer)
Disposition: FIX the three findings on your intact commits.

### [HIGH] Carve-out check must run BEFORE the label reads
Reorder the Step-1 guard so item 3 (pipeline-drive detection, `${PIPELINE_OPERATOR_ABSENT:-0}` etc.) runs FIRST; when true, skip the label reads and setting resolution entirely and proceed (reason=`pipeline-drive-carve-out`) — a transient gh failure on the label read must never hard-stop the one unattended caller the carve-out exists to protect (the script's own PRECEDENCE comment already says branch 1 wins regardless). Keep the hard stop for the non-carve-out path.

### [HIGH] Dangling doc reference
`docs/features/operational-drain.md` does not exist. Point the refusal message (and the changelog fragment) at the live doc — `docs/features/sweep.md` — which already documents SWEEP_ADMIT_OPERATIONAL_EPICS. Do not create a new doc here; the Level-5 feature-doc item owns that and may retarget the link when it lands. The plan item's acceptance has been amended to match (orchestrator edit).

### [MEDIUM] Override audit comment idempotency
Before posting the Step-1 override epic comment, probe the epic for an existing `operational-refusal override:`-marked comment from this run/session and skip the duplicate post — mirroring the repo's probe-before-append convention.

## Escalation resolution — epic-closing-gate (round 4 — activation proof red)
Disposition: FIX the missing wiring on your intact commits; never weaken the predicate.

The class-A activation proof `grep -q 'epic-closing-gate' workflows/scripts/config/mandatory-step-registry.tsv` exits 1 against your worktree — most likely the round-2 re-anchor of the registry row (onto check_epics_reviewed) reworded the row so the literal step identifier `epic-closing-gate` no longer appears anywhere in the tsv. FIX: make the registry row carry the literal `epic-closing-gate` identifier (e.g. as the step id/slug column or in its NOTE naming the static guard), keeping the round-2 unconditional static-guard anchoring intact. Verify the proof passes from the worktree root, and `validate-mandatory-step-signal.sh` stays green.


## Escalation resolution — epic-closing-gate (round 5 — persistent population + telemetry semantics)
Disposition: FIX the two findings on your intact commits.

### [HIGH] Review population must be persistent, not one-shot
The gate currently reviews only epics Step 1 item 6 admitted THIS run — but a fully-drained epic has zero Ready legs and can never be re-admitted, so every "re-offered next run" / "re-checked next run" promise is structurally dead and the pending-decisions dedup-across-history is dead code. FIX by broadening the population (the reviewer's option (a), which matches the acceptance's own contract "epics whose members all reached closed state are offered for parent close"): when the setting is on, the gate's review population each run = ALL still-open Operational epics carrying the edges-considered admission marker (the admission-eligible set — query the board once for open Operational-epic parents, independent of whether any leg was Ready this run), unioned with this run's item-6 admissions. This makes the declined-offer re-offer, the cannot-establish re-check, and the dedup-across-history all genuinely live (the dedup becomes load-bearing: a fully-drained epic re-detected every run must not re-append). Update the report language only where it needs to match, and extend the test suite with a case proving a drained epic with zero Ready legs this run still enters review.

### [MEDIUM] Telemetry-contract contradiction on the zero-epic fast path
Pick the always-carry semantics (the stronger K.52 execution signal): the zero-epic fast path KEEPS passing explicit zeros — every /sweep record always carries the three fields, so a /sweep record MISSING epics_reviewed is itself the "step didn't run" signal. Fix the two contradicting doc claims to match: emit-command-run.sh's header example becomes "callers other than /sweep (triage/fix) never touch this extension"; docs/features/sweep.md's closing paragraph becomes "every /sweep run carries the three fields (0/0/0 = the gate ran and found nothing to review); a record without them predates the feature or is not a /sweep run". The mandatory-step registry NOTE may cite this always-carry property as part of the signal.


## Escalation resolution — epic-closing-gate (round 6 — report honesty + one data-source clause)
Disposition: FIX the two findings on your intact commits. Small, surgical; touch nothing else.

### [HIGH] A failed close write must not render as "Offered, declined"
An operator-approved Close whose board_close_done/gh write fails currently falls into epics_left_open and renders identically to a decline — misattributing an infrastructure failure as an operator decision (a recurring write breakage would masquerade as the operator repeatedly declining). FIX: make the offer-close outcome tri-state (closed / declined-or-unanswered / write-failed) and add the seventh report-row shape — e.g. `#E → close approved but write failed this run (<one-line error>); will retry next run` — distinct from the declined row. The tally stays as-is (a failed write still counts epics_left_open); only the human-facing report gains the honest row. Extend the report/test coverage to pin the write-failed row.

### [LOW] Name epic_open's data source explicitly
Add one clause where arm (b)'s query is described: `epic_open` is true for every candidate this query returns, because `board_item_list` is documented as the board's open-only slice (workflows/scripts/board/lib/board.sh) — making the reliance visible so a future query-mechanism change can't silently default the field to false and regress the round-5 persistent population.


## Escalation resolution — epic-closing-gate (round 7 — retry honesty, backstop equivalence, comment failure path)
Disposition: FIX the three findings on your intact commits. Surgical; touch nothing else.

### [HIGH] Drop the unbacked "write retried, not re-asked" claim; make the audit comment idempotent
No mechanism backs retry-without-re-ask (the combinator has no previously-approved input), and comment-before-write re-posts "Closed by sweep" on every re-ask while the write keeps failing. FIX both halves honestly, with no new state channel: (1) drop the "write retried, not re-asked" prose — a close-write-failed epic is simply RE-OFFERED next run, and the round-6 write-failed report row already tells the operator why they are being re-asked; (2) keep the house comment-FIRST ordering (the 2.6/4d-epic/triage-4.8 convention: a failed comment leaves the epic open rather than closed-unexplained) but make the comment post IDEMPOTENT — probe the epic for an existing "Closed by sweep" comment before posting (the same probe-before-append idiom used elsewhere in this feature), so a re-ask after a failed write never posts a duplicate.

### [MEDIUM] tidy.md backstop dedup key must match the capture's
The left-open-unattended site's live capture dedups on "epic #E anywhere in the surface's WHOLE history" (one entry per epic EVER), but tidy.md § Pending decisions surface's generic backstop dedups on site + run-id/date — so the backstop would backfill a duplicate entry for an epic correctly recorded on a prior run. FIX: special-case this site's backstop dedup (or generalize: whenever the decision text names an epic number, match on that epic number anywhere in history), so the backstop cannot violate the invariant the capture guarantees.

### [LOW] Name the comment-post failure disposition
One clause at the offer-close Close arm: if the "Closed by sweep" comment post itself fails, warn naming the epic, SKIP the write this run (comment-first house convention — never close unexplained), and report it via the write-failed row so it retries (re-offers) next run.


## Escalation resolution — epic-closing-gate (round 8 — member-list source + mode-7 glosses)
Disposition: FIX the four findings on your intact commits. Surgical; touch nothing else.

### [HIGH] Name item 1's member-list source for arm-(b) epics
Item 1 sources members from "item 6's own per-epic reads" — but an arm-(b) epic (the round-5 persistent-population case) never passed through item 6, so that source doesn't exist for it; an empty members array feeds the combinator total_members:0 → verdict no-members, which item 4 has no branch for → the epic silently drops from the report, regressing the round-5 headline case. FIX: instruct item 1 to call `board_sub_issues "$BOARD" <E>` fresh at the top of the per-epic loop REGARDLESS of admission source (or reuse the list arm (b)'s population-build already fetched), and set member_reads_available:false — never silently empty — if that call errors. If the combinator can emit no-members, either give item 4 an explicit branch for it (report as cannot-establish-shaped, never dropped) or show it is unreachable once the source is fixed.

### [HIGH] docs/features/sweep.md mode-7 leaks
In the new epic-closing-gate paragraph: replace "Step 1's admission opt-in" with the stranger-safe phrasing the file already uses one paragraph up ("every epic the opt-in above admitted a member of this run"), and replace/gloss "triage's edges-considered marker" with a plain functional description (e.g. "every still-open Operational epic parent that triage has already finished recording membership for") — the Telemetry paragraph in the same diff is the register template.

### [MEDIUM] changelog.d/epic-closing-gate.added.md: gloss "Operational"
First use gets the sibling fragment's inline gloss ("the established-pattern half of the Operational/Foundational work-class split") or a link to claude/work-class-policy.md.

### [LOW] feature-manifest.txt: title hook on #1847
Append the hook at its mention: `epic #1847 (epic-as-metadata for operational work)`.


## Escalation resolution — policy-consumer-specs (round 2 — reference-token hooks + one redundancy cut)
Disposition: FIX the two findings on your intact commits. Prose-only; touch nothing mechanical.

### [HIGH] epic #1847 unhooked at first mention across five files
Give `epic #1847` a consistent ≤6-word title hook at its TRUE first mention in each file — `epic #1847 ("epic-as-metadata for operational work")`, reusing the hook sweep.md line 70 already carries — in: work-class-policy.md (line ~6), next.md (~69), ISSUES-ONLY-BACKEND.md (~393, the new ADR-0031 section), changelog.d/1847-policy-consumer-specs.changed.md (line 2), and sweep.md's new diagram line (~10), which now sits EARLIER than the existing line-70 hook — hook the diagram-adjacent first mention and demote the later one to a bare re-mention.

### [LOW] CLT redundancy in work-class-policy.md § Precedence per-group paragraph
The same claim is stated three times in successive sentences. Cut the closing meta-sentence (or fold its one new bit — this is deliberately not a new judgment axis — into the "same fail-safe direction" sentence).

## Escalation resolution — feature-doc-adr-changelog (round 2)
Kind: review-blocking (docs-reviewer — 1 HIGH, 2 MEDIUM)
Resolution: retry — fix the HIGH, apply both MEDIUMs; auto-loop per §3e (blocking findings return to the worker, no operator gate).
- HIGH (ADR 0030 § Context cites private-store artifacts): take the reviewer's second option — drop the parenthetical breakdown naming the premise gate's null-hypothesis alternatives / six-lens review findings / operator-ratified residuals, and say instead that the ratified brief carries fuller deliberation not reproduced here. Do NOT dangle named artifacts behind the acknowledged-private link. Orchestrator ruling on the "committed verbatim" acceptance bullet: the amendment is sanctioned — the orchestrator will re-stage the final ADR text as a follow-up comment on epic #1847 after merge, so the durable comment and the committed file re-converge; treat acceptance bullet 2 as "committed from the epic comment, Context sentence amended per this verdict".
- MEDIUM (reference-token hooks): add first-mention title hooks — `#1848 "pipeline-drive sweep-cutover rewiring"` in ADR 0030 § Consequences and operational-drain.md § Mutual-exclusion guard; `#1849 (<its actual title, read via gh issue view 1849>)` in operational-drain.md § Integration; `epic #1847 (epic-as-metadata for operational work)` in feature-manifest.txt's comment block.
- MEDIUM (CLT redundancy): the ADR owns the full 86-plan-note probe statistic; trim operational-drain.md § Problem to a one-to-two-sentence pointer at docs/adr/0030 plus what is new for the feature page (the mechanics).
- Re-run validate-feature-docs.sh and the scoped gates after the edits.
