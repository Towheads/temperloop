# Message schema

> **Source of truth: `claude/message-schema.md`**, deployed to
> `~/.claude/message-schema.md` by the same `claude/*` install glob
> (`workflows/scripts/install/links.sh`) that deploys `plan-schema.md`,
> `presentation-plane.md`, and `measurement-proxies.md` — every file in
> `claude/` deploys automatically except the two CLAUDE.kernel.md /
> CLAUDE.overlay.md compose sources, which the installer composes separately
> (§ Kernel vs overlay routing rule). Epic: temperloop#94 ("Communication
> style model"), plan item `message-schema`.

Peer to `claude/plan-schema.md`: where that file is the contract for plan-note
*data*, this file is the contract for the kernel's **named message
templates** — the recurring shapes a template-driven output takes, keyed to
who is reading it and when. It does not re-litigate which surfaces are safe
to restyle at all (`claude/presentation-plane.md` owns that classification)
or re-derive whether "readable" moved the needle (`claude/measurement-proxies.md`
owns that). This file only answers: for a given reader-state, what does a
well-formed message contain.

Grounding: an adversarial deep-research pass on temperloop#94 (5 search
angles → 25 sources → 121 claims → top-25 verified via 3-vote refutation
panels, synthesized to 12 Tier-1 findings), followed by an L0 spike
(`tier2-evidence-verify`) that put the report's five Tier-2 clusters through
the same verification, confirming 21/25 claims. Full detail:
`Context/temperloop - communication-style Tier-2 verification verdicts`
(vault note). Citations below are restated only as far as a template
decision needs; see that note for the full verdict table.

## Scope — artifact-shaped templates only

This file authors **artifact-shaped** templates: message shapes that are
written *into* a standalone artifact (a PR body, a board comment, a digest
record) and can be named, checked, and overridden as a unit. It deliberately
does **not** author **every-turn conversational shapes** — the completion
summary and the resume recap. Those stay inline in `claude/CLAUDE.kernel.md`
§ Communication conventions, because they are properties of *every response*
in a live session, not a discrete artifact a template engine renders once.
This file may reference them by name (as it does below, in the reader-state
table) but must never move or restate their content — doing so would create
a second, driftable copy of a rule the kernel file already owns (the
contract-by-pointer risk `claude/presentation-plane.md` warns against for
parsed surfaces applies just as much to prose rules split across two files).

The five templates authored here: **PR-body skeleton**, **parking note**,
**digest entry**, **question block**, **degradation notice**. Rewriting
`CLAUDE.kernel.md`'s existing communication rules to be *instances of* this
model is a separate, later plan item (`kernel-guides-unify`) — not performed
by this file. The overlay override mechanism itself was a separate, later
plan item (`override-seam`) at authoring time; it has since landed as
§ Overrides below.

## The seven interaction modes (recap)

Canonical in temperloop#94; restated here (as `measurement-proxies.md` also
does) only so each template's mode-mapping below is self-contained:

1. **CLI terminal output** — `try`/`init`, board commands, `gate.sh`
2. **Live conversational narration** — slash commands mid-session
3. **Blocking questions** — `AskUserQuestion` / `decision_sink_ask(...)`
4. **Return-cold summaries** — completion summary, resume recap, parking notes
5. **Unattended/deferred surfaces** — pending-decisions, digests, funnel-tick reports
6. **Durable review artifacts** — PR bodies, issue/epic contracts, plan notes, decision notes
7. **Newcomer/docs surface** — README, `bin/README`, generated docs site

## Reader-state axes

Every mode is a specific point (or span) on two independent axes: whether
the reader is live for the moment the message is produced, and what kind of
reader they are. Grice's maxim of Quantity — say as much as the exchange
requires, no more — is the cross-cutting frame; a mode's position on these
axes is what "as much as this exchange requires" cashes out to.

- **Presence** — `present` (reading synchronously, in the same session) /
  `cold` (returning after a gap, no live memory of the interim) / `absent`
  (not present when the message was produced; may never have been).
- **Reader** — `operator` (the resident driving this repo) / `stranger`
  (unfamiliar with private context — a newcomer, external contributor, or
  cross-repo reader) / `parser` (a mechanical reader: GitHub's closing-keyword
  scanner, `/build`'s orchestrator, a shell script's `jq` caller).

| # | Mode | Presence | Reader | Templates authored here | Key grounding |
|---|---|---|---|---|---|
| 1 | CLI terminal output | present | operator, stranger | *(none — style-free CLI text is unauthored; structured `.outcome` JSON is frozen, see `presentation-plane.md`)* | — |
| 2 | Live conversational narration | present | operator | Degradation notice (minimal form) | Mode-2 conciseness must be *structurally* enforced (locked) |
| 3 | Blocking questions | present | operator | Question block (blocking variant) | Amershi G3/G10 (locked) |
| 4 | Return-cold summaries | cold | operator | Parking note | Endsley skeleton (locked-structural; effectiveness provisional) |
| 5 | Unattended/deferred surfaces | absent | operator | Digest entry; question block (deferred variant) | Endsley skeleton + Lee & See calibrated trust (locked); Iqbal & Bailey ~90s anchor (locked) |
| 6 | Durable review artifacts | cold, absent | operator, stranger, parser | PR-body skeleton; degradation notice (recorded form) | ETRA-2025 title/desc/labels + mandatory Purpose + commit What+Why (all locked) |
| 7 | Newcomer/docs surface | absent | stranger | *(none — the docs-generator surface, out of scope for this file)* | Expertise reversal (locked): the same text cannot optimally serve mode 1 and mode 7 |

Mode 6 spans two presence states and all three reader types deliberately — a
PR body is read cold by its reviewer, absently by a later auditor, and
mechanically by GitHub's own closing-keyword scanner, all from the same
bytes. That is exactly the "mixed surfaces" trap `presentation-plane.md`
names: restyle the prose freely, leave the frozen fields (a bare `Closes #N`
line) byte-for-byte alone.

## The reference-token rule

A template class, not a single template: **any token whose meaning lives in
an external system — an issue/PR/epic id, a board id, a plan-note slug, a
session id, a milestone/phase name — must be self-sufficient at its point of
use.** Concretely:

- **First-mention inline hook.** The first mention of any such token in a
  response or artifact carries a short title hook drawn from the referent's
  own title/name — `#94 (communication-style epic)` — capped at roughly six
  words (Grice Quantity: enough to recognize or dismiss, not a summary).
  Bare refs are allowed only for **re-mentions** within the same response or
  artifact.
- **Board identity is named, not numbered, in prose.** Prose and templates
  use board *names* (`foundation`, `stageFind`); a raw numeric id appears
  only inside a literal, copy-pasteable command line (`--board 4`), never as
  a standalone identifier a reader must resolve from memory.
- **A legend/reference table is reserved for mode 6.** Only a long,
  non-linearly-read durable artifact — where any section may be the reader's
  first contact with a given ref — earns a trailing reference table. Modes
  1–5 never emit one.

This **supersedes** the every-response refs-legend convention as currently
written in `claude/CLAUDE.kernel.md` § Communication conventions: appending a
legend to every response is a split-attention layout (the id appears inline,
its meaning at the bottom, and the reader pays the integration cost) that
directly contradicts the locked CLT proximity finding (place related
information adjacent; eliminate the need to hold lookup state — Tier-1
findings 2 and 7). The supersession is stated here as the rule this schema
defines; **rewriting `CLAUDE.kernel.md`'s own prose to retire the legend and
adopt first-mention hooks is the separate `kernel-guides-unify` plan item**,
not performed by this change.

## Templates

Each template names its mode(s), its slots (required unless marked
optional), and the finding(s) it rests on. Where a template's substrate
overlaps a frozen surface owned elsewhere, that surface is named, never
restated.

### PR-body skeleton

**Mode(s):** 6 (durable review artifact) — read cold by the reviewer,
absently by a later auditor, mechanically by GitHub's closing-keyword
scanner.

- **Title** — front-loads the outcome; the primary read surface eye-tracking
  shows a triage reader actually fixates (locked, ETRA-2025).
- **Purpose ("what + why")** — mandatory. Locked as the top PR-body element
  by reader-rated importance (MSR-2026, ~80k PRs/156 projects); front-load it
  per BLUF (Tier-1 finding 1).
- **Verification surface** — required. Defers entirely to `CLAUDE.kernel.md`
  § PR verification surface for the by-change-type breakdown; this template
  only requires the slot exist, not its shape.
- **Reference tokens** — apply the reference-token rule above to every
  issue/PR/epic mention.
- **`Closes`/`Fixes` lines** — **frozen**, owned by `CLAUDE.kernel.md` §
  Issue linkage and indexed in `presentation-plane.md`'s kernel table. Not
  restated here; do not reformat.
- **Labels** (optional, advisory) — keep accurate; a stale label undermines
  the same title/description/labels triage signal the Title slot above
  relies on.
- **Desired feedback / focus area** (optional) — what kind of review
  attention this PR wants. Worth keeping despite reading as low-priority: the
  same MSR-2026 study found this field ranked *lowest* in reader-perceived
  importance yet *best predicted* engagement — don't cut it for looking
  unimportant.

### Parking note

**Mode(s):** 4 (return-cold), instantiated into a mode-6 substrate (a board
comment or plan-note line) for later reading.

Formalizes the existing "Park, don't abandon" rule (`CLAUDE.kernel.md` §
Task workflow) against the Endsley situation-awareness skeleton (locked,
structural only — three required slots, not a single "note where it stands"
line):

- **Perception** — what's done; the current state as of parking.
- **Comprehension** — why it matters / what it means for the item as a
  whole, not just a restatement of the perception slot (the CLT redundancy
  finding, Tier-1 finding 3, is the reason this slot must add integration,
  not repeat the artifact).
- **Projection** — the next concrete step. Already required by the informal
  "Park, don't abandon" rule; this template makes it the third leg of a
  three-part skeleton rather than a bare instruction.
- **Blocking pointer** (optional) — if parked pending a question, a pointer
  to the question block entry (below) that's blocking resumption.

**Provisional caveat:** the Endsley skeleton's *structure* is grounded
(Endsley 1995); whether it actually speeds resumption for this kind of
technical work is untested (SE-effectiveness is a borrowed scaffold, not an
SE result) — see § Provisional slots.

### Digest entry

**Mode(s):** 5 (unattended/deferred), read cold (mode 4) whenever the
operator later reviews it.

- **Event(s)** since last contact — perception.
- **Integrated meaning** — why the events matter together, not a bare list;
  per CLT (Tier-1 findings 2–3), don't restate what a linked artifact already
  shows without adding integration.
- **What happens next / what's needed from the reader, if anything** —
  projection. An entry with nothing pending should say so explicitly (Grice
  Quantity — don't manufacture urgency to fill the slot).
- **Calibrated-trust statement**, where the entry reports on autonomous or
  unattended action — state confidence and limits honestly (locked, Lee &
  See 2004) rather than defaulting to a uniformly confident tone.
- **Deferred-question backlog pointer** (optional) — a link to any question
  block entries (deferred variant, below) this digest is surfacing.

The Endsley skeleton and Lee & See calibrated trust are both locked
(structural). The **cadence** these entries batch on — deferring non-urgent
items to natural breakpoints rather than interrupting — is grounded in the
locked ~90s (88.6s mean) acceptable-deferral-cost finding; that anchor
justifies *why* entries batch and defer, not a claim about entry wording.

### Question block

**Mode(s):** 3 (blocking, present-reader) and 5 (deferred, absent-reader) —
one slot shape, two variants.

Shared required slots:

- **Context** — why this question exists now (Amershi G3, locked: don't
  interrupt without stating why it can't wait, or conversely why it's being
  batched instead of interrupting).
- **Options** — named choices, not a bare yes/no where a real choice exists
  (Amershi G10, locked: disambiguate rather than auto-commit when uncertain).
- **Routing** — a pointer to where the resolution is recorded (a plan-note
  `## Questions` entry, a decision-queue issue, the pending-decisions note) —
  a pointer to that surface, never a restatement of its grammar.

**When the block is the right vehicle.** This structured block (and
`AskUserQuestion`) fits a **bounded** decision — approve/reject, or pick from
a small closed set of named options. For an **open-ended** question — an
exploratory design fork, a "what should this even look like" — prefer plain
prose: forcing open-ended judgment into fixed options usually means the option
set omitted the real answer, and an operator who rejects every option is
exactly that signal. Reserve the block for the bounded case; ask the open-ended
one in prose.

Variant-specific:

- **Blocking variant** (mode 3): no default is required — the reader is
  present to decide directly.
- **Deferred variant** (mode 5): a **default is required** — this is the
  existing convention in `claude/plan-schema.md` § Orchestrator-written
  `## Questions` section ("every `batch-at-gate` entry MUST state its
  default") and in the pending-decisions surface; this template names both
  as the canonical deferred-variant instances rather than re-specifying
  their frozen grammar.

**Defers to (frozen, not restated):** `claude/plan-schema.md` §
Orchestrator-written `## Questions` section (checkbox/step/default/
auto-proceed grammar); `claude/decision-queue-contract.md` § 3 (typed reply
grammar, ` ```decision ` block, `/choose`/`/approve`).

### Degradation notice

**Mode(s):** 2 (live, minimal form) and 6 (recorded, fuller form when the
same notice lands in a durable artifact).

- **What was skipped or degraded** — the gate, agent, or mechanism.
- **Why** — the capability-probe result (e.g. "unavailable"), per
  `CLAUDE.kernel.md` § Subagent usage's "Legible agent-gate degradation" rule
  — this template is the presentation instance of that existing rule, not a
  restatement of it.
- **Calibrated-trust statement** — what the degradation means for confidence
  in the surrounding result (locked, Lee & See); never silently imply full
  confidence when a gate didn't run (Amershi G10, locked).
- **Remedy pointer** (optional) — what would restore the capability, if
  known. In mode 6 this is unconditional; in mode 2 it is permitted **only**
  for the shipped-but-not-installed subagent case defined below.

The mode-2 minimal form has **two shapes, and only two.** Its **default** is
the bare one-line `skipped — <agent> unavailable` convention verbatim — that
exact wording is owned by `CLAUDE.kernel.md` itself and is not restated here.
Its **one sanctioned exception** is the *shipped-but-not-installed* case: when
the skipped capability is a subagent that **ships as source under
`claude/agents/<agent>.md`** but is not resolvable as a live agent (no
`.claude/agents/<agent>.md` and no `CLAUDE.md § Subagents` declaration), the
mode-2 line MAY carry a **single short remedy clause** naming the one-command
fix — `skipped — <agent> available as source; run
workflows/scripts/install/project-agents.sh to enable`. This is the **only**
remedy pointer permitted on a live mode-2 line; it exists because this
specific degradation has a known, in-the-moment fix the operator needs
*while the panel is running*, not merely in a later durable record.
Conciseness stays structurally enforced — one clause, this case only; every
other mode-2 skip (a genuinely not-shipped agent, or a non-agent capability
like `/verify` that has no `project-agents.sh` install path) stays bare. The
fuller mode-6 form still adds the calibrated-trust and (unconditional) remedy
slots because a cold or stranger reader of a durable artifact lacks the live
session's surrounding context; this live-vs-recorded distinction is an
authoring judgment call, not itself a research-grounded finding — flag it as
such rather than dressing it up as locked.

## Provisional slots — do not lock

Per the L0 verification verdict, the following remain explicitly
provisional. A template above rests its *structure* on these where noted,
but none of the following may be authored as a firm, load-bearing rule:

- **Endsley skeleton's SE-effectiveness** (parking note, digest entry) —
  the three-part structure is grounded (Endsley 1995); whether it measurably
  speeds context resumption for this kind of technical work is untested.
- **The specific mode-2 verbosity-enforcement mechanism** — the premise
  (soft "be concise" fails; conciseness must be structurally enforced) is
  locked, but *which* mechanism (template length caps, a lint, a different
  device) actually enforces it is not — this file names the templates as the
  enforcement surface without claiming that surface is proven sufficient.
- **Mode-2/6 error-message readability tuned to expertise level** (Cluster
  5) — **unresolved**, zero evidence found either way; templates here must
  not assume the CHI-2021 vocabulary/jargon/sentence-structure/length
  findings (novice populations) generalize to an operator or expert reader
  of CLI/PR content. Routed to temperloop#100.
- **"Over-explanation harms comprehension/trust"** as a causal claim — the
  parking-note and digest-entry "don't restate what's already visible"
  guidance above rests only on the locked CLT redundancy-effect finding
  (self-sufficient artifacts, Tier-1 finding 3), not on a proven link to
  reader trust or comprehension outcomes. Routed to temperloop#100.

## Citation hygiene

- Cite **Iqbal & Bailey** (CHI 2008 / TOCHI 2010) for the ~90s (88.6s mean)
  breakpoint-deferral-cost anchor — **not** Iqbal & Horvitz.
- Scope the LLM-verbosity figure (≈50.4% compressible without information
  loss) to **short-QA tasks with an explicit brevity instruction** — do not
  generalize it to "about half of all responses."
- Do **not** cite arXiv 2507.10906 for the commit "What + Why" definition —
  refuted 0-3 on primary-source verification. Cite ICSE 2023 (doi
  10.1109/ICSE48619.2023.00076) and the stairs.ics.uci.edu commit-messages
  corpus study instead.
- Do **not** cite the cascade-mitigation numbers (e.g. Mistral
  63.81%→16.16% on Qasper) as a proven fix for verbosity — refuted 0-3; the
  premise that structural enforcement is needed survived, the specific fix
  did not.

## Overlay override status

The named templates in this file are the sanctioned surface an overlay may
override — see the carve-out added to `claude/CLAUDE.kernel.md` § Kernel vs
overlay routing rule in this same change. § Overrides below specifies the
mechanism (redeclaration precedence, dangling-override detection): "sanctioned
surface" means a future override of one of these five templates by name is
not, by itself, a violation of "overlay may extend, never contradict",
resolved per that mechanism.

## Overrides

This is the mechanism the carve-out in `claude/CLAUDE.kernel.md` § Kernel vs
overlay routing rule points at. It governs only the five named templates
this file authors (§ Templates) — no other kernel contract is overridable by
this or any other route.

- **Whole-template redeclaration by name, not a delta.** An overlay overrides
  a template by writing out the **entire template again under the same
  name** — not a structured patch/delta against the kernel's version (no
  "change slot X, leave the rest"). This is a deliberate rejection of a delta
  format, for a reason an architecture review flagged as load-bearing: a
  delta needs something to diff *against* and *stay in sync with* — a second
  drift guard tracking whether the delta still applies to the kernel
  template it patches. Whole-template redeclaration needs no such guard,
  because there is nothing to drift out of sync: the overlay's copy is
  simply read instead of the kernel's, in full, whenever it exists. Per
  `claude/CLAUDE.md` § Design discipline (subtraction over mechanism), a
  delta format is machinery to justify, not a default — and whole-template
  redeclaration is the smaller mechanism that gets the same override power
  without it.
- **Composition precedence: later-definition-wins.** Where both the kernel
  and an overlay define a template of the same name, the later definition in
  the compose order wins. This is the same order `workflows/scripts/
  install-claude-md.sh` already uses to compose `CLAUDE.kernel.md` and
  `CLAUDE.overlay.md` into the installed `~/.claude/CLAUDE.md` — kernel
  content first, overlay content concatenated after (§ Kernel vs overlay
  routing rule) — so "the overlay wins" is not a new precedence rule this
  file invents; it is the existing kernel-then-overlay compose order applied
  to template names instead of prose sections. A template name the overlay
  does not redeclare is untouched: the kernel's definition stands.
- **A no-override checkout is byte-identical, by construction.** A checkout
  with no overlay overrides present behaves exactly as this file defines,
  because there is no overlay definition to compose after the kernel's — the
  later-definition-wins rule has nothing to prefer, so the kernel template is
  what's read. This is a property that **falls out of** whole-template
  redeclaration; it is not a separate claim that needs its own proof or
  guard. (Contrast a delta format: even a no-op delta is a thing that could
  exist, drift, or be checked for existing — whole-template redeclaration
  has no such residue when absent.)
- **Dangling-override rule.** Every overlay-defined override name MUST match
  the name of a template this file defines (§ Templates) — an overlay may
  not "override" a template that doesn't exist here. Checking this
  mechanically is the job of the `template-lints` plan item (L4); this file
  states the rule, `template-lints` implements the check. Do not re-implement
  or duplicate that check here or elsewhere.
- **Per-template staleness detection is out of scope.** Whole-template
  redeclaration means a kernel update to a template's *content* (wording,
  slots, grounding) is silently shadowed wherever an overlay has redeclared
  that same name — the overlay's copy keeps winning under
  later-definition-wins even after the kernel version it was copied from has
  since changed. This is a known, accepted trade-off of the contract above,
  not an oversight: per the same subtraction-over-mechanism reasoning that
  rules out a delta format, a staleness guard (detecting when an overlay
  override has drifted from the kernel template it shadows) is itself
  exactly the kind of second mechanism whole-template redeclaration is
  designed to avoid needing. It is a ratified deferred seam, not an open
  question — see the epic's Re-triage signals / epic decision on this point
  (temperloop#94). Do not add a staleness guard, lint, or warning under this
  section; a future change that decides the trade-off is no longer
  acceptable is a new plan item against the epic, not an amendment folded in
  here.

## Cross-references

- Epic: temperloop#94 ("Communication style model: interaction-mode
  presentation layer")
- Peer contract (plan-note data, not message shape): `claude/plan-schema.md`
- Surface classification (what's safe to restyle at all):
  `claude/presentation-plane.md`
- Falsifiability contract for "did this help": `claude/measurement-proxies.md`
- Decision-queue mechanics (question block, deferred variant):
  `claude/decision-queue-contract.md`
- Existing rules this file's templates formalize, referenced not restated:
  `claude/CLAUDE.kernel.md` §§ Communication conventions, PR verification
  surface, Task workflow ("Park, don't abandon"), Subagent usage ("Legible
  agent-gate degradation")
- Reference-token design input: comment on temperloop#94 ("Design input:
  reference tokens are a first-class artifact class")
- L0 verification verdicts: `Context/temperloop - communication-style
  Tier-2 verification verdicts` (vault note)
- Deferred research debt (Cluster 5, over-explanation→harm link): temperloop#100
- Later plan items that build on this file: `kernel-guides-unify` (rewrites
  `CLAUDE.kernel.md`'s prose against this schema, retires the refs legend),
  `overlay-adoption` (foundation's adoption), `template-lints` (CI
  conformance checks, including the § Overrides dangling-override rule).
  `override-seam` (specified the override mechanism, § Overrides above) has
  landed.
