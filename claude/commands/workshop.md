---
description: Facilitate a structured design conversation for INVENTED work (an idea born in conversation, not a discovered defect) in two phases — Phase 1 executes `/interview` inline to build a shared understanding out of the operator's own decisions, Phase 2 expands every dimension of `claude/design-schema.md` unattended, runs the review panel and congruence pass, and puts the result back as one chunked delta report — then ratify and materialize it into the pipeline as a board epic with a well-formed `## Contract`, draft ADRs for its architectural calls, a Decisions note, and a hand-off to `/assess --epic N`. Operator-present only — no unattended arm.
argument-hint: "[<problem-statement> | <pointer-note>] [--board <N> | --project <name>]"
---

You are running the **workshop** command (formerly `/design`; renamed —
temperloop#354 — to avoid colliding with Claude Code's builtin `/design`).
Goal: take an idea *invented* in conversation — not discovered as a Backlog
defect — interview the operator until the design's decisions are theirs,
cover the rest against a fixed template, and ratify and materialize it into
the same pipeline `/triage` feeds. This is the pipeline's **second front
door**, for invented rather than discovered work
(`Decisions/temperloop - design command as front door for invented work`):

```
capture.sh (bugs) ┐
sweeps / audits   ┼─► /triage      cull → collapse → group → epic + sub-issues
loose Backlog     ┘
                                                                    │
a design conversation ──► /workshop   interview → coverage + review → delta approval → ratify → materialize
                                                                    │
                                                                    ▼
                                              board epic (## Contract, design-brief: marker)
                                                                    │
                                                                    └─► /assess --epic N   (unchanged)
                                                                            └─► /build
```

`/triage` explicitly disclaims a pre-designed epic (its own spec: "no path to
decompose an already-existing, fully-specified epic"); `/workshop` is that
epic's point of origin, not a patch to triage. Both front doors converge on
the same `/assess --epic N` → `/build` pipeline.

## The two phases

**Phase 1 (Steps 0–1)** — the operator drives, in batched `AskUserQuestion`
rounds; the premise gate is round 1's Q1. **Phase 2 (Steps 2–3.7)** — the
facilitator drives, foreground and unattended, with one operator gate at
the end: the chunked delta report (3.7), plus the ratio-gate round (3.6) when
over half the dimensions came out facilitator-drafted, not interviewed.
**Phase 3 (Steps 4–6)** — ratify, materialize, summarize.

Why (`docs/adr/0035-workshop-is-an-interview-then-unattended-coverage.md`):
the predecessor walked all seventeen dimensions one modal stop at a time —
26 stops on the 2026-09-11 graph-of-record brief, 10 acknowledgement-only,
Claude drafting and the operator auditing — while the panel on that same
brief folded ≈25 real findings. The part that paid is kept and run
unattended; the part that did not is replaced by the interview.

## Scope

This file ships the full flow end to end: interview → dimension expansion →
review pass → congruence pass → delta approval → ratify → materialize,
including Step 3's tier decision/adversarial panel/findings fold-back and
Step 5c's draft ADR emission (conforming to
`docs/adr/0000-adr-process.md`). Step 3.2's install-surface mandate
specifies *when* an executed first-run/uninstall persona run is required;
the agents that run one — `claude/agents/hobbyist-persona.md`,
`consultant-persona.md`, `team-member-persona.md` — are the
`design-persona-agents` (temperloop#221). Phase 1's question mechanics —
frontier, fact probes, per-round persist, resume grammar — belong to
`claude/commands/interview.md`; this file names the parameter block it
hands over, never restating them.

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
  construction: no `--unattended` flag, no `ScheduleWakeup` poll, no async
  decision-issue backend. Every ask (Phase 1's interview rounds, Step 3.6's
  ratio-gate round, Step 3.7's delta-report chunks, Step 4's ratify
  confirmation) is a direct, interactive `AskUserQuestion` — never routed
  through `decision_sink_ask(...)`, whose whole purpose is choosing between
  a live operator and an absent one, a choice that never arises here. Phase
  2 running *unattended* means no operator gate between 3.1 and 3.7, not
  that the operator has left.
- **Minimum-viable-output rule.** Whatever else is unavailable — no `gh` auth, <!-- cite: W.2 guard:docs/principles.md -->
  no repo, no registered board, no reviewer agents declared (Step 3) — the
  command still produces a **ratified brief note in the knowledge store**.
  That is the floor. Every dependency below degrades legibly (a stated
  `skipped — <reason>` line, never a silent no-op) rather than blocking.
- **Idempotent materialization.** Epic creation is **probe-before-create** on <!-- cite: W.3 class:duplicate-epics-on-rerun -->
  the `design-brief:` marker line (Step 5b) — a re-run against an
  already-ratified brief (or of just Step 5 after a partial failure)
  **adopts** the existing epic rather than duplicating it.
- **The dimension list belongs to `claude/design-schema.md`, not to this <!-- cite: W.4 class:driftable-dimension-list-copy -->
  file.** Step 2 expands whatever that file currently defines — the
  kernel's 17 dimensions plus any overlay-added ones (letter-suffixed, e.g.
  `16a`, per its § Overlay extensibility — add-only). Never hand-add or
  hand-drop a dimension here; that is a `design-schema.md` edit
  (kernel-repo, upstream-first per the kernel's routing rule).
- **No silent skips.** Every dimension gets exactly one of the three
  dispositions defined in `claude/design-schema.md` § Disposition grammar
  (quoted verbatim in Step 2 below) — never blank, never inferred. A
  dimension no interview decision reached is **drafted and flagged**, never
  passed off as the operator's call (Step 2.3).
- **Persist-then-ask — dual-surface before any gate.** Never open an <!-- cite: W.8 incident:K#670 -->
  accept/contest question over brief content until that content is **both
  (a)** persisted to the brief note via Step 2.4's write primitive — the
  note is the **artifact of record**, and a write's OK return is not proof
  it landed, so confirm it with a read-back — **and (b)** presented in
  chat, so the operator reviews the text itself rather than a gist of it.
  Neither alone is enough, and both must be current *before* the question
  is posed. Gating over content that exists **only** as a transient chat
  bullet list is forbidden (temperloop#670: a 13-dimension draft gated for
  approval while the brief note was still empty). **Scope: every Phase 2
  and Phase 3 gate, no exemptions.** Phase 1's own equivalent is
  `claude/commands/interview.md` § Operating principles'
  persist-before-you-ask rule, applied by that spec, not re-imposed here.
- **Kernel-only checkout works end to end.** This checkout (temperloop) has
  a plain-files knowledge store and its own board (board 7, Status on
  `fnd:status:*` labels); every step below works on that substrate with no
  overlay dependency.

## Step 0 — Validate

Run in parallel:

1. **Knowledge store reachable.** The brief lives at `Designs/<repo> - <short
   title>.md`, resolved per
   `workflows/scripts/lib/knowledge_store.contract.md`. On an Obsidian-backed
   checkout, confirm `mcp__obsidian-builtin__*` tools are loaded (the
   agent-plane transport for that mode); on a plain-files checkout, confirm
   `KNOWLEDGE_STORE_ROOT` resolves. Stop with a one-line error if neither
   resolves — there is no brief without this.
2. **`claude/design-schema.md` reachable.** Confirm the file exists in this
   checkout (deployed to `~/.claude/design-schema.md` by `make install-claude`
   alongside `plan-schema.md`). If missing, stop: "design-schema missing —
   run `make install-claude` from the foundation checkout, or copy
   `claude/design-schema.md` to `~/.claude/design-schema.md` directly (this
   repo's Makefile carries no `install-claude` target)."
3. **`gh` + repo (best-effort — needed for materialize, not for the design).**
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
   probe result changes Steps 0–2's behavior, so it is deferred to the
   point of use — Step 3 probes each lens right before it would spawn it,
   per the canonical predicate (Step 3.3).
6. **Config sourced (best-effort).**
   `source workflows/scripts/build/build.config.sh 2>/dev/null || true` —
   the one place Phase 1's fact-probe tier defaults. From here on both this
   spec and the interview it executes name that tier only as
   `$INTERVIEW_PROBE_MODEL`, never a literal (`claude/CLAUDE.kernel.md`
   § Named-setting convention); where the config file is not vendored,
   `${INTERVIEW_PROBE_MODEL:-}` is empty and probes run at the session
   tier, stated once rather than silently.

If check 1 or 2 fails, stop. Checks 3, 4 and 6 are best-effort — they only
shape Step 5's degradation path and Phase 1's probe tier; check 5 shapes
Step 3's.

## Step 1 — Phase 1: the interview

Phase 1 produces the brief's `## Shared understanding` section — the problem
in the operator's words, the facts the facilitator looked up itself, the
numbered decisions, deferrals and risks — by **executing
`claude/commands/interview.md` inline, in this same session**, with the
parameter block item 5 composes. Never as a subagent: that spec's
§ Invocation contract owns the rule and the reason (the caller's context
*is* the interview's context), applied here rather than restated.

1. **Source the problem statement.** If `$1` was given, read it (a one-line
   statement, or the pointer note it names); otherwise ask the operator
   live: what problem is this, and for whom? This is the interview's seed
   (`interview.md` § Inputs), not a dimension write.
2. **Resolve the brief path.** `Designs/<repo> - <short title>.md` — the
   store is one flat corpus per `$HOME`
   (`docs/features/knowledge-store.md` § Limitations), so the repo prefix
   is what keeps two repos' briefs on one topic apart.
3. **Dimensions 1 and 3 are interview decisions, not a pre-fill.** The
   problem/outcome from a stranger's standpoint (dimension 1) and the
   kernel/overlay routing call (dimension 3 — the stranger test in
   `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule) are
   **root-level nodes of the design tree**, reached in round 1 and answered
   by the operator — never drafted here and confirmed.
4. **Probe-before-create the brief note** — the brief-side mirror of Step
   5b.3's epic probe, so a re-run (including one crashed mid-phase) never
   clobbers an existing brief, **and so a killed or ratified idea
   short-circuits here before the premise gate (item 5) could re-litigate
   it**. Runs **ahead of** the interview, so the gate's dimension-0 write
   and any drop action always target a note already on disk. Check whether
   the item-2 path already exists in the knowledge store; if it does,
   branch on its frontmatter `status`: <!-- cite: W.5 incident:K#509 -->
   - **`draft`** → adopt it and **resume where the note itself shows**, read
     from the note alone, never from memory. A **tagged** `round N pending
     (ratio-gate):` line under `### Interview calls` is Phase 2's ratio-gate
     round (3.6.4) — resume at **Step 3.6**, never at the interview, whose
     § Resume would discard the finished panel and congruence work; a plain
     `round N pending:` line is Phase 1's — hand the note back to the
     interview, whose § Resume owns that
     recovery; otherwise resume at **Step 2** when the record carries no
     `delta` stop line, or at **Step 3.7** from the dimension after the
     last `delta` line when it does. The premise gate already ran on the
     pass that created this draft, so it is **not** re-run on a plain adopt
     and `--first-question` is omitted from any resumed interview call.
   - **`ratified`** → **stop.** A ratified brief is immutable
     (`claude/design-schema.md` § Frontmatter); never edit it in place. If
     the design has genuinely changed, author a **new** brief under a new
     title that supersedes it via `[[wikilink]]`; if it hasn't, the right
     move is Step 5 (materialize) against the ratified brief, not a new
     run.
   - **`dropped`** → **stop.** A `dropped` brief is a **killed idea** —
     Step 1.3b's drop action flipped it, and its dimension 0 carries the
     kill rationale. **Never take the silent `draft`-adopt path here**:
     reopening requires an **explicit operator confirmation** — offer an
     `AskUserQuestion` (reopen this dropped brief, or leave it killed).
     Absent an explicit "reopen", **stop**, so a later run on the same title
     never silently un-kills an idea the operator already rejected. Only on
     "reopen" does the run resume: flip `status: dropped → draft` and bump
     `last_verified`, using Step 4.4's full-file-rewrite/read-back
     discipline (never a `vault_patch` frontmatter `replace` — same silent-
     drop risk). Then resume at item 5 with a freshly composed premise gate.

   Only when no note exists: **create it**, `status: draft`, per
   `claude/design-schema.md`'s frontmatter shape (`tags`, `date`,
   `status: draft`, `source_kind: claude-stamped`, `source_session`,
   `source_model`, `last_verified`) **plus the record-grammar stamp**:

   ```
   record_grammar: delta
   ```

   Every brief this command authors carries it: it is what puts the brief
   under `claude/design-schema.md` § Record completeness's per-dimension
   `delta` bar (Step 4.1c) instead of the legacy exemption, and what makes
   Phase 1's `interview` stop lines legal rather than a
   `RECORD-GRAMMAR-UNSTAMPED` defect. Write it once, at creation, never
   edit it after. Give the note dimension 0's `## 0. Premise & null
   hypothesis` section as the landing place the premise gate (item 5)
   fills, then hand the path to the interview as `--into` — the interview
   **adopts** an existing note (`interview.md` Step 1.5) rather than
   creating its own `Context/` shape, which is why the `Designs/` brief is
   created here first.
5. **Execute the interview.** Read `claude/commands/interview.md` and run
   its steps inline with this parameter block — the three names are a
   frozen surface (`claude/presentation-plane.md` § Kernel table), so pass
   them exactly as spelled:

   - **`--into`** — the item-2 path, the note item 4 created or adopted.
   - **`--first-question`** — **Step 1.3b, the premise gate**, now asked as <!-- cite: W.6 incident:K#509 -->
     **Q1 of round 1** rather than as a modal stop of its own (it keeps the
     stable cross-reference name `1.3b` other specs cite). Compose the case
     *against* this design existing at all — the content of **dimension 0**
     in `claude/design-schema.md` § Kernel dimension list, the schema's one
     **`filled`-only** dimension — from the null hypothesis "this design
     should not exist", stating the **do-nothing cost** (what actually
     breaks if this is never built), the **strongest subtraction
     alternative** (the smallest existing surface — a rule, a gate, a doc,
     a habit — that could absorb the need with no new mechanism), and
     **existing-surface coverage** (which current mechanism already covers
     part or all of this). Argue each point **citing `docs/principles.md`
     by principle name** — most directly the **stranger test** (principle
     13), **subtraction over mechanism** (principle 8) and
     **minimum-viable-output** (principle 14); a case-against that names no
     principle is not composed. Compose it **fresh for THIS brief every
     time**, never reusing a premise from a prior brief — a recycled
     justification defeats the gate, whose whole point is that this idea
     earned its own place. The block carries that case in plain language
     and three options, the **recommended verdict first**:
     - **`proceed`** — the premise holds. The operator's answer (the
       option's own reasoning, or their verbatim words via `Other`) is the
       justification; the interview records it as `D1` and Step 2 writes it
       into `## 0. Premise & null hypothesis` at disposition `filled`.
     - **`reshape`** — the framing is wrong but the idea isn't dead, and
       this is **not** a terminating answer: the operator restates the
       framing in their own words, the interview records that as `D1` and
       recomputes the design tree from it in the same round
       (`interview.md` Step 2.7), so round 2's frontier is the reshaped
       design's. Persist a one-line `premise-gate: reshaped once` marker
       into `## Working notes` in that round's persist and **never offer
       `reshape` again this pass** — a re-composed gate offers `proceed` /
       `drop` only, so a framing that still fails resolves either way,
       never in a third loop.
     - **`drop`** — the case-against wins; the idea is killed. This option
       carries a **terminating `then:`** naming the **drop action**
       (`interview.md` § Parameters): the interview persists that one
       decision and returns immediately, and this command performs the drop
       as a **single full-file rewrite** (Step 4.4's discipline — never a
       `vault_patch` frontmatter `replace`, same silent-drop risk) that
       sets the frontmatter to **`status: dropped`**
       (`claude/design-schema.md` § Frontmatter), writes dimension 0's
       `## 0.` section with the kill rationale (disposition `filled` — the
       justification, stated in the negative), and bumps `last_verified`.
       Then **stop the command**: a dropped brief is neither ratified nor
       materialized; it stands as the durable record that this idea was
       considered and killed, so a later run on the same title sees the
       kill at item 4's `dropped` branch rather than re-litigating it.
   - **`--check-questions`** — one question, appended to the understanding
     check: **the review tier**, priced before it is picked. <!-- cite: W.9 class:unpriced-speculative-review-spend -->
     State the cost *inside the block*, in **model tiers** and a **token
     order-of-magnitude**, never as a bare label: **brief pass** = two
     standing lenses (`architecture-reviewer`, `requirements-auditor`)
     once each — two mechanical-tier runs, tens of thousands of tokens;
     **full pass** = those two **plus** a red-team lens, a persona pass and
     (when 3.2 applies) an executed first-run/uninstall run — of order
     eight runs, one at the judgment tier, hundreds of thousands of tokens
     and roughly ten minutes of Phase 2 wall-clock. This is the adapted
     Shape Up "appetite" move: the budgeted resource is review
     effort/tokens, and the tier is a quantized review-cost appetite, not a
     time estimate (`Context/temperloop - design methodology spike
     verdict.md` § 6). Naming the cost **before** the pick is the point —
     never spawn a reviewer speculatively while the pick is still open —
     with the availability caveat in the same breath: each lens runs only
     if it passes 3.3's capability probe, so a checkout missing a declared
     agent reduces part of a full pass to legible skip lines. Suggest a
     default from the design's apparent weight (single-file and
     low-blast-radius suggests brief; touching the install surface, adding
     a command, or reshaping a contract surface suggests full); the
     operator overrides it regardless. The answer is durable in the check
     call's working-notes entry (`interview.md` § Output), where Step 3.1
     reads it after a crash.

   **Dimension 4 is the last question by construction, not by a fourth
   parameter.** When the tree is built (`interview.md` Step 1.4), make the
   Contract — dimension 4's `Produces` / `Consumes` / `Acceptance` — a node
   whose prerequisites are **every other decision**, so the frontier
   reaches it last: the final question of the final round, derived from the
   decisions already taken, never asked cold. Write the actual contract
   text, not a summary of one; Step 5 copies it **verbatim** into the
   epic's `## Contract`, and `/assess`'s epic-decomposition mode must
   decompose `Produces` with zero changes (§ Materialization contract).

   The whole of Phase 1 is `AskUserQuestion` calls of at most **≤4**
   questions each, the recommended option first, the next call opening in
   the same turn as the previous answer, one persist per **round** — no
   per-dimension stop, no proposal splitting the dimensions into tiers, and
   no fixed round count; more rounds mean more refinement, not overrun.

6. **Phase 1 returns** the note path, the `--first-question` answer, the
   `--check-questions` answer (the review tier), and the run tally
   (`interview.md` Step 4). Step 3.1 reads the tier and Step 6 folds in the
   tally; continue at Step 2 in the same session.

## Step 2 — Phase 2a: dimension expansion

Phase 2 opens here and runs **foreground and unattended** — no operator gate
between this step and Step 3.7's delta report, except the ratio-gate round
(3.6) when it fires. Narrate one line per stage so the wait is legible.

1. Read `claude/design-schema.md` § Kernel dimension list, plus any
   overlay-added dimensions from `claude/design-schema.overlay.md` if this
   checkout carries one (letter-suffixed, e.g. `16a`, per that file's
   § Overlay extensibility — add-only; a kernel-only checkout like this one
   has none). **The expansion's size is that list as it stands, never a
   count cached here.**
2. **Expand every dimension into the brief body,** in the schema's order,
   from Phase 1's `## Shared understanding` section. A dimension one or
   more `D<n>` decisions touch is written **from those decisions**, naming
   them inline (`from D3, D7`) so the delta report can render it as
   unchanged-since-the-interview. Record, for each dimension, **exactly
   one** of the three dispositions defined in `claude/design-schema.md`
   § Disposition grammar, quoted here verbatim (this command applies the
   grammar; it does not restate a variant of it):

   ```
   filled                         — the dimension is answered in the brief body
   n/a — <reason>                 — genuinely inapplicable to this design, with the reason stated
   deferred → <tracking ref>      — real but out of scope for this brief; ref is an issue/epic that owns it
   ```

   Dimension 0 is `filled`-only — its content is the premise gate's
   case-against and the operator's answer to it (Step 1.5). Dimension 4 is
   the Contract the interview confirmed, copied forward as written.
3. **A dimension no decision reached is drafted and flagged.** Draft it
   honestly — the facilitator's best call, not a placeholder — and mark its
   provenance with the schema's flag line, `_facilitator-drafted, not from
   interview_`, written **immediately after the disposition line and before
   any body prose** (`claude/design-schema.md` § Disposition grammar owns
   that placement: the lint reads the first non-blank line under a heading
   as the disposition, so a flag ahead of it is misread as a malformed
   disposition value). The flag makes the interview's coverage gap
   **visible** rather than assumed away — it drives Step 3.7's rendering
   rule and is the numerator of Step 3.6's ratio gate and a Step 6 tally
   field.
4. **Persist as you go.** Write each dimension's content into the brief note
   as it is expanded, not in one end-of-phase rewrite, so a crash loses at
   most the dimension in flight. By backend:
   - **Obsidian-backed store:** a small append/patch per dimension (the vault's
     write-small convention), falling back to a full-file rewrite whenever a
     heading path isn't safely `vault_patch`-able (the safe-targeting contract).
   - **Plain-files store:** the backend has **no mid-file patch primitive** —
     only `ks_write` (whole-file replace) and `ks_append` (end-of-file). A
     dimension that lands **mid-file** (the numbered sections, whose order
     is the schema's) is therefore a **full-file rewrite via `ks_write`**
     (read → modify in memory → write): a per-dimension `ks_append` would
     land out of order and corrupt the note's numbered-section structure.
     Content that is genuinely **append-only at the end of the note** — a
     `## Working notes` stop line, a coverage-record line, an
     `### Interview calls` entry — may instead use a **targeted
     `ks_append`**, one call rather than a rewrite that grows with the
     note. The crash guarantee is unchanged either way because it comes
     from the **read-back**, not the write's width: every write, targeted
     or whole-file, is confirmed by re-reading the note and finding the
     slice it carried, under one retry, before anything else happens.
5. **Then validate the brief, and fix before continuing.** Run
   `workflows/scripts/validate-design-brief.sh --brief <path>` and resolve
   every failure before Step 3 spawns a single reviewer. This is a real
   gate: on the 2026-09-12 prototype the brief failed 18 checks at exactly
   this point and only the panel caught it — spending panel tokens on a
   brief the lint would have rejected is the waste this ordering removes.
   If the script is absent from this checkout, say so on one line per
   `claude/message-schema.md`'s **Degradation notice** template and check
   the same invariants by hand (one disposition per dimension, dimension 0
   `filled`, the flag line's placement) — never a silent skip.

   **Structure note — provisional, do not cite Double Diamond.** The <!-- cite: W.16 incident:K#224 -->
   expansion above is a **convergent inspection checklist**: a fixed
   dimension list in a default order, each dimension dispositioned against
   decisions already taken, with no divergent/alternatives-generation phase
   (a dimension's alternatives part reports alternatives already weighed in
   Phase 1; it generates none). Double Diamond's diverge-then-converge
   framing was evaluated against this pass and **rejected**
   (`Context/temperloop - design methodology spike verdict.md`) — never
   cite it for this command's structure. Whether to *add* a bounded
   alternatives-generation moment is still open — **provisional — pending
   temperloop#224**.

## Step 3 — Phase 2b–2d: review pass

Runs after Step 2's expansion completes (every dimension carries a
disposition and the brief validates clean), and before Step 3.5's
congruence pass. Four parts, in order: **3.1** tier decision, answered in
Phase 1 and stated before any reviewer is spawned; **3.2** the
install-surface first-run/uninstall mandate; **3.3** capability-probed
adversarial panel execution; **3.4** findings fold-back. A brief that skips
this step never reaches ratify — Step 4.1b re-checks that every finding it
produced was actually disposed of.

### 3.1 — Tier decision (priced in Phase 1, applied here)

1. **The tier is already chosen — read it, don't re-ask.** Phase 1's
   understanding check carried the review-tier question as its
   `--check-questions` block, priced before the pick (Step 1.5). Take the
   answer from Step 1.6's return, or — after a crash — from the check
   call's working-notes entry under `### Interview calls`, its durable
   record (`interview.md` § Output). **Never re-ask it here**: a second ask
   spends an operator turn on a decision already taken and invites a
   different answer than the one the brief's provenance records.
2. **State which tier is running, and what it costs, before spawning.**
   One line naming the tier, the lenses it implies, and the availability
   caveat. The red-team lens (`claude/agents/red-team-lens.md`,
   temperloop#510) and the persona lenses (`design-persona-agents`,
   temperloop#221) both ship as declared agents under `claude/agents/`, so
   a full pass runs live here subject to the normal capability probe.
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
   `skipped — <agent> unavailable` reason) — the live narration of a skip
   (3.3.2) is not enough on its own, since without the persisted record a
   brief whose entire panel skipped is indistinguishable from a
   fully-reviewed one.

   **One coverage record, every lens in it — 3.3's panel and 3.5's
   congruence lens alike.** Extend this same line again when 3.5 completes,
   recording whether `congruence-lens` ran (and with how many flags) or was
   skipped, in the form item 1a selects — its absence is the easiest of all
   to mistake for a clean bill of health.

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
   license calling the run itself "a cognitive walkthrough": an agent
   actually executing install/uninstall in a worktree is empirical
   first-use observation, which the literature rates *above* inspection,
   not an instance of it (`Context/temperloop - design methodology spike
   verdict.md` § 1). Never describe the run as a cognitive walkthrough in a
   brief or Decisions note.
3. **This file specifies the mandate, not the executor.** The agent that
   actually performs a fresh clone → install → report-friction → uninstall
   → diff-residue run is `design-persona-agents` (temperloop#221), scoped
   separately because it's parameterized by the customer archetypes the
   audience page (K136) defines — content this file must not invent.
   `claude/agents/hobbyist-persona.md`, `consultant-persona.md`, and
   `team-member-persona.md` each declare an EXECUTING mode for exactly this
   run. Whenever the mandate applies but no such executing agent is
   declared in a given checkout, this degrades like any other capability
   probe (3.3): a legible skip line — the shipped-but-not-installed form
   per § 3.3 item 1a — stamped into dimension 15 (failure modes /
   capability limits) as an honest gap, **never** a silent pass or treated
   as satisfying the mandate. A ratified brief with this gap stamped is
   still ratifiable (Step 4 blocks on undispositioned dimensions, not on an
   unavailable capability); a ratified brief with the mandate silently
   unmet is not.

### 3.3 — Capability-probed adversarial panel

1. **Availability predicate — run the helper, don't eyeball the surfaces.**
   A review subagent is available iff this project declares it in
   `CLAUDE.md § Subagents` or `.claude/agents/`
   ([[Decisions/foundation - Project capability probes]]) — the same
   predicate `/assess` Step 3 and `/triage` Step 3 apply to their own
   panels. **Evaluate it mechanically**, by sourcing
   `workflows/scripts/lib/agent_declared.sh` and reading
   `agent_declared_state <lens>`, which prints exactly one of `installed`,
   `source-only`, or `absent` (ADR 0029,
   `docs/adr/0029-agent-declared-probe.md`). `installed` is the spawn gate;
   the other two select the two skip-line forms in 1a, one each. Reading
   the predicate's two named surfaces *literally* is what temperloop#1462
   caught: on the kernel's own checkout `.claude/agents/` is gitignored and
   `CLAUDE.md` carries no `## Subagents` heading, yet every lens is
   installed at `$HOME/.claude/agents/` — so an eyeballed probe skipped the
   whole panel while every lens would have spawned fine. A skip line that
   fires for an *available* lens is a review that silently didn't happen,
   which is worse than the panel not existing. Probe each candidate lens
   right before it would be spawned; absence is never fatal to the run.
1a. **Two skip-line forms — the single definition every later mention below <!-- cite: W.11 incident:K#290 -->
   defers to.** When the state is not `installed`, the skip line takes one
   of two forms per `claude/message-schema.md` § Degradation notice (the
   contract home; kernel wording owner is `CLAUDE.kernel.md` § Legible
   agent-gate degradation). The state from item 1 *selects* the form —
   distinguish *why* before emitting it, and take the answer from the
   helper rather than re-deriving it:
   - **Not shipped** (`absent`) — no `claude/agents/<agent>.md` source file
     exists in this checkout. Nothing to install → bare
     `skipped — <agent> unavailable`.
   - **Shipped but not installed** (`source-only`) — a
     `claude/agents/<agent>.md` source file *does* exist but the lens isn't
     resolvable live (no `.claude/agents/<agent>.md`, no
     `$HOME/.claude/agents/<agent>.md`, no `CLAUDE.md § Subagents`
     declaration) → the remedy-bearing form `skipped — <agent> available as
     source; run workflows/scripts/install/project-agents.sh to enable`
     (temperloop#290).
     This is the recurring fresh-standalone-clone case — every lens ships as
     source under `claude/agents/` but no live `.claude/` exists yet — so the
     operator sees the one-command fix on the live line, not a bare dead-end.
     Note it is **not** the kernel maintainer's own case: a host with the
     lenses installed at `$HOME/.claude/agents/` reads `installed`, and
     emitting this line there would be the temperloop#1462 false negative.
   Every other reference to `skipped — <agent> unavailable` in this file —
   before or after this item, including the § 3.2 persona-agent skip — is
   shorthand for whichever of these two forms the probe selects; the skip is
   never silent either way.
2. **Brief pass (always).** Probe `architecture-reviewer` and
   `requirements-auditor`. For each available, spawn it read-only and
   advisory with the brief's per-dimension content and its own charter:
   `architecture-reviewer` judges dimensions 1, 3, 5, 7, 10 (problem/outcome
   incl. the stranger-test call, routing, command shape, maintainability
   coupling, upgrade path); `requirements-auditor` judges dimensions 4, 8,
   15 (Contract seams, testability, failure modes — the same
   requirements-sanity charter it applies in `/assess` Step 3). This
   design-time pass reviews the *brief* and is distinct from — not a
   substitute for — `workflow-reviewer`'s standing post-merge review of any
   resulting command spec (`claude/design-schema.md`'s Enforcing-gate
   column ties dimensions 5 and 15 to `workflow-reviewer` for exactly that
   reason). Each unavailable lens emits its own skip line — the not-shipped
   vs shipped-but-not-installed form per 1a — narrated live, never silently
   absorbed into a generic "review skipped" note.
3. **Full pass adds** (only when 3.1 picked full): a **red-team lens** —
   an adversarial charter that attacks the brief's stated acceptance
   criteria (dimension 4), threat model / premortem (dimension 15), and
   **premise justification (dimension 0)** directly — surfacing where they
   are weak, unfalsifiable, circular, or where the premise's case-against
   was not honestly engaged. Its **authoritative charter is
   `claude/agents/red-team-lens.md`** (temperloop#510), which also states
   the mandatory rule that every finding cites a named principle from
   `docs/principles.md` (an uncited finding is discardable on sight). Full
   pass also adds a **persona pass**: the opining half of the
   customer-archetype agents (§ 2 of the ratified brief), critiquing the
   brief from each declared archetype's value set —
   `claude/agents/hobbyist-persona.md`, `consultant-persona.md`,
   `team-member-persona.md` (`design-persona-agents`, temperloop#221). Both
   the red-team lens and the persona pass follow the same predicate as
   3.3.1 (each degrades to its own skip line only in a checkout where its
   agent isn't declared). 3.2's executed first-run also runs here when its
   mandate applies.
4. **Independent passes, aggregated after.** Every spawned lens sees only
   the brief — never another lens's findings — until 3.4 aggregates them.
   This adapts heuristic evaluation's independent-evaluator structure
   (Nielsen & Molich, CHI 1990) for the panel's *shape only*: **provisional
   — pending temperloop#225** — same-model lenses do not carry the
   independent-human-evaluator priors that literature's coverage/yield
   numbers were measured for, so this file claims only the structure (spawn
   independently, aggregate after) and makes no coverage or
   diminishing-returns claim (`Context/temperloop - design methodology
   spike verdict.md` § 2). Do not cite a numeric finding from that
   literature in a brief or Decisions note produced by this step.

### 3.4 — Findings fold-back (before ratify)

1. **Collect.** Gather every spawned lens's findings, each tagged to the
   dimension(s) it concerns.
2. **Apply clear wins directly.** A finding that clearly improves a
   dimension's content — no judgment call, no disagreement with the
   brief's existing stance — is folded into that dimension's body **now**,
   using Step 2.4's write primitive for this backend. A finding that
   surfaces a real gap the operator chooses not to resolve now converts
   that dimension's disposition to `deferred → <tracking ref>` rather than
   leaving it `filled` with an unaddressed critique.
   **Dimension-0 carve-out.** A finding on **dimension 0** (Premise & <!-- cite: W.13 guard:claude/design-schema.md -->
   null hypothesis — the red-team lens's sharpest target) is the one
   exception: dimension 0 is `filled`-only (`claude/design-schema.md`
   § Disposition grammar), so an unresolved dimension-0 finding may
   **never** convert to `deferred`. It resolves one of two ways — a real
   fix folded into the premise justification now (`folded`), or an
   explicit decline that leaves dimension 0 `filled` (noted per item 4's
   decline vocabulary). If the premise gap is serious enough that
   dimension 0 cannot honestly stay `filled`, route back to the premise
   gate (Step 1.3b) or decline-and-stay-`draft` — never mint an invalid
   `deferred` disposition the schema declares impossible.
3. **Carry contested findings to the delta report — don't ask here.** A
   finding the brief's stance disagrees with is not applied silently, and
   it is also **not** put to the operator at this point: Phase 2 has no
   gate between 3.1 and 3.7 by design. Instead attach it to its
   dimension(s) as a **contest marker** — the lens's name, the claim, and
   the brief's counter-stance, each in one line — which Step 3.7 renders
   inside that dimension's delta and inside the cluster question's own
   block, so the operator decides it **in context**, next to the text it
   concerns, rather than as a context-free interrupt mid-panel. (Clear win
   vs. contested is the same split `/assess` Step 3 makes for its own
   review pass; only *when* the contested half is asked differs.) A
   contest marker the operator resolves at 3.7 is disposed there under
   item 4's vocabulary, exactly as if it had been asked here.
4. **No dangling findings.** Every finding from 3.3 is either folded in, <!-- cite: W.12 class:silently-dropped-review-findings -->
   converted to a `deferred` disposition with a real tracking ref, or
   explicitly declined by the operator with the decline noted in the
   brief's working notes — never left as an unincorporated comment outside
   the brief. Record each finding's disposal (`folded` / `deferred → <ref>`
   / `declined — <note>`) against the coverage record 3.1.4 keeps: that
   record is what Step 4.1b mechanically re-checks, so a forgotten finding
   blocks ratify rather than evaporating (dimension-level completeness
   alone can't catch it — every dimension already carried a disposition
   before the panel ran).
5. **Only then does Step 3.5 run.** This step does not re-open Step 2's
   expansion or re-litigate the tier picked in 3.1 — it is strictly the
   apply-findings-then-proceed step between review and the congruence pass.
## Step 3.5 — Congruence pass

Runs once Step 3.4 has settled every finding, before Step 3.6. Per-dimension
completeness is not congruence: a brief can carry a valid disposition on
every dimension and still contradict itself *across* two of them —
dimension 4 promising an Acceptance check dimension 8 says is manual-only.
Two parts: the seam checklist (item 1) and the cold-read lens (item 2).
Both run unattended; what they surface reaches the operator in Step 3.7's
delta report, quoted against the dimensions it concerns.

1. **Run the congruence seam checklist.** Work the named-minimum seam table
   in `claude/design-schema.md` § Congruence seams — that section owns the
   seams, what must agree at each, and its floor-not-ceiling extension
   rule. **Apply it by reference; never restate the table here**, the same
   discipline Step 2.2 applies to the disposition grammar. The checklist is
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
     remains the only independent reviewer here.
   - **Unavailable is expected, and it takes the remedy-bearing form.**
     `congruence-lens` **ships as source** under `claude/agents/`, so a
     checkout where it isn't resolvable live is the shipped-but-not-
     installed case item 1a defines, and its skip line is that variant
     verbatim: `skipped — congruence-lens available as source; run
     workflows/scripts/install/project-agents.sh to enable`. Narrate it
     live, **stamp it into the 3.1.4 coverage record**, and name what was
     lost: items 1 and 3 both still run, so the pass degrades rather than
     collapses, but the fresh-context cross-check is gone.
   - **Its flags are findings, disposed under the existing vocabulary.** <!-- cite: W.17 class:parallel-finding-ledger -->
     Every flag this lens raises — and every seam item 1 flagged — enters
     3.4's disposal path and is recorded against the **same** 3.1.4
     coverage record under the **same** three-way vocabulary (`folded` /
     `deferred → <ref>` / `declined — <note>`) 3.4.4 already owns. Neither
     these flags nor Step 3.7's `delta` verdicts open a second disposal
     ledger: Step 4.1b re-checks one record.
3. **Then Step 3.6 runs.** What this step guarantees is that by the time
   the delta report is rendered, every cross-dimension seam has been worked
   and every flag it raised is attached to the dimension it concerns.

## Step 3.6 — Facilitator-drafted ratio gate

The interview cannot guarantee coverage; Step 2.3's flag makes the
shortfall visible, and this step is what the command *does* about it.

1. **Compute the ratio.** Flagged `_facilitator-drafted, not from
   interview_` dimensions ÷ every dimension in Step 2.1's list. State it on
   one line whether or not the gate fires — it is a Step 6 tally field
   either way.
2. **Fires above half.** If **more than 50%** are facilitator-drafted, run
   **one targeted interview round** before the delta report: a single
   `AskUserQuestion` call of at most **≤4** questions, composed exactly
   like any interview round (`claude/commands/interview.md` Step 2.3 — the
   decision in plain terms, two to four options with the recommended one
   first, `Other` carrying the operator's own words, no
   acknowledgement-only question), on the **highest-value undiscussed
   decisions** the drafted dimensions had to guess at. At or below 50%,
   skip it and say so on one line.
3. **The panel's contested findings ride the same call.** A contest marker
   from 3.4.3 that is a genuine *decision* — not a wording fix — is asked
   here as one of the round's questions, so one call resolves both the
   coverage gap and the contest. Markers left over stay attached to their
   dimension and are decided at 3.7.
4. **Record it as an interview round, then re-expand.** Persist it exactly
   as Phase 1 persists a round (`interview.md` Step 2.6): `D<n>` bullets
   continuing the existing numbering, an `### Interview record` line, and
   `interview`-kind stop lines under `### Challenge record` with
   `source: operator` — with one difference: its write-ahead pre-call line
   (2.4) is **tagged**, `round N pending (ratio-gate): call k — Q1 "<text>";
   …`, and no other round is, so the interview's own § Resume parse is
   untouched. 3.6 runs *before* 3.7, so a crash here leaves no `delta` line to
   tell it from a Phase-1 crash; the tag is what makes Step 1.4's recovery
   branch syntactic, resuming **here** rather than at `interview.md` § Resume,
   which would restart Phase 2 at Step 2 and discard the finished panel,
   fold-back and congruence work. Then rewrite each dimension the answers
   touched, **remove its facilitator-drafted flag** — it is no longer drafted
   — and re-run `validate-design-brief.sh --brief` (Step 2.5) before
   continuing.
5. **Exactly once per run.** A ratio still above half afterwards is a
   *reported* number, not a second round: coverage the operator declines to
   close is a legitimate outcome, the flags stand in the brief and in 3.7's
   rendering, and the ratify ask is where the brief is accepted or refused
   on those terms.

## Step 3.7 — Delta report (the Phase 2 operator gate)

The single gate Phase 2 has. Everything the panel, the fold-back, the
congruence pass and the ratio gate changed comes back to the operator here,
in chat, in about **two chunks**, with one verdict per dimension.

1. **Chunk the report.** Roughly two chunks — dimensions 0–7, then 8–16
   (overlay-added dimensions ride the chunk their number falls in). Two is
   a shape, not a constant: a brief whose changes cluster may use three,
   and the boundary moves rather than splitting one cluster question's
   dimensions across two calls.
2. **The rendering rule — what each dimension shows.** The report's length
   must track what actually needs reading, and the failure runs both ways:
   a report of gists is as context-free as the walkthrough it replaced, and
   a report of everything at full length goes unread.
   - **A dimension the panel changed, or one flagged
     `_facilitator-drafted, not from interview_`** → its disposition, its
     **full current text**, its deltas as explicit **before/after**, its
     flag, and any contest marker from 3.4.3 or congruence flag from 3.5,
     quoted against it.
   - **An interview-derived dimension the panel left untouched** → the
     decision it came from (`unchanged from D7`) and a **two-line gist**,
     with the full text still present **below a fold** — one expansion
     away, never absent.
   The **Decision presentation** template's plain-language rule
   (`claude/message-schema.md`) governs the gists and the deltas: a
   spec-internal reference, a slug, a dimension number or an issue ref is
   explained inline at its point of use, and the rule does not lapse
   because the phase is called a report.
3. **After each chunk, one `AskUserQuestion` call of at most ≤4 cluster
   questions** — accept, or contest via `Other` in the operator's own
   words. **Each cluster question carries its dimensions' Δ inside the
   question body and the option descriptions**, never only in the chat
   above it. This is the rule **risk R1** fired on — R1 being this design's own
   first premortem risk (`R<n>` is how `claude/design-schema.md` § `### Risks`
   numbers them; ADR 0035 records this one): that the report's questions reach
   the operator with no context inside the block. The prototype's own
   operator-outcome answer was that "the last several questions about
   dimensions had no context visible", because the report sat in chat while
   the block held one-line summaries (`claude/CLAUDE.kernel.md`
   § Communication conventions — load-bearing context goes inside the
   question). **If a cluster's Δ does not fit the block, the cluster is
   smaller — never the Δ.**
   - **Individually listed, individually verdicted.** Clustering compresses <!-- cite: W.18 class:cluster-collapsed-verdicts -->
     the *asking* only — never the showing, never the verdicting. A cluster
     question names each of its dimensions on its own line and yields **one
     verdict per dimension in it**: N verdicts, never one collapsed cluster
     verdict. That is what stops a load-bearing dimension batched in with
     three mechanical ones from reaching ratify without a look of its own.
   - **Persist-then-ask applies unchanged** (§ Operating principles): a
     chunk's question opens only over content already written into the
     note, read-back-confirmed, *and* rendered in chat.
4. **Contest → revise → re-present, with a soft checkpoint on the third.**
   A contested dimension is revised from the operator's words and its chunk
   re-presented, naming what changed. A dimension re-presents freely twice;
   **on the third the same call carries one extra question** — *accept
   as-is* / *defer to a tracking ref* / *park the brief* / *keep going* —
   with the **lens re-run cost so far** stated in the block (which lenses
   have re-run, at which tiers, roughly what that spent). It is a
   **checkpoint, not a bound**: `keep going` is always available and never
   forces an exit, and no round cap exists anywhere in this command.
   *Defer* is open to any non-premise dimension provided the ref names a
   real, open item (§ Congruence seams' `deferred-refs-resolve` seam checks
   that); **dimension 0 is excluded** — `filled` is its only legal
   disposition, so a premise the operator can no longer accept routes back
   to the premise gate (Step 1.3b) or leaves the brief `draft`.
5. **One `delta` line per dimension.** As each chunk's verdicts land, append
   the brief's `## Working notes` → `### Challenge record` per
   `claude/design-schema.md` § Challenge record — that section owns the
   line shape, verdict vocabulary, clustering rule and record-start marker,
   applied by reference and never re-copied here. What this step owes it:
   - **`kind` is `delta` and `source` is the literal `operator`** at every
     verdict here. Never `walkthrough`: that kind's source is a review
     lens, so a lens line would satisfy the operator gate and it would fail
     open.
   - **A cluster carries one verdict per dimension** — N lines or one
     clustered `dim-list`, but a mixed cluster splits into as many lines as
     it has distinct verdicts.
   - **An `operator-edited` verdict carries the operator's verbatim words**
     in its `response:` field, never a facilitator paraphrase.
   - **The first `delta` line also writes the `challenge-record-start:
     <today>` marker** when no `### Challenge record` subheading exists yet
     — in the *same* write, never ahead of it, so the record is never
     announced-but-empty.
6. **Then Step 4 runs**, once every dimension carries a `delta` verdict and
   every contest marker is resolved or deferred.

## Step 4 — Ratify

1. **Completeness check.** Confirm every dimension — every kernel dimension
   plus any overlay additions expanded in Step 2, including any disposition
   Step 3.4 converted to `deferred` during fold-back — carries exactly one
   disposition. List any gap and stop; do not proceed to ratify a brief with
   an undispositioned dimension. This is the enforcement point
   `claude/design-schema.md` § Disposition grammar's "No-silent-skips rule"
   names as living here, also mechanically checked on demand by
   `workflows/scripts/validate-design-brief.sh --brief` (temperloop#216) —
   Step 3's review tier existing does not relax this check; it only adds a
   source of new dispositions for it to catch. One per-dimension invariant
   the shipped lint does not yet special-case: **dimension 0's only legal
   disposition is `filled`** (`n/a` and `deferred` are both invalid for it),
   so a dimension 0 carrying `deferred` (e.g. from a mishandled fold-back)
   is a gap here, not a passing disposition.

   1b. **Finding-disposal check.** Dimension-level completeness alone
   cannot catch a dropped review finding — every dimension already carried
   a disposition when Step 2 ended, so a brief that silently dropped a
   finding still passes check 1. Re-check the coverage record in the
   brief's working notes (3.1.4): every finding each 3.3 lens returned
   **and every congruence flag 3.5 raised** — a flagged seam from 3.5.1, a
   contradiction from the 3.5.2 lens — must carry exactly one disposal:
   `folded`, `deferred → <tracking ref>`, or `declined — <note>` (3.4.4's
   vocabulary, which 3.5 reuses rather than parallels). List any finding
   without one and stop, same shape as check 1: return to Step 3.4 and
   dispose of it. A lens's `skipped — <agent> unavailable` entry satisfies
   this trivially (no findings to dispose); a lens that ran with zero
   findings records `no findings`, a clean checklist records its seams
   held.


   1c. **Challenge-record completeness check** (cross-referenced elsewhere
   as Step 4.1c). Runs immediately after 1b, before check 2, and gates the
   Ask (item 3 below). Re-read the brief's `### Challenge record` (working
   notes, 3.1.4) and apply `claude/design-schema.md` § Record
   completeness's two rules **by reference — never restated here**: that
   section is the single source of truth this check reuses, so the
   in-session gate and the shipped lint cannot diverge. It owns the
   **stamp-gated delta-completeness** predicate (rule 1 — keyed on the
   brief's own frontmatter `record_grammar` field, which Step 1.4 stamps
   `delta` on every brief this command authors), the verbatim-`response:`
   requirement (rule 2), and the `status:`-keyed exemptions bounding both.
   That same predicate is mechanically enforced by
   `workflows/scripts/validate-design-brief.sh`'s brief-conformance check
   (C), so a `--brief <path>` run **is** the cheapest way to evaluate 1c:
   its `MISSING-DELTA-VERDICT` and `RECORD-GRAMMAR-UNSTAMPED` codes name
   exactly the gaps this check blocks on, and its fixtures — not this file
   — pin the boundary cases. List any gap and stop, same shape as checks 1
   and 1b: return to Step 3.7 and complete the record before ratifying.
2. **Contract sanity.** Re-read dimension 4's `Produces` / `Consumes` /
   `Acceptance`. If it reads as a summary rather than an actual contract —
   the kind of content `/assess`'s epic-decomposition mode would need to
   reshape before it could decompose — send it back to Step 2 rather than
   ratifying a brief whose Contract isn't really `filled`.
3. **Ask — two questions, one call.** Confirm with the operator directly
   via `AskUserQuestion` (no `decision_sink_ask(...)` routing: this command
   has no operator-absent case to route around):
   - **Q1 — ratify this brief?**
   - **Q2 — the operator-outcome signal: "was any chunk of the delta report
     a rubber stamp?"** Ask it plainly, options `no` / `yes — <which
     chunk>`, and record the answer verbatim in Step 6's tally. This is the
     command's own falsification probe, not a satisfaction survey: a "yes"
     says the delta report has drifted back into the gist-approval failure
     it replaced. One "yes" sharpens the rendering rule (3.7.2). Beyond
     that it is **operator judgment, not a tracked threshold** — the
     answer is printed in the per-run tally, stored nowhere, and each run
     is a fresh session — so if *you* answer "yes" run after run, fall
     back to drafting the brief first and clarifying it afterwards.
4. **On approval:** flip the note's frontmatter `status: draft → ratified` <!-- cite: W.7 class:frontmatter-patch-silent-drop -->
   and update `last_verified`, via a **full-file rewrite** (`vault_write`,
   or the plain-files equivalent) — never a `vault_patch` frontmatter-scalar
   `replace`, which the vault safe-targeting contract documents as silently
   dropping the field and returning OK. Trust the flip only when written by
   that full-file rewrite (or confirm it with a read-back). A ratified
   brief is immutable from here: a later change is a **new** brief that
   supersedes it via `[[wikilink]]`, never an edit-in-place
   (`claude/design-schema.md` § Frontmatter).
5. **On decline:** stop. The brief stays `draft`; resume Phase 2 (Step 2) or
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
- If the pattern file isn't present in this checkout, skip with a legible
  degradation notice per `claude/message-schema.md`'s **Degradation
  notice** template: what was skipped, why, and the calibrated-trust
  statement (review the epic body yourself before it lands publicly).
  Never a silent skip.
- This scans the **epic body only**. The brief itself stays in the private
  knowledge store regardless of this repo's public/private status.

### 5b — Probe-before-create epic

1. Resolve `repo` from `--board`/`--project`, else the Step 0.4 inference. **If
   `gh` auth failed or no repo resolved at all** (Step 0.3), stop here — do
   **not** attempt epic creation. This is the minimum-viable-output floor:
   the brief is already ratified and persisted (Steps 1–4); only the epic
   and the final hand-off degrade. Skip the rest of 5b, still run 5c (each
   emitted ADR notes no epic exists yet) and 5d, and emit Step 5e's
   **degraded** hand-off line instead of the full one.
2. **Take the epic body composed and scanned in 5a** — do not re-compose it
   here; 5b writes exactly the content the leak-guard scan cleared, nothing
   else.
3. **Probe-before-create.** Search for an existing epic carrying this exact
   marker line before creating a new one:
   `gh issue list -R "$repo" --search "design-brief: [[Designs/<note>]] in:body" --state all`
   (or the `issue_marker_probe` helper,
   `workflows/scripts/lib/issue-marker-probe.sh`, when vendored — same
   corpus-first-then-live-fallback shape `/triage` Step 4 uses). **Found**
   → adopt it (the re-run path) — if the ratified brief's Contract changed
   since the epic was created, update the epic body to match, but never
   create a second epic for the same brief. **Not found** → `gh issue
   create -R "$repo" --title "<title>" --body "<body>"`.
4. **Board mirroring (best-effort).** If Step 0.4 resolved a registered board
   for `repo`, land the epic on it via the adapter (`board_create_on_board`,
   or `board_resolve` + a single add for the whole burst) — item state rides
   `fnd:`-namespaced labels, exactly as `/triage`'s epic creation behaves. No
   board registered → the epic still exists as a plain GitHub issue; note
   the skip in the Step 6 summary, don't treat it as a failure.

### 5c — ADR emission (best-effort, degrades legibly)

**Four artifacts, four different things — no content duplication.** <!-- cite: W.15 guard:docs/adr/0000-adr-process.md -->
`claude/design-schema.md` § Materialization contract names three: the brief
(private deliberation record, `Designs/` in the knowledge store), the epic
(operational tracker), and the Decisions note (personal capture, 5d below).
This sub-step adds a fourth: the **public decision record** — a draft ADR
under `docs/adr/`, immutable once later ratified to `Accepted` by a human
outside this command. Each of the four holds different content, never a
copy of another's: the brief carries the full deliberation (alternatives
considered, persona findings, rejected options); the ADR states the
decision plus its consequences, in ADR-0000's MADR-lite shape, at ADR
length; the Decisions note (5d) carries the operator's own personal
framing/rationale. Compose each ADR section fresh from the brief's
content; do not paste brief or Decisions-note prose into it verbatim.

1. **Identify architectural calls.** Walk the ratified brief's dispositioned
   dimensions for calls that pass the stranger test
   (`claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule, applied per
   `docs/adr/0000-adr-process.md` § "Routing rule: which decisions get an
   ADR, and which stay in the vault") — a decision a stranger's fresh clone
   of this kernel repo would need the rationale for. Dimension 3 (Alignment
   / routing) already ran this exact test at Step 1.3 and is the first
   place to look; dimensions 4, 5, 7, and 10 are the other likely sources
   wherever the brief commits to a specific architectural shape. A brief
   can make zero, one, or several such calls — a judgment call, not a fixed
   count.
2. **Degrade legibly when there's nothing to emit.** If `docs/adr/` doesn't
   exist in this checkout, or the walk in 5c.1 finds zero architectural
   calls, emit nothing and say so plainly per `claude/message-schema.md`'s
   Degradation notice template — never a silent skip.
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
     ratified brief").
   - `## Decision` — the call itself, stated plainly enough to act on
     without re-deriving it, per ADR-0000 § Decision.
   - `## Consequences` — what follows: benefits, costs, follow-on work,
     drawn from the brief's dimension 15 (failure modes) / dimension 16
     (adoption & enforcement) content where applicable.
   Register the `docs/adr/*` glob in both governance manifests ADR-0000 §
   Manifest registration names — `workflows/scripts/kernel/kernel-manifest.txt`
   and `docs/features/feature-manifest.txt` — if not already present
   (ordinarily a no-op after the first ADR, since the glob claims the whole
   directory once).
4. **Link back to the epic; link the epic forward to the ADRs.** Each
   emitted ADR's `## Context` already names the epic (5c.3). For the
   reverse direction, append a section to the epic body listing every
   emitted ADR's path, e.g. an `## ADRs` heading, via `gh issue edit`. **If
   5b degraded** (no epic exists), skip only this reverse-linking half —
   the ADRs still emit per 5c.3; note the skip in Step 6.
5. **Best-effort, like 5a/5b.** A failure in this sub-step is reported
   plainly in Step 6 and does not roll back 5a/5b or block 5d/5e.

### 5d — Decisions capture

Write a `Decisions/` note capturing the ratified design call, per
`claude/CLAUDE.kernel.md` § Decision capture (same frontmatter, same
`## Source` footer), cross-linking `[[wikilink]]`s both back to the brief
and forward to the epic (or, if 5b degraded, noting that no epic exists
yet). This is the third of the four artifacts named in 5c above, and it
runs **regardless of whether 5b succeeded**: a degraded materialize still
gets its Decisions note.

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
in Step 5c (path + number), or the degradation reason if none were; the
Decisions note path; the **per-run tally** below; and the Step 5e hand-off
line, verbatim, as the last line of the response.

**The per-run tally.** Computed from the persisted record — Phase 1's
`### Interview calls` entries (`interview.md` § Output) and Phase 2's own
chunk calls — never from memory, and reported in full whether or not the
numbers flatter the run. It is not a budget: more calls mean more context
and better alignment, so **count is reported, never capped**. Ten fields:

- **calls** — every `AskUserQuestion` call, Phase 1 and Phase 2 together.
- **questions, with each one's option count** — the shape of what was
  asked, not just how much.
- **decisions taken against the recommendation** (`chosen: alternative`) —
  the evidence that recommended-first is a proposal, not a nudge.
- **verbatim responses** (`chosen: other` and `chosen: free-text`).
- **acknowledgement-only questions — this must be `0`.** A question with
  fewer than two options and no free-text ask is acknowledgement-only, and
  the classification is mechanical from the persisted entry, never a
  judgment. A non-zero count is a defect in the run, reported as one: name
  which question. Baseline for contrast — the 2026-09-11 walk took 26 modal
  stops, 10 of them acknowledgement-only.
- **facilitator-drafted dimensions** — the count and ratio Step 3.6
  computed, plus whether the gate fired.
- **contested dimensions** — how many carried a contest marker into 3.7,
  and how each resolved.
- **chunk-accept latency** — the gap between consecutive call timestamps.
- **wall-clock, first question to ratify.**
- **the Step 4.3 Q2 answer, verbatim** — was any chunk a rubber stamp?

Dates and times render in the operator's display timezone, never UTC
(`claude/CLAUDE.kernel.md` § Communication conventions); the stored per-call
timestamps stay ISO-8601 UTC.

## Failure modes

Each mode is fully specified at its own step; this is an index, not a
restatement — follow the step reference for the actual handling.

- **Knowledge store or `design-schema.md` unreachable** (Step 0) → stop
  before any conversation starts.
- **`AskUserQuestion` unavailable** (a headless or `-p` run) → the
  interview stops at its own Step 0 and so does this command.
- **A round crashes mid-call** → the tag routes the recovery: a plain
  `round N pending:` line is Phase 1's, owned by
  `claude/commands/interview.md` § Resume; a `round N pending (ratio-gate):`
  line is Step 3.6's and resumes there (3.6.4). A re-run reaches both through
  Step 1.4's `draft` branch, which never re-runs the premise gate.
- **The brief fails `validate-design-brief.sh --brief` after expansion**
  (Step 2.5) → fix before spawning a reviewer; never spend panel tokens on
  a brief the lint would reject.
- **A dimension is undispositioned, or carries no `delta` verdict, at
  ratify time** (Step 4.1 / 4.1c) → block ratification, list the gaps, and
  return to Step 2 or Step 3.7 respectively.
- **`gh`/repo unavailable at materialize time** (Step 5b) → not a failure;
  the brief still ratifies, only the epic and hand-off degrade (Step 5e).
- **No board registered for the resolved repo** (Step 5b.4) → epic still
  created as a plain GitHub issue; note the skip. **No `docs/adr/`, or no
  architectural call** (Step 5c) → emit nothing, legible degradation.
- **Operator gated on drafted content with no persisted note behind it**
  (§ Operating principles, persist-then-ask) → forbidden; this is the
  temperloop#670 failure.
- **A reviewer, red-team lens, persona agent, or the congruence lens is
  unavailable** (Steps 3.2–3.3, 3.5.2) → expected under the capability-probe
  predicate ([[Decisions/foundation - Project capability probes]]); emit the
  per-lens skip line (§ 3.3 item 1a) and continue with whatever's available
  — see `docs/features/review-agents.md` § Installation for the remedy.
- **Dimension 4 reads as a summary, not a real contract** (Step 4.2) → send
  back to Step 2. **Leak-guard scan finds a hit** (Step 5a) → block
  materialization, the one non-best-effort check in Step 5.
- **Re-running `/workshop` (or just Step 5) against an already-ratified,
  already-materialized brief** → idempotent throughout (Step 5b.3 epic
  probe, 5d Decisions-note one-time-write check).
- **The operator declines to ratify** (Step 4.5) → stop; brief stays
  `draft`, nothing downstream runs.


## Cross-references

- Phase 1's callee, executed inline in this same session:
  `claude/commands/interview.md` — its § Invocation contract owns the
  never-a-subagent rule, its § Parameters the `--into` /
  `--first-question` / `--check-questions` block (a frozen surface in
  `claude/presentation-plane.md` § Kernel table).
- Peer front door: `claude/commands/triage.md` (discovered work; explicitly
  disclaims pre-designed epics). Consumer, unchanged:
  `claude/commands/assess.md`'s epic-decomposition mode.
- Template + grammar this command applies: `claude/design-schema.md`
  (Step 3.5 applies its § Congruence seams; Steps 3.7 and 4.1c apply its
  § Challenge record and § Record completeness by reference); cold-read
  lens charter: `claude/agents/congruence-lens.md`.
- The decisions this shape came from:
  `docs/adr/0035-workshop-is-an-interview-then-unattended-coverage.md` (two
  phases, two gates) and
  `docs/adr/0036-design-brief-record-operator-delta-lines.md` (the
  `delta`/`interview` record grammar).
- ADR process Step 5c conforms to: `docs/adr/0000-adr-process.md`
  (MADR-lite format, append-only numbering, kernel-public routing rule).
- Executing customer-persona agents: `design-persona-agents`,
  temperloop#221 — `claude/agents/hobbyist-persona.md`,
  `consultant-persona.md`, `team-member-persona.md`.
- Message templates used here: `claude/message-schema.md` § Question block
  (every gate in Phases 2 and 3), § Decision presentation (which fills that
  block's Context slot, and whose plain-language rule governs Step 3.7's
  gists and deltas) and § Degradation notice.
- Capability-probe predicate: [[Decisions/foundation - Project capability
  probes]] — the same predicate `/assess` and `/triage` Step 3 apply.
- Grounding: `Context/temperloop - design methodology spike verdict.md`
  (3.1's tier/appetite mapping, 3.2's executed-run rubric, 3.3's panel
  structure; Double Diamond is REJECTED there); the ratified brief behind
  this shape, `Designs/temperloop - workshop two-phase interview.md`.
- Kernel routing: `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule.
