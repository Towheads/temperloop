# Design-brief schema

Canonical coverage-dimension list and disposition grammar for design briefs
produced by `/design` and consumed by `/assess` (via the epic `## Contract`
it materializes into). Peer of `claude/plan-schema.md` — where a plan note
governs *how an approved epic decomposes into build items*, a design brief
governs *what a proposed feature must have decided before it becomes an
epic at all*. This file is the brief's contracts doc; `claude/commands/design.md`
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
status: draft                         # draft | ratified
source_kind: claude-stamped
source_session: <session-id>
source_model: <model id that drafted the brief>
last_verified: <YYYY-MM-DD>
---
```

This is the standard vault provenance schema (note-level) plus one
brief-specific field: `status`. `status: draft` is the gate between the
coverage walk and materialization — the command's ratify step
(`/design` Step 6) flips it to `ratified` only after every dimension carries
a disposition (§ Disposition grammar) and the review tier for that epic's
weight has run (`/design` Step 3–4). A `ratified` brief is treated as
immutable going forward: a later change is a **new** brief that supersedes
it (linked via `[[wikilink]]`), the same convention `Decisions/` notes use
for supersession — never an edit-in-place of a ratified brief.

## Kernel dimension list

Sixteen dimensions, one per numbered section of a brief. The kernel owns
this list and its order; an overlay may **add** dimensions but never
remove or reorder a kernel one (§ Overlay extensibility). Each entry below
states what the dimension must answer and the mechanism — if any — that
checks the promise at merge time. The "Enforcing gate" column's own
citations are not themselves lint-checked today (no lint scans this file's
gate references); the forthcoming brief-conformance lint (temperloop#216)
is chartered to also resolve this doc's gate citations, closing that gap.

| # | Dimension | What it answers | Enforcing gate |
|---|---|---|---|
| 1 | **Problem & outcome (stranger standpoint)** | The problem and the customer-visible outcome, stated from a stranger's point of view — never the implementation's. Decides the stranger test (kernel vs overlay routing, `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule). | Advisory — no mechanical gate; the stranger-test call is reviewed by the adversarial panel and, downstream, by whichever repo the resulting code actually lands in. |
| 2 | **Audience & interaction modes** | Who the feature is for (live operator, unattended run, both) and which `claude/message-schema.md` interaction modes it uses. | Advisory today — briefs live in the knowledge store, outside the repo, so no repo CI lint can scan one (`workflows/scripts/validate-template-refs.sh` scans only `claude/CLAUDE.kernel.md` + `claude/commands/*.md`, never a brief); brief-side template/mode reference checking routes to the forthcoming brief-conformance lint (temperloop#216), which runs at ratify time in a session that can read the knowledge store. |
| 3 | **Alignment (guiding principles / routing)** | How the feature advances a guiding principle, and the kernel-vs-overlay routing decision with its rationale. | Advisory at design time (reviewed by architecture-reviewer); the routing call is checked downstream when code lands — a kernel-routed dimension implemented as overlay code (or vice versa) trips `workflows/scripts/kernel/check-kernel-manifest.sh`'s path classification at merge. |
| 4 | **Contract seams (Produces / Consumes / Acceptance)** | The epic-shaped contract this design will materialize into (§ Materialization contract) — what the resulting work produces, what it depends on, and how completion is checked. | No static lint yet (forthcoming brief-conformance lint, temperloop#216); functionally enforced today by `/assess`'s epic-decomposition mode (foundation#526), which asks/fails when Produces/Consumes/Acceptance aren't well-formed enough to decompose without reshaping. |
| 5 | **Command/mechanism shape** | A steps sketch for the resulting workflow (if the design produces a command or ritual) — enough for a reviewer to judge shape, not the final grammar. | If the design produces a prose workflow spec (`claude/commands/*.md`), the `workflow-reviewer` agent covers every edit to it going forward — advisory, standing review, not merge-blocking. |
| 6 | **Scalability & resource impact** | Token/API cost, and — when the design touches board writes — GraphQL budget impact; the cost tier stated up front. | Advisory — no dedicated gate for the write-up; a design that adds direct Projects-v2 queries is caught at implementation time by `board-adapter-guard.sh`'s prompt-on-raw-query backstop. |
| 7 | **Maintainability** | Coupling this design introduces (which gates/contracts must move together), and whether it introduces a new live-capture rule needing a drain backstop. | `workflows/scripts/validate-live-drain.sh` — CI-enforced; fails the build if a new live/drain pair is only half-shipped. |
| 8 | **Testability** | What is mechanically gated vs. honestly advisory-only. | `scripts/quality-gates.sh` / the `KERNEL_GATES` set — the repo-wide static gate list every PR runs. |
| 9 | **Telemetry & measurement proxies** | Cheapest-first proxies for whether the feature worked, per the existing measurement-proxies convention. | `claude/measurement-proxies.md`'s contract, backed by the emit/validate pairs (`emit-command-run.sh`/`validate-command-run-emit.sh`, `emit-issue-touch.sh`/`validate-issue-touch-emit.sh`) when the design's proxies ride those paths; a genuinely new proxy stream still needs Live/Drain pairing (dimension 7). |
| 10 | **Upgrade path** | Whether this design changes a contract surface an overlay/stranger couples to (`VERSIONING.md` § The contract surface), and what CHANGELOG marker that implies. | The `breaking_sections()` detector in `scripts/update-kernel.sh` (reads the CHANGELOG `BREAKING` marker) plus the version-tag bump rule in `VERSIONING.md`. |
| 11 | **Uninstallability / reversibility** | What removing this feature requires — hooks, cron, runtime state, paired registry entries — so removal is clean, not a slow leak. | The family of registry/lint half-removal validators: `validate-live-drain.sh` (Live/Drain pairs), `validate-template-refs.sh` (template registry refs), `validate-feature-docs.sh` (`STALE-EXEMPT`/`ORPHAN-DOC`/`UNCLAIMED` catch a half-removed doc or path claim), `check-knob-registry.sh` (registry↔shell equality). |
| 12 | **First-run experience** | What a stranger's fresh install/first invocation experiences, with no prior state. | Advisory — no static gate; verified experientially by an executed first-run/uninstall persona run (mandatory whenever the design touches the install surface). Designs touching `bin/`/install code additionally run through `scripts/tests/test_stranger_config.sh`. |
| 13 | **Docs & marketing surface** | The feature doc this design will need (five required sections) and any positioning/marketing claim. | The feature-docs coverage gate, `workflows/scripts/validate-feature-docs.sh` (temperloop#132) — a non-exempt manifest slug with a missing/empty required section fails CI. |
| 14 | **Security / privacy** | What personal/org content this design's conversation or artifacts might carry, and where the public/private boundary sits. | The PR leak guard, `workflows/scripts/kernel/check-pr-leak-guard.sh` (temperloop#74) — scans outbound content before it can land in the public repo. |
| 15 | **Failure modes, degradation & capability limits** | Premortem-framed failure story, legible-degradation paths for every optional dependency, and honest capability limits (never overclaimed). | Advisory — no static lint; the legible-degradation invariant it documents (`skipped — <agent> unavailable`, never a silent no-op) is checked by `workflow-reviewer` wherever the resulting command spec implements a capability-probe gate. |
| 16 | **Adoption & enforcement** | How this design's flow **displaces the default it replaces** — every design must answer this, not just ones that add new commands. | The kernel routing rule (`claude/CLAUDE.kernel.md`) + `/assess`'s in-pipeline provenance check (an epic with `## Contract` but no `design-brief:` marker triggers a legible ask; forthcoming — temperloop#218) + the `/tidy` drain backstop (forthcoming — temperloop#218; it ships registered as a Live/Drain pair with that item, at which point dimension 7's own gate covers the pair's completeness). |

Dimension 16 (Adoption & enforcement) is itself a template addition
discovered by the /design brief's own bootstrap run — every design brief,
not only ones proposing a new command, must answer how its resulting flow
displaces the default behavior it replaces, or state honestly that it
doesn't change any existing default.

> **Provisional — pending temperloop#224.** Dimension 5's coverage-**walk
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

Every dimension in a brief gets **exactly one** explicit disposition —
no dimension may be silently absent:

```
filled                         — the dimension is answered in the brief body
n/a — <reason>                 — genuinely inapplicable to this design, with the reason stated
deferred → <tracking ref>      — real but out of scope for this brief; ref is an issue/epic that owns it
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

**No-silent-skips rule.** A brief with an undispositioned dimension fails
the brief-conformance lint. The lint itself ships as a separate item
(temperloop#216, forthcoming) — until it lands, this rule is an authoring
standard enforced by the review tier (`/design` Step 4), not yet a
mechanical gate; `/design`'s ratify step (Step 6) must not flip
`status: draft → ratified` while any dimension lacks a disposition,
regardless of whether the lint exists yet.

## Overlay extensibility — add-only

The kernel owns the sixteen-dimension default list (§ Kernel dimension
list) and its order. An overlay **may add** dimensions — an org-specific
concern with no meaning in a stranger's kernel-only checkout — but **may
never remove or weaken** a kernel dimension. This is the same
kernel-precedence shape `claude/message-schema.md` § Overlay override
status establishes for its named templates (an overlay may extend a
sanctioned surface, never contradict a kernel contract), applied here to a
list rather than a template body: appending is sanctioned, subtracting is
not. The override *mechanism* itself — how an overlay declares an added
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

`/design`'s materialize step (Step 7) turns a ratified brief into a board
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

  This is what `/assess` Step 1's in-pipeline provenance check (forthcoming
  — temperloop#218) looks for: an epic carrying a `## Contract` but no
  `design-brief:` marker triggers a legible ask (proceed without a brief,
  or park and run `/design` first) rather than either a silent bypass or a
  hard block. `/triage`'s mirror redirect line for new-design material
  handed to it instead of an already-designed epic ships with the same item
  (forthcoming — temperloop#218).
- **The brief's home stays `Designs/`** in the knowledge store — the epic
  links to it, it is never copied into the epic body. The brief is the
  deliberation record (full reasoning, rejected alternatives, persona
  findings); the epic is the operational tracker; a paired `Decisions/`
  note is the short personal-capture cross-link. Three artifacts, one
  deliberation, no duplication.

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
<cost tier; GraphQL/token impact>

## 7. Maintainability
disposition: filled
<coupling to watch; any new Live/Drain pair this introduces>

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
```

## Cross-references

- Source brief (the schema's own bootstrap run): the ratified `/design`
  design brief in the knowledge store's `Designs/` folder.
- Grounding: the L0 design-methodology spike verdict (Context note),
  temperloop#224 (walk-structure follow-up), temperloop#225 (lens-panel
  yield + failure-modes framing follow-up), temperloop#216 (forthcoming
  brief-conformance lint).
- Peer schema: `claude/plan-schema.md`.
- Kernel routing: `claude/CLAUDE.kernel.md` § Kernel vs overlay routing rule.
- Overlay-extension precedent: `claude/message-schema.md` § Overlay override
  status.
- Epic-decomposition consumer: `/assess` epic-decomposition mode
  (foundation#526).
