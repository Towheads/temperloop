# Plan-note schema

Canonical schema for plan notes consumed by `/build` and produced by `/assess`.

> **Source of truth: foundation `claude/plan-schema.md`**, deployed to `~/.claude/plan-schema.md` by `make install-claude` (same symlink as the rest of `claude/`). It is **not** kept in the Obsidian vault — it ships with the commands that cite it, so it resolves on every machine they run on (incl. stageFind / a headless cron/deploy host). The *plan notes* it describes still live in the vault at `Plans/<date> <project> - <title>.md`; only this contract lives with the code. Rationale: `Decisions/foundation - Plan schema in claude config (out of the vault)`. Branch field formatting: `Decisions/foundation - Branch naming convention`.

## File location

Plan notes live at `Plans/<YYYY-MM-DD> <project> - <short title>.md` in the Obsidian vault, where `<YYYY-MM-DD>` is the plan's creation date (the same value as frontmatter `date:`). The **date-first prefix is required on every plan** — it matches the vault's `Sweeps/` / `Issues/` / `Sessions/` naming and keeps the `Plans/` folder chronologically sortable. The short title is the theme (3-7 words) and must **not** also lead with a date, since the prefix already carries it. The `Plans/` folder is a sibling of `Decisions/` and holds work breakdowns derived from analysis docs.

## Frontmatter

```yaml
---
tags: [plan, project/<name>]
date: <YYYY-MM-DD created>
source_kind: claude-stamped
source_session: <session-id>
last_verified: <YYYY-MM-DD>
sources:                              # one or more analysis docs that produced this plan
  - "Sweeps/2026-05-15 tier-2 sweep results.md"
  - "Context/stagefind - eval taxonomy.md"
epic: 4567                            # optional; parent epic issue # (board-enabled projects); /build Step 2.6 backfills
status: draft                         # draft | approved | executing | done | abandoned
---
```

`status: draft` is the gate between planning and execution. `/build` refuses to start on a `draft` plan; the user must promote it to `approved` first.

A session can also *poll* on this field: `/assess` optionally arms an approval poll (`Decisions/foundation - Approval-poll handoff for batch workflow`) that watches `status` for up to 2h and auto-launches `/build <plan> --unattended` the moment the user flips it to `approved` — letting the user review, edit, and approve on their own time. The poll auto-starts *execution* only; `/build`'s per-level merge gates stay human-gated.

## Body structure

```markdown
# <Plan title>

## Problem
<2-4 sentences: the problem this plan solves and why it's happening now — the pain
or risk in user-facing terms, NOT the solution. This is the first thing the reviewer
reads at the approval gate.>

## Summary
<The work as grouped bullets (not a paragraph). Each PARENT bullet names one part of
the problem; each SUB-bullet is one item's change, prefixed with its build level
(**L0** first → **Ln** last; items in the same level ship together). Group parents by
theme — which part of the problem — not by level. Light `(#N)` refs, no slugs.>

- **<part of the problem>**
  - **L0** — <change> (#<issue>)
  - **L1** — <change> (#<issue>)
- **<another part of the problem>**
  - **L2** — <change> (#<issue>)

Build order: L0 first → Ln last; items in the same level ship together.

## Sequencing notes
<Free-form: known dependencies, recommended order, items that can run in parallel, items that block the rest. Merge edges go in per-item `depends-on`, logical-order edges in `after:`; this section is for genuinely soft guidance only.>

## Items

- [ ] **<title>** `slug: short-stable-slug` — <one-line scope; becomes PR title body>
  - branch: `<type>/<slug>`           # type ∈ {feat, fix, chore, refactor, docs, test}
  - repo: owner/repo                   # optional; target repo for this item's work, when different from the plan's home repo (the kernel-repo case). Default: the plan's home repo
  - size: S | M | L                    # L means "should probably be split"
  - kind: code | spike                 # default code; spike = verdict-only (note + routed issue, no PR)
  - model: sonnet                      # optional; advisory worker-model tier for /build 3c (sonnet | haiku); absent = inherit the session model (top tier)
  - depends-on: other-slug, another-slug   # MERGE-safety edge: dep must be [x] merged before this starts
  - after: predecessor-slug            # LOGICAL-order edge: satisfied by any terminal state ([x]/[-]/[v])
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 4: provider timeout fallback]]
  - gh_issue: 4567                     # optional; GitHub issue resolved on merge (PR body gets `Closes #N`)
  - also_closes: 4570, 4571            # optional; ADDITIONAL issues this PR resolves — one bare `Closes #M` line each
  - files: `evals/runners/gemini.py`, `evals/runners/__init__.py`
  - acceptance:
    - Gemini runner retries on 504 with exponential backoff (3 attempts, 1s/2s/4s)
    - Existing tests pass; new test covers 504 retry path
    - No change to runner public API
  - gate_check: "configs/artists.toml lists >=40 artists"   # optional; REQUIRED when an external/cross-plan gate rides notes: — a machine-checkable predicate on the CONSUMABLE (command / file-check), not the tracker's closed-state
  - notes: <nuance the worker needs — known gotchas, prior failed approaches, links to related Decisions/Mistakes; an external gate ("Do not start until #N lands") lives here AND must carry a matching gate_check:>
  - review: python-reviewer            # optional override; otherwise inferred from changed files
```

### Problem & Summary — problem-first, grouped by level

The first two sections are the human-readable face of the plan; they are what the reviewer reads at the approval gate (and what `/assess` Step 5 reproduces), so they are optimized for *reading*, not for the machine.

- **`## Problem`** states **why the plan exists** — the pain or risk in user-facing terms, not the fix. 2-4 sentences. (Authoring standard; it is **not** a `/build` validation rule, so older plans without it still execute.)
- **`## Summary`** is **grouped bullets, not a paragraph.** Each **parent bullet = one part of the problem** being addressed; each **sub-bullet = one item's change**, prefixed with its **build level** (`**L0**` first → `**Ln**` last; items in the same level ship together). Group parents by theme, not by level — the level tag carries sequencing, the grouping carries meaning. Use light `(#N)` refs; **no slugs** in this section (slugs live on the `## Items` entries). Don't invent per-item "Leg N" labels — the **level is the sequence**.

The level on each sub-bullet is the item's dependency level (the same level `/build` computes from `depends-on` + `after`), so the summary's sequencing and the execution DAG never disagree.

### Item fields at a glance

Every `## Items` entry is one checkbox line — `- [ ] **<title>** \`slug: <kebab>\` — <scope>` — followed by an indented field block. The table below is a scannable index; the subsections after it give each field's full rules. In the **Required?** column, *required* means every item carries it per the template; *optional* fields sit under an `Optional …` subsection below; validator-enforced fields cite their rule number (see `## Validation rules`).

| Field | Required? | Purpose |
|---|---|---|
| `**<title>**` | required | Human-readable item title. |
| *scope* (text after the slug) | required | One-line scope; becomes the PR title body. |
| `slug:` | required (rule 3) | Stable kebab-case id; the handle `depends-on:` / `after:` reference. |
| `branch:` | required (rule 4) | `<type>/<slug>`, type ∈ {feat, fix, chore, refactor, docs, test}. |
| `repo:` | optional (rule 12) | Target `owner/repo` when the item lands in a repo other than the plan's home (the kernel-vs-overlay split); absent = the plan's home repo. |
| `size:` | required | `S` \| `M` \| `L` (`L` means "should probably be split"). |
| `kind:` | optional (default `code`) | `code` → PR; `spike` → verdict note + routed issue, no PR. |
| `model:` | optional | Advisory worker-model tier `sonnet` \| `haiku`; absent = inherit the session model. |
| `depends-on:` | optional | MERGE-safety edge — each dep must be `[x]` merged before this item starts. |
| `after:` | optional | LOGICAL-order edge — satisfied by any terminal state (`[x]` / `[-]` / `[v]`). |
| `source:` | recommended (rule 6) | Wikilink to the analysis doc/finding; must resolve when present. |
| `gh_issue:` | optional (rule 7) | GitHub issue closed on merge — emits `Closes #N` in the PR body. |
| `also_closes:` | optional | Additional issues this PR resolves — one bare `Closes #M` line each. |
| `files:` | optional | Files the item is expected to touch. |
| `acceptance:` | required (rule 2) | Bullet list of independently checkable conditions. |
| `gate_check:` | conditional (rule 11) | Machine-checkable external-gate predicate; required whenever a prose external gate rides `notes:`. |
| `activation:` | conditional (rule 13) | Inward activation predicate — how `/build` confirms *this item's own* output is live. A `class: A` block carries a `proof:` command run at Step 3e.6; `class: B`/`C` are ledger-discharged (temperloop#317). |
| `notes:` | optional | Nuance for the worker — gotchas, prior failed approaches, external-gate prose. |
| `review:` | optional | Reviewer override; otherwise inferred from changed files. |
| `split_from:` | optional (rule 10) | `#N` this item was split from; mutually exclusive with `gh_issue:`. |
| `epic:` (frontmatter) | optional | Parent epic issue # on board-enabled projects. |
| `pr:`, `pushed_sha:` | orchestrator-written | Set by `/build` at PR-create time; authors don't set them. |

### Item identifier — slug, not position

Each item has a stable slug (`slug: <kebab>`) used by `depends-on`. **Do not** reference items by position number — reorderings break positional references silently. Slugs survive edits.

Slug rules:
- Lowercase, kebab-case, `[a-z0-9-]+`, max 40 chars.
- Unique within the plan note.
- Should be descriptive enough to read in prose: `gemini-retry-504`, not `item-3`.

### Branch field

`branch:` must follow `<type>/<slug>` per `Decisions/foundation - Branch naming convention`. The slug part should equal the item's `slug:` field — keeping them in lockstep makes the plan→branch→PR chain easy to trace.

Type derivation table:

| Finding nature | Type |
|---|---|
| Behavior wrong; fix restores intended behavior | `fix` |
| New capability requested | `feat` |
| Correct but messy / duplicated | `refactor` |
| Build / deps / config / tooling | `chore` |
| Docs only | `docs` |
| Test gap | `test` |

### Optional `repo:` field

`repo:` names the `owner/repo` this item's work actually lands in, when that differs from the plan's home repo. Default (absent) is the plan's home repo — the common case. The motivating case is the **kernel-vs-overlay split** (`claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule, the "stranger test"): a plan authored in an overlay/consumer repo can carry an item whose fix is actually kernel-classified and belongs **upstream**, in the kernel repo, not the plan's own checkout. `/triage` flags such candidates (its kernel-vs-overlay routing step) and `/assess` carries the classification into the item's `repo:` field.

`/build` consumes `repo:` at two honor points:
- **Checkout/worktree selection (Step 3b).** When `repo:` is set and differs from the plan's home repo, the orchestrator resolves a local checkout of `repo:` (rather than the plan's own checkout) and passes *that* root to `worktree.sh create` — the item's worktree, branch, and commits all land against the target repo, never the plan's. If no local checkout of `repo:` exists, this is a hard block (surface it — do not silently fall back to the plan's own repo).
- **PR-body close line (Step 3f).** A cross-repo item's `Closes` line must use the fully-qualified `owner/repo#N` form — `Closes owner/repo#<gh_issue>` — never bare `Closes #N`, which is same-repo only and would not reach the target repo's tracker (per the global `CLAUDE.md` § Issue linkage cross-repo-closes caveat). `also_closes:` entries on a cross-repo item are qualified the same way.

Format: bare `owner/repo` (no `#`, no issue number — that's what `gh_issue:` carries). Slug/kebab org and repo names only.

### Acceptance — bullet list, not prose

Each `acceptance:` block is a list of independently checkable conditions. The worker uses these for self-verification before returning `status: done`; a paragraph form is harder to tick off mentally.

**Gate scope, when sequential legs share one gate/corpus.** When a plan's items are **sequential legs measured by one shared acceptance gate** (a full-corpus eval sweep, a CI smoke gate, any check whose denominator spans multiple legs), each leg's `acceptance:` MUST state its **gate scope** — the fixtures/cases that leg is accountable for, *and* the exclusions whose failure is owned by a **later leg, naming the owning item** (e.g. `excludes Y — owned by #Z`). This is the **gate-side analog** of the falsifiable-acceptance / assume-unverified-mechanism rule (#108): where #108 pins what a leg *produces* (no acceptance criterion may rest on an unbuilt mechanism), gate scope pins what a leg is *measured against* (no acceptance criterion may rest on a shared gate whose denominator a later leg can fail). Without it, a shared-gate failure is **ambiguous between "this leg regressed" and "a later leg's known failure is in my denominator"** — the #491/#512 trap, where leg #491 met its own contract yet could not pass the shared eval-smoke gate because a later leg (#492) owned the fixtures that collapsed, forcing a park, a follow-up issue (#512), and a mid-run gate rescope. Pinning each leg's scope at assess time makes the failure attributable and avoids that churn. Example acceptance bullet:

```markdown
  - acceptance:
    - Gate scope: this leg owns fixtures `ibiza-hi.es`, `barcelona.es` (deterministic year inference); it EXCLUDES the bare-artist fixtures `sf-audio`/`sf-1015`, owned by #492 — their failure does not count against this leg's gate.
    - ibiza-hi.es year-inference accuracy ≥ 99% on the locale corpus
```

### Optional `gh_issue:` field

When an item resolves a GitHub issue tracked in the project's repo, set `gh_issue: <number>`. `/build` consumes this field to inject `Closes #N` into the PR body, which auto-closes the issue on merge per GitHub's keyword linkage. Items without `gh_issue:` don't emit a `Closes` section — refactors, chores, features without a pre-existing tracker.

Three flavours of item leave `gh_issue:` unset, and `/build` Step 2.5 mints a fresh tracking issue for each: (a) untracked work with no pre-existing issue; (b) a **split item** (carries `split_from: #N`; Step 2.6 then *closes* the coarse #N); and (c) a **Contract-derived item** from `/assess` **epic-decomposition mode** — a pre-designed epic decomposed from its `## Contract` body when it had no sub-issues (foundation #526). A Contract-derived item leaves **both** `gh_issue:` and `split_from:` unset and relies on `epic:` frontmatter: `/build` mints its sub-issue and Step 2.6 links it under the **existing** epic, closing nothing (unlike the split case, there is no coarse issue to retire — the parent is the epic, which stays open until its last child closes).

When a plan item is decomposed from an `Issues/` vault note that wraps the GH issue (as `/assess` does for bug batches), populate `gh_issue:` from the issue number in the source heading. The vault Issues note remains the source-of-record for the discussion; the GH issue is the operational tracker.

Project-level rule on PR-body issue references lives in the project `CLAUDE.md` under "Issue linkage" (when the project has one).

### Optional `also_closes:` field

`also_closes:` is a list of **additional** issue numbers this PR resolves, beyond the primary `gh_issue:`. `/build` emits **one bare `Closes #M` line per entry** (each on its own line, never combined) in the PR body, alongside the primary `Closes #<gh_issue>`. GitHub closes an issue only when it carries its **own** keyword — `Closes #1` then `Closes #2` on separate lines — **never** `Closes #1 and #2`; so each entry must become its own line.

Two patterns motivate it:

- **Opportunistic same-PR fix** — a `capture.sh`'d defect fixed alongside the planned work in the same PR; list it in `also_closes:` so it closes atomically with the primary issue.
- **Root-cause-collapse atomic close** — instead of `/triage` closing absorbed symptoms early, the symptoms stay open and the survivor's fix PR carries `Closes #<survivor>` (the primary `gh_issue:`) plus `Closes #<symptomN>` (each `also_closes:` entry), so the whole cluster closes atomically on merge.

`also_closes:` absent is the common case. The list accepts plain integers or `#N` refs; each must be a positive integer.

**On board-enabled projects, `/build` backfills this field.** When the project root provides `scripts/claim.sh` (stageFind's GitHub Projects board), `/build` creates a tracking issue at run start for every worked item that lacks `gh_issue:` and writes the number back here — so on those projects the field ends up populated for all executed items, and each item is claimed In Progress while worked and moved to Done on merge. Authoring `gh_issue:` ahead of time still works when the issue already exists. See `Decisions/foundation - build board integration`.

### Item `kind:` — code vs spike

`kind:` is `code` (default) or `spike`. A **code** item produces a PR (worker → commit → push → PR → CI → merge). A **spike** item is verdict-only — its deliverable is a Context/Decision note + a routed follow-up issue, not a PR. `/build` runs a `spike` read-only, skips push/PR/CI, verifies the note exists and the issue is routed, and marks it `[v]` (verdict-captured); on board-enabled projects the spike's issue closes on verdict-capture, not via a PR `Closes`. In the `## Summary`, a spike gets its level tag like any other item — isolate it into its own earlier level (via `after:` edges) so no level mixes a spike and a build item.

### Optional `model:` field — tier by verification, not difficulty

`model:` is an optional per-item worker-model tier: `sonnet` | `haiku`, or absent. **Absent = inherit the session model (the top tier)** — the safe default. The field is **advisory routing for `/build` 3c only** (it is passed through to the worker `Agent` spawn when present); it is never a validation rule, and an item without it executes normally on the session model.

**Stamping rule** (applied by `/assess` Step 2 when drafting items):

- `size: S` or `M` **and** `kind: code` → stamp `model: sonnet`.
- `kind: spike` or `size: L` → leave `model:` absent (inherit the session model).

The principle is **tier by verification, not difficulty**: a seat takes a cheaper model only when a *mechanical gate* downstream — CI, `quality-gates.sh` (3e.5), the acceptance bullets, the structured return contract — catches a weaker model's mistakes; a seat keeps the top model when its output *is* the gate (judgment nothing downstream checks). An S/M code item rides the full gate chain, so a cheaper worker is safe; a spike's verdict and an L item's breadth are judgment, so they inherit. **Escalate-on-retry:** `/build` re-runs any failed cheap-tier attempt (a `failed` return or a CI failure) on the top tier regardless of the stamp — a retry never stays on the cheap model (see `/build` 3c).

### Edges — `depends-on:` (merge-safety) vs `after:` (logical order)

Two distinct ordering fields, both comma-separated slug lists:

- **`depends-on:`** is a **merge-safety** edge — use it only when out-of-order merging would break (items share schema or identical lines). The dependent's worker starts only after the dep is `[x]` **merged** (it builds on the dep's merged code). `[m]` does **not** satisfy a `depends-on`.
- **`after:`** is a **logical-order** edge — the dependent shares no code with its antecedent but must follow it (e.g. a fix that must follow a spike's verdict). It only sequences the item into a later level, and is satisfied once the antecedent reaches **any** terminal state (`[x]`, `[-]`, or `[v]`) — so a spike satisfies an `after:` edge with no merge.

`/build` builds dependency levels from the **union** of both fields, but applies the "must be merged first" precondition only to `depends-on`. Reach for `after:` whenever the edge is purely about order, not merge conflict — keeping `depends-on` honest is what lets a level fan out safely.

### Optional `epic:` frontmatter field

`epic: <issue-number>` records the parent epic that tracks this plan as one unit. On board-enabled projects, `/build` (Step 2.6) creates the epic from the plan `## Summary` if `epic:` is absent, links each per-item issue as a child, and writes the number back here — idempotent on re-run, exactly like `gh_issue:`. `epic:` absent is valid.

### Optional `split_from:` item field

`split_from: #N` marks an item that `/assess` split out of one coarse sub-issue #N. It is set **only** on split-derived items, and **only with `gh_issue:` left unset** — the two are mutually exclusive. It exists to preserve `/build`'s one-item↔one-issue invariant when one sub-issue decomposes into several items: copying `gh_issue: #N` onto all of them is the #73 bug (the first PR's `Closes #N` closes the shared issue while the rest of the chain is unmerged, and the board moves #N to Done prematurely).

Mechanism: `/build` Step 2.5 sees no `gh_issue:` and **mints a fresh per-item issue** for each split item, writing the minted `gh_issue:` while **removing `split_from:` in the same patch** (the atomic swap that makes "1:1 restored" literal and keeps rule 10 always true — see rule 10), and adding a `Split from #N` lineage line to each minted body; Step 2.6 links the minted leaves as **direct epic children** and then **closes the coarse #N** (once all its leaves are minted) so the data-driven 4d epic-close doesn't hang on a bucket issue. Most items are 1:1 and carry `gh_issue:` instead — `split_from:` absent is the common case. See `Decisions/foundation - Split member 1-to-1 issue minting`.

### Optional `gate_check:` field — the external-gate predicate

The schema forbids cross-plan `after:` refs, so an item that must wait on work **outside this plan** (another plan's leg, an unplanned upstream issue) records that gate as **prose in `notes:`** — `"Do not start until #380 lands"`. Prose is unverifiable: a reader (or `/build`) can only *infer* whether the gate lifted, and the cheapest inference — "the issue is closed" — is **wrong**, because **"issue closed" ≠ "dependency consumable exists."** An issue can close the *data-capture* half of its work while explicitly deferring the *product-wiring* half, so the consumable the gated item actually needs still doesn't exist.

`gate_check:` makes the gate **machine-checkable**: a command or file-check on the **consumable, not the tracker** — the artifact / file / schema / count the gated item actually depends on, evaluated directly. Examples:

```markdown
  - notes: External gate — do not start until the roster lands (#380).
  - gate_check: "configs/artists.toml lists >=40 artists"
```
```markdown
  - gate_check: "test -f build/schema.json && jq -e '.version==2' build/schema.json"
```

Write the predicate against what makes the gated work *possible*, never against the upstream tracker's state. A `gate_check:` that just re-states "#380 is closed" defeats the purpose — pin the **consumable** (`configs/artists.toml lists >=40 artists`), which is true only when the dependency is genuinely *consumable*, not merely when its issue flipped closed.

**This prevents the ELT #492 false gate-lift.** During the ELT run, item #492's gate rode `notes:` as prose ("don't start until #380 lands"); the orchestrator declared it lifted from issue state alone — *"#380 CLOSED → roster gate lifted"* — but #380 had closed the data capture while deferring product wiring (`configs/artists.toml` still listed 3 of 40 artists). #492 was re-opened on that false premise, re-parked, two missing prereqs filed (#519/#520), and the leg re-decomposed — the costliest replan of the run. A `gate_check: "configs/artists.toml lists >=40 artists"` would have read **false** at the gate-lift decision and stopped it. `/assess` emits the predicate alongside the prose gate; `/build` Step 3a runs it instead of inferring lift from issue-closed-state.

### Optional `activation:` block — the inward activation predicate

`gate_check:` points **outward** — "has a *dependency's* consumable materialized." `activation:` is its **inward twin**: "is *this item's own* output now wired into the running path?" It exists because the pipeline's definition of done — worker self-checks `acceptance:` → static gate → CI green → PR merged — measures the *artifact*, never the artifact's *integration*. A runner that is correct but never registered, a flag built but never flipped, a rollup computed but never rendered all satisfy "done" while staying dormant. See `Decisions/temperloop - Activation-completeness contract`.

Activation is a taxonomy of three classes, keyed by **where** the proof lives and **when** it is observable:

```markdown
  - activation:
    - class: A
    - proof: "grep -q GeminiRunner evals/runners/__init__.py"
```

- **`class: A` — synchronous / in-repo.** Flag flip, dispatch-table registration, call-site wiring, render-a-rollup. Proof lives in the same repo and is observable at merge. Carries a **`proof:`** predicate — a shell command that reads **false until the built code is genuinely reachable**, pinned on the *reachability surface* (the `__init__.py` entry, the config value, the rendered panel), never on "the code exists." `/build` runs it at Step 3e.6; if `proof:` is omitted, `/build` falls back to driving `/verify` on the item's `files:`. **This is the only class enforced today** (temperloop#317 Level 1).
- **`class: B` — propagation-gated / cross-repo.** A kernel feature is live only after a release + each consumer's `make update-kernel` + `make install`. Discharged **per-consumer** against an installed-kernel-version watermark, on the `Context/pipeline - pending activations.md` ledger — not at merge. *(Machinery lands with temperloop#317; a `class: B` block records intent today but is not yet auto-discharged.)*
- **`class: C` — time-deferred / soak.** A LaunchAgent firing on cadence, a rollup accumulating data, cross-host reconciliation. Discharged by a periodic liveness poll after a soak window (`env-reconcile.sh`'s `AGENT_STALE` is the launchd sensor), also via the ledger. *(Same status as class B — intent recorded, auto-discharge is temperloop#317.)*

The block is **optional** while temperloop#317 is in flight — a product-source item that omits it is not yet a validation failure (that hard requirement lands with the full epic, once B/C discharge exists, so authoring a B/C block isn't forced before the machinery can honor it). When the block **is** present, rule 13 enforces its internal consistency.

### Orchestrator-written fields (`pr:`, `pushed_sha:`)

`/build` writes these onto an item as it works — authors don't set them. `pr:` (the open PR number) and `pushed_sha:` (the worker commit pushed to the branch) are recorded at PR-create time (3f), *before* the CI watch, so a crash leaves a recoverable pointer: Step 1 resume re-attaches to `pr:` instead of re-spawning a worker, and Step 0.5 reconciles open PRs against it.

## Orchestrator-written `## Questions` section (batch-at-gate deferred decisions)

`/build` writes this section onto the plan note as it runs — authors don't author it; it is created on demand the first time a deferrable in-run decision arises. It is the **in-run, ephemeral queue** for **`batch-at-gate`** decisions: non-blocking choices that arise *during an active run* (e.g. "create N tracking issues?", "auto-fix the safe reconcile divergences?", a per-PR conflict disposition) which carry an **obvious default** and so need not interrupt the level. Instead of issuing an interrupting `AskUserQuestion` mid-level, the orchestrator **appends one entry here** and proceeds on the default; the whole batch is then surfaced as ONE question at the next **level merge gate** (Step 4), before merge consent is recorded. See the severity taxonomy `[[Context/foundation - AskUserQuestion severity taxonomy]]` for which sites defer here vs. stay blocking.

This section is **distinct** from the unattended/ritual pending-decisions surface (#236): that one is cross-run, durable, and read at the daily ritual; this one is per-run, drained at *this* run's next gate. The only thing the two share is the convention below (default-if-unanswered) — a contract, not a schema.

### Shape

```markdown
## Questions

- [ ] `step: 2.5` `item: gemini-retry-504` — Create a tracking issue for this item? **default: create**
  - auto-proceed: if unanswered at the level merge gate, the default (create) is taken — no stall.
- [ ] `step: 0.5` — Auto-fix the safe reconcile divergences (adopt orphan PR #210, prune dead worktree `…/foo`)? **default: don't auto-fix (report only)**
  - auto-proceed: unanswered → default (leave as-is) at gate.
- [x] `step: 4c` `pr: 205` — Conflicting PR #205 disposition? **default: leave open for manual rebase** → answered: re-spawn worker to rebase
```

Each entry is **one line** with a checkbox sentinel plus a `## Questions`-local one-line `auto-proceed:` sub-line stating what the default does:

- **Checkbox** — `[ ]` unanswered (default still pending), `[x]` answered/resolved (default overridden or confirmed at the gate).
- **`step:`** (required) — the originating build step that deferred the question (e.g. `2.5`, `2.6`, `0.5`, `4c`), so the gate can route the answer back to the right action.
- **`item:`** / `pr:` (optional) — the plan-item slug or PR number the question is scoped to, when per-item; omitted for run-wide questions.
- **The question text**, then **`default: <value>`** in bold — the value taken if the entry is unanswered when the gate resolves. **Every entry MUST state its default** — a `batch-at-gate` entry with no default is a defect (it cannot be deferred, because deferral needs a value to proceed with meanwhile). This is the pinned convention from the severity taxonomy.
- **`auto-proceed:` sub-line** (required) — one line spelling out what taking the default does, so an unanswered entry resolving at the gate is legible after the fact.

### Lifecycle

- **Append** (any time during a level): the originating step appends an `[ ]` entry instead of interrupting, then proceeds on the entry's `default`.
- **Drain at gate** (Step 4): the orchestrator reads every `[ ]` entry and surfaces the batch as ONE question before merge consent is recorded — in the **timed** gate regime, an entry still `[ ]` when the window elapses takes its `default` (consistent with the timed-gate "absence of objection = consent" auto-proceed); in the **modal** regime, the entries are presented alongside the merge `AskUserQuestion`. Either way, **an unanswered entry at gate resolution takes its default — never a silent stall.**
- **Resolve**: tick `[ ]` → `[x]` and append `→ answered: <choice>` (or `→ default taken: <value>`) when the gate resolves it, so a resumed run never re-asks a settled question.

## Orchestrator-written `## Merge gate log` section (merge-consent lines)

`/build` appends this section onto the plan note as it runs — authors don't author it. It is the **durable record of merge consent**, one line per level-consent event, written **at consent time** (modal approval given, timed window elapsed with no objection, or the headless immediate-merge re-poll passed) and **before the first merge call of that level**, via `vault_append` (a reliable EOF op). Like `pr:`/`pushed_sha:`, it exists so a crash leaves a recoverable pointer — here, the pointer that makes **resume-without-re-consent** mechanical on the MANAGED merge backend (`/build` 4b "Merge — MANAGED backend" resume state table): a resumed run that finds a consent line covering a still-`[m]` item's PR re-enters the managed loop without re-asking the operator; absent a covering line, the level takes a fresh gate. No PR/issue label carries this state — consent and resume ride the plan note alone, cross-checked against a live PR probe.

### Shape

```markdown
## Merge gate log

- consent: level 0 · 2026-07-04T18:22:05Z · mode: modal-approved · PRs: #17 #18 #19
- consent: level 1 · 2026-07-05T02:10:44Z · mode: timed-elapsed · PRs: #21
```

One line per consent event, four fields:

- **`level <k>`** — the dependency level the consent covers.
- **Timestamp** — ISO-8601 UTC, the moment consent was recorded.
- **`mode:`** — how consent arose: `modal-approved` (explicit operator approval at the modal gate) | `timed-elapsed` (timed window elapsed with no objection) | `headless-immediate` (`FUNNEL_OPERATOR_ABSENT=1` immediate-merge branch, re-poll passed).
- **`PRs:`** — the **exact** consented PR list. Consent pins this list: a PR not in it (or work re-pushed under a new PR number) is **not** covered and must earn consent at a fresh gate. A level gated more than once (e.g. an EJECTED item re-parked and re-gated) appends a **new** line — lines are append-only, never edited.

## Status sentinels (in-band tracking)

`/build` mutates the plan note as it goes. Six states:

```markdown
- [ ] <title> ...        # untouched
- [~] <title> ...        # in-progress (worker active, or PR opened but CI not green)
- [m] <title> ...        # merge-pending (PR open, CI green, parked for batch gate)
- [x] <title> — merged in #142 (2026-05-17)
- [v] <title> — verdict-captured 2026-05-17 (kind: spike — note written + issue routed; no PR)
- [-] <title> — skipped 2026-05-17: <reason>, see [[Sessions/...]]
```

`[m]` is set by `/build` when an item reaches CI-green inside a dependency-level batch; it transitions to `[x]` (merged) or stays `[m]` (left open at the gate) when the level's batch merge gate fires. `[v]` is the terminal state for `kind: spike` items — set on verdict-capture (note written + issue routed), it never enters the merge gate. Grep `\- \[~\]\|\- \[m\]` across the vault to find anything in flight.

## Validation rules (enforced by `/build` before execution)

Fail fast if any of:

1. Frontmatter `status` is `draft` — force the user to mark `approved`.
2. Any item has no `acceptance:` block — workers need a self-check signal.
3. Any item has no `slug:` — required for stable `depends-on` references.
4. Any item's `branch:` doesn't match `<type>/<slug>` where type ∈ {feat, fix, chore, refactor, docs, test}.
5. `depends-on` references a slug that doesn't exist in this plan, or one that is not yet in `[x]` state when the dependent item is about to start. (`[m]` does not satisfy a `depends-on` — the dep must be merged into main before the dependent's worker can build on top of it.)
6. A `source:` wikilink target doesn't resolve (analysis doc was moved/renamed since planning).
7. `gh_issue:` (when present) must be a positive integer — fail otherwise; do not silently coerce.
8. `after:` references a slug that doesn't exist in this plan, OR the union of `depends-on` + `after` edges contains a cycle. (Unlike `depends-on`, an `after:` edge is satisfied by *any* terminal state — `[x]`, `[-]`, or `[v]` — not only `[x]` merged.)
9. An item's `acceptance:` block still contains the placeholder `- (no acceptance criteria derivable from source — fill in during review)`. The placeholder is a valid *authoring* signal but a *fatal* execution signal — fill it in before approving. (`epic:` absent is never a failure — it is optional and only meaningful on board-enabled projects.)
10. An item carries **both** `gh_issue:` and `split_from:` (mutually exclusive), or a non-empty `split_from:` whose value isn't a `#<positive-integer>` issue ref. A split item must leave `gh_issue:` unset so Step 2.5 mints it a fresh per-item issue (#73). This mutual exclusion is an **always-true invariant**, including across a resume: `build` Step 2.5 **swaps `split_from:`→`gh_issue:` atomically** — the same patch that writes the minted `gh_issue:` also *removes* `split_from:`, restoring the 1:1 item↔issue end-state — so an item is never left carrying both, and a resumed run's re-validation of this rule always passes. Worked before/after of one split item across Step 2.5: `split_from: #40` / no `gh_issue:`  →  `gh_issue: #57` / no `split_from:`.
11. An item declares an **external / cross-plan gate in `notes:`** (a prose gate of the "don't start until #N lands" form — the schema forbids a cross-plan `after:` ref, so such a gate can only ride `notes:`) but carries **no `gate_check:` predicate**. A prose-only external gate is a **validation smell**: it is unverifiable, so a gate-lift can only be *inferred* from issue-closed-state — the ELT #492 trap, where "#380 CLOSED → roster gate lifted" was wrong because #380 deferred product wiring ("issue closed" ≠ "dependency consumable exists"). Every external/cross-plan gate MUST carry a machine-checkable `gate_check:` on the **consumable** (e.g. `gate_check: "configs/artists.toml lists >=40 artists"`) that `/build` Step 3a evaluates directly instead of inferring lift from the tracker. (A `gate_check:` is **optional** on an item with no external gate — the requirement is conditional on the prose gate being present.)
12. `repo:` (when present) must match `owner/repo` shape — a single `/` separating two non-empty segments of `[A-Za-z0-9_.-]+`, no leading `#`, no issue number. Fail otherwise; do not silently coerce or strip. (`repo:` absent is never a failure — it is optional and defaults to the plan's home repo.)
13. An item declares an `activation:` block whose `class:` is not one of `A` \| `B` \| `C`, **or** a `class: A` block that carries no `proof:` predicate. Class A is the synchronous in-repo activation check `/build` runs at Step 3e.6, so it must be machine-checkable — like `gate_check:`, but pinned on *this item's own* reachability surface (the `__init__.py` entry, the flipped flag, the rendered panel) rather than a dependency's. Class B/C are ledger-discharged (temperloop#317) and need no `proof:`. (An `activation:` block is **optional** — the requirement is conditional on the block being present; a `class: A` block specifically must carry `proof:`.)

> `## Problem` and the grouped `## Summary` are an **authoring standard, not a validation rule** — `/build` does not fail a plan that lacks them, so plans authored before this convention still execute on resume.

## Worked example

```markdown
---
tags: [plan, project/stagefind]
date: 2026-05-16
source_kind: claude-stamped
source_session: 784be64a
last_verified: 2026-05-16
sources:
  - "Sweeps/2026-05-15 tier-2 sweep results.md"
status: approved
---

# stagefind - 2026-05-15 sweep follow-up

## Problem
The tier-2 sweep surfaced three independent reliability gaps in the eval runners: upstream 504s aren't retried, the cache key changes every run so nothing is reused, and one runner silently ignores `--max-items`. Together they make sweeps flaky and slow and undermine trust in the numbers.

## Summary
- **Make the runners resilient and reproducible.**
  - **L0** — Add exponential-backoff retry for Gemini 504s. (#4567)
  - **L1** — Derive the cache key only from (prompt, model, params) so reruns hit cache.
- **Make the CLI honor its flags.**
  - **L1** — Respect `--max-items` in the batch runner (currently parsed but ignored).

Build order: L0 first → L1 last; items in the same level ship together.

## Sequencing notes
The cache-miss fix touches the same runner registration code as the max-items fix — do `gemini-retry-504` first, then `cache-key-stability` and `respect-max-items` can go in parallel.

## Items

- [ ] **Gemini runner: retry on 504** `slug: gemini-retry-504` — add exponential-backoff retry for upstream 504s
  - branch: `fix/gemini-retry-504`
  - size: S
  - model: sonnet                     # stamped: size S + kind code → sonnet (absent = inherit session model)
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 4: provider timeout fallback]]
  - gh_issue: 4567                    # tracked in the repo; PR body emits `Closes #4567`
  - files: `evals/runners/gemini.py`
  - acceptance:
    - Retries on 504 with 1s/2s/4s backoff (3 attempts total)
    - Existing tests pass; new test covers the 504 retry path
    - No change to runner public API
  - notes: see [[Mistakes/stagefind - silent provider timeouts]] for prior approach that masked errors

- [ ] **Stabilize cache key across runs** `slug: cache-key-stability` — cache key currently includes a timestamp, defeating reuse
  - branch: `fix/cache-key-stability`
  - size: M
  - depends-on: gemini-retry-504
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 7: 0% cache hits in tier-2]]
  - files: `evals/cache.py`, `evals/runners/__init__.py`
  - acceptance:
    - Cache key derived only from (prompt, model, params) — no clock-dependent inputs
    - Tier-2 sweep shows >80% cache hits on second consecutive run
    - Existing cache tests pass; new test asserts key stability across two builds 1s apart

- [ ] **CLI: honor `--max-items` in batch runner** `slug: respect-max-items` — flag is parsed but ignored
  - branch: `fix/respect-max-items`
  - size: S
  - depends-on: gemini-retry-504
  - source: [[Sweeps/2026-05-15 tier-2 sweep results#Finding 9: --max-items ignored by batch runner]]
  - files: `evals/cli.py`, `evals/runners/batch.py`
  - acceptance:
    - `--max-items N` truncates the input set to N before dispatch
    - New CLI test asserts truncation; existing tests unaffected
```

## Cross-references

- Decision: `Decisions/foundation - Plan-note schema`
- Decision: `Decisions/foundation - Plan schema in claude config (out of the vault)`
- Decision: `Decisions/foundation - Approval-poll handoff for batch workflow`
- Kernel-vs-overlay routing (the `repo:` field's motivating case): `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule
- Convention: `Decisions/foundation - Branch naming convention`
- Consumer command: `claude/commands/build.md` (deployed `~/.claude/commands/build.md`)
- Producer command: `claude/commands/assess.md` (deployed `~/.claude/commands/assess.md`)
