---
description: Decompose a single triaged board **epic** into a structured plan note in `Plans/` per the canonical schema. Normally reads the epic + its native sub-issues, maps one sub-issue → one plan item; for a **pre-designed epic with a `## Contract` body but zero sub-issues** (the intentionally-undecomposed, per-tier pattern) it instead decomposes the Contract's `Produces` into seam-scoped items (`/build` mints the sub-issues under the existing epic). Computes dependency edges/levels fresh and writes a `Plans/` note (`status: draft`) for human review. Can arm an approval poll that auto-starts `/build` once the user flips `status` to `approved`. Doc/sweep intake now belongs to `/triage` (the single front door).
argument-hint: "--epic <N> [--board <N> | --project <name>] [--no-poll]"
---

You are running the **assess** command. Goal: take one **already-triaged epic** and work out *how it builds safely* — decompose it to the **seam**, compute merge-safety (`depends-on`) and logical-order (`after:`) edges and dependency levels, and emit a structured plan note that `/build` can execute. This is the **technical-judgment** stage of the funnel (logical grouping already happened in `/triage`):

```
/triage   cull → group → epic + sub-issues (Backlog→Ready)
   └─► /assess --epic N   epic → decompose to seams → edges/levels → Plans/ note (draft)
          └─► /build   execute → claim → merge → close children → close epic (Done)
```

The plan conforms to the plan-note schema (`~/.claude/plan-schema.md`) and ships with `status: draft` — promotion to `approved` is the user's decision. See [[Decisions/foundation - Triage stage and the logical-technical pipeline split]] for the logical/technical split this command's scope sits on.

**Single funnel — doc-mode is retired.** `/assess` no longer reads loose analysis docs (sweeps / audits / bug-report sets). Those now enter through `/triage`, which culls and groups them onto the board as an epic; `/assess` then plans that epic. To plan a sweep, run `/triage <sweep-doc>` first. (The old `$1..$N` doc-path arguments are gone.)

**`/assess` owns sub-issue authoring for a pre-designed, intentionally-undecomposed epic** (foundation #526). `/triage` materialises sub-issues only when it culls/groups **loose findings** (Backlog items, sweep docs) into a new epic — it has **no** path to expand an already-existing, fully-specified epic. So a tier-N>1 epic authored with a rich `## Contract` body but **zero sub-issues by design** (the *"sub-issues authored when the tier approaches"* pattern, `[[Decisions/ssmobile - Subset iOS MVP program decomposition]]`) is **not** triage's to decompose — running `/triage` on it does nothing. It is `/assess`'s: **epic-decomposition mode** (Step 1) decomposes the epic's `## Contract` `Produces` into seam-scoped items when membership is empty, instead of stopping. The "no sub-issues → run `/triage`" stop now fires **only** for an epic that carries *no* Contract (genuinely undecomposed). See [[Decisions/foundation - Assess epic-decomposition mode (who authors sub-issues for a designed epic)]].

## Inputs

- `--epic <N>` (required) — the board issue number of a **triaged epic** (a parent issue whose group members are its native sub-issues). This is the only source.
- `--board <N>` / `--project <name>` (optional) — which board/repo the epic lives on. stageFind = `3` (repo `<org>/stageFind`), foundation = `4` (repo `<org>/foundation`). Explicit `--board`/`--project` is **preferred**; if omitted, the board is **inferred from the local repo** (see Step 0.3). Inference is bounded to the repo you're standing in — it can only resolve to that repo's registered board, so it cannot silently act on an *unintended* board (the prior arbitrary stageFind-`3` default is gone; this matches `/triage`'s inference rule, foundation#547). The project slug for the plan filename/tag is derived from the resolved board (3 → `stagefind`, 4 → `foundation`) unless `--project` overrides.
- `--no-poll` (optional) — skip the Step 6 approval-poll offer; stop after the Step 5 summary.

## Operating principles

- **The epic is gospel; triage already made the logical calls.** Take the epic's membership as given — do **not** re-cull or re-group here. If seam analysis surfaces a *logical* doubt (a suspected dupe, a mis-scoped or invalid member, a regroup candidate, or genuinely new work), **route it, don't act on it** — see the `## Re-triage signals` handling in Step 4. Authority is one-directional: this command acts only on *technical* findings (it wires phases, spikes, edges itself); logical findings it surfaces for triage.
- **Stay in the orchestrator for decomposition.** Cognitive core; keep it in the parent context. Subagents only for the read-only sanity-check pass in Step 3.
- **One sub-issue = one plan item** by default. Combine two members into one item only when fixing one without the other is awkward (and note the merge); split a member into sub-items only when it has genuinely independent sub-fixes. **When you split one sub-issue #N into multiple items, do NOT copy `gh_issue: #N` onto all of them** — that many-to-one binding breaks `/build`'s one-item↔one-issue invariant (the first PR to merge auto-closes #N while the rest of the chain is unmerged; see #73). Instead leave `gh_issue:` **unset** on every split-derived item and stamp `split_from: #N` on each. `/build` Step 2.5 then **mints a fresh per-item sub-issue** for each (restoring 1:1) and closes the coarse #N. Non-split items keep `gh_issue: #N` as normal.
- **Epic-decomposition mode: a Contract-bearing epic with no sub-issues is decomposed here, not stopped (foundation #526).** When Step 1 finds the epic has **zero sub-issues** *and* its body carries a **`## Contract`** section (the pre-designed, intentionally-undecomposed epic — the per-tier *"sub-issues authored when the tier approaches"* pattern), do **not** emit the "run `/triage`" stop. Instead **decompose the Contract's `Produces` into seam-scoped items** (one item per produced seam, or per logical cluster of `Produces` bullets), with `Consumes` framing the deps/sequencing and `Acceptance` seeding each item's acceptance. **Mechanics — reuse the mint path, never `split_from:`:** leave `gh_issue:` **unset** and `split_from:` **unset** on every Contract-derived item, and record `epic: <N>` (the epic being assessed) in the plan frontmatter. `/build` Step 2.5 then mints a fresh sub-issue per item and Step 2.6 links each under the **existing** epic — closing nothing. (Do **not** set `split_from: <epic>`: that marker makes `/build` Step 2.6 *close* the coarse issue, which here is the epic — it must stay open until its last child closes.) **Don't fabricate:** a `Produces` bullet too vague to yield a falsifiable acceptance gets the `- (no acceptance criteria derivable from source — fill in during review)` placeholder, not invented criteria — the Step 3 sanity pass and the approval gate then force it filled before build. See [[Decisions/foundation - Assess epic-decomposition mode (who authors sub-issues for a designed epic)]].
- **Decompose to the seam, not the implementation.** Scope each item to its *contract* — what it **produces** (interface / artifact / schema / verdict), what it **consumes** (its deps), its **acceptance check** — and leave *how* to execution. This is what makes items both parallelizable (no coordination once the seam is fixed) and stale-resistant (an implementation learning changes the *how*, not the contract). An item body that prescribes implementation is the staleness smell — pull back. The plan note *is* the epic's decomposition; mirror the epic→sub-issue structure as items + dependency levels. See [[Decisions/stageFind - Contract-based epic decomposition]].
- **Be conservative on `depends-on`; use `after:` for logical order.** `depends-on` is a **merge-safety** edge — use it only when out-of-order merging would break (shared schema, identical lines). For purely *logical* ordering (a fix that must follow a spike's verdict but shares no code), use the separate `after:` edge: it sequences the item into a later level without asserting a merge conflict, and is satisfied once its antecedent reaches any terminal state (incl. a spike's `[v]`). Genuinely soft guidance still goes in `## Sequencing notes`. **Edges and levels are recomputed fresh every run into the plan — they are never stored as board state** (only membership is; see the triage decision).
- **Verdict-only / spike items are legitimate.** Not every item is a code PR. A spike's deliverable can be a Context/Decision note + a routed follow-up issue. A sub-issue carrying the `spike` label (set by `/triage`) maps to `kind: spike` (default is `kind: code`); give it a falsifiable acceptance bar (what the note must state), and route anything that must follow its verdict with an `after:` edge. `/build` closes a spike on verdict-capture (`[v]`), not on a merged PR.
- **Isolate spikes into their own earlier level — never mix a spike and a build item in one level.** A spike's verdict reshapes downstream scope (it can rewrite the contract, the edges, even which items survive), so any build that shares its level would start *before* that reshaping lands and risk mid-level replanning. Add an `after:` edge from every dependent build to the spike so the spike floats up into a **spike-only level that resolves first**. (Concretely: in the ELT epic the L0 keystone spike shared a level with a build item, and its verdict then rewrote a downstream `depends-on` edge mid-run — exactly the churn this avoids.) `/build`'s preview already treats spike-only levels as needing no merge gate. See [[Mistakes/foundation - build design-fork drops to manual, orchestrator context blowup]].
- **Spike the seam before planning a no-behavior-change refactor or an L-sized unification.** When an item's true interface is only discoverable by reading the code it moves/unifies (a refactor, a shared-seam extraction, anything `size: L` that merges two implementations), the build's contract is a *guess* until someone finds the seam — and guesses surface as plan reversals mid-build (a byte-exactness trap; a persistence assumption that breaks the test suite). **Split the sub-issue into a precursor `kind: spike` item + the build item** — reuse the split mechanism (`gh_issue:` unset + `split_from: #N` on both, so `/build` mints fresh issues and the 1:1 invariant holds) — give the spike the acceptance *the seam is identified and the compatibility / byte-exactness traps enumerated*, and make the build `after:` it. This pulls discovery that would otherwise happen (expensively) mid-`/build` forward to assess time.
- **Partition the gate per leg when sequential legs share one acceptance gate/corpus.** When the items you emit are **sequential legs measured by one shared gate** (a full-corpus eval sweep, a CI smoke gate, any acceptance check whose denominator spans multiple legs), each leg's `acceptance:` **MUST state its gate SCOPE** — the fixtures/cases that leg is accountable for, *and* the exclusions whose failure is owned by a **later leg, naming the owning item** (`excludes Y — owned by #Z`). Without this, a shared-gate failure is **ambiguous between "this leg regressed" and "a later leg's known failure is in my denominator"** — exactly the #491/#512 churn: leg #491 met its own contract (date-locale inference green) yet could not pass the shared eval-smoke gate because sf-audio/sf-1015 collapse on bare-artist behavior owned by the *later* leg #492; the run had to park #491, file #512, rescope the gate off the bare-artist fixture, and re-fold it in. Pinning each leg's scope at assess time makes the failure attributable and prevents that park/rescope cycle. This is the **gate-side analog** of the falsifiable-acceptance / assume-unverified-mechanism rule (#108) the Step 3 sanity check enforces: #108 pins what a leg *produces*; gate-scope pins what a leg is *measured against*. Example: *"Leg accountable for fixtures `ibiza-hi.es`, `barcelona.es` (deterministic year inference); excludes the bare-artist fixtures `sf-audio`/`sf-1015`, owned by #492 — their failure does not count against this leg."*
- **Emit a `gate_check:` predicate for every externally-gated item — never a prose-only gate.** When an item must wait on work **outside this plan** (another plan's leg, an unplanned upstream issue), the schema forbids a cross-plan `after:` ref, so the gate rides `notes:` as prose ("Do not start until #N lands"). Prose alone is unverifiable — it forces `/build` to *infer* gate-lift from issue-closed-state, the ELT #492 trap (*"#380 CLOSED → roster gate lifted"* was wrong because #380 closed data-capture while deferring product-wiring — `configs/artists.toml` still listed 3 of 40 artists — so the consumable didn't exist; **"issue closed" ≠ "dependency consumable exists."**). So **emit the prose gate AND a matching machine-checkable `gate_check:` predicate alongside it** — a command or file-check on the **consumable, not the tracker** (e.g. `gate_check: "configs/artists.toml lists >=40 artists"`, never "#380 is closed"). `/build` Step 3a runs the predicate at claim time instead of inferring lift from the issue's closed-state. An external gate in `notes:` with no `gate_check:` is a plan-schema **rule-11** validation smell — do not ship it. See `~/.claude/plan-schema.md` § Optional `gate_check:` field.
- **The Step 6 approval-poll ask routes through the `decision_sink_ask(...)` seam.** The orchestrator does not call `AskUserQuestion` directly for the poll offer; it calls the documented seam **`decision_sink_ask(question, options, severity)`** (defined canonically in `/build` § Operating principles — *question* = prompt text, *options* = offered choices with their defaults, *severity* = taxonomy class per [[Context/foundation - AskUserQuestion severity taxonomy]]). The seam has two wired backends, selected by the same rule as all other gates: operator-present → **modal `AskUserQuestion`** (byte-for-byte the same prompt and result as before); operator-absent + blocking-now → **async decision-issue backend (re-homed, not inherited — see Step 6)**: posts a comment on the plan's epic issue with the poll offer, the two options (`approve` / `skip`), the typed-reply grammar, and **the load-bearing marker line `plan-approval-poll: [[Plans/<vault-path>]]`** that `/build` Step 0a uses to identify and drain this issue at the next tick start. Applies the `decision` label, assigns the operator, and stops — the `ScheduleWakeup` poll is **not** armed on an operator-absent run (no session is live to execute it; the tick-start drain in `/build` Step 0a replaces it). The seam carries **only the ask** — the `ScheduleWakeup` poll arming (modal path only), the deadline-timestamp encoding, the `status` re-reads, and the `/build` invocation all stay **outside** the call, in their existing order on the modal path; the async path stops after the decision issue is posted and resumes via `/build` Step 0a at the next tick.
- **Always ship `status: draft`.** Never set `approved` from this command.
- **Honor [[Decisions/foundation - Branch naming convention]] for the `branch:` field.** See type derivation table below.

## Step 0 — Validate

Run in parallel:

1. Confirm `mcp__obsidian__*` tools are loaded. Stop with one-line error if not. (Document paths cited throughout this file — `Plans/`, `Priorities/<project>.md`, `Mistakes/`, `Decisions/`, `Patterns/` — are relative to **the knowledge store root**, resolved per `workflows/scripts/lib/knowledge_store.contract.md`; Travis's default: the Obsidian vault `~/dev/mind`. The agent-plane transport stays on Obsidian MCP tools — including `search_vault_smart` for fuzzy matching, used in the Context-bundling pass below — per that contract's Obsidian-mode note.)
2. `gh auth status` — must list the **`project`** scope (reading the epic's board sub-issues and labels needs it). If missing, stop with the `gh auth refresh -s project` hint.
3. Resolve the board/repo from `--board`/`--project`. **If neither was given, infer the board from the local repo** (matching `/triage` Step 0.3, foundation#547): set `BOARD_LIB` = the first of `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that exists, `source "$BOARD_LIB"`, then `repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); BOARD=""; for b in 3 4 5 6; do [ "$(board_repo "$b")" = "$repo" ] && BOARD="$b"; done`. If a match is found, print `inferred board $BOARD (repo $repo)` before any board read and continue; if **no** candidate matches (an unmapped repo), STOP with `/assess: cannot infer board — pass --board <N> (3=stageFind, 4=foundation, 5=ssmobile, 6=subsetwiki) or --project <name>, or run from a board-mapped repo`. Call the resolved board number `$BOARD` (the `## Re-triage signals` persistent route in Step 4 reads it). Confirm the epic exists: `gh issue view <N> -R <repo> --json number,title,state` — stop if it's missing or closed.
4. Confirm the plan-note schema `~/.claude/plan-schema.md` is reachable (deployed from foundation `claude/plan-schema.md` by `make install-claude`). If missing, surface "schema reference missing — run `make install-claude` in foundation" and stop.
5. Resolve `--project` (plan filename/tag): explicit flag, else derived from the board (3 → `stagefind`, 4 → `foundation`).

## Step 1 — Read the source (the epic + its sub-issues) — the only source-selection step

Everything after this step is source-agnostic. Read the epic and enumerate its members:

1. **Epic context.** `gh issue view <epic> -R <repo> --json title,body,number` — the epic body's group summary frames the plan's `## Summary`.
2. **Sub-issues.** `gh api repos/<owner>/<repo>/issues/<epic>/sub_issues` — each child is one **candidate item**. From each child's full issue object (or a per-child `gh issue view <n> --json title,body,labels`), prefill:
   - `gh_issue:` ← the child's **number** (so `/build` Step 2.5 creates nothing and Step 2.6 is a no-op — the issue and epic already exist). **Exception — a split member** (one sub-issue → multiple items, see the decomposition principle below): leave `gh_issue:` unset on the split-derived items and set `split_from: <child-number>` instead, so `/build` mints a fresh issue per item and the 1:1 invariant holds.
   - `repo:` ← if the child carries the **`kernel-candidate`** label (set by `/triage`'s Step 2.8 kernel-vs-overlay routing, per `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule), prefill `repo: <org>/temperloop` (the kernel repo per the board glossary's `K` row; `/build` surfaces a clear block if no local checkout of it exists yet, rather than silently building in this repo). Else leave `repo:` unset (defaults to the plan's home repo). **In-kernel-checkout no-op (temperloop#58):** when this checkout **IS the kernel repo itself** — `claude/CLAUDE.kernel.md` present **AND** `claude/CLAUDE.overlay.md` **absent** (the same detection `validate-live-drain.sh` uses) — the prefill is a no-op: `/triage` Step 4 stamps no `kernel-candidate` label in that case, so no child carries it and `repo:` correctly stays unset (the kernel repo *is* the home repo — routing `repo: <org>/temperloop` from within it would be a vacuous self-route). No extra guard is needed here beyond the absent label, but do not hand-add a `repo:` on a kernel-classified survivor in this case.
   - `kind: spike` ← if the child carries the **`spike`** label (else `kind: code`).
   - `needs_clarification: true` ← if the child carries the **`needs-clarification`** label (triage flagged it underspecified at source — Step 2 emits a clarifying-acceptance bullet and Step 4 routes it to `## Re-triage signals`). Else omit.
   - `title` ← the child's title (refine to an imperative PR title in Step 2 if needed).
   - candidate `scope` / `acceptance` / `source` ← from the child body. If the child body carries a `Triaged from: [[<vault-doc>#<heading>]]` back-link (triage wrote it for doc-sourced findings), carry that wikilink forward as the item's `source:`. Otherwise the item's `source:` is the sub-issue itself: `source: #<child-number>`.
3. Record `epic: <N>` to write into the plan frontmatter (Step 4) — this is the durable epic↔plan link.

**No sub-issues found** → branch on whether the epic body carries a **`## Contract`** section (foundation #526):

- **Contract present → epic-decomposition mode** (the pre-designed, intentionally-undecomposed epic). Do **not** stop. Parse the epic body's `## Contract` into the source for Step 2:
  - **`Produces`** bullets are the **seam list** — each becomes one candidate item (combine a tight cluster of bullets into one item only when they're one indivisible seam; the same combine/split judgment as the 1:1 principle). These items are **Contract-derived**, so per the epic-decomposition operating principle they carry **`gh_issue:` unset and `split_from:` unset** — `/build` mints a fresh sub-issue per item and links it under the existing epic.
  - **`Consumes`** frames cross-epic / cross-level deps — carry it into `## Sequencing notes` and any in-plan `after:`/`depends-on` edges (a `Consumes` of *another epic* is an external gate → `gate_check:` per the external-gate principle, not an in-plan edge).
  - **`Acceptance`** seeds each item's `acceptance:` — distribute the Contract's acceptance clauses to the items they bear on; where a clause spans items, give each its slice. A seam with no derivable falsifiable check gets the acceptance placeholder (don't fabricate).
  - **MUST record `epic: <N>` (the epic being assessed) in the plan frontmatter** — the existing epic *is* the parent; `/build` Step 2.6 adopts it and links the minted children, creating nothing. **This is load-bearing, not optional, in epic-decomposition mode:** `epic:` is the *only* signal that keeps `/build` Step 2.6 in **adopt-mode**. If it is omitted, Step 2.6's backstop arm (`build.md` "If the plan frontmatter has no `epic:`") fires and **creates a brand-new duplicate epic**, links the minted children under it, and leaves the real designed epic orphaned with zero children — so the data-driven 4d epic-close never converges on it. (For 1:1 epic mode `epic:` is equally required, but there Step 1 always sets it; here it is the one field the mode cannot skip.)
- **No Contract → genuinely undecomposed.** Surface "epic #N has no sub-issues and no `## Contract` to decompose — run `/triage` to populate it, or link members first" and stop. (This stop now fires *only* for the no-Contract case; a Contract-bearing epic is decomposed above.)

## Step 2 — Propose decomposition

For each sub-issue-derived candidate, draft the plan item.

**Required fields** (block the item if any can't be filled):

| Field | How to derive |
|---|---|
| `title` | Short imperative — what the PR will be titled. "Gemini runner: retry on 504" |
| `slug` | kebab-case, `[a-z0-9-]+`, max 40 chars, unique within plan. Mnemonic, not "item-3" |
| `scope` | One line, becomes PR description lead |
| `branch` | `<type>/<slug>` per [[Decisions/foundation - Branch naming convention]] — see type derivation below |
| `size` | **S:** single file, <~100 LOC, minimal test changes. **M:** multiple files, <~300 LOC, may add a test. **L:** significant refactor or multi-subsystem — flag for user to split before approval |
| `gh_issue` | the sub-issue number (prefilled in Step 1 — present in epic mode for **1:1 items**). **Leave unset for a split member's items** (set `split_from:` instead — see below); `/build` Step 2.5 mints a fresh issue per split item. **Also leave unset for a Contract-derived item** (epic-decomposition mode — and leave `split_from:` unset too; `/build` mints a fresh sub-issue and links it under the existing epic, closing nothing) |
| `source` | the carried-forward `[[<vault-doc>#<heading>]]` wikilink if the child had one, else `#<child-number>` (the sub-issue itself). **For a Contract-derived item** (epic-decomposition mode — no child sub-issue exists yet) set `source: #<epic-number>` (the source epic); `/build` validation rule 6 resolves a `#<n>` GitHub issue ref by existence, so it passes without a vault-path check |
| `acceptance` | 2-5 bullets of independently checkable conditions. Derive from the sub-issue's body / recommended fix. If none is given, write `- (no acceptance criteria derivable from source — fill in during review)` so the user knows to add them. **If the item carries `needs_clarification: true`** (Step 1), one bullet MUST be the clarifying-acceptance placeholder `- (needs-clarification: <the open question> — resolve at the approval gate before this item is worked)` so the ambiguity is visible and blocks a blind build (it also routes to `## Re-triage signals` in Step 4). **If this item is one of several sequential legs sharing one gate/corpus** (see the per-leg gate-scope operating principle), one bullet MUST state the leg's **gate scope** — the fixtures/cases it owns and the exclusions owned by a later leg, *naming the owning item* — so a shared-gate failure is attributable to this leg vs a later leg's known failure |

**Optional fields:**
- `repo` — `owner/repo`, only when the item's work lands outside the plan's home repo (prefilled from the `kernel-candidate` label in Step 1). Default absent = the plan's home repo. See the **seam-straddling check** below and `~/.claude/plan-schema.md` § Optional `repo:` field.
- `files` — only when the sub-issue names specific paths
- `kind` — `code` (default) or `spike` (prefilled from the `spike` label in Step 1)
- `model` — advisory worker-model tier for `/build` 3c, **stamped from size/kind** per `~/.claude/plan-schema.md` § Optional `model:` field: `size: S` or `M` **and** `kind: code` → stamp `model: sonnet`; `kind: spike` or `size: L` → leave absent (inherit the session model). Tier by verification, not difficulty — an S/M code item's output is checked by mechanical gates (CI, the 3e.5 acceptance gate, its acceptance bullets), so a cheaper worker is safe; a spike's verdict or an L item's breadth is judgment nothing downstream checks, so it inherits the top tier
- `depends-on` — **merge-safety** edge only (shared schema / identical lines); default empty
- `after` — **logical-ordering** edge (sequences level, no merge assertion); for spike→fix / verdict-gated order; default empty
- `split_from` — `#N`, the coarse sub-issue this item was split out of. Set **only** on split-derived items (and only with `gh_issue:` left unset); it tells `/build` Step 2.5 to mint a fresh per-item issue and Step 2.6 to close the coarse #N. Mutually exclusive with `gh_issue:`. Default empty (most items are 1:1 and carry `gh_issue:` instead). **Do NOT set this on a Contract-derived item** (epic-decomposition mode): its parent is the **epic**, recorded in `epic:` frontmatter, which must stay open — `split_from:` would make `/build` *close* it. A Contract-derived item leaves **both** `gh_issue:` and `split_from:` unset
- `gate_check` — **REQUIRED when the item carries an external/cross-plan gate in `notes:`** (the "don't start until #N lands" prose gate); a machine-checkable predicate (command / file-check) on the **consumable, not the tracker** that `/build` Step 3a evaluates instead of inferring gate-lift from issue-closed-state. Default empty (only items with an external gate carry it); see the emit-`gate_check:` operating principle above
- `notes` — nuance, prior approaches, gotchas
- `review` — override only when default routing would be wrong

### Branch type derivation

Per [[Decisions/foundation - Branch naming convention]]:

| Finding nature | Type |
|---|---|
| Behavior is wrong; fix restores intended behavior | `fix` |
| New capability requested | `feat` |
| Code is correct but messy / duplicated / hard to follow | `refactor` |
| Build / deps / config / tooling | `chore` |
| Docs only | `docs` |
| Test gap | `test` |

If a member straddles types (e.g., a bug fix that also adds a missing test), pick the primary intent. Don't invent new types — extend the convention via a Decision-note edit if a project needs one.

### Context-bundling pass

For each item, search the vault for related context:
- `mcp__obsidian__search_vault_simple` with the slug words across `Mistakes/`, `Decisions/`, `Patterns/`.
- For each strong hit, add a `[[wikilink]]` to the item's `notes:` field with one line on relevance.

Default to silence. Only add links clearly on-topic — padded notes hurt more than they help.

### Seam-straddling check (only when this checkout carries `claude/CLAUDE.kernel.md`)

For each item's `files:` list, classify every path via `workflows/scripts/kernel/lib.sh`'s `kernel_lib_classify <path>` (source it, `kernel_lib_load_manifest workflows/scripts/kernel/kernel-manifest.txt`, then classify each file — the same longest-match logic `check-kernel-manifest.sh` uses). An item is **seam-straddling** when its files classify to **both** `kernel` and `overlay` (a `split` classification doesn't itself straddle — it's a file already known to be a content mix, tracked by its own named follow-up). A seam-straddling item cannot honestly carry a single `repo:` — its kernel-classified files belong upstream, its overlay-classified files stay here. Do not silently pick one; flag it as a **re-triage signal** (Step 4) recommending a split into a kernel-repo item and an overlay item, each with its own `repo:` (or absent for the overlay half). Skip this check entirely on a checkout with no `claude/CLAUDE.kernel.md`.

## Step 3 — Sanity-check pass

**Load the project's principles first.** Read `Priorities/<project>.md` (via `mcp__obsidian-builtin__vault_read`); if it has a `## Principles` section, the wikilinked notes are the project's standing engineering bar — pass them to **every** review subagent below as **additional evaluation criteria** ("also judge each item against these principles; flag any that violate one"). **If the file is absent, the read fails, or it has no `## Principles` section** (the three collapse to one outcome — never assume a read error means "section absent" without naming it), proceed with a generic review and note `no declared principles — generic review` in the Step 5 summary (graceful skip, same shape as the capability-probe predicate). The principle notes are the canonical source; each carries an `## Enforced by` footer naming the CI gate + agent that operationalizes it.

Spawn `Agent { subagent_type: "requirements-auditor" }` with the draft item list (titles, slugs, scopes, files, acceptance, `depends-on`, `after`, `kind`). Prompt it to surface:

- Items hiding a dependency not captured in `depends-on`/`after`.
- **Edge mis-classification:** a merge edge mislabeled `after:` (two conflicting PRs would land in one level), or a purely-logical edge using `depends-on:` (over-serializes).
- Items whose `size` is wrong (L items needing splits, or trivially-tiny items worth folding).
- Items with weak / circular / unverifiable acceptance criteria — **including criteria that assume an unverified mechanism** (e.g. "the scorer aligns on `_eval_id`" when nothing yet produces `_eval_id`). Flag these as likely-to-move: either pin the mechanism inside the same item's scope, or split it out as a precursor (per the seam-spike principle), so the criterion can't be silently reinterpreted mid-build.
- **Sequential legs sharing one gate but no per-leg gate scope** (per the per-leg gate-scope principle). If two or more items are sequential legs measured by one shared gate/corpus and any leg's `acceptance:` doesn't name the fixtures/cases it owns plus the exclusions owned by a later leg, flag it — the leg's gate failure would be ambiguous (its own regression vs a later leg's known failure in its denominator, the #491/#512 trap). Fix by adding the scope bullet at assess time.
- **Re-triage candidates** (route, don't act): two members that look like the *same* change, a member that looks invalid / out of scope, or work the epic seems to be missing. These feed the `## Re-triage signals` block in Step 4 — they are **not** acted on here (triage owns logical judgment).

The subagent is read-only and returns advisory feedback. Apply technical suggestions where clearly right; surface contested ones to the user via `AskUserQuestion` before committing. Logical suggestions become re-triage signals, never silent regroupings.

If items touch architectural boundaries (new module, import-graph changes, public-API shifts), also spawn `Agent { subagent_type: "architecture-reviewer" }` with the same list. Skip otherwise.

**Graceful skip:** review-agent availability follows the canonical predicate in [[Decisions/foundation - Project capability probes]] (a review subagent is available iff the project declares it in `CLAUDE.md § Subagents` or `.claude/agents/`; absent ⇒ skip the review pass). If either subagent isn't available, note "review agents unavailable — review pass skipped" in the Step 5 summary and continue.

## Step 3.5 — Decomposition preview (before writing)

Before writing the note, print the decomposition shape so the user can catch a bad structure before reviewing prose:
- the **level DAG** (level *k* → item slugs), each cross-item edge tagged `depends-on` (merge) or `after` (logical);
- items flagged: `kind: spike` (verdict-only, no PR) and `size: L` (split candidate);
- the implied downstream shape: *N levels; a merge gate per level that has ≥1 `code` item (spike-only levels need none); level 0 has K parallelizable items*;
- **if epic-decomposition mode** (Contract-derived, no existing sub-issues): a one-line `epic-decomposition: N items decomposed from epic #<N>'s Contract → /build will mint N fresh sub-issues under the epic (none exist on the board yet)` so the reviewer knows the board has no sub-issues until `/build` runs;
- any **re-triage signals** queued for the plan.

This is the authoring-time mirror of `build --dry-run`. It is a print, not a gate — continue to Step 4.

## Step 4 — Write the plan note

Filename: `Plans/<YYYY-MM-DD> <project> - <short title>.md`, where `<YYYY-MM-DD>` is the plan's creation date (today — the same value as frontmatter `date:`). **The date-first prefix is required on every plan** — it matches the vault's `Sweeps/` / `Issues/` / `Sessions/` naming and keeps `Plans/` chronologically sortable. The title is 3-7 words describing scope (use the epic's theme); it must **not** also lead with a date, since the prefix already carries it:
- "2026-05-24 stagefind - tier-2 sweep follow-up"
- "2026-05-24 acme - auth middleware rewrite"

Write via `mcp__obsidian__create_vault_file` using exactly the `~/.claude/plan-schema.md` structure:

- **Frontmatter:** `tags: [plan, project/<name>]`, today's date, `source_kind: claude-stamped`, `source_session: <session-id>`, `last_verified: <today>`, **`epic: <N>`** (the source epic — the durable plan↔epic link; makes `/build` Step 2.6 a no-op), `sources:` listing the epic (`#<N>`), `status: draft`.
- **`## Problem`** — 2-4 sentences naming the problem this plan solves and **why it's happening now**: the pain or risk in user-facing terms, **not** the solution. This is the first thing the reviewer reads at the approval gate.
- **`## Summary`** — the work as **grouped bullets**, not a paragraph: each **parent bullet names one part of the problem** being addressed; each **sub-bullet is one item's change**, prefixed with its **build level** (`**L0**` first → `**Ln**` last; items in the same level ship together). Group parents by *theme* (which part of the problem), not by level; a light `(#<issue>)` ref per sub-bullet is fine — **no slugs**. End with the one-line legend `Build order: L0 first → Ln last; items in the same level ship together.` See `~/.claude/plan-schema.md` § Body structure for the exact shape. (Spike/verdict items get their level tag like any other; don't invent per-item "Leg" labels — the level *is* the sequence.)
- **`## Sequencing notes`** — soft order guidance (parallel-safe items, cheap-wins-first ordering, anything not captured by hard `depends-on`).
- **`## Re-triage signals`** — advisory **logical** findings surfaced during seam analysis, to be read at the approval gate. **Routed, not acted on** (authority is one-directional). Two routes:
  - *Ephemeral* ("decide before approving THIS plan" — e.g. two members that may be the same change, a member that may be mis-scoped): list here as a bullet with the suggested logical action, so the user resolves it when promoting `draft → approved`.
  - *Persistent* ("true regardless of this plan's fate" — a member that is genuinely invalid, or new work the epic is missing): in addition to listing here, route it durably so triage re-intakes it next pass. **`Status` is the only re-queue signal** — `/triage` sweeps **`Backlog` only**, so a comment or label alone does *not* re-enter the funnel (it records intent but never re-queues; see #44). By route:
    - *An existing epic member* (invalid / mis-scoped / a regroup candidate): flip it **`Ready → Backlog`** so the next `/triage` re-intakes it, and add a one-line comment saying why. Resolve the board adapter the way `/triage` Step 0.3–0.4 does — set `BOARD_LIB` (first of `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that exists), then `source "$BOARD_LIB"; board_resolve "$BOARD"` — and run `board_set_status "$(board_item_id <n>)" "$BOARD_OPT_BACKLOG"`, then `gh issue comment <n> -R "$(board_repo "$BOARD")" --body "Flagged for re-triage by \`/assess --epic <N>\`: <reason>"`.
    - *Genuinely new work the epic is missing*: `capture.sh` — it lands a fresh issue in `Backlog`, which triage sees next pass.
    Note in the bullet which durable route was taken.
  - *Clarifying questions* (a member carried `needs_clarification: true` from triage — its `acceptance` holds the `(needs-clarification: …)` placeholder): list the open question here so the user **answers it at the approval gate**. On answer, fold it into the item's `scope`/`acceptance` (replacing the placeholder) before promoting `draft → approved`, then clear the source label (`gh issue edit <n> -R "$(board_repo "$BOARD")" --remove-label needs-clarification`) — the `needs-clarification` label is the open-question gate, so clearing it is what makes `/build` (and `/next`) treat the member as workable again. There is no status to flip back: a `/sweep`-parked member stays in `Ready` throughout (the open question parks it via the label, not a status bucket — the `Blocked` Status option was retired in #435). This is the epic-path counterpart to `/sweep` Phase 1 — the *answering* triage deferred to its consumer (the logical/technical split: triage flags, the consumer answers).
  - If there are none, write `- none` (don't omit the section — its presence tells the reviewer it was considered).
- **`## Items`** — the decomposed list per schema (each item carries its prefilled `gh_issue:`).

**Filename collision handling:** if a plan note for this epic already exists (same `epic:` frontmatter), surface to user and ask: **overwrite**, **suffix with version (`v2`, `v3`)**, or **merge into the existing note**. Don't silently overwrite.

## Step 5 — Summarize for review

Emit the **problem-first** review block below — never a prose paragraph or a stat dump. The reviewer should see *why* the plan exists and *what it does*, grouped by problem, before any housekeeping. Four parts: a **header** line (what was written + status), the **`## Problem`** definition, the **`## Plan`** grouped bullets, and a compact **`NEEDS ATTENTION`** block of only the actionable flags.

Rules for filling it:
- **`## Problem` and `## Plan` are the same content written into the note** (Step 4) — reproduce them verbatim so the reviewer reads the readable form, not the raw note. `## Plan` is the note's `## Summary` (parents = parts of the problem, sub-bullets = changes tagged by level).
- **`NEEDS ATTENTION` lists only rows with a non-zero count.** Drop any flag that's zero. If all are zero, replace the whole block with the single line `✓ nothing flagged — clean plan`.
- Reference flagged items by **issue # or short title** — never slug.
- **If epic-decomposition mode was used** (Contract-derived items, no existing sub-issues), add the `epic-decomposition:` notice line under the header so the reviewer knows `/build` will mint the sub-issues; omit the line otherwise.

```
/assess --epic <N>  →  [[Plans/<date> <project> - <title>]]   (status: draft)
[epic-decomposition: N items from epic #<N>'s Contract → /build mints N sub-issues under the epic]   ← only in epic-decomposition mode

## Problem
<the 2-4 sentence problem definition from the note>

## Plan
- **<part of the problem>**
  - **L0** — <change> (#<issue>)
  - **L1** — <change> (#<issue>)
- **<another part of the problem>**
  - **L2** — <change> (#<issue>)

Build order: L0 first → Ln last; items in the same level ship together.

NEEDS ATTENTION
  !  split (L-sized) ....... K   <#issues / titles>
  !  missing acceptance .... K   <#issues / titles>
  ↩  re-triage signals ..... K   ephemeral:x · re-queued:y — resolve at approval
```

Then close with the next two actions (a short numbered list, not prose):
1. Review `[[Plans/<date> <project> - <title>]]`; fix slugs / acceptance / sizing, and **resolve every `NEEDS ATTENTION` row** (re-run `/triage` if a regroup is warranted).
2. Flip frontmatter `status: draft → approved`, then run `/build Plans/<date> <project> - <title>` — or let me arm the approval poll (Step 6) and I'll start it the moment you flip the status.

## Step 6 — Offer the approval poll (optional walk-away handoff)

Skip this step if `--no-poll` was passed. The point: the user reviews, edits, and approves the plan **on their own time** by flipping one frontmatter field, and the session picks it up automatically — no need to come back and launch `/build` by hand. The approval signal **is** the existing `status` gate (`draft → approved`); this step just makes the session wait on it. Ask once via `decision_sink_ask(<the poll offer>, [arm the approval poll, "No — I'll run it myself" (default)], blocking-now)` — operator-present → modal `AskUserQuestion`, the identical one-shot prompt as before; operator-absent → async decision-issue backend (posts the poll offer on the plan's epic issue with both options, applies `decision` label, assigns operator, stops — no `ScheduleWakeup` is armed since no session is live, per the re-homed path below). The poll arming and `/build` launch happen **after** the ask returns (modal path only), outside the seam:

- **Arm the approval poll** — I watch `status:` and auto-start `/build` the moment you approve.
- **No — I'll run it myself** (default) — stop after the Step 5 actions; the user launches `/build` when ready.

If declined, stop. If armed, the session runs one of two paths based on operator-presence:

**Operator-present path — `ScheduleWakeup` poll (unchanged):**

Run a self-paced poll on the plan note's frontmatter `status`:

- **Mechanism:** `ScheduleWakeup` (dynamic-mode self-pacing). On each wake, re-read **only** the plan note's frontmatter via `mcp__obsidian__get_vault_file` and branch on `status`. The poll is one in-flight thread, not board work.
- **Cadence:** first wake at **~270s** (≈4.5 min — fast enough that a quick review isn't stalled, and inside the prompt-cache window so the first check is cheap), then **1200s** (20 min) per wake thereafter. Do **not** land the first wake on exactly 300s — that is a cache miss for no latency benefit.
- **Budget:** give up **2 hours** after arming. Encode the **absolute deadline timestamp** in the `ScheduleWakeup` `prompt` itself, not just working memory — context may be summarized across a 2h span and the deadline must survive it.
- **Branch table:**

  | `status` reads | Action |
  |---|---|
  | `draft`, before deadline | reschedule the next wake; stay quiet |
  | `draft`, deadline passed | stop; one-line report — "approval poll expired after 2h, plan still draft; launch `/build` manually when ready" |
  | `approved` | invoke `/build <plan> --unattended` (see build "unattended start"). Poll ends. |
  | `abandoned` | stop; explicit reject — "plan marked abandoned, not executing" |
  | `executing` / `done` | another session already claimed it — stop and note it |

- **Honor in-doc scoping.** Before approving, the user may pre-mark items `[-]` to skip them; `--unattended` `/build` respects those, so no interactive subset prompt is needed.
- **The poll only removes *start* friction.** `/build`'s human checkpoints stay intact: the run still parks at each per-level **merge gate** and on any **blocked / design-fork / failed** item, issuing an `AskUserQuestion` the user answers on return. Unattended means unattended *start*, not unattended *merge*. See [[Decisions/foundation - Approval-poll handoff for batch workflow]].

**Operator-absent path — epic-carried plan-approval decision-issue, drained at tick start (re-homed, not inherited):**

The `ScheduleWakeup` poll cannot span cron-tick gaps: no session is live between ticks to execute the wakeup. On an operator-absent run the async backend already posts the poll offer on the plan's epic issue — **what replaces the poll is the drain step in `/build` Step 0a**, which runs at the start of each tick and processes answered plan-approval decision issues. The handoff is as follows:

1. **The async backend posts a comment on the plan's epic issue** with:
   - The poll offer text (the same two options: `approve` / `skip`).
   - The typed-reply grammar per `decision-queue-contract.md` § 3.
   - **A machine-readable marker line — required:** `plan-approval-poll: [[Plans/<vault-path>]]` (e.g. `plan-approval-poll: [[Plans/2026-06-20 foundation - my plan]]`). This is the filter `/build` Step 0a uses to distinguish plan-approval issues from other decision issues in the queue; its format is load-bearing and must not change.
2. The `decision` label is applied and the issue is assigned to the operator (per the contract's assignee-baton semantics).
3. The session stops. No `ScheduleWakeup` is armed.
4. **At the next tick start,** `/build` Step 0a scans for answered (unassigned, `decision`-labelled) issues matching the marker, parses the operator's reply, and either invokes `/build <plan> --unattended` (approved) or records the decline and skips (declined). See `/build` Step 0a for the full drain procedure.

This is an **epic-carried, cross-tick handoff** — the plan-approval answer lives on the GH issue and is drained by the next tick, not by a ScheduleWakeup that expires between ticks. The operator-present `ScheduleWakeup` path above is unchanged.

## Failure modes

- **Epic not found / closed.** Surface and stop at Step 0 — don't plan a phantom epic.
- **Epic has no sub-issues.** Branch on the epic body (foundation #526): **a `## Contract` is present** → enter **epic-decomposition mode** (Step 1) and decompose the Contract's `Produces` into items (`gh_issue:`/`split_from:` unset — `/build` mints sub-issues under the existing epic); **no Contract** → surface "no sub-issues and no `## Contract` to decompose — run `/triage` to populate it" and stop. Don't manufacture items from a vague Contract — a seam with no falsifiable check gets the acceptance placeholder, not invented criteria.
- **`project` scope missing.** Stop at Step 0 with the `gh auth refresh -s project` hint (reading sub-issues + labels needs it).
- **Acceptance criteria un-derivable for an item.** Emit the literal placeholder rather than fabricating. Count in summary.
- **A member looks like a dupe / mis-scoped / invalid.** Do **not** cull or merge it here — surface it as a `## Re-triage signals` bullet (if persistent, flip it `Ready → Backlog` so triage re-intakes it, or `capture.sh` for new work — a comment/label alone won't re-queue; see #44). Triage owns that call.
- **Sanity-check subagent disagrees with the draft.** Surface — never silently override.
- **Subagent unavailable.** Note in summary, continue; user can do the review pass manually.
- **All items flagged L.** Surface as a decomposition failure ("epic too coarse to decompose at this level — the sub-issues need splitting, likely back in `/triage`") rather than writing a plan of un-shippable chunks.
