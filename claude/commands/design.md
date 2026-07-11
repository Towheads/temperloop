---
description: Facilitate a structured design conversation for INVENTED work (an idea born in conversation, not a discovered defect) against the coverage template in `claude/design-schema.md`, then ratify and materialize it into the funnel as a board epic with a well-formed `## Contract`, a Decisions note, and a hand-off to `/assess --epic N`. Operator-present only — no unattended arm. This file ships the CORE flow (intake → coverage walk → ratify → materialize); tier decision, adversarial review, and persona passes are `design-review-machinery` (temperloop#217), which edits the Step 3 seam this file leaves open.
argument-hint: "[<problem-statement> | <pointer-note>] [--board <N> | --project <name>]"
---

You are running the **design** command. Goal: take an idea that was *invented* in
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
a design conversation ──► /design   intake → coverage walk → [review — #217] → ratify → materialize
                                                                    │
                                                                    ▼
                                              board epic (## Contract, design-brief: marker)
                                                                    │
                                                                    └─► /assess --epic N   (unchanged)
                                                                            └─► /build
```

`/triage` explicitly disclaims a pre-designed epic (its own spec: "no path to
decompose an already-existing, fully-specified epic"); `/design` is that epic's
point of origin, not a patch to triage. Both front doors converge on the same
`/assess --epic N` → `/build` pipeline — nothing downstream of materialization
changes.

## Scope — this item vs. `design-review-machinery` (temperloop#217)

This file ships the **core flow only**: intake → coverage walk → ratify →
materialize. That flow alone closes the K94/K131 intake gap — a design
conversation gets a named path to a well-formed epic even with no review tier
wired in yet. Tier decision (brief pass vs. full pass), the adversarial lens
panel, capability probes for reviewer agents, and the persona pass are
**out of scope here** — they belong to `design-review-machinery` (temperloop#217),
tracked in the same plan
(`Plans/2026-07-08 temperloop - design command front door.md`), which edits
the placeholder in Step 3 below. Nothing in Steps 0–2 or 4–6 assumes review
machinery exists; #217 should need no changes outside Step 3.

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

- **Operator-present only — no unattended arm.** `/design` is modal by
  construction: there is no `--unattended` flag, no `ScheduleWakeup` poll, and
  no async decision-issue backend. Every ask in this command (Step 4's ratify
  confirmation; any disambiguating question during the walk) is a direct,
  interactive `AskUserQuestion` — never routed through `decision_sink_ask(...)`,
  because that seam's whole purpose is choosing between a live operator and an
  absent one, and there is never an absent-operator case to choose here. A
  design ritual cannot run against an absent operator; that is a deliberate
  property of this command, not a gap to fill later.
- **Minimum-viable-output rule.** Whatever else is unavailable — no `gh` auth,
  no repo, no registered board, no reviewer agents (#217's concern, not this
  file's) — the coverage walk still produces a **ratified brief note in the
  knowledge store**. That is the floor this command guarantees. Every
  dependency below degrades legibly (a stated `skipped — <reason>` line, never
  a silent no-op) rather than blocking the walk itself. See Step 5's
  degradation paths.
- **Idempotent materialization.** Epic creation is **probe-before-create** on
  the `design-brief:` marker line (Step 5b) — a re-run of `/design` against an
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
   run `make install-claude`."
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
5. **Reviewer-agent capability probing is out of scope here.** This command
   invokes no review subagent (Step 3 is a placeholder — see the Scope
   section). `design-review-machinery` (#217) owns that probe when it lands.

If check 1 or 2 fails, stop. Checks 3–4 are best-effort and never stop the
run — they only shape Step 5's degradation path.

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
4. **Create the brief note**, `status: draft`, at `Designs/<short
   title>.md`, per `claude/design-schema.md`'s frontmatter shape (`tags`,
   `date`, `status: draft`, `source_kind: claude-stamped`, `source_session`,
   `source_model`, `last_verified`), with dimensions 1 and 3 pre-filled from
   this step's answers (disposition `filled` on both, assuming the answers
   are real — a stranger test that can't yet be answered gets `deferred → …`
   like any other dimension, never a placeholder masquerading as an answer).

## Step 2 — Coverage walk

1. Read `claude/design-schema.md` § Kernel dimension list — the 16 kernel
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
   incrementally (a small append/patch per dimension) rather than one
   end-of-walk rewrite — per the vault's write-small convention, using a
   full-file rewrite whenever a heading path isn't safely `vault_patch`-able
   (the vault safe-targeting contract). On a plain-files knowledge store,
   write the same way.

## Step 3 — Review pass

`(review machinery — temperloop#217, forthcoming)`

This item ships **no review-tier gate**. After Step 2's coverage walk
completes, the command proceeds straight to Step 4 (ratify) — there is no
tier decision, no adversarial lens panel, and no persona pass in this file
today. `design-review-machinery` (temperloop#217) inserts those here, between
the coverage walk and ratify, editing this section in place. Steps 0–2 and
4–6 make no assumption about what does or doesn't happen in this step, so
#217 landing should require no change outside it.

## Step 4 — Ratify

1. **Completeness check.** Confirm every dimension — every kernel dimension
   plus any overlay additions walked in Step 2 — carries exactly one
   disposition. List any gap and stop; do not proceed to ratify a brief with
   an undispositioned dimension. This is the enforcement point
   `claude/design-schema.md` § Disposition grammar's "No-silent-skips rule"
   names as living here (in the review tier, until temperloop#216's
   mechanical lint lands) — Step 3 having no review tier yet does not relax
   this check.
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

Runs only against a `ratified` brief (Step 4). Four sub-steps, in order —
each degrades legibly rather than blocking the ones after it, except where
noted.

### 5a — Leak-guard scan (outbound content only)

Before the epic body (composed in 5b) is written anywhere outbound, scan it:

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
   brief is already ratified and persisted (Steps 1–4), and 5c (Decisions
   capture) still runs, so nothing is lost; only the epic and the final
   hand-off degrade. Emit the degraded hand-off from Step 5d instead of
   continuing to 5c/5d as written below.
2. **Compose the epic body**: title = the brief's title; body = a `##
   Contract` heading containing dimension 4's `Produces` / `Consumes` /
   `Acceptance`, copied forward **verbatim** from the ratified brief — not
   re-derived (`claude/design-schema.md` § Materialization contract) — plus
   the provenance marker line, on its own line:

   ```
   design-brief: [[Designs/<note>]]
   ```

3. **Probe-before-create.** Search for an existing epic carrying this exact
   marker line before creating a new one:
   `gh issue list -R "$repo" --search "design-brief: [[Designs/<note>]] in:body" --state all`
   (or the `issue_marker_probe` helper,
   `workflows/scripts/lib/issue-marker-probe.sh`, when this checkout vendors
   it — same corpus-first-then-live-fallback shape `/triage` Step 4 uses).
   **Found** → adopt it; this is the re-run path (a repeated `/design` pass,
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

### 5c — Decisions capture

Write a `Decisions/` note capturing the ratified design call, per
`claude/CLAUDE.kernel.md` § Decision capture (the same frontmatter, the same
`## Source` footer convention), cross-linking `[[wikilink]]`s both back to
the brief and forward to the epic (or, if 5b degraded, noting that no epic
exists yet). This is the third artifact `claude/design-schema.md` §
Materialization contract names — brief (deliberation record), epic
(operational tracker), Decisions note (personal capture) — and it runs
**regardless of whether 5b succeeded**: a degraded materialize still gets its
Decisions note.

### 5d — Hand-off line

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
why); the epic — created, adopted, or not-created-and-why; the Decisions
note path; and the Step 5d hand-off line, verbatim, as the last line of the
response.

## Failure modes

- **Knowledge store or `design-schema.md` unreachable (Step 0).** Stop before
  any conversation starts — there is nothing to walk without the schema, and
  nowhere to write the brief without the store.
- **`gh`/repo unavailable at materialize time (Step 5b).** Not a failure of
  the command — the brief still ratifies and persists; only the epic and the
  final hand-off degrade (Step 5d's degraded line). Report it plainly in Step
  6, never silently.
- **No board registered for the resolved repo (Step 5b.4).** The epic still
  gets created as a plain GitHub issue; board mirroring is a convenience, not
  a requirement. Note the skip.
- **A dimension is left undispositioned at ratify time (Step 4.1).** Block
  ratification — list the gaps and return to Step 2. Never ratify with a
  silent skip; the mechanical lint (temperloop#216) isn't required for this
  to be enforced here.
- **Dimension 4 reads as a summary, not a real contract (Step 4.2).** Send it
  back to Step 2 rather than ratifying a Contract `/assess` would have to
  reshape.
- **Leak-guard scan finds a hit (Step 5a).** Block materialization — this is
  the one non-best-effort check in Step 5, because the epic body is outbound
  content. Fix the offending text (in the brief, then re-copy into the
  Contract) and re-run Step 5.
- **Re-running `/design` (or just Step 5) against an already-ratified,
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
- Review-tier seam (Step 3, forthcoming): `design-review-machinery`,
  temperloop#217.
- Grounding: `Context/temperloop - design methodology spike verdict.md` (L0
  spike verdict); the ratified brief,
  `Designs/temperloop - design command design brief.md`; the epic plan,
  `Plans/2026-07-08 temperloop - design command front door.md`.
- Kernel routing: `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule.
- Message templates used here: `claude/message-schema.md` § Degradation
  notice.
