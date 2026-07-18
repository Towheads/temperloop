---
title: The self-learning loop — how temperloop learns from its own operation
---

# The self-learning loop — how temperloop learns from its own operation

An agent that makes the same mistake twice is expensive, and a pipeline that
only improves when a human remembers every lesson doesn't scale. temperloop
closes that gap with a **self-learning loop**: each session's learnings are
captured the moment they happen, drained nightly into durable knowledge, and —
when a mistake *recurs* — hardened into a mechanical control that makes the
mistake structurally hard to repeat. The system's own operation is what makes
it better.

The loop is a cycle: **capture → log → drain → detect recurrence → harden →
enforce → dispose**. Each stage is a real script, command, or rule in this repo
(or, for a couple of stages, in the personal overlay it composes with — see
below).

> **What ships here, up front.** This repo is the **kernel half**: it carries
> the *drain, enforcement, and plumbing* of the loop — the `/tidy` drain, the
> session hooks, the maturity-ladder guards, the CI check, and `/check-in`. The
> *live-capture* rules (decision capture, feedback memory, the tooling-friction
> ledger) and the *curated knowledge store* they write to are supplied by the
> private overlay + Obsidian vault that a full install composes in. So: the
> **kernel is the drain + enforcement half; the overlay + vault is the
> live-capture + ledger half.** The stages below note which is which where it
> matters.

## The loop, stage by stage

### 1. Capture at source — the moment it's learned

A learning held for an end-of-session summary is a learning often lost — the
summary may never happen. So the governing rule is to capture the instant
something is noticed ([`principles.md`](principles.md) #12, "Capture at source,
drain on schedule").

- **The kernel's own live-capture rule is defect routing.** A defect noticed
  mid-work is filed to the tracker *immediately* — "capture, don't ask" forbids
  ending a turn with "want me to file this?", because that offer dies with the
  session ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task
  workflow). Filing is reversible; a dropped bug is not.
- **Epic completion files its own retrospective.** When `/build` drives an epic
  to completion, its `4d-retro` step *synchronously* files a "Process retro:
  epic #N" issue — the four standing decomposition-retro questions (was the
  sub-unit threshold right, did the contract seam hold, was spike routing
  right, where did the triage→assess→build cadence add friction) plus a
  handoff-defect taxonomy — so the lessons of *how the work was structured* get
  a durable tracker instead of depending on someone remembering to open one
  ([`claude/commands/build.md`](../claude/commands/build.md) § 4d-retro). It's
  filed at the instant the epic closes, not deferred to the drain, so the
  learning can't be lost if the session ends first. This closes the
  contract-decomposition loop: every completed epic teaches the next
  decomposition.
- **The other live rules are overlay/vault** — decision capture (→ `Decisions/`
  notes), feedback memory, config-drift sync, session-optimization tracking (→
  `Patterns/`), and tooling-friction capture (→ the friction ledger,
  `Context/Session friction ledger.md`). The kernel doesn't ship the capture
  *rules*, but it ships their nightly **drain backstops** (stage 3) and the CI
  check that keeps the two halves paired (stage 6). One in-repo trace: a
  reviewer agent enforces config-drift sync — "a `claude/` change with no paired
  note update is config drift" ([`claude/agents/workflow-reviewer.md`](../claude/agents/workflow-reviewer.md)).

### 2. Log the session — the plumbing that feeds the drain

- A **SessionEnd hook** writes a transcript stub to a local `.mind/` directory
  when a session ends with real activity, recording the session's model set for
  later provenance ([`claude/hooks/session-end-log.sh`](../claude/hooks/session-end-log.sh)).
- A **SessionStart hook** drains those stubs into the vault's `Sessions/_inbox/`
  and deletes the local copy on success — and hands the session id back to the
  model so live captures can be stamped with their provenance
  ([`claude/hooks/session-start-drain.sh`](../claude/hooks/session-start-drain.sh)).
- Raw transcripts get a terminal home in a **git-tracked archive** (outside the
  vault, so semantic search never re-embeds them) — retrievable with
  `git log -S` / `rg`, not by recall.

### 3. Drain on schedule — `/tidy`, nightly and unattended

The drain is where raw sessions become durable knowledge
([`claude/commands/tidy.md`](../claude/commands/tidy.md)). It runs nightly, never
blocks on a question, and parks anything needing human judgment to append-only
surfaces the operator disposes later (stage 7). Each run:

- **scans** each stub into a compact ~2–3k-token report rather than loading the
  ~18k-token raw transcript;
- **extracts learnings** into the knowledge store — Decisions, Patterns,
  Mistakes, Context, feedback/project/user memories — adjudicated against a
  structured tell file ([`workflows/scripts/drain/lexicon.tsv`](../workflows/scripts/drain/lexicon.tsv),
  the single source of truth for extraction tells) plus structural passes over
  tool events (a tool error → a Mistake or an unfiled-defect; an answered
  question → Feedback; a correction → a self-correction finding);
- runs a **mandatory sensitivity scan** (a possible secret is flagged by
  location and kind, never copied) and **hygiene probes** (vault drift,
  environment drift, stale board claims);
- **archives** processed stubs and emits a summary.

Every adjudication — accepted or rejected — is written as a **findings record**
([`workflows/scripts/drain/findings-schema.md`](../workflows/scripts/drain/findings-schema.md)),
which is what makes the next stage possible.

### 4. Detect recurrence → promote — one-off vs. pattern

A single stumble is just a note; a *repeated* one is tracked work. The drain
tallies recurrence and escalates:

- **Friction that recurs** — if a friction-ledger category shows **≥5 rows in
  14 days**, `/tidy` surfaces it as a candidate and files an issue: "how the
  most-frequent stumbles become tracked work rather than repeating silently"
  ([`claude/commands/tidy.md`](../claude/commands/tidy.md) § Tooling friction).
- **Findings that recur** — [`workflows/scripts/drain/tally_recent_findings.py`](../workflows/scripts/drain/tally_recent_findings.py)
  counts accepted feedback/pattern/mistake findings over a trailing window; past
  threshold it proposes a rule change (a CLAUDE.md or skill edit). A recurring
  **mistake** specifically proposes *tightening a guard rule* — the on-ramp to
  the next stage.

This is the loop's decisive move: it doesn't just record mistakes, it notices
when one is *systemic* and routes it toward a control.

### 5. Climb the maturity ladder — learning hardens into enforcement

The escalation has a fixed shape ([`principles.md`](principles.md) #5, "Climb
the maturity ladder on evidence"): **a rule starts as prose** (a habit stated in
`CLAUDE.md`); **if it keeps leaking, it earns a mechanical backstop** (a
PreToolUse hook that warns or asks); **only a backstop that keeps firing earns a
hard, CI-enforced invariant.** Each rung is a response to an observed leak, not a
guess at what might leak.

The worked examples all began as repeated frictions and climbed to hooks:

- [`claude/hooks/git-stale-branch-guard.sh`](../claude/hooks/git-stale-branch-guard.sh)
  — backs "fetch ground truth before building"; born because branching off a
  stale local `main` was the single most frequent friction class in the ledger.
- [`claude/hooks/write-lane-guard.sh`](../claude/hooks/write-lane-guard.sh) —
  backs "working-tree ownership"; born from a real session stepping on a peer's
  checkout.
- [`claude/hooks/board-adapter-guard.sh`](../claude/hooks/board-adapter-guard.sh)
  — backs "adapter-first"; born from a raw GraphQL query draining the shared
  budget in a real session.

Each is a *backstop*, not a replacement for the habit — it fails open and only
nudges. The top rung of the ladder is a hard invariant (stage 6).

### 6. Enforce that the loop stays whole — live/drain pairing

The loop only works if a capture rule can't silently lose its backstop. So
every live-capture rule must ship **paired** with a nightly drain rule,
registered in a table, and [`workflows/scripts/validate-live-drain.sh`](../workflows/scripts/validate-live-drain.sh)
**fails the build** (it's part of the required `checks` gate) if any pair is
half-present — a live anchor with no drain, or a drain with no live. That is the
CI-enforced invariant at the top of the maturity ladder, guarding the loop
against its own silent-loss failure mode ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
§ Live/Drain pairing).

### 7. Operator disposes, and the loop is measured — `/check-in`

The daily `/check-in` is the human "operator-disposes" half of the
drain-proposes / operator-disposes split
([`claude/commands/check-in.md`](../claude/commands/check-in.md)). It's the sole
mutator of the append-only surfaces `/tidy` wrote, and disposing them feeds the
loop forward:

- **accepting a finding** files a board issue;
- **promoting a candidate tell** grows [`workflows/scripts/drain/lexicon.tsv`](../workflows/scripts/drain/lexicon.tsv)
  — the drain sharpening its *own* detectors from the misses it measured;
- **promoting a note** stages an edit adding its reference into
  [`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) — a learning literally
  re-entering the operating instructions.

Whether all of this *actually* reduces repeated mistakes is checked, not
assumed: [`claude/measurement-proxies.md`](../claude/measurement-proxies.md) is
the falsifiability contract — friction-ledger volume over a fixed window is one
named proxy for the loop's effect — and it is careful to call these **proxies,
not proofs**. Same honesty as the cost and token-spend pages.

## What ships here vs. what a full install adds

| Half of the loop | Where it lives | Examples |
|---|---|---|
| Drain, enforcement, plumbing | **kernel (this repo)** | `/tidy`, `/check-in`, the session hooks, the drain scripts, the maturity-ladder guard hooks, `validate-live-drain.sh`, the findings schema |
| Live-capture rules | **private overlay** | decision capture, feedback memory, config-drift sync, session-optimization tracking, tooling-friction capture (composed into `~/.claude/CLAUDE.md` at install) |
| The knowledge store the loop reads and writes | **Obsidian vault** | the friction ledger, curated `Decisions/`/`Patterns/`/`Mistakes/`/`Context/`, the `Sessions/_inbox/` stubs, the pipeline disposition surfaces |

So a bare kernel checkout has the machine that *processes and hardens*
learnings; a full install adds the rules that *capture* them and the store that
*holds* them. The pairing check (stage 6) is what keeps a downstream install
from shipping a capture rule whose drain backstop went missing.

## Related

- [`principles.md`](principles.md) — the loop rests on two of its principles:
  #12 (capture at source, drain on schedule) and #5 (climb the maturity ladder
  on evidence).
- [`token-spend.md`](token-spend.md) — a companion "how temperloop stays
  efficient" page; the durable-capture lever there is this loop's output.
  (Its sibling page on operator cognitive load covers the review-ergonomics
  side.)
