---
description: Facilitate a structured design conversation for INVENTED work (an idea born in conversation, not a discovered defect) against the coverage template in `claude/design-schema.md`, then ratify and materialize it into the pipeline as a board epic with a well-formed `## Contract`, draft ADRs for its architectural calls, a Decisions note, and a hand-off to `/assess --epic N`. Operator-present only — no unattended arm. Ships the full intake → coverage walk → review pass → ratify → materialize flow; Step 3's tier decision, adversarial panel, and capability probes landed with `design-review-machinery` (temperloop#217); ADR emission at materialize landed with `design-adr-emission` (temperloop#219). Executing customer-persona agents shipped with `design-persona-agents` (temperloop#221).
argument-hint: "[<problem-statement> | <pointer-note>] [--board <N> | --project <name>]"
---

You are running the **workshop** command (formerly `/design`; renamed — temperloop#354 — to avoid colliding with Claude Code's builtin `/design`). Goal: take an idea that was *invented* in
conversation — not discovered as a Backlog defect — and walk it against a fixed
coverage template until every dimension has an explicit disposition, then ratify
and materialize it into the same pipeline `/triage` feeds. This is the pipeline's
**second front door**, for invented rather than discovered work
(`Decisions/temperloop - design command as front door for invented work`):

```
capture.sh (bugs) ┐
sweeps / audits   ┼─► /triage      cull → collapse → group → epic + sub-issues
loose Backlog     ┘
                                                                    │
a design conversation ──► /workshop   intake → coverage walk → review pass → ratify → materialize
                                                                    │
                                                                    ▼
                                              board epic (## Contract, design-brief: marker)
                                                                    │
                                                                    └─► /assess --epic N   (unchanged)
                                                                            └─► /build
```

`/triage` explicitly disclaims a pre-designed epic (its own spec: "no path to
decompose an already-existing, fully-specified epic"); `/workshop` is that epic's
point of origin, not a patch to triage. Both front doors converge on the same
`/assess --epic N` → `/build` pipeline — nothing downstream of materialization
changes.

## Scope — this item vs. `design-persona-agents` (#221)

This file ships the full flow: intake → coverage walk → **review pass** →
ratify → materialize. `design-command-core` shipped intake/walk/ratify/
materialize; `design-review-machinery` (temperloop#217) filled Step 3 below
with the tier decision, the adversarial lens panel, capability probes for
reviewer agents, and the findings-fold-back step — closing the review-tier
gap on top of the K94/K131 intake fix `design-command-core` already closed.
`design-adr-emission` (temperloop#219) added Step 5c below — draft ADR
emission for the ratified brief's architectural calls, conforming to
`docs/adr/0000-adr-process.md` — a different section of Step 5, not Step 3,
so it needed no Step 3 change.

One thing Step 3 below deliberately did **not** implement itself, tracked
in the same plan (`Plans/2026-07-08 temperloop - design command front
door.md`): the **executing** customer-persona agents themselves (Step 3
specifies *when* an executed first-run/uninstall run is mandatory and how
it degrades when no such agent is declared; the agents that actually run
one are `design-persona-agents`, temperloop#221 — closed 2026-07-11,
shipping `claude/agents/hobbyist-persona.md`, `consultant-persona.md`, and
`team-member-persona.md`). As anticipated, #221 landed without touching
Step 3 below — Steps 0–2 and 4–6 needed no change either for #217 or #219.

## Inputs

- `$1` (optional) — a one-line problem statement, or a vault pointer (e.g.
  `Context/…`, `Issues/…`) to seed intake. If omitted, the orchestrator asks
  the operator to state the problem live at Step 1 — there is no non-interactive
  path into this command.
- `--board <N>` / `--project <name>` (optional) — which board/repo the
  materialized epic should land on. If omitted, inferred from the local repo
  the same way `/triage` Step 0.3 / `/assess` Step 0.3 do (bounded to the repo
  you're standing in). **Unlike those commands, an unresolved board is not
  fatal here** — see the minimum-viable-output principle below.

## Operating principles

- **Operator-present only — no unattended arm.** `/workshop` is modal by <!-- cite: W.1 class:rubber-stamped-coverage-walk -->
  construction: there is no `--unattended` flag, no `ScheduleWakeup` poll, and
  no async decision-issue backend. Every ask in this command (Step 4's ratify
  confirmation; any disambiguating question during the walk) is a direct,
  interactive `AskUserQuestion` — never routed through `decision_sink_ask(...)`,
  because that seam's whole purpose is choosing between a live operator and an
  absent one, and there is never an absent-operator case to choose here. A
  design routine cannot run against an absent operator; that is a deliberate
  property of this command, not a gap to fill later.
- **Minimum-viable-output rule.** Whatever else is unavailable — no `gh` auth, <!-- cite: W.2 guard:docs/principles.md -->
  no repo, no registered board, no reviewer agents declared (Step 3) — the
  coverage walk still produces a **ratified brief note in the
  knowledge store**. That is the floor this command guarantees. Every
  dependency below degrades legibly (a stated `skipped — <reason>` line, never
  a silent no-op) rather than blocking the walk itself. See Step 3's and
  Step 5's degradation paths.
- **Idempotent materialization.** Epic creation is **probe-before-create** on <!-- cite: W.3 class:duplicate-epics-on-rerun -->
  the `design-brief:` marker line (Step 5b) — a re-run of `/workshop` against an
  already-ratified brief (or a re-run of just Step 5 after a partial failure)
  **adopts** the existing epic rather than duplicating it, exactly like
  `/triage`'s epic creation.
- **The dimension list belongs to `claude/design-schema.md`, not to this <!-- cite: W.4 class:driftable-dimension-list-copy -->
  file.** This command walks whatever that file currently defines — the
  kernel's 16 dimensions plus any overlay-added ones (letter-suffixed, e.g.
  `16a`, per that file's § Overlay extensibility — add-only). Never hand-add
  or hand-drop a dimension here; a dimension-list change is a `design-schema.md`
  edit (kernel-repo, upstream-first per `claude/CLAUDE.kernel.md` § Kernel vs
  overlay routing rule).
- **No silent skips.** Every dimension gets exactly one of the three
  dispositions defined in `claude/design-schema.md` § Disposition grammar
  (quoted verbatim in Step 2 below) — never left blank, never inferred.
- **Kernel-only checkout works end to end.** This checkout (temperloop) has a
  plain-files knowledge store and an issues-only board backend (board 7, no
  Projects-v2 `Status` field) — every step below is written to work on that
  substrate with no overlay dependency, per the ratified design brief's
  first-run-experience dimension (§ 12).

## Step 0 — Validate

Run in parallel:

1. **Knowledge store reachable.** The brief lives at `Designs/<short
   title>.md` in the knowledge store, resolved per
   `workflows/scripts/lib/knowledge_store.contract.md`. On an Obsidian-backed
   checkout, confirm `mcp__obsidian-builtin__*` tools are loaded (the
   agent-plane transport for that mode); on a plain-files checkout, confirm
   `KNOWLEDGE_STORE_ROOT` resolves (default per the contract). Stop with a
   one-line error if neither resolves — there is no brief without this.
2. **`claude/design-schema.md` reachable.** Confirm the file exists in this
   checkout (deployed to `~/.claude/design-schema.md` by `make install-claude`
   alongside `plan-schema.md`). If missing, stop: "design-schema missing —
   run `make install-claude` from the foundation checkout, or copy
   `claude/design-schema.md` to `~/.claude/design-schema.md` directly on a
   standalone kernel checkout (this repo's Makefile deliberately carries no
   `install-claude` target)."
3. **`gh` + repo (best-effort — needed for materialize, not for the walk).**
   `gh auth status`; if it fails, or no repo resolves at all (`gh repo view`
   also fails), note the gap and continue — Step 5 degrades materialize to
   brief-only rather than blocking Steps 1–4.
4. **Board adapter probe (best-effort — same capability-probe predicate as
   `/triage`/`/assess`/`/build` Step 0).** Set `BOARD_LIB` = the first of
   `scripts/lib/board.sh` or `workflows/scripts/board/lib/board.sh` that
   exists; if found, `source "$BOARD_LIB"` and resolve the board the same way
   `/triage` Step 0.3 does (`--board`/`--project`, else infer from the local
   repo via `board_repo` reverse-lookup over the registered set). No adapter,
   or no registered board for this repo, is **not fatal** — it only means
   Step 5b's epic lands as a plain `gh issue create` with no board mirroring.
5. **Reviewer-agent capability probing happens at Step 3, not here.** No
   probe result changes Steps 0–2's behavior, so it's deferred to the point
   of use — Step 3 probes `architecture-reviewer`, `requirements-auditor`,
   a red-team lens, and any persona agent right before it would spawn each,
   per the canonical predicate (Step 3.3).

If check 1 or 2 fails, stop. Checks 3–4 are best-effort and never stop the
run — they only shape Step 5's degradation path; check 5 shapes Step 3's.

## Step 1 — Intake

Establish problem/outcome, the stranger test, and the kernel/overlay routing
call **before** anything else — they gate every downstream dimension, so
getting them right first means the rest of the walk isn't re-litigating a
foundation that later shifts underneath it.

1. **Source the problem statement.** If `$1` was given, read it (a one-line
   statement, or the pointer note it names). Otherwise ask the operator
   directly, live: what problem is this, and for whom?
2. **Dimension 1 — Problem & outcome (stranger standpoint).** State the
   problem and the customer-visible outcome from a **stranger's** point of
   view — never the implementation's. This is the exact content
   `claude/design-schema.md`'s dimension 1 asks for; capture it now so Step 2
   can simply confirm/refine it rather than starting cold.
3. **Stranger test → kernel/overlay routing.** Apply the stranger test from
   `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule: would a
   stranger's kernel-only install need this for the kernel machinery (board
   adapter, build/sweep pipeline, install/doctor, branch/PR policy) to work
   correctly? The answer feeds **dimension 3** (Alignment / routing)
   directly — record the routing call and its rationale now.

4. **Probe-before-create the brief note** — the brief-side mirror of Step
   5b.3's epic probe, so a re-run (including one crashed between ratify and
   materialize) never clobbers an existing brief, **and so a killed or
   ratified idea short-circuits here — before the premise gate (item 5) could
   re-litigate it**. This probe therefore runs **ahead of** the premise gate:
   create-or-adopt the note first, walk the gate second, so the gate's
   dimension-0 write and any drop action always target a note already on disk.
   Check whether `Designs/<short title>.md` already exists in the knowledge
   store; if it does, branch on its frontmatter `status`: <!-- cite: W.5 incident:K#509 -->
   - **`draft`** → adopt it: skip creation and **resume the walk at Step 2**
     against the existing note (its already-dispositioned dimensions stand;
     the walk covers the rest). The premise gate already ran on the pass that
     first created this draft, so it is **not** re-run on a plain adopt.
   - **`ratified`** → **stop.** A ratified brief is immutable
     (`claude/design-schema.md` § Frontmatter); never edit it in place. If
     the design has genuinely changed, author a **new** brief under a new
     title that supersedes it via `[[wikilink]]`; if it hasn't, the right
     move is Step 5 (materialize) against the ratified brief, not a new
     walk.
   - **`dropped`** → **stop.** A `dropped` brief is a **killed idea** —
     Step 1.3b's drop action flipped it, and its dimension 0 carries the
     kill rationale. **Never take the silent `draft`-adopt path here**:
     reopening a killed idea requires an **explicit operator confirmation**
     — offer an `AskUserQuestion` (reopen this dropped brief, or leave it
     killed). Absent an explicit "reopen", **stop**, so a later run on the
     same title never silently un-kills an idea the operator already rejected.
     Only on an explicit "reopen" does the walk resume: flip `status:
     dropped → draft` **via a full-file rewrite** (`vault_write`, or the
     plain-files `ks_write` equivalent) and bump `last_verified` to today —
     **never** a `vault_patch` frontmatter-scalar `replace`, which the vault
     safe-targeting contract (and Step 4.4) documents as **silently dropping
     the field and returning OK**; a silent no-op there would leave the brief
     `status: dropped` while the walk believed it reopened. Trust the flip
     only when written by that full-file rewrite (or confirm it with a
     read-back). Then resume at Step 2.

   Only when no note exists: **create it**, `status: draft`, per
   `claude/design-schema.md`'s frontmatter shape (`tags`, `date`,
   `status: draft`, `source_kind: claude-stamped`, `source_session`,
   `source_model`, `last_verified`), with **dimension 0's `## 0. Premise &
   null hypothesis` section present as the landing place the premise gate
   (item 5) fills** — created empty/placeholder here, populated by the gate's
   part (ii) — and dimensions 1 and 3 pre-filled from this step's answers
   (disposition `filled` on both, assuming the answers are real — a stranger
   test that can't yet be answered gets `deferred → …` like any other
   dimension, never a placeholder masquerading as an answer). Then **continue
   to the premise gate (item 5)**: note-creation is a precondition of the
   gate, so on a brand-new design's first pass the gate's dimension-0 write
   and its drop action both act on the note just created here — a `drop`
   therefore persists a durable `status: dropped` kill record even on that
   first pass, which is the whole point of creating the note first.
5. **Step 1.3b — Premise gate (null-hypothesis checkpoint).** Runs **after** <!-- cite: W.6 incident:K#509 -->
   the brief note exists (item 4's probe-before-create) — so its dimension-0
   write and its drop action always target a note already on disk, and a
   killed or ratified idea has already short-circuited at item 4 before this
   gate could re-litigate it. (Numbered `1.3b` for its stable
   cross-reference name — it is the null-hypothesis checkpoint that
   conceptually belongs with the Step 1.3 routing call — but it **executes
   here**, as the fifth intake action, once the note exists.) Compose and
   answer the case *against* this design existing at all — the content of
   **dimension 0** (Premise & null hypothesis) in `claude/design-schema.md`
   § Kernel dimension list, the schema's one **`filled`-only** dimension
   (`n/a`/`deferred` are invalid for it). This gate fires once per intake
   pass. Three parts, in order:

   - **(i) Compose the case *against*.** From the null hypothesis "this
     design should not exist", state:
     - the **do-nothing cost** — what actually breaks if this is never built;
     - the **strongest subtraction alternative** — the smallest existing
       surface (a rule, a gate, a doc, a habit) that could absorb the need
       with no new mechanism;
     - **existing-surface coverage** — which current mechanism already covers
       part or all of this.

     Argue each point **citing `docs/principles.md` by principle name** —
     most directly the **stranger test** (principle 13: would a stranger's
     kernel-only install actually need this?), **subtraction over mechanism**
     (principle 8: fit or remove an existing mechanism before adding one), and
     **minimum-viable-output** (principle 14). A case-against that names no
     principle is not composed — cite the named principle each point rests on.
     This is a genuine adversarial pass, not a formality: compose the
     strongest case you honestly can, so the operator answers a real
     challenge rather than a rubber stamp.

   - **(ii) Elicit and record the operator's justification into dimension
     0.** Put the composed case-against to the operator; elicit their
     justification for proceeding anyway (or their agreement to kill it).
     Record that justification — and the case-against it answers — into the
     brief's **`## 0. Premise & null hypothesis`** section (the landing place
     item 4 created) at disposition `filled`. **Compose the case-against and
     its justification fresh for THIS brief every time** — never reuse, copy,
     or suggest a premise carried over from a prior brief; a recycled
     justification defeats the gate, whose whole point is that this specific
     idea earned its own place. On the **proceed** path this dimension-0 body
     write uses the same backend write primitive Step 2.6 defines (a
     `vault_patch`/append on an Obsidian store, a full-file `ks_write` on a
     plain-files store); on the **drop** path it is folded into that path's
     single full-file rewrite (below), which also flips the frontmatter.

   - **(iii) Offer the decision — `AskUserQuestion`.** Present it as
     `claude/message-schema.md`'s **Decision presentation** template requires,
     under that template's plain-language rule — the decision in plain terms,
     the proposed answer, the reasoning, alternatives considered and why they
     lost, and what accepting constrains downstream (parts (i) and (ii) above
     supply the case-against and the elicited justification those slots draw
     on). **Apply it by reference; never restate its parts here** — it owns
     their shape, and it is **not overridable by an overlay** (that file's
     § Overrides), so no local variant can exist to drift from it. The offered
     option set is **conditioned on this brief's reshape marker** (see the
     `reshape` bullet): on the **first** encounter this pass, present all
     three —
     `proceed` / `reshape` / `drop`; **once the reshape marker is set**,
     present only two — `proceed` / `drop` (reshape is spent). This is the
     bounded-ceremony rule, stated once here so the "exactly three" and "two
     on the second encounter" cases don't read as a contradiction — the count
     is a function of the marker, not a constant.
     - **proceed** → the premise holds. Record dimension 0 `filled` (part ii)
       and continue to **Step 2**.
     - **reshape** → the framing is wrong but the idea isn't dead. **First set
       the reshape marker**: persist a one-line `premise-gate: reshaped once`
       marker into the brief's **working-notes surface — the same surface
       Step 3.1's tier record uses (3.1.4)** — so the once-per-pass bound
       survives a crash/resume rather than living only in this pass's
       in-context memory. Then loop back to **Step 1.1** to restate the
       problem and re-run **Steps 1.1, 1.2, 1.3, and this gate** against the
       new framing — **not** item 4's note probe (the draft note already
       exists this pass; re-probing it would adopt-and-resume, skipping this
       gate). Because the marker is now set, this gate's next encounter offers
       only `proceed` / `drop` — reshape is **not** offered a second time; if
       the reshaped framing still fails the premise the operator chooses
       `proceed` or `drop`, never a third loop.
     - **drop** → the case-against wins; the idea is killed. Perform the
       **drop action** as a **single full-file rewrite** (`vault_write`, or
       the plain-files `ks_write` equivalent) that sets the brief's
       frontmatter to **`status: dropped`** (the additive enum value in
       `claude/design-schema.md` § Frontmatter), writes **dimension 0's
       `## 0.` section with the kill rationale** (disposition `filled` — the
       justification, stated in the negative), and bumps `last_verified` to
       today. **Never** use a `vault_patch` frontmatter-scalar `replace` for
       the status flip — the vault safe-targeting contract (and Step 4.4)
       documents it as **silently dropping the field and returning OK**, which
       would leave the brief `status: draft` while the gate believed the kill
       landed, defeating the whole invariant. Trust the flip only when written
       by that full-file rewrite (or confirm it with a read-back). Then
       **stop the command** — a dropped brief is neither ratified nor
       materialized; it stands as the durable record (persisted by item 4's
       note creation, now flipped `dropped`) that this idea was considered and
       killed, so a later run on the same title sees the kill at item 4's
       `dropped` branch rather than silently re-litigating it.

## Step 2 — Coverage walk

Collaborative by construction: every decision that reaches the brief is
presented with its reasoning and can be contested before it is recorded —
there is no minimal-interaction path. The operator's speed lever is how fast
they accept at each stop, never whether content is shown.

1. Read `claude/design-schema.md` § Kernel dimension list, plus any
   overlay-added dimensions from `claude/design-schema.overlay.md` if this
   checkout carries one (letter-suffixed, e.g. `16a`, per that file's
   § Overlay extensibility — add-only; a kernel-only checkout like this one
   has none). **The walk's size is that list as it stands, never a count
   cached here.**
2. **Tier-split proposal — the walk's first stop, and its first challengeable
   decision.** Before walking anything, propose the split: which dimensions
   are **load-bearing for this design** (each gets its own stop) and which are
   **mechanical** (clustered 2–4 to a stop, every dimension's full content
   still shown — a cluster compresses the *asking*, never the *showing*).
   Present it per item 3, stating in the proposal itself:
   - **the total stop count** the split commits this session to, so the
     operator sees the interaction cost before accepting it and can time-box
     or re-split against it; and
   - **every dimension from item 1, each assigned exactly one tier —
     including the Step-1-seeded dimensions 0, 1 and 3.** They are seeded (0
     by the Step 1.3b premise gate, 1 and 3 by Step 1's intake), not exempt:
     their stop is a **confirm-or-challenge** over content that already
     exists, and a confirm is a real verdict — it records a `walk` stop line
     with `source: step-1-seed` (`claude/design-schema.md` § Challenge
     record, "Seeded dimensions count their Step-1 confirm as their walk
     verdict"). Leave them out and the problem statement and the routing call
     are the only calls in the brief the operator never formally accepted.

   The split is a proposal: the operator may move a dimension between tiers,
   re-cluster, or reject it — item 4's loop applies here as at any stop, and no
   content stop opens until it is accepted. The schema's order is the default
   walk order and the operator may reorder freely, but every dimension in the
   split must be reached before Step 3. This sets *walk* granularity only;
   Step 3.1's brief/full **review** tier is a separate axis.
3. **Each stop: a decision presentation, then exactly one disposition per
   dimension.** Present every stop — a load-bearing dimension, a mechanical
   cluster, or item 2's split itself — as `claude/message-schema.md`'s
   **Decision presentation** template requires, under that template's
   plain-language rule. **Apply it by reference; never restate its parts
   here** — it owns their shape, and it is **not overridable by an overlay**
   (that file's § Overrides), so no local variant can exist to drift from.
   Then record, for each dimension the stop covered, **exactly one** of the
   three dispositions defined in `claude/design-schema.md` § Disposition
   grammar, quoted here verbatim (this command applies the grammar; it does
   not restate a variant of it):

   ```
   filled                         — the dimension is answered in the brief body
   n/a — <reason>                 — genuinely inapplicable to this design, with the reason stated
   deferred → <tracking ref>      — real but out of scope for this brief; ref is an issue/epic that owns it
   ```

   - **No-silent-skips rule.** A dimension left without one of the three
     dispositions is incomplete — never let the walk move past it.
     `workflows/scripts/validate-design-brief.sh --brief FILE` (temperloop#216,
     shipped 2026-07-11) checks this on demand, and its brief-conformance
     check (C) checks the challenge record (item 5) too; briefs live outside
     CI in the knowledge store, so Step 4 re-checks both in-session anyway.
   - **Dimension 4 (Contract seams) gets special care.** Its `Produces` /
     `Consumes` / `Acceptance` is what Step 5 copies **verbatim** into the
     epic's `## Contract` — write the actual contract text, not a summary of
     one; `/assess`'s epic-decomposition mode must decompose `Produces` with
     zero changes (the schema's § Materialization contract).
4. **Bounded challenge loop — three free rounds, then an explicit fork.** When
   the operator challenges a stop, fold the challenge in, revise, and
   re-present (item 3's shape, naming what changed). Rounds one through three
   loop freely; a **fourth** does not loop — it escalates to a fork the
   operator picks from explicitly: **accept as-is** (content stands, verdict
   recorded); **`deferred → <tracking ref>`** (real but not resolvable this
   session — the ref owns the gap; never available for dimension 0, whose only
   legal disposition is `filled`); or **park the walk** (stop the command,
   brief left `status: draft` — record and dispositions persist, and a later
   run adopts the draft at Step 1's probe and resumes here). A non-converging
   stop is therefore a visible operator choice, never an invisible grind
   (`docs/principles.md` principle 11, applied to review effort).
5. **Append to the challenge record as each stop closes.** Write the stop's
   line(s) into the brief's `## Working notes` → `### Challenge record` per
   `claude/design-schema.md` § Challenge record — that section owns the line
   shape, verdict vocabulary, clustering rule, `walk`/`walkthrough`
   discriminator and record-start marker, applied by reference, never
   re-copied here. What this walk owes it:
   - **`kind` is `walk`** at every Step 2 stop; `walkthrough` belongs to
     Step 3's review pass.
   - **A clustered stop carries one verdict per dimension in the cluster** —
     N verdicts, never one collapsed cluster verdict. Dimensions share a line
     only when they genuinely share the identical verdict (that section's
     clustering rule); a mixed cluster splits into as many lines as it has
     distinct verdicts.
   - **An `operator-edited` verdict carries the operator's verbatim words**
     in its `response:` field — quoted from their own `AskUserQuestion`
     answer, never a facilitator paraphrase.
   - **The pass's first stop also writes the `challenge-record-start:
     <today>` marker** when no `### Challenge record` subheading exists yet —
     in the *same* write as that first stop line, so the record is never
     announced-but-empty (that section's record-start defect). It is what lets
     a resume tell a post-change crash from a pre-change brief.

   **Walk-structure note — provisional, do not cite Double Diamond.** The <!-- cite: W.16 incident:K#224 -->
   walk above is a **convergent inspection checklist**: dimensions applied in
   a default order, each presented, challenged and dispositioned, with no
   divergent / alternatives-generation phase in it (item 3's alternatives part
   reports alternatives already weighed; it generates none). This is the
   grounding the L0 methodology spike confirmed (`Context/temperloop - design
   methodology spike verdict.md`) — Double Diamond's diverge-then-converge
   framing was evaluated against this walk and **rejected**; never cite it for
   the walk's structure. Whether to *add* a bounded alternatives-generation
   moment is still open — **provisional — pending temperloop#224**.
6. **Persist as you go.** Write each dimension's content into the brief note
   incrementally — as each stop closes, not in one end-of-walk rewrite — so a
   crashed walk loses at most the stop in flight. By backend:
   - **Obsidian-backed store:** a small append/patch per dimension (the vault's
     write-small convention), falling back to a full-file rewrite whenever a
     heading path isn't safely `vault_patch`-able (the safe-targeting contract).
   - **Plain-files store:** the backend has **no mid-file patch primitive** —
     the `knowledge_store` interface offers only `ks_write` (whole-file
     replace) and `ks_append` (end-of-file). So each dimension update is a
     **full-file rewrite via `ks_write`** (read → modify in memory → write).
     **Never** persist dimensions as per-dimension `ks_append` calls: the walk
     is operator-reorderable (Step 2.2), so appends land out of dimension
     order and corrupt the note's numbered-section structure.
7. **Persist-then-ask ordering — dual-surface before any gate.** Step 2.6 <!-- cite: W.8 incident:K#670 -->
   requires the incremental *write*; this fixes its **ordering** relative to
   any operator gate. Never open a stop's accept/challenge question (or any
   approval question) over drafted content until that content is **both**:
   - **(a) persisted to the brief note** via Step 2.6's write primitive — the
     note is the **artifact of record**, the durable surface the operator and
     every later step read. A write's OK return is **not** proof it landed: an
     Obsidian `vault_patch` can silently misfire (the vault safe-targeting
     contract — duplicate-heading synthesis, a stale document map), so
     **confirm the persist with a read-back**, or take the misfire-free
     full-file-rewrite path — the same read-back discipline Steps 1.3b and 4.4
     already require for this silent-drop class; **and**
   - **(b) presented in chat** — item 3's decision presentation over that
     same content, for in-line review.

   Both surfaces must be **current** — reflecting exactly the content the gate
   asks about — *before* the question is posed; neither alone is enough.
   Gating over content that exists **only** as a transient chat bullet list
   with **no** persisted note behind it is forbidden: that is the observed
   failure (temperloop#670 — a 13-dimension draft gated for approval while the
   brief note was still empty, leaving no reviewable artifact).

   **Scope: every gate over brief content, no exemptions.** This ordering
   governs the walk's own stops (Step 2), the findings fold-back (Step 3.4)
   and the ratify ask (Step 4) alike. Nor is there an ad-hoc grouping license:
   the only sanctioned way to ask once over several dimensions is a mechanical
   cluster the operator accepted at item 2 — every dimension still shown, every
   dimension separately verdicted.

## Step 3 — Review pass

Runs after Step 2's coverage walk completes (every dimension carries a
disposition), and before Step 3.5's congruence pass hands a reviewed brief
to Step 4 (ratify). Four parts, in order: **3.1** tier
decision, stated to the operator before any reviewer is spawned; **3.2** the
install-surface first-run/uninstall mandate; **3.3** capability-probed
adversarial panel execution; **3.4** findings fold-back into the brief. A
brief that skips this step never reaches ratify — Step 4.1's
dimension-completeness check is unchanged, Step 4.1b re-checks that every
finding this step produced was actually disposed of, and Step 4.3's ratify
question then follows a brief that has actually been reviewed, not merely
walked.

### 3.1 — Tier decision (stated before committing)

1. **State the cost, then ask.** Before spawning a single reviewer, tell the <!-- cite: W.9 class:unpriced-speculative-review-spend -->
   operator what each tier costs: **brief pass** = two standing lenses
   (`architecture-reviewer`, `requirements-auditor`) reviewing the brief
   once each; **full pass** = the same two lenses **plus** a red-team lens,
   a persona pass, and (when 3.2 applies) an executed first-run/uninstall
   run. This is the adapted Shape Up "appetite" move (Singer, *Shape Up*
   ch. 3, 2019) — the L0 methodology verdict confirms the mapping survives
   *re-targeted*: the budgeted resource here is review effort/tokens, not a
   team's build cycle, and the tier is a quantized review-cost appetite, not
   a time estimate (`Context/temperloop - design methodology spike verdict.md`
   § 6). Naming the cost **before** the pick is the point of the mapping;
   never spawn a reviewer speculatively while the pick is still open. State
   the availability caveat in the same breath: each lens runs only if it
   passes 3.3's capability probe, so on a checkout missing a declared agent,
   part of a full pass reduces to legible skip lines — the operator is
   pricing what *can* run here, not a hypothetical. Both the red-team lens
   (`claude/agents/red-team-lens.md`, temperloop#510) and the persona lenses
   (`design-persona-agents` temperloop#221) now ship as declared agents under
   `claude/agents/`, so a full pass runs live here subject to the normal
   capability probe.
2. **Ask.** `AskUserQuestion`: brief pass or full pass? Suggest a default
   from the epic's apparent weight (a single-file, low-blast-radius design
   suggests brief; a design that touches the install surface, adds a new
   command, or reshapes a contract surface suggests full) — the operator's
   answer overrides the suggestion regardless.
3. **Brief pass always runs both standing lenses.** Per the ratified
   design brief's RQ-4: `architecture-reviewer` **and**
   `requirements-auditor` run on *every* review, brief tier or full —
   there is no one-lens floor. Full pass is strictly additive on top of
   brief pass, never a replacement of it.
4. **Record the chosen tier** as a line in the brief's working notes (it is
   not a schema dimension of its own — it's provenance for what review this
   brief actually received) before proceeding to 3.2–3.3. When 3.3
   completes, extend that same line with the **per-lens coverage record**:
   which lenses actually ran and which were skipped (each skip naming its
   `skipped — <agent> unavailable` reason). The live narration of a skip
   (3.3.2) is not enough on its own — without the persisted record, a
   brief whose entire panel skipped is indistinguishable in the artifact
   from a fully-reviewed one, which is exactly the miscalibrated-trust
   failure the degradation-notice template exists to prevent.

   **One coverage record, every lens in it — 3.3's panel and 3.5's
   congruence lens alike.** The cold-read congruence lens (3.5.2) is not a
   separate accounting: extend this same line again when 3.5 completes,
   recording whether `congruence-lens` ran (and with how many flags) or was
   skipped, in the form item 1a selects. Its absence is the easiest of all
   to mistake for a clean bill of health, so a brief it never read says so
   in the artifact, not only in the live transcript.

### 3.2 — Install-surface first-run/uninstall mandate (spec-presence only)

1. **The mandate.** If the design touches the install surface — bin/
   entry points, install/uninstall code, hook or cron registration,
   anything a stranger's fresh clone would run once and never again — an
   **executed** first-run/uninstall persona run is **mandatory**,
   regardless of which tier 3.1 picked. This is RQ-3 from the ratified
   brief: the mandate is not a full-pass-only nicety, and dimension 12
   (First-run experience) is the dimension that names the trigger.
2. **What "executed" means, and why it outranks inspection.** The L0 <!-- cite: W.10 incident:K#221 -->
   verdict adapts cognitive walkthrough (Wharton, Rieman, Lewis, Polson,
   1994) for this run's *rubric* only — its four questions (will the
   persona try the right action, notice it's available, know it's correct,
   understand the feedback?) and its required-inputs discipline (a named
   user, a concrete task, the documented correct sequence). It does **not**
   license calling the run itself "a cognitive walkthrough": per the
   verdict, an agent actually executing install/uninstall in a worktree is
   empirical first-use observation, which the literature rates *above*
   inspection, not an instance of it (`Context/temperloop - design
   methodology spike verdict.md` § 1). Never describe the run as a
   cognitive walkthrough in a brief or Decisions note.
3. **This file specifies the mandate, not the executor.** The agent that
   actually performs a fresh clone → install → report-friction → uninstall
   → diff-residue run is `design-persona-agents` (temperloop#221 — closed
   2026-07-11), scoped separately because it's parameterized by the
   customer archetypes the audience page (K136) defines — content this
   file must not invent. `claude/agents/hobbyist-persona.md`,
   `consultant-persona.md`, and `team-member-persona.md` now declare it,
   each with an EXECUTING mode for exactly this run. Whenever the mandate
   applies but no such executing agent happens to be declared in a given
   checkout, this degrades exactly like any other capability probe (3.3): a
   legible skip line — the not-shipped vs shipped-but-not-installed form per
   § 3.3 item 1a (the persona agents ship as source under `claude/agents/`, so
   the shipped-but-not-installed remedy form applies) — stamped into
   dimension 15 (failure modes / capability limits) as an honest gap —
   **never** a silent pass, and never treated as satisfying the mandate. A
   ratified brief with this gap stamped is still ratifiable (Step 4 blocks
   on undispositioned dimensions, not on a capability that was never
   available in this checkout); a ratified brief with the mandate silently
   unmet is not.

### 3.3 — Capability-probed adversarial panel

1. **Availability predicate.** A review subagent is available iff this
   project declares it in `CLAUDE.md § Subagents` or `.claude/agents/`
   ([[Decisions/foundation - Project capability probes]]) — the same
   predicate `/assess` Step 3 and `/triage` Step 3 apply to their own
   panels. Probe each candidate lens right before it would be spawned;
   absence is never fatal to the walk.
1a. **Two skip-line forms — the single definition every later mention below <!-- cite: W.11 incident:K#290 -->
   defers to.** When the predicate is false, the skip line takes one of two
   forms per `claude/message-schema.md` § Degradation notice (the contract
   home; kernel wording owner is `CLAUDE.kernel.md` § Legible agent-gate
   degradation) — distinguish *why* before emitting it:
   - **Not shipped** — no `claude/agents/<agent>.md` source file exists in
     this checkout. Nothing to install → bare `skipped — <agent> unavailable`.
   - **Shipped but not installed** — a `claude/agents/<agent>.md` source file
     *does* exist but the lens isn't resolvable live (no
     `.claude/agents/<agent>.md`, no `CLAUDE.md § Subagents` declaration) →
     the remedy-bearing form `skipped — <agent> available as source; run
     workflows/scripts/install/project-agents.sh to enable` (temperloop#290).
     This is the recurring fresh-standalone-clone case — every lens ships as
     source under `claude/agents/` but no live `.claude/` exists yet — so the
     operator sees the one-command fix on the live line, not a bare dead-end.
   Every other reference to `skipped — <agent> unavailable` in this file —
   before or after this item, including the § 3.2 persona-agent skip — is
   shorthand for whichever of these two forms the probe selects; the skip is
   never silent either way.
2. **Brief pass (always).** Probe `architecture-reviewer` and
   `requirements-auditor`. For each available, spawn it read-only and
   advisory with the brief's per-dimension content (all seventeen
   dimensions plus any overlay additions) and its own charter:
   `architecture-reviewer` judges dimensions 1, 3, 5, 7, 10
   (problem/outcome incl. the stranger-test call, routing, command shape,
   maintainability coupling, upgrade path — boundary and contract-call
   concerns); `requirements-auditor` judges dimensions 4, 8, 15 (Contract
   seams, testability, failure modes — the same requirements-sanity
   charter it applies in `/assess` Step 3). This design-time pass reviews
   the *brief* and is distinct from — not a substitute for —
   `workflow-reviewer`'s standing post-merge review of any resulting
   command spec: `claude/design-schema.md`'s Enforcing-gate column ties
   dimensions 5 and 15 to `workflow-reviewer` precisely because it later
   reviews every edit to the spec the design *produces*; here the same
   dimensions are judged as brief content, before any spec exists. Each
   unavailable lens emits its own skip line — the not-shipped vs
   shipped-but-not-installed form per 1a — narrated live (Mode 2 degradation
   notice, `claude/message-schema.md` § Degradation notice) — never silently
   absorbed into a generic "review skipped" note.
3. **Full pass adds** (only when 3.1 picked full): a **red-team lens** —
   an adversarial charter that attacks the brief's stated acceptance
   criteria (dimension 4), threat model / premortem (dimension 15), and
   **premise justification (dimension 0)** directly — surfacing where they
   are weak, unfalsifiable, circular, or where the premise's case-against
   was not honestly engaged — looking for a way the design could satisfy
   every dimension's disposition and still fail the customer. Its
   **authoritative charter is `claude/agents/red-team-lens.md`**
   (temperloop#510), which also states the mandatory rule that every finding
   cites a named principle from `docs/principles.md` (an uncited finding is
   discardable on sight). Full pass also adds a **persona pass**: the opining
   half of the customer-archetype agents (§ 2 of the ratified brief),
   critiquing the brief from each declared archetype's value set. All follow
   the same predicate as 3.3.1: the red-team lens ships as
   `claude/agents/red-team-lens.md` and the persona agents shipped with
   `design-persona-agents` (temperloop#221) —
   `claude/agents/hobbyist-persona.md`, `consultant-persona.md`,
   `team-member-persona.md` — so both the red-team lens and the persona pass
   run live in this checkout, each subject to the normal capability probe
   (each degrades to `skipped — <agent> unavailable` only in a checkout where
   its agent isn't declared). 3.2's executed first-run also runs here when
   its mandate applies.
4. **Independent passes, aggregated after.** Every spawned lens sees only
   the brief — never another lens's findings — until 3.4 aggregates them.
   This adapts heuristic evaluation's independent-evaluator structure
   (Nielsen & Molich, CHI 1990) for the panel's *shape only*: **provisional
   — pending temperloop#225** — same-model lenses do not carry the
   independent-human-evaluator priors the coverage/yield numbers in that
   literature were measured for, so this file claims the structure (spawn
   independently, aggregate after) and makes no coverage or
   diminishing-returns claim for it (`Context/temperloop - design
   methodology spike verdict.md` § 2). Do not cite a numeric finding
   (e.g. any figure for what fraction of problems one evaluator finds) in
   a brief or Decisions note produced by this step.

### 3.4 — Findings fold-back (before ratify)

1. **Collect.** Gather every spawned lens's findings, each tagged to the
   dimension(s) it concerns.
2. **Apply clear wins directly.** A finding that clearly improves a
   dimension's content — no judgment call, no disagreement with the
   brief's existing stance — is folded into that dimension's body **now**,
   using the same write primitive Step 2.6 already uses for this backend
   (Obsidian: small patch/append per dimension, full-file fallback when a
   heading path isn't safely patchable; plain-files: full-file `ks_write`).
   A finding that surfaces a real gap the operator chooses not to resolve
   now converts that dimension's disposition to `deferred → <tracking
   ref>` rather than leaving it `filled` with an unaddressed critique.
   **Dimension-0 carve-out.** A finding on **dimension 0** (Premise & <!-- cite: W.13 guard:claude/design-schema.md -->
   null hypothesis — the red-team lens's sharpest target) is the one
   exception: dimension 0 is `filled`-only (`claude/design-schema.md`
   § Disposition grammar), so an unresolved dimension-0 finding may
   **never** convert to `deferred`. It resolves one of two ways — a
   real fix folded into the premise justification now (`folded`), or an
   explicit decline that leaves dimension 0 `filled` (the finding is
   rejected, noted per item 4's decline vocabulary). If the operator
   judges the premise gap serious enough that dimension 0 cannot
   honestly stay `filled`, that is a signal to route back to the premise
   gate (Step 1.3b) or to decline-and-stay-`draft` — never to mint an
   invalid `deferred` disposition the schema declares impossible.
3. **Surface contested findings.** A finding the brief's owner disagrees
   with is not applied silently — put it to the operator via
   `AskUserQuestion` (clear win vs. contested is the same split `/assess`
   Step 3 makes for its own review pass) before folding or discarding it.
4. **No dangling findings.** Every finding from 3.3 is either folded in, <!-- cite: W.12 class:silently-dropped-review-findings -->
   converted to a `deferred` disposition with a real tracking ref, or
   explicitly declined by the operator with the decline itself noted in
   the brief's working notes — never left as an unincorporated comment
   outside the brief. Record each finding's disposal (`folded` /
   `deferred → <ref>` / `declined — <note>`) against the coverage record
   3.1.4 keeps in the brief's working notes: that record is what Step
   4.1b mechanically re-checks, so a forgotten finding blocks ratify
   rather than evaporating (dimension-level completeness alone can't
   catch it — every dimension already carried a disposition before the
   panel ran).
5. **Only then does Step 3.5 run.** This step does not re-open Step 2's walk
   order or re-litigate the tier picked in 3.1 — it is strictly the
   apply-findings-then-proceed step between review and the congruence pass.

## Step 3.5 — Congruence pass + walkthrough

Runs once Step 3.4 has settled every finding, before Step 4. Per-dimension
completeness is not congruence: a brief can carry a valid disposition on
every dimension and still contradict itself *across* two of them —
dimension 4 promising an Acceptance check dimension 8 says is manual-only.
Three parts, in order — the seam checklist (item 1), the cold-read lens
(item 2), and the tier-mirrored walkthrough (item 3) that puts both, plus
everything 3.3 and 3.4 changed, in front of the operator one dimension at a
time.

1. **Run the congruence seam checklist.** Work the named-minimum seam table
   in `claude/design-schema.md` § Congruence seams — that section owns the
   seams, what must agree at each, and its floor-not-ceiling extension
   rule. **Apply it by reference; never restate the table here**, the same
   discipline Step 2.3 applies to the disposition grammar. The checklist is
   **facilitator-run and unconditional**: no agent, no probe, no network —
   so it runs on every brief in every checkout, including one where item
   2's lens is unavailable. Record each seam as **held** or **flagged**; a
   flagged seam names both dimensions and the single claim their two
   passages disagree about, quoting each. A congruence gap outside the
   named minimum is still a flag — call it an unnamed seam rather than
   forcing it into a table row.
2. **Spawn the cold-read congruence lens.** Probe `congruence-lens` per
   3.3.1's availability predicate, then spawn it read-only and advisory
   against **exactly one document — this brief, and nothing else**. Its
   charter (`claude/agents/congruence-lens.md`) binds that read set
   mechanically: hand it the brief's path (or full text) and never a second
   note, a sibling brief, or repo source — the one-document bound is what
   makes the pass honestly fresh-context.
   - **Say what the lens is, and is not, when reporting its result.** It
     is a fresh-context textual-consistency check, not an
     independent-priors reviewer — the same model family that drafted the
     brief, in a different hat. A clean pass means the text does not
     contradict itself, **never** that the brief is sound; the operator
     remains the only independent reviewer here. Report a clean pass in
     those terms, not as "reviewed, no problems found".
   - **Unavailable is expected, and it takes the remedy-bearing form.**
     `congruence-lens` **ships as source** under `claude/agents/`, so a
     checkout where it isn't resolvable live is the
     shipped-but-not-installed case item 1a defines, and its skip line is
     that variant verbatim: `skipped — congruence-lens available as
     source; run workflows/scripts/install/project-agents.sh to enable`.
     Narrate it live (Mode 2 degradation notice,
     `claude/message-schema.md` § Degradation notice), **stamp it into the
     3.1.4 coverage record**, and name what was lost: items 1 and 3 both
     still run, so the pass degrades rather than collapses, but the
     fresh-context cross-check on the facilitator's own narration is gone
     and does not silently come back.
   - **Its flags are findings, disposed under the existing vocabulary.** <!-- cite: W.17 class:parallel-finding-ledger -->
     Every flag this lens raises — and every seam item 1 flagged — enters
     3.4's disposal path and is recorded against the **same** 3.1.4
     coverage record under the **same** three-way vocabulary (`folded` /
     `deferred → <ref>` / `declined — <note>`) 3.4.4 already owns. Neither
     these flags nor item 3's walkthrough verdicts open a second disposal
     ledger: Step 4.1b re-checks one record, and a parallel one is just a
     place for a finding to sit undisposed while the checked record shows
     nothing missing.
3. **Tier-mirrored walkthrough — every dimension, one verdict each.** It
   mirrors the **walk** tier split the operator accepted at Step 2.2 (that
   axis, not Step 3.1's brief/full *review* tier — the two are independent
   and compose freely): each load-bearing dimension gets its own step, each
   mechanical cluster steps through as the cluster it was walked in. **The
   step count derives from the schema's dimension list as it stands** —
   § Kernel dimension list plus any overlay additions, as read at Step 2.1
   — and the accepted split. Never a count cached here, never a hardcoded
   seventeen.
   - **Individually listed, delta-flagged, individually verdicted.** <!-- cite: W.18 class:cluster-collapsed-verdicts -->
     Clustering compresses the *asking* only — never the showing, never
     the verdicting. A cluster step lists each of its dimensions on its
     own line and closes with **one walkthrough verdict per dimension in
     it**: N verdicts, never one collapsed cluster verdict (Step 2.5's
     N-verdict rule for walk stops). This is what stops a load-bearing
     decision tier-split into a mechanical cluster from reaching ratify
     without a second look of its own.
   - **What each step shows, per dimension:** its **final disposition**; a
     **gist** of the content as it now stands; the **delta since the
     operator last saw it** — what 3.3's panel and 3.4's fold-back changed,
     named concretely, or an explicit `no change since your walk verdict`;
     and any **congruence flags** items 1–2 raised against it, quoted. The
     § Decision presentation template's plain-language rule **governs the
     gists and deltas too** — compression is where jargon is cheapest to
     reach for, and the rule does not lapse when the challenge phase ends.
   - **Persist-then-ask applies unchanged** (Step 2.7 — every gate over
     brief content, no exemptions): a step's question opens only over
     content already written into the note, read-back-confirmed, *and*
     echoed in chat. 3.4's fold-back edits are exactly what these steps
     review, so they land in the note before the step that reviews them.
   - **Verdicts, and the time-boxing valve.** Each dimension's verdict
     comes from § Challenge record's vocabulary (`accepted` / `challenged
     → revised ×N` / `operator-edited`). A dimension the operator wants
     changed re-enters 3.4 for that edit and its step re-presents; Step
     2.4's three-free-rounds-then-explicit-fork bound applies here as at
     any stop. **Any non-premise dimension may instead resolve `deferred →
     <tracking ref>` at its step** — the sanctioned time-boxing valve for
     a session that has to end — provided the ref names a real, open item
     (§ Congruence seams' `deferred-refs-resolve` seam checks that, so
     re-run it for a ref minted here). **Dimension 0 is excluded**:
     `filled` is its only legal disposition, so a premise the operator can
     no longer accept routes back to the premise gate (Step 1.3b) or
     leaves the brief `draft` — never a `deferred` the schema forbids.
   - **Append to the challenge record as each step closes** — same write
     discipline as Step 2.5, per `claude/design-schema.md` § Challenge
     record, applied by reference and never re-copied. What this step owes
     it: **`kind` is `walkthrough`** at every step here (`walk` belongs to
     Step 2); one line per distinct verdict, so a mixed cluster splits;
     and an `operator-edited` verdict carries the operator's **verbatim**
     words in its `response:` field, never a facilitator paraphrase. A
     verdict a lens flag drove names `congruence-lens` as its `source`;
     this file mints no new `source` token of its own — that production
     belongs to § Challenge record.
4. **Then Step 4 runs.** This step neither ratifies nor blocks ratify —
   Step 4.1's checks are Step 4's. What it guarantees is that by the time
   the ratify question is asked, every dimension has been shown once more
   with its deltas and congruence flags, and carries a verdict of its own.

## Step 4 — Ratify

1. **Completeness check.** Confirm every dimension — every kernel dimension
   plus any overlay additions walked in Step 2, including any disposition
   Step 3.4 converted to `deferred` during fold-back — carries exactly one
   disposition. List any gap and stop; do not proceed to ratify a brief with
   an undispositioned dimension. This is the enforcement point
   `claude/design-schema.md` § Disposition grammar's "No-silent-skips rule"
   names as living here (in the review tier, now also mechanically checked
   on demand by `workflows/scripts/validate-design-brief.sh --brief`,
   temperloop#216, shipped 2026-07-11) — Step 3's review tier existing does
   not relax this check; it only adds a source of new dispositions for it
   to catch. One per-dimension invariant this check also holds, which the
   shipped lint does not yet special-case: **dimension 0's only legal
   disposition is `filled`** (`n/a` and `deferred` are both invalid for it —
   `claude/design-schema.md` § Disposition grammar), so a dimension 0
   carrying `deferred` (e.g. from a mishandled fold-back) is a gap here, not
   a passing disposition.

   1b. **Finding-disposal check.** Dimension-level completeness alone
   cannot catch a dropped review finding — every dimension already
   carried a disposition when Step 2 ended, so a brief that silently
   dropped a finding still passes check 1. Re-check the coverage record
   in the brief's working notes (3.1.4): every finding each 3.3 lens
   returned **and every congruence flag 3.5 raised** — a flagged seam
   from 3.5.1, a contradiction from the 3.5.2 lens — must carry exactly
   one disposal: `folded`, `deferred → <tracking ref>`, or `declined —
   <note>` (3.4.4's vocabulary, which 3.5 reuses rather than parallels —
   one record, one vocabulary, one check). List any finding without one
   and stop, same shape as check 1: return to
   Step 3.4 and dispose of it, never ratify past it. A lens's `skipped —
   <agent> unavailable` entry satisfies this trivially (no findings to
   dispose) — including `congruence-lens`, whose skip takes the
   remedy-bearing form per § 3.3 item 1a; a lens that ran with zero
   findings records `no findings`, a clean checklist records its seams
   held.

   1c. **Challenge-record completeness check** (cross-referenced elsewhere
   as Step 4.1c). Runs immediately after 1b, before check 2, and gates the
   Ask (item 3 below) — ratify becomes the terminal act of the walkthrough
   only once this passes. Re-read the
   brief's `### Challenge record` (working notes, 3.1.4) and enforce
   `claude/design-schema.md` § Record completeness's two rules verbatim —
   the single source of truth this check reuses rather than restates, so
   the two can never diverge: **(1)** every kernel dimension 0..16 carries
   at least one `walk` stop line (dimensions 0, 1, and 3 satisfy this via
   their Step-1 seed — `source: step-1-seed`, written at the Step 1.3b
   premise-gate proceed for dimension 0 and the Step 1 intake confirm for
   1 and 3, per § "Seeded dimensions count their Step-1 confirm as their
   walk verdict" — never a second carve-out); **(2)** every
   `operator-edited` stop line carries a verbatim `response:` field.
   `walkthrough` coverage stays opportunistic and is never required per
   dimension. List any gap and stop, same shape as checks 1 and 1b: return
   to Step 2 or 3.4 and complete the record before ratifying.

   **Migration carve-out.** A brief with NO `### Challenge record`
   subheading at all is exempt from rule (1) — never flagged — keyed on
   the per-brief `status:` signal (temperloop#512), never a global
   version flip; a non-ratified (draft/dropped) brief is never held to
   (1) or (2) either. The record-start-marker-present-but-empty defect is
   independent of ratification status and applies regardless. Fixture
   `workflows/scripts/tests/fixtures/design-briefs/challenge-record-migration-exempt.md`
   (ratified, no `### Challenge record` section at all) ratifies under
   this carve-out.

   **Not excused.** Fixture
   `workflows/scripts/tests/fixtures/design-briefs/challenge-record-walk-missing.md`
   (ratified, `challenge-record-start:` marker present, dimension 6's
   `walk` line omitted) is NOT excused by the carve-out and IS blocked —
   the loophole the record-start marker exists to close: a crashed
   post-change walk masquerading as a migration case.
2. **Contract sanity.** Re-read dimension 4's `Produces` / `Consumes` /
   `Acceptance`. If it reads as a summary rather than an actual contract —
   the kind of content `/assess`'s epic-decomposition mode would need to
   reshape before it could decompose — send it back to Step 2 rather than
   ratifying a brief whose Contract isn't really `filled`.
3. **Ask.** Confirm with the operator directly via `AskUserQuestion` — ratify
   this brief? (No `decision_sink_ask(...)` routing: per the Operating
   principles, this command has no operator-absent case to route around.)
4. **On approval:** flip the note's frontmatter `status: draft → ratified` <!-- cite: W.7 class:frontmatter-patch-silent-drop -->
   and update `last_verified` to today, via a **full-file rewrite**
   (`vault_write`, or the plain-files equivalent) — never a `vault_patch`
   frontmatter-scalar `replace`, which the vault safe-targeting contract
   documents as silently dropping the field. A ratified brief is immutable
   from here: a later change to it is a **new** brief that supersedes it via
   `[[wikilink]]`, never an edit-in-place (`claude/design-schema.md` §
   Frontmatter).
5. **On decline:** stop. The brief stays `draft`; resume the walk (Step 2) or
   materialize (Step 5) later — nothing here is lost.

## Step 5 — Materialize

Runs only against a `ratified` brief (Step 4). Five sub-steps, in order —
each degrades legibly rather than blocking the ones after it, except where
noted.

### 5a — Compose the epic body, then leak-guard scan it (outbound content only)

**First, compose the epic body** — composition is a precondition of the scan,
so it happens here, before anything outbound exists: title = the brief's
title; body = a `## Contract` heading containing dimension 4's `Produces` /
`Consumes` / `Acceptance`, copied forward **verbatim** from the ratified
brief — not re-derived (`claude/design-schema.md` § Materialization
contract) — plus the provenance marker line, on its own line:

```
design-brief: [[Designs/<note>]]
```

**Then scan the composed body** before it is written anywhere outbound: <!-- cite: W.14 incident:K#74 -->

- If this checkout's `workflows/scripts/kernel/personal-token-denylist.tsv`
  exists, grep the composed epic body text against its pattern column — the
  same deny-pattern data the diff-scoped leak guard
  (`workflows/scripts/kernel/check-pr-leak-guard.sh`, temperloop#74) applies
  to a PR's added lines, applied here to the epic body instead of a diff. A
  hit **blocks** materialization until the operator edits the offending
  content (in the brief, then re-copy into the Contract) — this is the one
  sub-step in Step 5 that is not best-effort, because the epic is outbound
  content in a repo that may be public.
- If the pattern file isn't present in this checkout (a downstream repo with
  its own denylist convention, or none at all), skip with a legible
  degradation notice — `claude/message-schema.md`'s **Degradation notice**
  template: what was skipped (the leak-guard scan), why (no denylist data in
  this checkout), and the calibrated-trust statement (the epic body was not
  scanned — review it yourself before it lands publicly). Never a silent
  skip.
- This scans the **epic body only**. The brief itself stays in the private
  knowledge store regardless of this repo's public/private status — nothing
  about the brief's own storage changes here.

### 5b — Probe-before-create epic

1. Resolve `repo` from `--board`/`--project`, else the Step 0.4 inference. **If
   `gh` auth failed or no repo resolved at all** (Step 0.3), stop here — do
   **not** attempt epic creation. This is the minimum-viable-output floor: the
   brief is already ratified and persisted (Steps 1–4), so nothing is lost;
   only the epic and the final hand-off degrade. Skip the rest of 5b, still
   run 5c (ADR emission — each emitted ADR notes no epic exists yet) and 5d
   (Decisions capture), and emit Step 5e's **degraded** hand-off line
   instead of the full one.
2. **Take the epic body composed and scanned in 5a** — do not re-compose it
   here; 5b writes exactly the content the leak-guard scan cleared, nothing
   else.
3. **Probe-before-create.** Search for an existing epic carrying this exact
   marker line before creating a new one:
   `gh issue list -R "$repo" --search "design-brief: [[Designs/<note>]] in:body" --state all`
   (or the `issue_marker_probe` helper,
   `workflows/scripts/lib/issue-marker-probe.sh`, when this checkout vendors
   it — same corpus-first-then-live-fallback shape `/triage` Step 4 uses).
   **Found** → adopt it; this is the re-run path (a repeated `/workshop` pass,
   or a materialize retried after a partial failure) — if the ratified
   brief's Contract changed since the epic was created, update the epic body
   to match, but never create a second epic for the same brief.
   **Not found** → `gh issue create -R "$repo" --title "<title>" --body
   "<body>"`.
4. **Board mirroring (best-effort).** If Step 0.4 resolved a registered board
   for `repo`, land the epic on it via the adapter (`board_create_on_board`,
   or `board_resolve` + a single add for the whole burst if other issues are
   being created in the same pass) — on this checkout's issues-only backend
   (board 7), that means no Projects-v2 field writes, exactly as `/triage`'s
   epic creation behaves there. No board registered → the epic still exists
   as a plain GitHub issue; note the skip in the Step 6 summary, don't treat
   it as a failure.

### 5c — ADR emission (best-effort, degrades legibly)

**Four artifacts, four different things — no content duplication.** <!-- cite: W.15 guard:docs/adr/0000-adr-process.md -->
`claude/design-schema.md` § Materialization contract names three: the brief
(private deliberation record, `Designs/` in the knowledge store), the epic
(operational tracker), and the Decisions note (personal capture, 5d below).
This sub-step adds a fourth, distinct from all three: the **public decision
record** — a draft ADR under `docs/adr/`, immutable once later ratified to
`Accepted` by a human outside this command. Each of the four holds different
content, never a copy of another's: the brief carries the full deliberation
(alternatives considered, persona findings, rejected options); the ADR
states the decision plus its consequences, in ADR-0000's MADR-lite shape,
at ADR length — not the brief's exploratory reasoning restated; the
Decisions note (5d) carries the operator's own personal framing/rationale.
Compose each ADR section fresh from the brief's content; do not paste brief
prose or Decisions-note prose into it verbatim.

1. **Identify architectural calls.** Walk the ratified brief's dispositioned
   dimensions for calls that pass the stranger test
   (`claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule, applied to
   decision records per `docs/adr/0000-adr-process.md` § "Routing rule:
   which decisions get an ADR, and which stay in the vault") — a decision a
   stranger's fresh clone of this kernel repo would need the rationale for,
   to understand why kernel machinery is shaped the way it is. Dimension 3
   (Alignment / routing) already ran this exact test at Step 1.3 and is the
   first place to look; dimensions 4, 5, 7, and 10 are the other likely
   sources wherever the brief commits to a specific architectural shape (a
   new component, a contract surface, a board-field axis, a coupling
   commitment). A brief can make zero, one, or several such calls — this is
   a judgment call over the brief's content, not a fixed count.
2. **Degrade legibly when there's nothing to emit.** If `docs/adr/` doesn't
   exist in this checkout, or the walk in 5c.1 finds zero architectural
   calls, emit nothing and say so plainly — `claude/message-schema.md`'s
   Degradation notice template (what was skipped, why, one line) — never a
   silent skip. This mirrors 5a/5b's own best-effort degradation style.
3. **Emit one draft ADR per identified call.** For each: allocate the next
   append-only 4-digit number by scanning `docs/adr/NNNN-*.md` for the
   highest existing prefix and incrementing by one (per ADR-0000 §
   Numbering — never reused, never a guessed gap); write
   `docs/adr/NNNN-<kebab-case-title>.md` conforming to ADR-0000's
   MADR-lite four-section format:
   - Frontmatter `title: NNNN: <title>` (single line, per ADR-0000).
   - `## Status` — **`Proposed`**, always, never `Accepted`: this command
     only drafts the ADR, it does not ratify it. Accepting an ADR (or
     superseding one) is a separate, later human act outside this command's
     scope.
   - `## Context` — the forces at play, drawn from the brief's relevant
     dimension(s), plus a reference back to the materialized epic (`epic:
     <owner/repo>#<N>`, or — if 5b degraded — "no epic exists yet; see the
     ratified brief", the same degraded-path phrasing 5d uses for its own
     epic cross-link).
   - `## Decision` — the call itself, stated plainly enough to act on
     without re-deriving it, per ADR-0000 § Decision.
   - `## Consequences` — what follows: benefits, costs, follow-on work,
     drawn from the brief's dimension 15 (failure modes) / dimension 16
     (adoption & enforcement) content where applicable.
   Register the `docs/adr/*` glob in both governance manifests ADR-0000 §
   Manifest registration names — `workflows/scripts/kernel/kernel-manifest.txt`
   (`kernel docs/adr/*`) and `docs/features/feature-manifest.txt` (`none
   docs/adr/*`) — if an entry for the glob isn't already present; ordinarily
   a no-op after the first ADR this command ever emits, since the glob
   claims the whole directory once.
4. **Link back to the epic; link the epic forward to the ADRs.** Each
   emitted ADR's `## Context` (or `## Consequences`) already names the epic
   per 5c.3 above — that is the epic-ward direction. For the reverse
   direction, append a section to the epic body (composed in 5a, created or
   adopted in 5b) listing every emitted ADR's path, e.g. an `## ADRs`
   heading with one path per line, via `gh issue edit`. **If 5b degraded**
   (no epic exists), skip only this reverse-linking half — the ADRs
   themselves still emit per 5c.3, each noting "no epic exists yet" in its
   `## Context` rather than a real epic reference; note the skip in Step 6.
5. **Best-effort, like 5a/5b.** A failure in this sub-step (a write error,
   a manifest-registration failure) is reported plainly in Step 6 and does
   not roll back 5a/5b or block 5d/5e from running.

### 5d — Decisions capture

Write a `Decisions/` note capturing the ratified design call, per
`claude/CLAUDE.kernel.md` § Decision capture (the same frontmatter, the same
`## Source` footer convention), cross-linking `[[wikilink]]`s both back to
the brief and forward to the epic (or, if 5b degraded, noting that no epic
exists yet). This is the third of the four artifacts named in 5c above —
brief (deliberation record), epic (operational tracker), ADR (public
decision record, 5c), Decisions note (personal capture, here) — and it runs
**regardless of whether 5b succeeded**: a degraded materialize still gets its
Decisions note.

### 5e — Hand-off line

End Step 5 with exactly one line:

- **Full materialize:** `next: /assess --epic <N>`
- **Degraded (5b stopped at its check 1):** `next: create the epic by hand
  from the ratified brief's § 4 Contract (Produces/Consumes/Acceptance +
  the design-brief: marker), then /assess --epic <N>` — so the operator is
  never left without a next step just because `gh`/a repo wasn't available.

## Step 6 — Summarize

Print, in order: the brief note's path and final `status`; each dimension's
disposition in one compact line (`filled: N · n/a: N · deferred: N`, with the
deferred refs listed); whether the leak-guard scan ran or was skipped (and
why); the epic — created, adopted, or not-created-and-why; each ADR emitted
in Step 5c (path + number), or the degradation reason if none were emitted;
the Decisions note path; and the Step 5e hand-off line, verbatim, as the
last line of the response.

## Failure modes

- **Knowledge store or `design-schema.md` unreachable (Step 0).** Stop before
  any conversation starts — there is nothing to walk without the schema, and
  nowhere to write the brief without the store.
- **`gh`/repo unavailable at materialize time (Step 5b).** Not a failure of
  the command — the brief still ratifies and persists; only the epic and the
  final hand-off degrade (Step 5e's degraded line). Report it plainly in Step
  6, never silently.
- **No board registered for the resolved repo (Step 5b.4).** The epic still
  gets created as a plain GitHub issue; board mirroring is a convenience, not
  a requirement. Note the skip.
- **No `docs/adr/` directory in this checkout, or the ratified brief makes no
  architectural call (Step 5c).** Emit nothing — a legible degradation
  notice naming which condition applied, same best-effort style as 5a/5b;
  never a silent skip.
- **A dimension is left undispositioned at ratify time (Step 4.1).** Block
  ratification — list the gaps and return to Step 2. Never ratify with a
  silent skip; the mechanical lint (temperloop#216) isn't required for this
  to be enforced here.
- **Operator gated on drafted content with no persisted note behind it (Step
  2.7).** The note is the artifact of record; a chat-only draft is not
  reviewable on a later read, and a `vault_patch` that returned OK may have
  silently misfired. Never open an approval gate until the content is
  persisted (read-back-confirmed) *and* echoed in chat — this is the
  temperloop#670 failure, and its subtler belief-vs-actual-persistence
  variant one layer down.
- **A reviewer, red-team lens, persona agent, or the congruence lens is
  unavailable (Steps 3.2–3.3, 3.5.2).** Not a failure of the command — the
  capability-probe predicate
  ([[Decisions/foundation - Project capability probes]]) makes this an
  expected outcome in a checkout with no `.claude/agents/` declared. Emit
  the per-lens skip line — the not-shipped vs shipped-but-not-installed form
  per § 3.3 item 1a — live, and continue the panel with whatever's available;
  an unmet install-surface first-run mandate (3.2) is stamped into
  dimension 15 rather than silently satisfied. A missing `congruence-lens`
  (3.5.2) never stops 3.5: the seam checklist and the operator walkthrough
  both still run, the skip is stamped into the 3.1.4 coverage record, and
  the lost fresh-context cross-check is named. The shipped-but-not-installed
  form is the common one: in a fresh standalone clone the agents ship as
  source under `claude/agents/` but no live `.claude/` exists, so its skip
  line already names the remedy on the live line — run the project-scoped
  install path once, `bash workflows/scripts/install/project-agents.sh`
  (temperloop#290), which wires `claude/agents/*` + `claude/commands/*` into
  `.claude/`; see `docs/features/review-agents.md` § Installation.
- **Dimension 4 reads as a summary, not a real contract (Step 4.2).** Send it
  back to Step 2 rather than ratifying a Contract `/assess` would have to
  reshape.
- **Leak-guard scan finds a hit (Step 5a).** Block materialization — this is
  the one non-best-effort check in Step 5, because the epic body is outbound
  content. Fix the offending text (in the brief, then re-copy into the
  Contract) and re-run Step 5.
- **Re-running `/workshop` (or just Step 5) against an already-ratified,
  already-materialized brief.** Idempotent throughout: the epic probe adopts
  rather than duplicates (5b.3); the Decisions note capture is a one-time
  write per decision, not a per-run one (skip if it already exists for this
  brief — check via its `[[wikilink]]` back-reference before writing a
  second one).
- **The operator declines to ratify (Step 4.5).** Stop. The brief stays
  `draft` — nothing is lost, nothing downstream runs.

## Cross-references

- Peer front door: `claude/commands/triage.md` (discovered work; explicitly
  disclaims pre-designed epics).
- Consumer, unchanged: `claude/commands/assess.md`'s epic-decomposition mode
  (a `## Contract`-bearing epic with no sub-issues).
- Template + grammar this command applies: `claude/design-schema.md`
  (Step 3.5 applies its § Congruence seams and § Challenge record by
  reference); cold-read lens charter: `claude/agents/congruence-lens.md`.
- ADR process Step 5c conforms to: `docs/adr/0000-adr-process.md`
  (MADR-lite format, append-only numbering, kernel-public routing rule).
- Review-tier machinery (Step 3): shipped by `design-review-machinery`,
  temperloop#217. ADR emission (Step 5c, not Step 3): shipped by
  `design-adr-emission`, temperloop#219. Executing customer-persona agents
  shipped with `design-persona-agents`, temperloop#221 (closed 2026-07-11)
  — `claude/agents/hobbyist-persona.md`, `consultant-persona.md`,
  `team-member-persona.md`.
- Capability-probe predicate: [[Decisions/foundation - Project capability
  probes]] — same predicate `/assess` Step 3 and `/triage` Step 3 apply to
  their own review panels.
- Grounding: `Context/temperloop - design methodology spike verdict.md` (L0
  spike verdict — grounds Step 3.1's tier/appetite mapping, Step 3.2's
  executed-run rubric, and Step 3.3's panel-structure mapping; Double
  Diamond is REJECTED there for the walk's structure and is never cited by
  this file); the ratified brief,
  `Designs/temperloop - design command design brief.md`; the epic plan,
  `Plans/2026-07-08 temperloop - design command front door.md`.
- Kernel routing: `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule.
- Message templates used here: `claude/message-schema.md` § Decision
  presentation (every Step 2 stop) and § Degradation notice.
