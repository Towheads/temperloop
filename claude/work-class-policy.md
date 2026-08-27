# Work-class taxonomy: Operational vs Foundational

Every issue/epic processed by the autonomous pipeline driver carries one of two <!-- cite: WC.1 incident:F#567 -->
**work-class labels**.

**Scope has widened past the driver alone (epic Towheads/temperloop#1847).**
The label started as one consumer's private setting — the autonomous pipeline
driver's own autonomy policy for an item, § Policy table below — and now
doubles as a **pipeline-wide routing key** that other pipeline stages read to
make their own structural decisions: `/sweep`'s Operational-epic
member-admission gate (`workflows/scripts/build/sweep-epic-admission.sh`)
reads it to decide whether an epic's Ready legs may join the singleton fix
pool at all, and `/triage`'s Step 4 logical-order stamping
(docs/adr/0031-durable-logical-order-lives-on-the-board-as-blocked-by.md)
reads it to decide whether a group's ordering may live as durable board
`blocked_by` edges (Operational) or must stay plan-resident `after:` edges
(Foundational). One pair of labels, several independent readers — not a
driver-private setting any more. <!-- cite: WC.3 guard:workflows/scripts/build/sweep-epic-admission.sh -->

> **Canonical source:** `Decisions/foundation - Autonomous pipeline driver + GitHub decision queue`
> (vault note, sections "Work-class taxonomy" + "Settled policy details").

---

## Policy table

| Label | What it covers | Driver autonomy policy |
|---|---|---|
| `Operational` | Bug fixes, follow-ups, issue splits, bugs found mid-work, venue/artist expansion along an **established axis** | **Fully autonomous** — triage → sweep (auto-merge per chunk once CI green; **modal, never timed, for a correlated set**, `claude/commands/sweep.md` § regime selection, epic #1847). An ordinary chunk of unrelated Ready singletons is provably independent and rides the timed, no-objection-window auto-merge path unchanged. A chunk carrying an **epic-admitted member** (`$SWEEP_ADMIT_OPERATIONAL_EPICS`) is no longer provably independent — two legs of one epic are drawn from a single design — so `gate.sh risk` partitions it, and anything short of a clean/disjoint/independent verdict is offered **modally** instead of timed, per `claude/CLAUDE.md § Merge autonomy & consent`'s "only a clean, disjoint set is timed; a risky set is always modal." Parks only on a genuine design-fork halt (`/build`) or a worker escalation / merge-risk hold (`/sweep`). |
| `Foundational` | New features, new *kinds* of task, architectural decisions, highly disruptive changes, environment changes | **Prep-then-gate** — driver may decompose and draft a plan, but always routes design decisions + plan approval to the operator's decision queue before building. Operator-led. |

---

## Precedence when both labels are present: `Foundational` wins — per item, and per group

Carrying **both** work-class labels is outside the "one of two" authoring intent
stated above, and no current writer can produce it — `capture.sh` picks exactly
one `work_class` and substitutes rather than appends, and `/triage`'s work-class
stamp skips the add when either label is already present. But issues that reached
the both-present state before those writers settled still exist, so the **router
needs a defined answer** for them.

**The rule: when an item carries both labels, it resolves to `Foundational`.**
The driver therefore **gates it to the operator's decision queue**
(`route-foundational`) instead of routing it to autonomous drive — it gets the
`Foundational` row's prep-then-gate policy, not the `Operational` row's
auto-merge-once-green policy.

The direction is the fail-safe one: an item whose work class is ambiguous gets
human judgment, never an autonomous merge.

This is deliberately a **router precedence rule, not a new invariant**:

- **No backfill.** Precedence is already correct for the pre-existing
  dual-labeled issues that any stamp-time guard would never reach — picking a
  work class for old issues by rule rather than judgment was rejected.
- **No new enforcement machinery.** Mechanical mutual exclusivity at the stamp
  sites (a `--remove-label` plus a validator gate) would build prevention for a
  case the writers already prevent, while leaving this actual gap undefined.

"Exactly one work-class label" stays the **authoring intent** (unchanged); this
section states only the router's behaviour when reality diverges from it. It
composes with the § Default-Operational rule below as two halves of one lookup,
which is exactly how `pipeline-tick.sh`'s `classify_item` implements it: match
`Foundational` first, fall through to `Operational` otherwise.

**Extension: per-group, not only per-item (epic #1847).** The rule above
answers "what does *this issue's own* label pair resolve to." Operational-epic
member admission (`/sweep` Step 1 item 6, `sweep-epic-admission.sh`) raises the
same question one level up, over a **group** — an epic plus its native
sub-issues — rather than a single item's own labels: does *any* member of the
group carry `Foundational` while the group is being considered for the
`Operational` row's autonomous-merge treatment? The combined label set across
the epic and every one of its sub-issues (not only the Ready ones — a closed
or in-progress sibling's label still counts) is read as `any_foundational_in_group`,
and **`Foundational` wins anywhere in the group exactly as it wins on a single
dual-labeled item**: one `Foundational` member is enough to refuse admission
for every member, including the ones individually labeled `Operational` — the
group is never split so that some legs drive autonomously while a sibling
awaits operator judgment. This is the **same fail-safe direction** as the
per-item rule above (a work class ambiguous at *any* granularity gets human
judgment, never an autonomous merge), applied at the granularity `/sweep`'s
admission gate actually operates on; it is not a new judgment call, only the
per-item rule's existing rationale extended to cover a group rather than
restated for it. A **uniformly-Foundational** group was never an Operational
admission candidate in the first place and is reported `mixed_class_group:
false` — the mixed-label anomaly this extension exists to catch is
specifically a group straddling both labels, refused and surfaced (never
silently skipped) per `claude/commands/sweep.md` Step 1 item 6's "On `admit:
false`" branch.

---

## The axis: specifiability / blast-radius, NOT origin or recency

The deciding question is: **does this work follow an established pattern, or does it
establish a new one?**

- **Operational** = follows a known pattern (operates or grows the running system along
  known axes). "New" in the sense of recency does not make a work item Foundational.
  A freshly-filed bug is Operational; venue/artist expansion is Operational even
  though it is *initiated* (not event-driven) — it follows a fully-specified,
  established axis.
- **Foundational** = changes the system's shape, requires operator judgment up front
  to determine *what* and *how*.

"New work" was rejected as the axis name because it conflates **recency** (a fresh
bug is new too) with **blast-radius**, and it mis-files the canonical case:
venue/artist expansion is *initiated* yet Operational. The correct axis is
**specifiability/blast-radius**.

---

## Misclassification safety net

The work-class binary is a **default routing, not a guarantee.** An Operational item <!-- cite: WC.2 guard:claude/commands/build.md -->
that turns out to need architectural judgment trips `/build`'s existing **design-fork
halt**, which routes the item to the decision queue regardless of its label. That
safety net is what makes the binary safe even when a classification is wrong.

---

## Default-Operational rule

Issues filed outside `/triage` — via `capture.sh` (mid-work defect capture) or any
ad-hoc `gh issue create` — **default to the `Operational` label.** `Foundational` is
the deliberate exception, marked up explicitly at triage time or when the operator
recognises the item needs their judgment.

This matches the existing **defect-vs-enhancement capture-routing** in `CLAUDE.md`
(defect → Operational; net-new capability → Foundational), making that instinct
machine-readable.

> Note: the `/triage` enforcement of this default (auto-stamping the label at triage
> time) and the `capture.sh` default are implemented in a separate item (foundation#567).
> This document states the rule; #567 wires it into the tooling.

---

## Label designation mechanism

Work-class is carried as a **GitHub repo label** (`Operational` / `Foundational`),
set at `/triage`. This is consistent with the existing `spike` and
`needs-clarification` labels, works identically on every registered board (stageFind 3,
foundation 4, ssmobile 5, subsetwiki 6, temperloop 7) with no per-board field
provisioning, and requires no extra reads beyond what the board adapter
already performs.

Labels are created on each board repo as a one-time setup step (idempotent
`gh label create`). The pilot board is **stageFind / board 3** (repo
`<org>/stageFind`).
