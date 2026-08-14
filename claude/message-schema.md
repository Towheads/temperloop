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

This file authors **artifact-shaped** templates: message shapes that are <!-- cite: MS.1 class:driftable-second-copy -->
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

The six templates authored here: **PR-body skeleton**, **parking note**,
**digest entry**, **question block**, **decision presentation**,
**degradation notice**. Five of the six are the sanctioned overlay-override
surface; **decision presentation** is explicitly excluded from it and may not
be redeclared by an overlay at all (§ Overrides). Rewriting
`CLAUDE.kernel.md`'s existing communication rules to be *instances of* this
model is a separate, later plan item (`kernel-guides-unify`) — not performed
by this file. The overlay override mechanism itself was a separate, later
plan item (`override-seam`) at authoring time; it has since landed as
§ Overrides below.

## The seven interaction modes (recap)

Canonical in temperloop#94; restated here (as `measurement-proxies.md` also <!-- cite: MS.2 incident:K#94 -->
does) only so each template's mode-mapping below is self-contained:

1. **CLI terminal output** — `try`/`init`, board commands, `gate.sh`
2. **Live conversational narration** — slash commands mid-session
3. **Blocking questions** — `AskUserQuestion` / `decision_sink_ask(...)`
4. **Return-cold summaries** — completion summary, resume recap, parking notes
5. **Unattended/deferred surfaces** — pending-decisions, digests, pipeline-tick reports
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
| 3 | Blocking questions | present | operator | Question block (blocking variant); decision presentation (which fills that block's Context slot) | Amershi G3/G10 (locked) |
| 4 | Return-cold summaries | cold | operator | Parking note | Endsley skeleton (locked-structural; effectiveness provisional) |
| 5 | Unattended/deferred surfaces | absent | operator | Digest entry; question block (deferred variant) | Endsley skeleton + Lee & See calibrated trust (locked); Iqbal & Bailey ~90s anchor (locked) |
| 6 | Durable review artifacts | cold, absent | operator, stranger, parser | PR-body skeleton; degradation notice (recorded form); decision presentation (recorded form — its challenge-record line) | ETRA-2025 title/desc/labels + mandatory Purpose + commit What+Why (all locked) |
| 7 | Newcomer/docs surface | absent | stranger | *(none — the docs-generator surface, out of scope for this file)* | Expertise reversal (locked): the same text cannot optimally serve mode 1 and mode 7 |

Mode 6 spans two presence states and all three reader types deliberately — a
PR body is read cold by its reviewer, absently by a later auditor, and
mechanically by GitHub's own closing-keyword scanner, all from the same
bytes. That is exactly the "mixed surfaces" trap `presentation-plane.md`
names: restyle the prose freely, leave the frozen fields (a bare `Closes #N`
line) byte-for-byte alone.

## The reference-token rule

A template class, not a single template: **any token whose meaning lives in <!-- cite: MS.3 incident:K#94 -->
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

**Mode(s):** 6 (durable review artifact) — read cold by the reviewer, <!-- cite: MS.4 guard:workflows/scripts/build/pr.sh -->
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
  See 2004) rather than defaulting to a uniformly confident tone. The
  concrete failure mode this guards against is citable: explanations can be
  **persuasive but not informative**, raising reader acceptance of *wrong*
  outputs (arXiv 2605.10930) — a confident-sounding rationale is itself a
  trust-miscalibration risk, not automatically a transparency win.
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

Conditionally-required slot:

- **Problem summary** — required whenever the block asks the operator to
  **approve work that resolves a tracked item** (the merge gate is the
  canonical instance: `claude/commands/fix.md` Step 5 and
  `claude/commands/build.md` Step 4a/4b). Order the block **problem first,
  then the change**: a compressed one-to-two-line restatement of the linked
  issue's own defect statement — **not its title**, which the block already
  carries as an identifier and which names the change rather than what was
  broken. Without it the operator can judge that a change is coherent but
  not that it addresses the right problem or that the fix shape was the
  right trade-off — precisely the judgment a blocking approval reserves for
  a human, so a prompt missing it collects a weaker consent than it appears
  to.
- **Source — ONE `gh issue view <n> -R <owner>/<repo> --json body` at ask
  time.** Name it, because the defect prose is **not** already in hand when
  the block renders: the run's own state probe
  (`workflows/scripts/build/issue-state.sh resolve`) reads
  `state,labels,assignees` — no `body`, no `title` — so holding a *resolved
  issue number* is not holding its defect statement. A slot sourced from
  "whatever the run already has" would therefore take its unavailable arm on
  essentially every ask, i.e. do nothing. The read is negligible where the
  slot is required: the gate fires **once per run**, at a point already
  issuing `gh` calls (the `gate.sh backend` probe), so one issue read buys
  the operator the defect for the cost of a round-trip already being paid.
  Fetch it with `-R` naming **the repo the issue is tracked in**, which is
  not always the repo the PR opens against.
- **Three arms — exactly one renders, none silently dropped.** All three are
  live paths, not decoration; a consumer implementing only the first two has
  left the failure case rendering nothing at all.
  1. **Summary rendered** — the `--json body` read returned a non-empty
     body: the compressed one-to-two-line restatement above.
  2. **`no linked issue — <one-line reason>`** — there is no tracked item to
     read at all (an untracked refactor or chore), so the reader can tell
     "there is no filed defect" from "somebody omitted the summary".
  3. **`summary unavailable — <one-line reason>`** — the read failed or came
     back empty: deleted issue, auth failure, rate limit, network error, or
     a blank issue body. Name which.
- **Never fabricate the defect.** On arm 3 the slot renders the stated
  absence — it does **not** infer, paraphrase, or reconstruct the defect
  from the issue title, the PR title, the branch slug, or the diff. An
  invented restatement is strictly worse than an honest `summary
  unavailable`, because the operator cannot tell the two apart and the
  fabrication lands in the one artifact whose whole purpose is to make merge
  consent better informed. This is the arm's reason for existing: giving the
  failure path a legitimate rendering is what removes the pressure to guess.

**When the block is the right vehicle.** This structured block (and <!-- cite: MS.5 guard:claude/plan-schema.md -->
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
  `## Questions` section ("every `ask-at-gate` entry MUST state its
  default") and in the pending-decisions surface; this template names both
  as the canonical deferred-variant instances rather than re-specifying
  their frozen grammar.

**Defers to (frozen, not restated):** `claude/plan-schema.md` §
Orchestrator-written `## Questions` section (checkbox/step/default/
auto-proceed grammar); `claude/decision-queue-contract.md` § 3 (typed reply
grammar, ` ```decision ` block, `/choose`/`/approve`).

### Decision presentation

**Mode(s):** 3 (blocking, present-reader) — a `/workshop` coverage-walk stop, <!-- cite: MS.10 incident:K#923 -->
a pre-ratify walkthrough step, or the premise-gate ask; the same content
recorded into the brief's challenge record is that instance read cold and
absently later, i.e. mode 6.

**Composes with § Question block — it does not replace it.** A walk stop *is*
a Question block whose **Context** slot is a decision presentation (and whose
**Options** slot carries the stop's named choices, where the stop offers a
closed set). Stating the composition here is what keeps neither template's
slots dangling: § Question block still owns Context/Options/Routing and the
blocking-vs-deferred variant split; this template owns what a *decision*
specifically must contain before an operator can fairly contest it.

Five required parts, in order:

1. **The decision, in plain terms** — what is actually being decided, stated
   so a reader carrying none of the surrounding spec in their head can
   evaluate it.
2. **The proposed answer** — the facilitator's recommendation, offered as a
   proposal to be contested, never as an accomplished fact.
3. **The reasoning** — why this answer rather than another.
4. **Alternatives considered, and why they lost** — each named with the
   reason it was set aside. "None considered" is a legitimate value and must
   be said outright; an empty slot is not the same statement.
5. **What accepting constrains downstream** — what the decision forecloses,
   commits, or makes expensive to reverse later.

**Plain-language rule (required, and it governs all five parts).** A
spec-internal reference or piece of jargon — a step number, a slug, an issue
ref, a schema section name, an internal coinage — must be explained inline at
its point of use, never assumed. The counterexample is citable rather than
hypothetical: the premise gate of the very design brief that produced this
template first fired as a context-free, jargon-dense question the operator
could not evaluate ("I don't have context on this question so I have to
challenge you to understand what's hidden from me") — the failure
demonstrated inside its own intake (temperloop#923). The rule does **not**
lapse once the challenge phase ends: it governs the walkthrough steps' gists
and delta summaries too, which is precisely where compression makes jargon
cheapest to reach for.

**Not overridable by an overlay.** Alone among the templates in this file,
this one is excluded from the sanctioned overlay-override surface — see
§ Overrides for the exclusion and the lint that enforces it.

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

The mode-2 minimal form has **two shapes, and only two.** Its **default** is <!-- cite: MS.6 incident:F#164 -->
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
with no `project-agents.sh` install path) stays bare. **This clause fixes the
SHAPE of such a line; it never licenses a kernel surface to keep routing to a
capability that does not exist.** The example that used to sit here —
`/verify`, which never shipped — was that failure: `build.md` §3e.6 routed
its no-predicate class-A activation arm to `/verify`, so a mandatory gate
degraded to a skip notice on every run that reached it. temperloop#1451
deleted the route rather than keeping the notice; no kernel surface routes to
`/verify` today. A degradation line reports a *real* capability's
absence; it is never a standing stand-in for a gate that can never run. The
fuller mode-6 form still adds the calibrated-trust and (unconditional) remedy
slots because a cold or stranger reader of a durable artifact lacks the live
session's surrounding context; this live-vs-recorded distinction is an
authoring judgment call, not itself a research-grounded finding — flag it as
such rather than dressing it up as locked.

## Provisional slots — do not lock

Per the L0 verification verdict, the following remain explicitly <!-- cite: MS.7 incident:K#100 -->
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
  5) — direction **theoretically supported but empirically unconfirmed**:
  expertise-reversal predicts expert readers may tolerate or even prefer
  terser, denser output (2025 meta-analysis, 176 effect sizes), but this is
  unconfirmed for professional developers, untested in the error-message
  domain, and the reversal effect itself is unestablished at professional
  expertise levels. Templates here must still not assume the CHI-2021
  vocabulary/jargon/sentence-structure/length findings (novice populations)
  generalize to an operator or expert reader of CLI/PR content. **Stays
  provisional** — accepted standing gap per the temperloop#718 verdict
  record (`Context/temperloop - CHI-2021 readability + over-explanation
  harm research verdicts (#100)`, from the temperloop#100 spike).
- **"Over-explanation harms comprehension"** as a causal claim — the former
  combined "harms comprehension/trust" slot is **split in two** per the
  temperloop#100 verdicts. The *trust-miscalibration / over-reliance* half
  is now **citable and no longer provisional**: explanations can be
  persuasive but not informative, raising reader acceptance of wrong
  outputs (arXiv 2605.10930; supporting: doi 10.1080/0144929X.2025.2568928,
  S0747563224002206, doi 10.1145/3686164) — see the strengthened Mode-5
  calibrated-trust rule (§ Digest entry) and § Citation hygiene. The
  *comprehension-degradation* half **stays provisional**: no study isolates
  over-explanation → worse understanding, so the parking-note and
  digest-entry "don't restate what's already visible" guidance above still
  rests only on the locked CLT redundancy-effect finding (self-sufficient
  artifacts, Tier-1 finding 3). Verdicts recorded in the temperloop#718
  verdict record (`Context/temperloop - CHI-2021 readability +
  over-explanation harm research verdicts (#100)`).

## Citation hygiene

- Cite **Iqbal & Bailey** (CHI 2008 / TOCHI 2010) for the ~90s (88.6s mean) <!-- cite: MS.8 incident:K#94 -->
  breakpoint-deferral-cost anchor — **not** Iqbal & Horvitz.
- Scope the LLM-verbosity figure (≈50.4% compressible without information
  loss) to **short-QA tasks with an explicit brevity instruction** — do not
  generalize it to "about half of all responses."
- Cite **arXiv 2605.10930** for the trust-harm link: explanations
  "persuasive but not informative" raise reader acceptance of wrong outputs
  (supporting: doi 10.1080/0144929X.2025.2568928, S0747563224002206, doi
  10.1145/3686164). The measured harm is a function of **explanation
  type/presence, not narration length per se** — do not cite it as evidence
  that longer narration harms trust.
- Keep **arXiv 2411.07858** scoped to **verbosity-compensation frequency
  and compressibility only**. The trust/reliance sources above measure a
  different construct (reader trust and over-reliance) and **complement,
  not replace**, it — do not merge the two into one "verbosity harms" claim.
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
override — see the carve-out in `claude/CLAUDE.kernel.md` § Kernel vs overlay
routing rule — **with one exclusion**: of the six templates authored here,
**five are overridable and § Decision presentation is not**. § Overrides below
specifies the mechanism (redeclaration precedence, dangling-override
detection, and the non-overridable set): "sanctioned surface" means an
override of one of those five templates by name is not, by itself, a
violation of "overlay may extend, never contradict", resolved per that
mechanism. It has never meant *every* template here, and the exclusion is
enforced by a lint rather than left to prose.

## Overrides

This is the mechanism the carve-out in `claude/CLAUDE.kernel.md` § Kernel vs <!-- cite: MS.9 class:drifting-delta-divergence -->
overlay routing rule points at. It governs only the **five overridable** of
the six named templates this file authors (§ Templates) — no other kernel
contract is overridable by this or any other route.

- **Non-overridable set — an enforced exclusion, not a convention.** <!-- cite: MS.11 guard:workflows/scripts/validate-template-refs.sh -->
  § **Decision presentation** may not be redeclared by an overlay **at all**.
  It is a challenge-gate contract: a sanctioned redeclaration would let an
  overlay quietly shrink its five parts or drop its plain-language rule, and
  a walk stop that no longer has to be intelligible is exactly the
  overlay-weakens-kernel back-channel `CLAUDE.kernel.md` § Kernel vs overlay
  routing rule forbids. This is enforced, not asserted:
  `workflows/scripts/validate-template-refs.sh` carries the exclusion set and
  **fails** an overlay that redeclares a listed name — without that check the
  exclusion would be inert, since a redeclaration of a template this file
  defines otherwise passes the dangling-override rule below cleanly (the name
  *is* canonical). Maintaining the set is a two-site change made in one PR —
  this bullet and that script's `NON_OVERRIDABLE_TEMPLATES` — and the script
  self-checks that every name it excludes is still a template § Templates
  defines, so renaming or retiring one here reds CI instead of silently
  disarming the exclusion.
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
  not "override" a template that doesn't exist here. This is checked
  mechanically by `workflows/scripts/validate-template-refs.sh` (shipped by
  the `template-lints` plan item); this file states the rule, that script
  implements the check. Do not re-implement or duplicate it here or
  elsewhere. Note the two checks are complements, not duplicates: this one
  rejects a name § Templates does **not** define, the non-overridable-set
  check above rejects one specific name it **does**.
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
- Research debt (Cluster 5, over-explanation→harm link): adjudicated by the
  temperloop#100 spike, applied here via temperloop#718; verdict record:
  `Context/temperloop - CHI-2021 readability + over-explanation harm
  research verdicts (#100)` (vault note)
- Later plan items that build on this file: `kernel-guides-unify` (rewrites
  `CLAUDE.kernel.md`'s prose against this schema, retires the refs legend),
  `overlay-adoption` (foundation's adoption). `template-lints` (CI
  conformance checks, including the § Overrides dangling-override rule),
  `override-seam` (specified the override mechanism, § Overrides above), and
  `decision-presentation-template` (§ Decision presentation plus the enforced
  non-overridable set, temperloop#928) have landed.
- Design brief this template answers to: `Designs/temperloop - workshop
  collaborative decision walk` (ratified 2026-08-01), epic temperloop#923
