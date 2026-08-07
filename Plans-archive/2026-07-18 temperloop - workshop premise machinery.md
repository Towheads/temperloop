---
tags: [plan, project/temperloop]
date: 2026-07-18
source_kind: claude-stamped
source_session: 7dbd0225
last_verified: 2026-07-18
sources:
  - "#498"
epic: 498
status: done
---

# temperloop - workshop premise machinery

## Run status

run complete 2026-07-18 · session 7dbd0225 · 2 levels · items: 4 done / 0 parked / 0 in-flight / 0 skipped · epic #498 closed

## Problem

The `/workshop` design flow has no premise gate: every idea that reaches intake is walked through the full coverage template and materialized, with nothing forcing an explicit "should we build this at all?" test. The do-nothing cost, the strongest subtraction / existing-surface alternative, and the operator's justification for proceeding are never recorded, so a weak-premise idea gets the same green-lit treatment as a strong one and the null hypothesis is never on the table. Compounding this, the adversarial review panel's red-team slot has no executing agent shipped, so it silently degrades to `skipped` — the one lens meant to attack a brief's premise never runs. The result: `/workshop` can ratify and build work whose premise was never challenged.

## Summary

- **Give the premise something to be judged against, and a place to be recorded**
  - **L0** — Extend `docs/principles.md` with the three missing principles (stranger test, minimum-viable-output, legible degradation) so the gate and lens can cite them by name (#498)
  - **L0** — Add kernel dimension `0. Premise & null hypothesis` to `design-schema.md` (`filled`-only), sweep the stale 16→17 dimension-count literals, and clean up the stale `/design`→`/workshop` refs (#498)
- **Make the premise challenge actually fire**
  - **L1** — Add the premise gate at `workshop.md` Step 1.3b — case-against + record justification into dimension 0 + `proceed`/`reshape`/`drop`; `drop` flips the brief to `status: dropped` with a reopen-confirm (#498)
  - **L1** — Ship `claude/agents/red-team-lens.md` so Step 3.3.3's red-team slot runs live instead of degrading to `skipped` (#498)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes

- **L0 items are fully parallel** — `principles-charter-extension` touches only `docs/principles.md`; `design-schema-dimension-0` touches `claude/design-schema.md` / `claude/commands/workshop.md` / `docs/features/workshop.md` / `CHANGELOG.md`. Disjoint files.
- **L1 items branch off fresh `origin/main` after L0 merges**, so the dimension-0 row, the `dropped` status enum's home file, the swept count literals, and the L0 CHANGELOG entry are all already in place — no cross-level conflict.
- **Both L1 items edit `claude/commands/workshop.md` but in disjoint regions** — Step 1.3b / Step 1.4 (intake) vs Step 3.3.3 (adversarial panel). They parallelize; if the L1 merge gate ever hits a conflict it's a trivial rebase. (Confirmed by line inspection in the Step 3 sanity pass.)
- **Item `workshop-premise-gate` is the heaviest** — a new interactive gate plus a new frontmatter enum value plus a Step 1.4 probe branch. All four items are prose/contract edits whose substance is only advisory-reviewed (no mechanical gate checks the prose), so the operator may prefer to bump one or more worker tiers to the top model at approval; the draft stamps `model: sonnet` per the size/kind rule.
- **Note (parser workaround):** each item's `activation:` block is placed **before** its `acceptance:` block to dodge a `plan.sh` rule-14 parser bug that fails to detect an activation block placed after acceptance (tracked as #506). No semantic effect — item-field order is free.
- **External / adjacent (NOT build items in this plan):**
  - PR **#499** (open) carries the two draft ADRs for this epic and must be renumbered `0007`/`0008` before it merges — see `## Re-triage signals`, tracked as **#503**.
  - `claude/design-measurement-proxies.md` carries stale `/design` refs (temperloop#354 rename debt) — out of this epic's scope, tracked as **#504**.

## Re-triage signals

- **[ephemeral — resolve at/around approval]** Epic #498's `## ADRs` section names `docs/adr/0002-premise-gate-as-kernel-dimension-0.md` and `docs/adr/0003-principles-doc-as-charter-source.md`, but `0002`/`0003` are **already taken** on `origin/main` (`0002-managed-clone-state-ownership.md`, `0003-knowledge-store-sync-optional-capability.md`; ADRs run 0000–0006). PR **#499** (open) adds the colliding files, so merging it as-is would collide with two unrelated existing ADRs. **Durable route taken:** filed as **#503** (board 7 Backlog, `bug`) recommending PR #499 renumber the drafts to `0007`/`0008` and the epic Contract's `## ADRs` be updated to match. This is a fix on the existing PR, **not a build item** in this plan — none of the four items touch `docs/adr/`.
- **[persistent — re-queued]** `claude/design-measurement-proxies.md` carries stale `/design` command refs and a dead `claude/commands/design.md` path (renamed to `workshop.md` in temperloop#354). Out of epic #498's scope (its Contract scopes the `/design`→`/workshop` sweep to `design-schema.md` only). **Durable route taken:** filed as **#504** (board 7 Backlog, `bug`) for the next `/triage`.

## Items

- [x] **Extend docs/principles.md with the stranger test, minimum-viable-output, and legible-degradation principles** `slug: principles-charter-extension` — add the three missing principles the premise gate and red-team lens cite by name, in the doc's established shape
  - branch: `docs/principles-charter-extension`
  - size: M
  - kind: code
  - model: sonnet
  - source: #498
  - gh_issue: #507
  - files: `docs/principles.md`
  - acceptance:
    - Three new principles — **stranger test**, **minimum-viable-output**, **legible degradation** (subtraction-over-mechanism is already principle 8) — added to `docs/principles.md`, each in the established `### N.` shape (named, short section)
    - Each added principle carries a resolvable mechanism-receipt citation back to the kernel source it consolidates (stranger test → `CLAUDE.kernel.md` § Kernel vs overlay routing rule; minimum-viable-output → `workshop.md` "Minimum-viable-output rule"; legible degradation → `message-schema.md` § Degradation notice / `CLAUDE.kernel.md` § Legible agent-gate degradation) — reviewer-checked (advisory, per design dimension 8); no invented principles, no second consolidation doc
    - No new doc is created and **no governance-manifest change** is made (the doc is already registered in both manifests)
    - The doc's **dual use** is made explicit — stranger-facing thesis (README/ADR-0001, unchanged) *and* charter-derivation source for principle-referencing lenses — mirroring the dual use `docs/who-its-for.md` already carries
    - The count literal in the `## The twelve principles` heading (and any in-body "twelve" count reference) is updated to the new total
  - notes: Docs-only item (all `files:` under `docs/`), so exempt from the rule-14 `activation:` requirement. This is the L0 charter-source item that L1's gate (`workshop-premise-gate`) and lens (`red-team-lens-agent`) cite by principle name — they carry `after:` edges to it. Related: [[Decisions/temperloop - workshop premise gate and adversarial machinery]].
  - pr: 511

- [x] **Add kernel dimension 0 (Premise & null hypothesis) to design-schema.md and sweep stale count / command literals** `slug: design-schema-dimension-0` — introduce dimension 0 (filled-only), refresh the 16→17 dimension-count literals, and clean the stale `/design`→`/workshop` refs
  - branch: `feat/design-schema-dimension-0`
  - size: M
  - kind: code
  - model: sonnet
  - source: #498
  - gh_issue: #508
  - files: `claude/design-schema.md`, `claude/commands/workshop.md`, `docs/features/workshop.md`, `CHANGELOG.md`
  - depends-on:
  - after:
  - activation:
    - class: A
    - proof: "grep -qE '^\\|[[:space:]]*0[[:space:]]*\\|' claude/design-schema.md"
  - acceptance:
    - `claude/design-schema.md` § Kernel dimension list carries a dimension-`0` row (`0. Premise & null hypothesis`) with an enforcing-gate entry, numbered 0 so it sorts and is walked first without renumbering 1–16
    - The dimension-0 row states the **`filled`-only pin** — `n/a` and `deferred` are invalid dispositions for dimension 0 (a deferred premise is the exact gap the gate closes)
    - The schema's worked-example skeleton carries a `## 0.` section
    - A grep for the old count literals returns only updated text: `design-schema.md` "Sixteen dimensions"/"sixteen-dimension"; `workshop.md` "16 kernel"/"all sixteen"; `docs/features/workshop.md` "sixteen kernel dimensions" — all 16→17
    - `design-schema.md` carries no remaining `/design` command references (all → `/workshop`)
    - `CHANGELOG.md` marks the schema change **additive**, notes that dimension **0 spends the only prepend slot** (a future intake-time dimension forces renumbering — never reach for −1), and honestly notes in-flight draft briefs need a one-touch migration (add dimension 0) before they can ratify
    - Existing lints pass: `validate-template-refs.sh`, `validate-feature-docs.sh`, `check-kernel-manifest.sh`
  - notes: Product-source (`claude/`), so carries a class-A activation proof pinned on the dimension-0 table row actually landing in the kernel dimension list (reads false until the row exists). The 16→17 count reflects dimension 0 being added to the kernel set. This is the L0 schema item both L1 items depend on (dimension 0 is the surface the gate records into and the lens attacks; the `dropped` status enum L1 adds lives in this same file). Related: [[Decisions/temperloop - workshop premise gate and adversarial machinery]].
  - pr: 513

- [x] **Add the premise gate at workshop.md Step 1.3b (case-against + justification into dimension 0 + proceed/reshape/drop)** `slug: workshop-premise-gate` — the null-hypothesis gate that composes the case against a brief, records the operator's justification, and can drop the brief
  - branch: `feat/workshop-premise-gate`
  - size: M
  - kind: code
  - model: sonnet
  - source: #498
  - gh_issue: #509
  - files: `claude/commands/workshop.md`, `claude/design-schema.md`, `CHANGELOG.md`
  - depends-on: design-schema-dimension-0
  - after: principles-charter-extension
  - activation:
    - class: A
    - proof: "grep -q '1.3b' claude/commands/workshop.md"
  - acceptance:
    - `claude/commands/workshop.md` Step **1.3b** exists (after the stranger test / kernel-overlay routing call) and (i) composes the case *against* — do-nothing cost, strongest subtraction alternative, existing-surface coverage — citing `docs/principles.md` **by principle name**
    - The gate (ii) elicits and records the operator's justification **into dimension 0** (composed fresh per brief — never reused or suggested from prior briefs), and (iii) offers `AskUserQuestion` **proceed / reshape / drop**; **reshape** loops back to Step 1.1 exactly once per pass (bounded ceremony)
    - **drop** flips the brief's frontmatter to a new `status: dropped` (additive enum value alongside `draft`/`ratified` in `design-schema.md`) with dimension 0 carrying the kill rationale
    - Step **1.4**'s probe gains a `dropped` branch: **stop** — reopening a dropped brief requires an explicit operator confirmation, never the silent draft-adopt path
    - `CHANGELOG.md` marks the `status`-enum addition (`… | dropped`) as an **additive** contract-surface change, parallel to the dimension-0 additive marker (a consumer pattern-matching `draft|ratified` must be told about `dropped`)
    - **Verification surface (pinned by the epic Contract):** the PR body includes a `/workshop` **dry-run transcript** showing the gate firing on a test idea — case-against citing ≥1 named principle, justification recorded into dimension 0, proceed/reshape/drop offered — and a drop leaving a `status: dropped` brief whose re-probe stops with the explicit reopen ask
  - notes: Product-source (`claude/`), class-A activation proof pinned on Step 1.3b actually landing in the command spec `/workshop` executes (reads false until wired). `depends-on: design-schema-dimension-0` is a genuine merge-safety edge — both edit `claude/design-schema.md` (the `dropped` status enum lives beside the dimension-0 row) — and also the logical edge (the gate records into dimension 0). `after: principles-charter-extension` because the case-against cites the *new* principle names, which must exist first. The CHANGELOG marker was added on the Step 3 requirements-auditor's finding (its own contract-surface edit was missing the marker item 2 correctly requires). Related: [[Decisions/temperloop - workshop premise gate and adversarial machinery]].
  - pr: 517

- [x] **Ship claude/agents/red-team-lens.md and wire it into workshop.md Step 3.3.3** `slug: red-team-lens-agent` — the executing red-team lens so Step 3.3.3 runs live instead of degrading to skipped
  - branch: `feat/red-team-lens-agent`
  - size: M
  - kind: code
  - model: sonnet
  - source: #498
  - gh_issue: #510
  - files: `claude/agents/red-team-lens.md`, `claude/commands/workshop.md`
  - depends-on: design-schema-dimension-0
  - after: principles-charter-extension
  - activation:
    - class: A
    - proof: "test -f claude/agents/red-team-lens.md && grep -q 'red-team-lens' claude/commands/workshop.md"
  - acceptance:
    - `claude/agents/red-team-lens.md` exists — read-only, advisory; charter = attack the brief's **acceptance criteria, threat model, and premise justification (dimension 0)**; every finding must cite a named principle (uncited findings are discardable on sight)
    - The charter is **self-contained prose authored from `docs/principles.md`** and names it as the derivation source — the same authored-from (not runtime-file-read) shape every existing reviewer/persona agent uses, so a deployed copy is auditable standalone
    - `/workshop` Step **3.3.3**'s slot description is updated in the same change to name the **premise-justification target**, with the agent file stated as the authoritative charter
    - The **second** stale "the red-team lens has no agent shipped yet" mention in `workshop.md` (§3.1 tier-cost narration, ~line 279) is also updated, so the PR does not land a doc that says both "runs live" (§3.3.3) and "no agent shipped" (§3.1)
    - **Verification surface (pinned by the epic Contract):** on a checkout with project agents installed, a full pass runs the red-team lens **live** — no `skipped — <agent> unavailable` line — and its findings each cite a named principle; the PR attaches a sample lens run against a fixture brief
  - notes: Product-source (`claude/`), class-A activation proof checks both the artifact exists **and** it is wired into the Step 3.3.3 slot (reads false until the slot names the agent — existence alone isn't reachability). `claude/agents/*` is wildcard-registered in both `kernel-manifest.txt` and `feature-manifest.txt`, so the new file needs no manifest edit. `depends-on: design-schema-dimension-0` (the lens attacks dimension 0, the schema surface item 2 defines) + shared `workshop.md`; `after: principles-charter-extension` (charter cites the new principle names). The second-stale-mention fix (~line 279) was added on the Step 3 requirements-auditor's finding. Related: [[Decisions/temperloop - workshop premise gate and adversarial machinery]].
  - pr: 516
