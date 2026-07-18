---
title: Managing operator cognitive load — what temperloop keeps out of your head
---

# Managing operator cognitive load — what temperloop keeps out of your head

An agent fleet can generate work — plans, PRs, decisions, telemetry — far
faster than one human can absorb it. Left unmanaged, the *operator* becomes the
bottleneck: reconstructing context, fielding interruptions, remembering what's
in flight, and reviewing diffs blind. [`principles.md`](principles.md) names
"cheaper — in **human cognitive load**" as one of the axes the whole system is
built to buy; this page is the elaboration of that axis — the concrete
mechanisms, grouped by the four kinds of load they reduce:

- **what you have to read** — situational awareness,
- **what you have to decide** — interruptions and choices,
- **what you have to remember** — tracking in-flight work,
- **what you have to review** — approving change.

These aren't ad-hoc. temperloop carries an explicit design spine for reader and
operator load — [`claude/message-schema.md`](../claude/message-schema.md),
[`claude/presentation-plane.md`](../claude/presentation-plane.md), and
[`claude/measurement-proxies.md`](../claude/measurement-proxies.md) — grounded
in named findings (Endsley's situation-awareness model; Grice's maxim of
Quantity; Cognitive Load Theory's split-attention and redundancy effects;
Iqbal & Bailey on interruption-deferral cost; Lee & See on calibrated trust;
BLUF). The honest caveat up front: these are mechanisms *designed to* reduce
load, and `measurement-proxies.md` is the falsifiability contract that checks
whether they actually do — several are explicitly marked provisional, their
effectiveness untested, not proven. Treat this page as the design's theory of
its own ergonomics.

## What you have to read — situational awareness

The goal is that any message lets you reconstruct where things stand in one
pass, without scrolling back or leaving the conversation.

- **Front-loaded outcome (BLUF), then the Endsley shape.** A completion summary
  leads with the outcome — the thing you'd ask for if you said "just give me
  the TL;DR" — then gives *what changed → what it means → what's next*, so a
  cold reader rebuilds state top-down ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Communication conventions; [`claude/message-schema.md`](../claude/message-schema.md)).
- **Resume recap.** The first response after a resume or a long gap opens with
  one line on the active item and where it stands, *before* answering the new
  message — so you don't reconstruct context or scroll ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Communication conventions).
- **Self-sufficient references.** Every id whose meaning lives in an external
  system (an issue, PR, epic, board, plan slug) carries a short title hook on
  first mention and is repo-qualified when more than one repo is in play — so a
  bare `#N` never forces you to leave the conversation to resolve it. The old
  trailing "refs legend" was retired precisely because a lookup table at the
  bottom is a split-attention layout ([`claude/message-schema.md`](../claude/message-schema.md)
  § The reference-token rule).
- **One place says which surfaces are frozen.** The presentation-plane index
  tells the author-agent which outputs are machine-parsed (and must not be
  reworded) versus free prose, so nobody has to hold the whole frozen-surface
  set in their head ([`claude/presentation-plane.md`](../claude/presentation-plane.md)).

## What you have to decide — interruptions and choices

The principle: only a decision with **no safe default** is allowed to
interrupt you. Everything with a default is batched, deferred, or auto-taken
and recorded — so you engage on the genuinely risky calls, not the routine
ones.

- **A severity taxonomy gates every question.** Decisions are partitioned
  `blocking-now` (no safe default → interrupts, every run), `batch-at-gate`
  (defer to the next checkpoint), and `batch-at-ritual` (defer to a daily
  review) — the routing axis that decides whether you're pulled in at all
  (behavior specified in [`claude/commands/build.md`](../claude/commands/build.md)
  Operating principles and [`claude/plan-schema.md`](../claude/plan-schema.md)).
- **One merge gate per dependency level, not per item.** A whole level runs
  unattended to CI-green, then a single gate approves the set — the run
  proceeds "without constant monitoring" instead of pulling you in per PR
  ([`claude/commands/build.md`](../claude/commands/build.md)).
- **Deferred questions batch into the plan note.** A non-blocking in-run choice
  appends one line (with its default) to the plan's `## Questions` section and
  proceeds; the whole batch surfaces as *one* question at the gate — and an
  unanswered entry takes its default, never a silent stall
  ([`claude/plan-schema.md`](../claude/plan-schema.md)).
- **Unattended runs record what they auto-took.** When a command runs with no
  live operator, a `batch-at-ritual` choice takes its safe default to keep
  moving *and* records the auto-disposition on a durable surface, so a defaulted
  decision never stands silently — you review the batch later in one place
  ([`claude/commands/check-in.md`](../claude/commands/check-in.md)).
- **Timed autonomy on the safe set only.** A clean, disjoint change set
  auto-merges after a timed window (walk-away = consent); a structurally risky
  set is *always* a modal approval and is never timed out — a timeout is never
  consent for a no-safe-default decision ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Merge autonomy & consent).
- **Minimal reply effort when you are asked.** An async decision is answered
  with a tiny fixed grammar (a fenced `decision` block, or `/approve`), and a
  parse-miss re-asks rather than guessing — closed-enum-or-escalate
  ([`claude/decision-queue-contract.md`](../claude/decision-queue-contract.md)).

## What you have to remember — tracking so you don't have to

The board and a handful of durable surfaces are the system's memory, so nothing
in flight lives only in your head.

- **Capture at source, don't ask.** A defect noticed mid-work is filed
  immediately, not offered as an end-of-turn "want me to file this?" — because
  that offer dies with the session. Filing is reversible; a dropped bug is not
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task workflow).
- **Park, don't abandon.** Setting work aside is a tracked status change plus a
  one-line parking note (where it stands + the next step), never a silent drop
  — so the board stays a complete picture you can trust
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task workflow).
- **Session-start ritual.** At session start the machine lists the In-Progress
  set and asks which to resume, rather than making you recall what was open
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Task workflow).
- **One daily review, `/check-in`.** Everything the overnight machinery parked
  — decisions, sensitivity flags, environment-hygiene drift, pending
  activations that couldn't be confirmed at merge — is disposed in one ritual
  that *leads with "what needs me,"* and alarms loudly (`DATA STALE`) if the
  telemetry it's showing you can't be trusted. You clear queues and set
  direction in one place instead of hunting across surfaces
  ([`claude/commands/check-in.md`](../claude/commands/check-in.md)).
- **`/next` gives exactly one next move.** Asked "what do I do now," the
  advisory conductor hands back a single concrete command plus the road ahead —
  not a ranked backlog to triage in your head — and reads other sessions' lanes
  so you don't double-book ([`claude/commands/next.md`](../claude/commands/next.md)).
- **Degradation is legible, never silent.** When a review gate can't run, the
  step says `skipped — <agent> unavailable` instead of quietly no-opping, so you
  are never misled into thinking a gate ran when it didn't — a calibrated-trust
  signal, not a false green ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § Subagent usage).

## What you have to review — approving change

When a decision does reach you, the surface is shaped so you spend attention on
judgment, not on reconstruction.

- **You review a plan, not a diff.** Non-trivial work goes through plan mode (or
  `/workshop` for invented work) first, so you approve an approach at a readable
  altitude rather than reverse-engineering intent from code
  ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md) § Plan-first default).
- **Problem-first review blocks.** `/assess`'s approval summary shows *why* (the
  `## Problem`) and *what* (the plan, grouped by problem), then only a compact
  `NEEDS ATTENTION` block of actionable flags — never a stat dump — so you see
  rationale before mechanics and read only what needs a decision
  ([`claude/commands/assess.md`](../claude/commands/assess.md)).
- **The PR carries its own verification surface.** Every PR ships a way to
  confirm correctness in-body — the before/after, the test that now passes — so
  you never grep logs, decode JSON, or run commands to check the claim. A PR
  that says "run the script and see" is incomplete ([`claude/CLAUDE.kernel.md`](../claude/CLAUDE.kernel.md)
  § PR verification surface).
- **Structure preview before prose.** `/assess` prints the dependency-level DAG
  before writing the note, so you can reject a bad decomposition before reading
  a full plan ([`claude/commands/assess.md`](../claude/commands/assess.md)).

## The grounding — and the honest caveat

The mechanisms above are applications of the design spine, not folk wisdom:

- [`claude/message-schema.md`](../claude/message-schema.md) models the reader's
  state (present vs absent, warm vs cold) against Grice's Quantity maxim and
  defines the reusable message templates (completion summary, parking note,
  question block, PR-body skeleton, degradation notice), each carrying the
  Endsley perception→comprehension→projection slots.
- [`claude/presentation-plane.md`](../claude/presentation-plane.md) indexes
  which surfaces are frozen (machine-parsed) versus free prose, so the load of
  "how do I phrase this" is bounded and the #164 silent-break class is designed
  out.
- [`claude/measurement-proxies.md`](../claude/measurement-proxies.md) is the
  falsifiability contract: it names the proxies (interruption-deferral cost,
  friction-ledger volume, and others) by which these reducers are checked
  against reality.

The caveat is deliberate and load-bearing: several of these are marked
**provisional** — grounded in the *structure* a finding prescribes, but with
their effectiveness for this kind of technical work *untested*. This page
claims the design intent and its research basis, not a measured reduction in
operator load. That is the same honesty the [cost](cost-and-autonomy.md) and
[token-spend](token-spend.md) pages apply to dollars and tokens.

## Related

- [`principles.md`](principles.md) — the thesis this page elaborates ("cheaper,
  in human cognitive load" is one of its named axes).
- [`token-spend.md`](token-spend.md) — the parallel page for *token* cost;
  several levers (bounded context, batching) reduce both token and operator
  load.
- [`claude/message-schema.md`](../claude/message-schema.md) /
  [`claude/presentation-plane.md`](../claude/presentation-plane.md) /
  [`claude/measurement-proxies.md`](../claude/measurement-proxies.md) — the
  design spine behind this page.
