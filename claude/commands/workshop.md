---
description: Facilitate a structured design conversation for INVENTED work (an idea born in conversation, not a discovered defect) against the coverage template in `claude/design-schema.md`, then ratify and materialize it into the funnel as a board epic with a well-formed `## Contract`, draft ADRs for its architectural calls, a Decisions note, and a hand-off to `/assess --epic N`. Operator-present only — no unattended arm. Ships the full intake → coverage walk → review pass → ratify → materialize flow; Step 3's tier decision, adversarial panel, and capability probes landed with `design-review-machinery` (temperloop#217); ADR emission at materialize landed with `design-adr-emission` (temperloop#219). Executing customer-persona agents shipped with `design-persona-agents` (temperloop#221).
argument-hint: "[<problem-statement> | <pointer-note>] [--board <N> | --project <name>]"
---

You are running the **workshop** command (formerly `/design`; renamed — temperloop#354 — to avoid colliding with Claude Code's builtin `/design`). Goal: take an idea that was *invented* in
conversation — not discovered as a Backlog defect — and walk it against a fixed
coverage template until every dimension has an explicit disposition, then ratify
and materialize it into the same funnel `/triage` feeds. This is the funnel's
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

- **Operator-present only — no unattended arm.** `/workshop` is modal by
  construction: there is no `--unattended` flag, no `ScheduleWakeup` poll, and
  no async decision-issue backend. Every ask in this command (Step 4's ratify
  confirmation; any disambiguating question during the walk) is a direct,
  interactive `AskUserQuestion` — never routed through `decision_sink_ask(...)`,
  because that seam's whole purpose is choosing between a live operator and an
  absent one, and there is never an absent-operator case to choose here. A
  design ritual cannot run against an absent operator; that is a deliberate
  property of this command, not a gap to fill later.
- **Minimum-viable-output rule.** Whatever else is unavailable — no `gh` auth,
  no repo, no registered board, no reviewer agents declared (Step 3) — the
  coverage walk still produces a **ratified brief note in the
  knowledge store**. That is the floor this command guarantees. Every
  dependency below degrades legibly (a stated `skipped — <reason>` line, never
  a silent no-op) rather than blocking the walk itself. See Step 3's and
  Step 5's degradation paths.
- **Idempotent materialization.** Epic creation is **probe-before-create** on
  the `design-brief:` marker line (Step 5b) — a re-run of `/workshop` against an
  already-ratified brief (or a re-run of just Step 5 after a partial failure)
  **adopts** the existing epic rather than duplicating it, exactly like
  `/triage`'s epic creation.
- **The dimension list belongs to `claude/design-schema.md`, not to this
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
   store; if it does, branch on its frontmatter `status`:
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
5. **Step 1.3b — Premise gate (null-hypothesis checkpoint).** Runs **after**
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

   - **(iii) Offer the decision — `AskUserQuestion`.** The offered option set
     is **conditioned on this brief's reshape marker** (see the `reshape`
     bullet): on the **first** encounter this pass, present all three —
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

1. Read `claude/design-schema.md` § Kernel dimension list — the 17 kernel
   dimensions — plus any overlay-added dimensions from
   `claude/design-schema.overlay.md` if this checkout carries one (letter-suffixed,
   e.g. `16a`, per that file's § Overlay extensibility — add-only; a kernel-only
   checkout like this one has none).
2. Walk each **remaining** dimension (1 and 3 are already seeded from Step 1)
   conversationally with the operator. The schema's own order is the default
   walk order; the operator may reorder freely — nothing here enforces a
   sequence — but every dimension must be reached before Step 4. For each
   dimension, elicit its content and record **exactly one** of the three
   dispositions defined in `claude/design-schema.md` § Disposition grammar,
   quoted here verbatim (this command applies the grammar; it does not
   restate a variant of it):

   ```
   filled                         — the dimension is answered in the brief body
   n/a — <reason>                 — genuinely inapplicable to this design, with the reason stated
   deferred → <tracking ref>      — real but out of scope for this brief; ref is an issue/epic that owns it
   ```

3. **No-silent-skips rule.** A dimension left without one of the three
   dispositions above is incomplete — do not let the walk move past it
   unaddressed. Until the brief-conformance lint (temperloop#216, forthcoming)
   lands, this is enforced here as an **authoring standard**, not yet a
   mechanical gate; Step 4 (ratify) re-checks it regardless of whether the
   lint exists, per `claude/design-schema.md`'s own "No-silent-skips rule".
4. **Dimension 4 (Contract seams) gets special care.** Its `Produces` /
   `Consumes` / `Acceptance` content is what Step 5 copies **verbatim** into
   the epic's `## Contract` — write it as the actual contract text, not a
   summary of one; `/assess`'s epic-decomposition mode must be able to
   decompose `Produces` with zero changes (`claude/design-schema.md` §
   Materialization contract).
5. **Walk-structure note — provisional, do not cite Double Diamond.** The
   walk above is a **convergent inspection checklist**: dimensions applied in
   a fixed default order, each dispositioned, with no divergent /
   alternatives-generation phase anywhere in it. This is the grounding the L0
   methodology spike confirmed (`Context/temperloop - design methodology
   spike verdict.md`) — Double Diamond's diverge-then-converge framing was
   evaluated against this walk and **rejected**; never cite it for the walk's
   structure. Whether a bounded alternatives-generation moment should be
   *added* to the walk is still open — **provisional — pending temperloop#224**
   — this command makes no change either way until that item resolves.
6. **Persist as you go.** Write each dimension's content into the brief note
   incrementally — after each dimension (or small cluster) is dispositioned,
   not in one end-of-walk rewrite — so a crashed walk loses at most the
   dimension in flight. The write primitive differs by backend:
   - **Obsidian-backed store:** a small append/patch per dimension (the
     vault's write-small convention), falling back to a full-file rewrite
     whenever a heading path isn't safely `vault_patch`-able (the vault
     safe-targeting contract).
   - **Plain-files store:** the backend has **no mid-file patch primitive** —
     the `knowledge_store` interface offers only `ks_write` (whole-file
     replace) and `ks_append` (end-of-file). So each dimension update is a
     **full-file rewrite via `ks_write`** (read → modify in memory → write).
     **Never** persist dimensions as per-dimension `ks_append` calls: the
     walk is operator-reorderable (Step 2.2), so appends land out of
     dimension order and corrupt the note's numbered-section structure.
7. **Persist-then-ask ordering — dual-surface before any gate.** Step 2.6
   requires the incremental *write*; this fixes its **ordering** relative to
   any operator gate. Never open an accept/object (or any approval)
   `AskUserQuestion` over drafted dimension content until that content is
   **both**:
   - **(a) persisted to the brief note** via Step 2.6's write primitive —
     the note is the **artifact of record**, the durable surface the
     operator (and every later step) reads. A write's OK return is **not**
     proof it landed: an Obsidian `vault_patch` can silently misfire (the
     vault safe-targeting contract — duplicate-heading synthesis, a stale
     document map), so **confirm the persist with a read-back** (or take the
     full-file-rewrite path, which is misfire-free) before treating (a) as
     satisfied — the same read-back discipline Steps 1.3b and 4.4 already
     require for this silent-drop class; **and**
   - **(b) echoed in chat** — a readable presentation of the same content,
     for in-line review.

   Both surfaces must be **current** — reflecting exactly the content the
   gate asks about — *before* the question is posed. A batched draft is
   still fine: you may walk and disposition several dimensions, then persist
   and echo the batch, then ask once over it. What is forbidden is asking
   the operator to accept or object to content that exists **only** as a
   transient chat bullet list with **no** persisted note behind it — the
   observed failure (temperloop#670: a 13-dimension draft gated for
   approval while the brief note was still empty, leaving the operator no
   reviewable artifact). The chat echo is for review convenience; the note
   is what makes the review *possible* on the next read. Ask over neither
   surface alone — over both, current.

   **Scope:** this ordering governs the gates *inside* the coverage walk
   (Step 2) and the findings fold-back (Step 3.4). Step 4.3's ratify ask is
   **exempt** — its precondition, Step 4.1's dimension-completeness check,
   already guarantees the note is current, so no re-echo is required there.

## Step 3 — Review pass

Runs after Step 2's coverage walk completes (every dimension carries a
disposition) and before Step 4 (ratify). Four parts, in order: **3.1** tier
decision, stated to the operator before any reviewer is spawned; **3.2** the
install-surface first-run/uninstall mandate; **3.3** capability-probed
adversarial panel execution; **3.4** findings fold-back into the brief. A
brief that skips this step never reaches ratify — Step 4.1's
dimension-completeness check is unchanged, Step 4.1b re-checks that every
finding this step produced was actually disposed of, and Step 4.3's ratify
question then follows a brief that has actually been reviewed, not merely
walked.

### 3.1 — Tier decision (stated before committing)

1. **State the cost, then ask.** Before spawning a single reviewer, tell the
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

### 3.2 — Install-surface first-run/uninstall mandate (spec-presence only)

1. **The mandate.** If the design touches the install surface — bin/
   entry points, install/uninstall code, hook or cron registration,
   anything a stranger's fresh clone would run once and never again — an
   **executed** first-run/uninstall persona run is **mandatory**,
   regardless of which tier 3.1 picked. This is RQ-3 from the ratified
   brief: the mandate is not a full-pass-only nicety, and dimension 12
   (First-run experience) is the dimension that names the trigger.
2. **What "executed" means, and why it outranks inspection.** The L0
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
   legible `skipped — <persona-agent> unavailable` line, stamped into
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
   unavailable lens emits its own `skipped — <agent> unavailable` line,
   narrated live (Mode 2 degradation notice, `claude/message-schema.md` §
   Degradation notice) — never silently absorbed into a generic "review
   skipped" note.
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
   **Dimension-0 carve-out.** A finding on **dimension 0** (Premise &
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
4. **No dangling findings.** Every finding from 3.3 is either folded in,
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
5. **Only then does Step 4 run.** This step does not re-open Step 2's walk
   order or re-litigate the tier picked in 3.1 — it is strictly the
   apply-findings-then-proceed step between review and ratify.

## Step 4 — Ratify

1. **Completeness check.** Confirm every dimension — every kernel dimension
   plus any overlay additions walked in Step 2, including any disposition
   Step 3.4 converted to `deferred` during fold-back — carries exactly one
   disposition. List any gap and stop; do not proceed to ratify a brief with
   an undispositioned dimension. This is the enforcement point
   `claude/design-schema.md` § Disposition grammar's "No-silent-skips rule"
   names as living here (in the review tier, until temperloop#216's
   mechanical lint lands) — Step 3's review tier existing does not relax
   this check; it only adds a source of new dispositions for it to catch.
   One per-dimension invariant this check also holds until #216's lint
   lands: **dimension 0's only legal disposition is `filled`** (`n/a` and
   `deferred` are both invalid for it — `claude/design-schema.md` §
   Disposition grammar), so a dimension 0 carrying `deferred` (e.g. from a
   mishandled fold-back) is a gap here, not a passing disposition.

   1b. **Finding-disposal check.** Dimension-level completeness alone
   cannot catch a dropped review finding — every dimension already
   carried a disposition when Step 2 ended, so a brief that silently
   dropped a finding still passes check 1. Re-check the coverage record
   in the brief's working notes (3.1.4): every finding each 3.3 lens
   returned must carry exactly one disposal — `folded`, `deferred →
   <tracking ref>`, or `declined — <note>` (3.4.4's vocabulary). List
   any finding without one and stop, same shape as check 1: return to
   Step 3.4 and dispose of it, never ratify past it. A lens's `skipped —
   <agent> unavailable` entry satisfies this trivially (no findings to
   dispose); a lens that ran with zero findings records `no findings`.
2. **Contract sanity.** Re-read dimension 4's `Produces` / `Consumes` /
   `Acceptance`. If it reads as a summary rather than an actual contract —
   the kind of content `/assess`'s epic-decomposition mode would need to
   reshape before it could decompose — send it back to Step 2 rather than
   ratifying a brief whose Contract isn't really `filled`.
3. **Ask.** Confirm with the operator directly via `AskUserQuestion` — ratify
   this brief? (No `decision_sink_ask(...)` routing: per the Operating
   principles, this command has no operator-absent case to route around.)
4. **On approval:** flip the note's frontmatter `status: draft → ratified`
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

**Then scan the composed body** before it is written anywhere outbound:

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

**Four artifacts, four different things — no content duplication.**
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
- **A reviewer, red-team lens, or persona agent is unavailable (Step
  3.2–3.3).** Not a failure of the command — the capability-probe predicate
  ([[Decisions/foundation - Project capability probes]]) makes this an
  expected outcome in a checkout with no `.claude/agents/` declared. Emit
  `skipped — <agent> unavailable` per lens, live, and continue the panel
  with whatever's available; an unmet install-surface first-run mandate
  (3.2) is stamped into dimension 15 rather than silently satisfied. To make
  the lenses resolvable in a fresh standalone clone (where the agents ship as
  source under `claude/agents/` but no live `.claude/` exists), run the
  project-scoped install path once — `bash
  workflows/scripts/install/project-agents.sh` (temperloop#290) — which wires
  `claude/agents/*` + `claude/commands/*` into `.claude/`; see
  `docs/features/review-agents.md` § Installation.
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
- Template + grammar this command applies: `claude/design-schema.md`.
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
- Message templates used here: `claude/message-schema.md` § Degradation
  notice.
