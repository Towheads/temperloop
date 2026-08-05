# Design-brief schema

Canonical coverage-dimension list and disposition grammar for design briefs
produced by `/workshop` and consumed by `/assess` (via the epic `## Contract`
it materializes into). Peer of `claude/plan-schema.md` — where a plan note
governs *how an approved epic decomposes into build items*, a design brief
governs *what a proposed feature must have decided before it becomes an
epic at all*. This file is the brief's contracts doc; `claude/commands/workshop.md`
is the command that walks it.

> **Core idea: design-time promise ↔ merge-time enforcement is one loop.**
> Nearly every dimension below is not an invention — it is an existing
> merge-time gate or kernel contract, pulled forward to design time. A brief
> that honestly fills a dimension has pre-written what the corresponding
> gate will demand at merge; a brief that skips a dimension is a bet that
> the gate won't notice. Each dimension entry below names its enforcing
> gate where one exists, so the loop is traceable in both directions.

## File location

Design briefs live at `Designs/<short title>.md` in the knowledge store —
a sibling of `Decisions/`, `Context/`, and the other note folders, but its
own distinct artifact class: **pre-plan, ratifiable, lint-checked**. A brief
is not a `Decisions/` note (it precedes and produces one — see
§ Materialization contract) and not a `Plans/` note (it precedes and
produces an epic that `/assess` decomposes into one). `Designs/` did not
exist before this schema; it is a new top-level folder in the knowledge
store, parallel in status to `Plans/`.

## Frontmatter

```yaml
---
tags: [design-brief, project/<name>]
date: <YYYY-MM-DD created>
status: draft                         # draft | ratified | dropped
source_kind: claude-stamped
source_session: <session-id>
source_model: <model id that drafted the brief>
last_verified: <YYYY-MM-DD>
---
```

This is the standard vault provenance schema (note-level) plus one
brief-specific field: `status`. `status: draft` is the gate between the
coverage walk and materialization — the command's ratify step
(`/workshop` Step 4) flips it to `ratified` only after every dimension carries
a disposition (§ Disposition grammar) and the review tier for that epic's
weight has run (`/workshop` Step 3). A `ratified` brief is treated as <!-- cite: DS.4 class:ratified-record-silent-mutation -->
immutable going forward: a later change is a **new** brief that supersedes
it (linked via `[[wikilink]]`), the same convention `Decisions/` notes use
for supersession — never an edit-in-place of a ratified brief.

A `dropped` brief is a **killed idea** — the third terminal `status` value,
alongside `draft` (in-walk) and `ratified` (accepted). The `/workshop`
Step 1.3b premise gate's **drop action** (temperloop#509) flips
`status: draft → dropped` when the operator decides the case *against* the
design wins the null-hypothesis checkpoint, with **dimension 0 carrying the
kill rationale** (disposition `filled`). A dropped brief is neither ratified
nor materialized; it is the durable record that the idea was considered and
rejected, so a later `/workshop` run on the same title **stops** rather than
silently re-adopting it as a draft. Reopening a dropped brief requires an
**explicit operator confirmation** (`/workshop` Step 1.4), never the silent
draft-adopt path — a killed idea does not un-kill itself on the next run.

## Kernel dimension list

Seventeen dimensions, one per numbered section of a brief. The kernel owns <!-- cite: DS.1 incident:K#148 -->
this list and its order; an overlay may **add** dimensions but never
remove or reorder a kernel one (§ Overlay extensibility). Each entry below
states what the dimension must answer and the mechanism — if any — that
checks the promise at merge time. The "Enforcing gate" column's own
citations ARE lint-checked: `workflows/scripts/validate-design-brief.sh`'s
schema-citation check (its bare-invocation mode, run in CI via
`scripts/quality-gates.sh`) resolves every backtick-quoted,
extension-terminated path in this column against the tracked tree and
fails the build on a dangling one — the brief-conformance lint
(temperloop#216) shipped 2026-07-11; this is one of its two checks
(§ Disposition grammar's No-silent-skips rule covers the other, the
per-brief `--brief` check).

| # | Dimension | What it answers | Enforcing gate |
|---|---|---|---|
| 0 | **Premise & null hypothesis** | The do-nothing cost, the strongest subtraction/existing-surface alternative, and the operator's justification for proceeding (or the kill rationale) — the case *against* this design existing at all, made and answered before any other dimension is walked. **`filled`-only**: `n/a` and `deferred` are not valid dispositions for this dimension (§ Disposition grammar) — a deferred premise is exactly the gap this dimension exists to close. | The `/workshop` Step 1.3b premise gate (temperloop#509, forthcoming) — composes the case against citing `docs/principles.md`, elicits and records the operator's justification into this dimension, and offers proceed/reshape/drop; a drop flips the brief's `status` to `dropped` with this dimension carrying the kill rationale. |
| 1 | **Problem & outcome (stranger standpoint)** | The problem and the customer-visible outcome, stated from a stranger's point of view — never the implementation's. Decides the stranger test (kernel vs overlay routing, `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule). | Advisory — no mechanical gate; the stranger-test call is reviewed by the adversarial panel and, downstream, by whichever repo the resulting code actually lands in. |
| 2 | **Audience & interaction modes** | Who the feature is for (live operator, unattended run, both) and which `claude/message-schema.md` interaction modes it uses. | Advisory today — briefs live in the knowledge store, outside the repo, so no repo CI lint can scan one automatically (`workflows/scripts/validate-template-refs.sh` scans only `claude/CLAUDE.kernel.md` + `claude/commands/*.md`, never a brief); brief-side template/mode reference checking is coverable by the brief-conformance lint's on-demand `--brief FILE` mode (`workflows/scripts/validate-design-brief.sh`, temperloop#216, shipped 2026-07-11) when run against an exported brief — nothing wires that invocation into the pipeline automatically yet. |
| 3 | **Alignment (guiding principles / routing)** | How the feature advances a guiding principle, and the kernel-vs-overlay routing decision with its rationale. | Advisory at design time (reviewed by architecture-reviewer); the routing call is checked downstream when code lands — a kernel-routed dimension implemented as overlay code (or vice versa) trips `workflows/scripts/kernel/check-kernel-manifest.sh`'s path classification at merge. |
| 4 | **Contract seams (Produces / Consumes / Acceptance)** | The epic-shaped contract this design will materialize into (§ Materialization contract) — what the resulting work produces, what it depends on, and how completion is checked. | The brief-conformance lint's `--brief` mode (`workflows/scripts/validate-design-brief.sh`, temperloop#216, shipped 2026-07-11) checks disposition shape/presence only, not content quality; content-level enforcement is `/assess`'s epic-decomposition mode (foundation#526), which asks/fails when Produces/Consumes/Acceptance aren't well-formed enough to decompose without reshaping. |
| 5 | **Command/mechanism shape** | A steps sketch for the resulting workflow (if the design produces a command or routine) — enough for a reviewer to judge shape, not the final grammar. | If the design produces a prose workflow spec (`claude/commands/*.md`), the `workflow-reviewer` agent covers every edit to it going forward — advisory, standing review, not merge-blocking. |
| 6 | **Scalability & resource impact** | Token/API cost, and — when the design touches board writes — how many extra tracker round-trips it adds; the cost tier stated up front. | Advisory — no dedicated gate for the write-up. |
| 7 | **Maintainability** | Coupling this design introduces (which gates/contracts must move together), and whether it introduces a new live-capture rule needing a backstop. | `workflows/scripts/validate-capture-backstop.sh` — CI-enforced; fails the build if a new capture/backstop pair is only half-shipped. |
| 8 | **Testability** | What is mechanically gated vs. honestly advisory-only. | `scripts/quality-gates.sh` / the `KERNEL_GATES` set — the repo-wide static gate list every PR runs. |
| 9 | **Telemetry & measurement proxies** | Cheapest-first proxies for whether the feature worked, per the existing measurement-proxies convention. | `claude/measurement-proxies.md`'s contract, backed by the emit/validate pairs (`emit-command-run.sh`/`validate-command-run-emit.sh`, `emit-issue-touch.sh`/`validate-issue-touch-emit.sh`) when the design's proxies ride those paths; a genuinely new proxy stream still needs Capture/Backstop pairing (dimension 7). |
| 10 | **Upgrade path** | Whether this design changes a contract surface an overlay/stranger couples to (`VERSIONING.md` § The contract surface), and what CHANGELOG marker that implies. | The `breaking_sections()` detector in `scripts/update-kernel.sh` (reads the CHANGELOG `BREAKING` marker) plus the version-tag bump rule in `VERSIONING.md`. |
| 11 | **Uninstallability / reversibility** | What removing this feature requires — hooks, cron, runtime state, paired registry entries — so removal is clean, not a slow leak. | The family of registry/lint half-removal validators: `validate-capture-backstop.sh` (Capture/Backstop pairs), `validate-template-refs.sh` (template registry refs), `validate-feature-docs.sh` (`STALE-EXEMPT`/`ORPHAN-DOC`/`UNCLAIMED` catch a half-removed doc or path claim), `check-setting-registry.sh` (registry↔shell equality). |
| 12 | **First-run experience** | What a stranger's fresh install/first invocation experiences, with no prior state. | Advisory — no static gate; verified experientially by an executed first-run/uninstall persona run (mandatory whenever the design touches the install surface). Designs touching `bin/`/install code additionally run through `scripts/tests/test_stranger_config.sh`. |
| 13 | **Docs & marketing surface** | The feature doc this design will need (five required sections) and any positioning/marketing claim. | The feature-docs coverage gate, `workflows/scripts/validate-feature-docs.sh` (temperloop#132) — a non-exempt manifest slug with a missing/empty required section fails CI. |
| 14 | **Security / privacy** | What personal/org content this design's conversation or artifacts might carry, and where the public/private boundary sits. | The PR leak guard, `workflows/scripts/kernel/check-pr-leak-guard.sh` (temperloop#74) — scans outbound content before it can land in the public repo. |
| 15 | **Failure modes, degradation & capability limits** | Premortem-framed failure story, legible-degradation paths for every optional dependency, and honest capability limits (never overclaimed). | Advisory — no static lint; the legible-degradation invariant it documents (`skipped — <agent> unavailable`, never a silent no-op) is checked by `workflow-reviewer` wherever the resulting command spec implements a capability-probe gate. |
| 16 | **Adoption & enforcement** | How this design's flow **displaces the default it replaces** — every design must answer this, not just ones that add new commands. | The kernel routing rule (`claude/CLAUDE.kernel.md` § Design-first default for invented work) + `/assess`'s in-pipeline provenance check (`claude/commands/assess.md` Step 1 — an epic with `## Contract` but no `design-brief:` marker triggers a legible, fail-open ask) + the `/tidy` backstop (`claude/commands/tidy.md` § Provenance-less epics — registered as a Capture/Backstop pair per dimension 7's own gate, `workflows/scripts/validate-capture-backstop.sh`). |

Dimension 16 (Adoption & enforcement) is itself a template addition
discovered by the /workshop brief's own bootstrap run — every design brief,
not only ones proposing a new command, must answer how its resulting flow
displaces the default behavior it replaces, or state honestly that it
doesn't change any existing default.

**Dimension 0 (Premise & null hypothesis) is numbered `0`, not appended as <!-- cite: DS.2 incident:K#509 -->
`17`, so it sorts and is walked *first*** — before problem/outcome, before
anything — without renumbering dimensions 1–16. It is also the schema's
**only `filled`-only dimension**: every other dimension may legitimately
resolve `n/a` or `deferred` (§ Disposition grammar), but dimension 0 may
not — a brief that "defers" its own premise justification has produced
exactly the unexamined-idea gap the premise gate exists to close, so the
gate (`/workshop` Step 1.3b, temperloop#509) never accepts anything but a
real answer or an honest kill.

**Dimension-0 walk-verdict note.** Dimension 0 is seeded at the Step 1.3b <!-- cite: DS.9 class:gate-satisfiability-deadlock -->
premise gate rather than walked in Step 2's per-remaining-dimension loop
(`/workshop` Step 2.2 walks only the dimensions not already seeded from
Step 1). **A Step-1-seeded dimension's Step-1 confirm counts as that
dimension's `walk` verdict** — see § Challenge record's `step-1-seed`
source — so a downstream gate requiring a `walk` verdict for every kernel
dimension before ratify stays satisfiable for every brief. Without this
rule, dimensions 0, 1, and 3 (all three seeded in Step 1, per `/workshop`
Step 2.2) would structurally never carry a Step-2 `walk` stop line, and any
gate checking "walk verdict present for all 17 dimensions" would deadlock
on every single brief, not just an unusual one.

> **Provisional — pending temperloop#224.** Dimension 5's coverage-**walk <!-- cite: DS.7 incident:K#224 -->
> structure** (the order dimensions are walked in, and whether a bounded
> alternatives/divergence moment precedes the convergent walk) is not
> settled. The walk is grounded as a **convergent inspection checklist**
> (the tradition behind dimensions 1–2's fixed-question-set method), *not*
> Double Diamond or any diverge-then-converge framing — that mapping was
> evaluated and rejected. Do not cite Double Diamond for the walk's
> structure. This slot resolves when temperloop#224 decides whether a
> divergence moment joins the walk.
>
> **Provisional — pending temperloop#225.** The adversarial lens panel's
> (dimensions cited via review, e.g. 1, 3, 5, 15) *yield claim* — how much
> coverage multiple same-model lenses actually add over one — is
> unmeasured. Cite heuristic evaluation (Nielsen & Molich, CHI 1990) for
> the panel's *structure* (independent parallel passes, aggregated after)
> only, never for a numeric coverage/diminishing-returns claim — those
> numbers were measured for independent human evaluators with different
> priors, which same-model lenses are not. Likewise, dimension 15's
> premortem framing ("assume this shipped and failed; write the failure
> story") is grounded for *shape* (Klein 2007) but whether prospective-
> hindsight framing measurably improves LLM-generated failure modes (vs. a
> neutral "list failure modes" prompt) is unmeasured. Neither slot is
> firm until temperloop#225 resolves it.

## Disposition grammar

Every dimension in a brief gets **exactly one** explicit disposition — <!-- cite: DS.3 guard:workflows/scripts/validate-design-brief.sh -->
no dimension may be silently absent:

```
disposition: filled                       — the dimension is answered in the brief body
disposition: n/a — <reason>               — genuinely inapplicable to this design, with the reason stated
disposition: deferred → <tracking ref>    — real but out of scope for this brief; ref is an issue/epic that owns it
```

The disposition line is the **first non-blank line** under its dimension
heading — body prose follows it, never precedes it (the brief-conformance
lint enforces this position).

`n/a` is not a way to skip an inconvenient dimension — it is for a
dimension that genuinely does not apply (e.g. dimension 11 uninstallability
may be `n/a — no runtime component; brief proposes only a docs change` when
that's literally true). `deferred` is for a real gap the brief owner
chooses not to resolve now; it must point at something that tracks the gap,
not dangle. A dimension with no disposition at all — not filled, not
`n/a`, not `deferred` — is the failure mode this grammar exists to prevent.

**Dimension 0 is the one exception to this three-way grammar: `filled` is
its only valid disposition.** `n/a` and `deferred` are both invalid for
dimension 0 — there is no design for which "should this exist at all" is
inapplicable, and deferring the premise justification is the exact gap
the premise gate (§ Kernel dimension list, row 0) exists to close. A
dimension-0 section carrying `n/a` or `deferred` is an authoring-standard
violation, checked today by the review tier (`/workshop` Step 3/Step 4) the
same way any other missing disposition is (§ No-silent-skips rule below).
The shipped brief-conformance lint (`workflows/scripts/validate-design-brief.sh
--brief`, temperloop#216) checks dimension 0's *presence* and every
dimension's disposition-line *shape* today, but does not yet special-case
this dimension's `filled`-only value restriction: a syntactically
well-formed `n/a — <reason>` on dimension 0 passes the lint's generic
shape check even though it is a grammar violation per this section — the
value restriction remains authoring-standard-only until the lint is
extended to special-case it.

**No-silent-skips rule.** A brief with an undispositioned dimension fails
the brief-conformance lint's `--brief` mode check
(`workflows/scripts/validate-design-brief.sh --brief FILE`, temperloop#216,
shipped 2026-07-11) — a mechanical check now exists, callable on demand
against any brief exported to a file. Because briefs live in the knowledge
store outside this repo (§ File location), nothing here wires that check
into an automatic CI run; the operational enforcement point today remains
the review tier (`/workshop` Step 3), and `/workshop`'s ratify step
(Step 4) must not flip `status: draft → ratified` while any dimension
lacks a disposition, whether the gap is caught by a manual `--brief` run
or by review.

## Congruence seams

Per-dimension completeness (§ Disposition grammar) only proves every
dimension carries *a* disposition — it says nothing about whether two
dimensions' content actually **agrees**. A brief can pass every disposition
check and still be internally incongruent: dimension 4's Acceptance
criteria naming a check dimension 8 doesn't actually cover, or dimension
16's adoption story solving a different problem than the one dimension 1
states. A **congruence seam** is a named pairing of dimensions whose
content must agree, not merely both be filled — checked at Step 3.4
(findings fold-back) and Step 4 (ratify), the same review tier that
enforces § Disposition grammar's No-silent-skips rule today.

Named-minimum checklist — five seams, kernel-owned:

| Seam | Dimensions | What must agree |
|---|---|---|
| contract↔mechanism-shape | 4 ↔ 5 | Dimension 5's steps sketch actually implements dimension 4's Produces/Consumes — a mechanism sketch that visibly doesn't produce what the contract promises is incongruent even though both dimensions are individually `filled`. |
| adoption↔problem-statement | 16 ↔ 1 | Dimension 16's displacement story follows from dimension 1's stated problem/outcome — an adoption story solving a different problem than the one dimension 1 names is incongruent. |
| acceptance↔testability | 4 ↔ 8 | Dimension 4's Acceptance criteria are actually coverable by what dimension 8 says is mechanically gated vs. advisory — an Acceptance clause with no corresponding testability path is a promise the brief can't keep. |
| deferred-refs-resolve | any `deferred` dimension ↔ its ref | Every `deferred → <ref>` disposition (§ Disposition grammar) names a ref that resolves to a real, open tracking item — a dangling or already-closed ref is incongruent with the "real gap, tracked elsewhere" claim `deferred` makes. |
| cost↔scope | 6 ↔ 4 | Dimension 6's stated cost tier is consistent with dimension 4's Produces/Consumes scope — a "low cost" dimension 6 paired with a Produces clause that plainly implies a multi-repo, multi-agent build is incongruent. |

This list is a **floor, not a ceiling** — the same add-only discipline <!-- cite: DS.8 class:cross-dimension-incongruence -->
§ Overlay extensibility applies to the dimension list applies here: a
design may surface a congruence gap the five seams above don't name, and
a later kernel change (or an overlay, for an org-specific pairing) may add
a seam to this table, but never remove or weaken one of the five above
without an upstream, `CHANGELOG.md`-marked kernel change (§ Overlay
extensibility's own removal rule applies verbatim to this list too).

No mechanical checker exists for these seams today — the same maturity
stage § Disposition grammar's No-silent-skips rule was in before its own
lint shipped (temperloop#216). They are reviewed as an authoring standard
at Step 3.4/Step 4 until a future lint extends `workflows/scripts/validate-design-brief.sh`
(or a successor) to check them mechanically.

## Overlay extensibility — add-only

The kernel owns the seventeen-dimension default list (§ Kernel dimension <!-- cite: DS.5 class:overlay-dimension-collision -->
list) and its order. An overlay **may add** dimensions — an org-specific
concern with no meaning in a stranger's kernel-only checkout — but **may
never remove or weaken** a kernel dimension. This is a **narrow,
dimension-list-specific carve-out** — not an invocation of
`claude/message-schema.md` § Overlay override status, whose named-template
exception is scoped explicitly to that file's own named templates
(`claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule: "it does not
license an overlay to diverge from any other kernel contract"). The two
carve-outs share only a family resemblance — both let an overlay extend a
fixed kernel surface without licensing subtraction — never assume one
authorizes the other; a narrower carve-out for this doc's own list, if one
lands, is its own explicit sentence here, never inherited from
message-schema.md's grant. Here, on this list's own terms: appending is
sanctioned, subtracting is not. The override *mechanism* itself — how an overlay declares an added
dimension and how precedence resolves — is deferred to the override-seam
pattern (temperloop#112); the numbering namespace is reserved now:
overlay-added dimensions are letter-suffixed on the kernel dimension they
follow (e.g. `16a`), never bare integers, so a future kernel-additive
dimension (a new `17`) can never collide with an overlay's addition.

Removing or weakening a kernel dimension is itself a **kernel change**,
never an overlay decision — it requires editing this file upstream and a
`CHANGELOG.md` entry (per `VERSIONING.md`, a dimension-list change to this
file is a contract-surface change: additive if a dimension is added,
breaking if one is removed or its enforcing-gate binding changes in a way
that no longer holds for existing overlays).

## Materialization contract

`/workshop`'s materialize step (Step 5) turns a ratified brief into a board <!-- cite: DS.6 incident:K#218 -->
epic. A well-formed epic produced this way carries:

- **A `## Contract` body** with the same three sections `/assess`'s
  epic-decomposition mode already expects (foundation#526) — `Produces`,
  `Consumes`, `Acceptance` — copied forward from the brief's dimension 4
  disposition, not re-derived. `/assess --epic N` must be able to decompose
  the epic's `Produces` into seam-scoped plan items with **zero changes**
  to the Contract itself; a Contract that needs reshaping at `/assess` time
  is evidence dimension 4 wasn't actually filled.
- **A `design-brief:` provenance marker** — a bare line in the epic body:

  ```
  design-brief: [[Designs/<note>]]
  ```

  This is what `/assess` Step 1's in-pipeline provenance check
  (`claude/commands/assess.md` Step 1, temperloop#218) looks for: an epic
  carrying a `## Contract` but no `design-brief:` marker triggers a legible,
  fail-open ask (proceed without a brief, or park and run `/workshop` first)
  rather than either a silent bypass or a hard block. `/triage`'s mirror
  redirect line for invented work handed to it instead of an
  already-designed epic (`claude/commands/triage.md` § Mirror redirect:
  invented work arriving at triage's door) ships with the same item.
- **The brief's home stays `Designs/`** in the knowledge store — the epic
  links to it, it is never copied into the epic body. The brief is the
  deliberation record (full reasoning, rejected alternatives, persona
  findings); the epic is the operational tracker; a paired `Decisions/`
  note is the short personal-capture cross-link. Three artifacts, one
  deliberation, no duplication.

## Challenge record

`/workshop` Step 3 (review pass) and Step 2 (coverage walk) both produce
per-dimension verdicts — a lens accepted a dimension as walked, challenged
it, or the operator edited past a challenge. § Disposition grammar records
only the dimension's *final* content-disposition (`filled` / `n/a` /
`deferred`); it has no place to record *how many stops that dimension took
to get there, from what source, or in the operator's own words*. The
**challenge record** is that grammar.

| Section | Enforcing gate |
|---|---|
| § Challenge record (this section's grammar, the record-start marker/empty-record guard, and § Record completeness below) | `workflows/scripts/validate-design-brief.sh`'s brief-conformance check (C) |

**Home section.** The challenge record lives in the brief's `## Working
notes` section — a free-form, non-dimension provenance area for the
review pass's own bookkeeping (the tier record and per-lens coverage
record `/workshop` Step 3.1.4 already keeps there, the Step 1.3b
`premise-gate: reshaped once` marker, and this record). `## Working notes`
is not one of the 17 kernel dimensions and carries no disposition line —
it is provenance *about* the walk, not brief content itself. § Worked
example below adds this section; earlier ratified briefs that predate it
carry no `## Working notes` at all, which is the same grandfather shape
§ Frontmatter's `status: ratified` immutability already gives dimension 0
(a ratified brief is never retrofitted).

**Record-start marker and its absence.** The first line under a
`### Challenge record` subheading is a bare marker line:

```
challenge-record-start: <YYYY-MM-DD>
```

Its presence commits to "at least one stop line follows below, before the
next heading." Its **absence has two distinct readings, and they are not <!-- cite: DS.10 class:silently-incomplete-review-record -->
interchangeable**: no `### Challenge record` subheading at all under
`## Working notes` means *zero stops were recorded this pass* — every
dimension's first look sailed through as an implicit accept with nothing
worth logging, which is a valid, common, non-defective state, never
grounds to infer "review didn't happen" (that is instead what the Step
3.1.4 tier/coverage record — a separate line in the same `## Working
notes` section — attests to). A `### Challenge record` heading whose
`challenge-record-start:` marker is present but **zero stop lines follow
it** before the next heading is the other case, and it *is* a defect: a
record announced but never populated.

**Per-stop line shape.** One stop is one dimension (or a same-verdict
cluster of dimensions, see below) reaching one verdict from one source, at
one point in the walk or review pass:

```
<dim-list> [<kind>] <source>: <verdict>[ — response: "<verbatim text>"]

dim-list ::= <dim-ref> ("," <dim-ref>)*
dim-ref  ::= digit+ [a-z]?              (a kernel dimension, optionally
                                          letter-suffixed per § Overlay
                                          extensibility, e.g. `8`, `16a`)
kind     ::= "walk" | "walkthrough"
source   ::= "step-1-seed" | <review-lens-or-persona-name>
verdict  ::= "accepted"
           | "challenged → revised ×" digit+
           | "operator-edited"
response ::= present only when the operator's own verbatim words are what
             decided the verdict (e.g. Step 3.4.3's contested-finding
             resolution) — quoted, never paraphrased or summarized
```

**Clustering.** `dim-list` legitimately holds more than one `dim-ref` —
several dimensions that share the identical `kind`, `source`, and
`verdict` (most commonly a clean panel-wide `accepted` sweep from one
lens) collapse onto one line rather than repeating a line per dimension.
Clustering is a compression of `dim-list`, not a distinct line shape: a
one-dimension stop and a five-dimension cluster parse identically past the
comma-split.

**Walk-vs-walkthrough discriminator.** `kind` distinguishes which pass
produced the verdict: `walk` = Step 2's coverage walk (per-dimension
content authored and dispositioned); `walkthrough` = Step 3's review pass
— the adversarial lens panel (3.3) and/or the executed first-run/uninstall
persona run (3.2), i.e. cognitive-walkthrough-shaped review, never the
coverage walk itself. A dimension may carry a `walk` line, a `walkthrough`
line, or both — dimension 12 on an install-surface-touching design gets
both (Step 2's content, then Step 3.2's mandatory executed run); a
dimension no panel lens reached (one skipped per its capability probe)
carries only a `walk` line.

**Seeded dimensions count their Step-1 confirm as their walk verdict.**
Dimensions 0, 1, and 3 are seeded in Step 1 rather than walked in Step 2's
per-remaining-dimension loop (§ Kernel dimension list's dimension-0
walk-verdict note; `/workshop` Step 2.2). Their `walk` stop line uses
`source: step-1-seed` and is written at the point Step 1 confirms that
dimension's content (the Step 1.3b premise-gate proceed for dimension 0;
the Step 1 intake confirm for dimensions 1 and 3) — this is the mechanism
that realizes the walk-verdict note's rule, not a separate concept from it.

**Verdict vocabulary.**

- `accepted` — the source reviewed the dimension's existing content and
  found it sufficient as written; nothing changed.
- `challenged → revised ×<N>` — the source raised a finding, the finding
  was folded in (`/workshop` Step 3.4's `folded` disposal), and the
  dimension's content changed as a result; `N` counts the number of
  distinct revision rounds this stop went through (almost always `1`;
  greater than `1` only when a revision itself drew a further challenge
  within the same pass).
- `operator-edited` — the change came from the operator's own hand, not
  from folding in the source's finding verbatim (e.g. Step 3.4.3's
  contested-finding resolution overriding the lens's proposed fix, or a
  direct operator rewrite mid-walk) — distinguished from `challenged →
  revised` by *whose* edit produced the final content.

**Record completeness.** Grammar shape (above) says how a stop line reads; <!-- cite: DS.11 guard:workflows/scripts/validate-design-brief.sh -->
it says nothing about whether the record, taken as a whole, is *done*. Before
a brief may ratify, a challenge record that is present at all (see the
migration carve-out below) must satisfy two structural rules — both
mechanically checked by `workflows/scripts/validate-design-brief.sh`'s
brief-conformance check (C), and this is the single source of truth
`/workshop` Step 4.1c's in-session ratify gate reuses verbatim rather than
restating, so the two can never diverge: **(1)** every kernel dimension
0..16 carries at least one `walk` stop line — the coverage-walk requirement
the dimension-0 walk-verdict note (above) already establishes is satisfiable
for every brief via the seeded-dimension rule; `walkthrough` coverage stays
opportunistic, exactly as the walk-vs-walkthrough discriminator above
describes ("a dimension no panel lens reached ... carries only a `walk`
line"), and is never required for every dimension. **(2)** every
`operator-edited` stop line carries a verbatim `response:` field — the
verdict's own definition ("the operator's own hand ... not from folding in
the source's finding verbatim") means the record is incomplete without
capturing what that hand actually wrote.

**Migration carve-out.** A `ratified` brief carrying no `### Challenge <!-- cite: DS.12 class:ratified-record-silent-mutation -->
record` subheading at all predates this record — challenge records did not
exist when it ratified — and is EXEMPT from rule (1) above, never flagged,
by the same per-brief `status:` signal § Disposition grammar's dimension-0
requirement already keys on (temperloop#512), never a global version flip.
A non-ratified (draft or dropped) brief is never held to rule (1) or (2)
either — its record is still being built. Only a `ratified` brief whose
`### Challenge record` subheading is present is checked for completeness;
the record-start-marker-present-but-empty defect (above) is independent of
ratification and applies regardless of status.

## Worked example (skeleton)

```markdown
---
tags: [design-brief, project/example]
date: 2026-08-01
status: draft
source_kind: claude-stamped
source_session: a1b2c3d4
source_model: claude-example-model
last_verified: 2026-08-01
---

# Design brief: <feature name>

## 0. Premise & null hypothesis
disposition: filled
<do-nothing cost; the strongest subtraction/existing-surface alternative;
the operator's justification for proceeding (or, on a kill, the rationale
recorded here instead) — `n/a` and `deferred` are not valid dispositions
for this dimension>

## 1. Problem & outcome (stranger standpoint)
disposition: filled
<problem, from a stranger's standpoint; the customer-visible outcome>

## 2. Audience & interaction modes
disposition: filled
<who this is for; which message-schema modes it uses>

## 3. Alignment (guiding principles / routing)
disposition: filled
<which guiding principle this advances; kernel-vs-overlay routing call>

## 4. Contract seams (Produces / Consumes / Acceptance)
disposition: filled
**Produces:** ...
**Consumes:** ...
**Acceptance:** ...

## 5. Command/mechanism shape
disposition: n/a — this design adds no new command, only a schema change

## 6. Scalability & resource impact
disposition: filled
<cost tier; API/token impact>

## 7. Maintainability
disposition: filled
<coupling to watch; any new Capture/Backstop pair this introduces>

## 8. Testability
disposition: filled
<what's mechanically gated vs. advisory-only>

## 9. Telemetry & measurement proxies
disposition: deferred → temperloop#999
<cheapest-first proxy sketch; full wiring deferred to the tracked follow-up>

## 10. Upgrade path
disposition: filled
<does this change a contract surface? additive/breaking?>

## 11. Uninstallability / reversibility
disposition: filled
<what removal requires; any paired registry entries>

## 12. First-run experience
disposition: filled
<what a stranger's fresh checkout experiences>

## 13. Docs & marketing surface
disposition: filled
<feature doc this will need; positioning claim if any>

## 14. Security / privacy
disposition: n/a — no personal/org content surfaces in this design's artifacts

## 15. Failure modes, degradation & capability limits
disposition: filled
<premortem-framed failure story; legible-degradation paths; honest limits>

## 16. Adoption & enforcement
disposition: filled
<how this displaces the default it replaces, or states it changes no default>

## Working notes

### Challenge record
challenge-record-start: 2026-08-01

0 [walk] step-1-seed: accepted
1,3 [walk] step-1-seed: accepted
8 [walk] requirements-auditor: accepted
12 [walkthrough] first-run-uninstall persona: challenged → revised ×1 — response: "yes, the uninstall step needs its own confirm prompt — add it"
```

`## Working notes` is not a numbered kernel dimension (no digit prefix, no
disposition line) — it is the § Challenge record's home section, plus a
home for the review-tier/per-lens coverage record `/workshop` Step 3.1.4
keeps and the Step 1.3b `premise-gate: reshaped once` marker. The four
lines above exercise every production the § Challenge record grammar
defines: `challenge-record-start:` (the record-start marker), a
single-dimension `walk` stop (`8 [walk] requirements-auditor: accepted`),
a clustered `walk` stop across two dimensions sharing the identical
`step-1-seed` source and `accepted` verdict (`1,3 [walk] step-1-seed:
accepted` — the same mechanism dimension 0's own line demonstrates for the
seeded-dimension walk-verdict rule), and a `walkthrough` stop carrying a
verbatim `response:` field.

## Cross-references

- Source brief (the schema's own bootstrap run): the ratified `/workshop`
  design brief in the knowledge store's `Designs/` folder.
- Grounding: the L0 design-methodology spike verdict (Context note),
  temperloop#224 (walk-structure follow-up), temperloop#225 (lens-panel
  yield + failure-modes framing follow-up), temperloop#216 (brief-conformance
  lint, `workflows/scripts/validate-design-brief.sh`, shipped 2026-07-11).
- Peer schema: `claude/plan-schema.md`.
- Kernel routing: `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule.
- Overlay-extension precedent: `claude/message-schema.md` § Overlay override
  status.
- Epic-decomposition consumer: `/assess` epic-decomposition mode
  (foundation#526).
