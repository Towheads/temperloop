---
title: Managing operator cognitive load — what temperloop keeps out of your head
---

# Managing operator cognitive load — what temperloop keeps out of your head

An agent fleet can generate work — plans, PRs, decisions, telemetry — far
faster than one human can absorb it. Left unmanaged, *you* become the
bottleneck: reconstructing context, fielding interruptions, remembering
what's in flight, reviewing diffs blind. This page is the concrete
mechanisms temperloop uses to keep that load down, grouped by the four
kinds of load they reduce: what you have to **read**, **decide**,
**remember**, and **review**.

These aren't ad-hoc — they follow a written design backbone
([`claude/message-schema.md`](../claude/message-schema.md),
[`claude/presentation-plane.md`](../claude/presentation-plane.md),
[`claude/measurement-proxies.md`](../claude/measurement-proxies.md))
grounded in named findings from the situation-awareness and cognitive-load
literature. The honest caveat up front: these are mechanisms *designed to*
reduce load, several explicitly marked provisional and untested —
`measurement-proxies.md` is the contract for checking whether they actually
work. Treat this page as the design's theory of its own ergonomics.

## What you have to read

The goal: any message lets you reconstruct where things stand in one pass,
without scrolling back or leaving the conversation.

- **Outcome first.** A completion summary leads with the outcome — the
  thing you'd ask for if you said "just give me the TL;DR" — then *what
  changed → what it means → what's next*, so a cold reader rebuilds state
  top-down.
- **Resume recap.** The first response after a resume or long gap opens
  with one line on the active item and where it stands, before answering
  the new message.
- **Self-sufficient references.** Every id whose meaning lives in an
  external system (an issue, PR, epic, plan) carries a short title hook on
  first mention, so a bare `#N` never forces you to leave the conversation
  to resolve it.
- **One place says which surfaces are frozen.** The presentation-plane
  index tells the writing agent which outputs are machine-parsed (and must
  not be reworded) versus free prose, so nobody holds that set in their
  head.

## What you have to decide

The principle: only a decision with **no safe default** is allowed to
interrupt you. Everything with a default is batched, deferred, or
auto-taken and recorded — you engage on the genuinely risky calls, not the
routine ones.

- **A severity taxonomy gates every question** into ask-now (no safe
  default → interrupts), ask-at-gate (defer to the next checkpoint), and
  ask-at-check-in (defer to the daily review).
- **One merge gate per dependency level, not per item.** A whole level runs
  unattended to CI-green, then a single gate approves the set.
- **Deferred questions batch into the plan note** with their defaults; the
  whole batch surfaces as one question at the gate, and an unanswered entry
  takes its default rather than stalling.
- **Unattended runs record what they auto-took** on a durable surface, so a
  defaulted decision never stands silently — you review the batch later in
  one place.
- **Timed autonomy on the safe set only.** A clean, disjoint change set
  auto-merges after a timed window (walk-away = consent); a structurally
  risky set is always a modal approval — a timeout is never consent for a
  no-safe-default decision.

## What you have to remember

The tracker and a handful of durable surfaces are the system's memory, so
nothing in flight lives only in your head.

- **Capture at source, don't ask.** A defect noticed mid-work is filed
  immediately, never offered as an end-of-turn "want me to file this?" —
  that offer dies with the session. Filing is reversible; a dropped bug is
  not.
- **Park, don't abandon.** Setting work aside is a tracked status change
  plus a one-line note (where it stands, next step), never a silent drop.
- **Session start lists what's in flight** and asks which to resume, rather
  than making you recall what was open.
- **One daily review, `/check-in`.** Everything the overnight machinery
  parked is disposed in one routine that leads with "what needs me" — and
  alarms loudly if the telemetry it's showing can't be trusted.
- **`/next` gives exactly one next move** — a single concrete command, not
  a ranked backlog to triage in your head.
- **Degradation is legible, never silent.** When a review gate can't run,
  the step says `skipped — <agent> unavailable`, so you're never misled
  into thinking a gate ran when it didn't.

## What you have to review

When a decision does reach you, the surface is shaped so you spend
attention on judgment, not reconstruction.

- **You review a plan, not a diff.** Non-trivial work goes through plan
  mode (or `/workshop` for invented work) first, so you approve an approach
  at a readable altitude rather than reverse-engineering intent from code.
- **Problem-first review blocks.** `/assess`'s approval summary shows *why*
  (the problem) and *what* (the plan), then only a compact needs-attention
  block — rationale before mechanics, and you read only what needs a
  decision.
- **The PR carries its own verification surface** — the before/after, the
  test that now passes — so you never grep logs or run commands to check
  the claim.
- **Structure preview before prose.** `/assess` prints the dependency-level
  DAG before writing the note, so you can reject a bad decomposition before
  reading a full plan.

## Related

- [`principles.md`](principles.md) — "cheaper, in human cognitive load" is
  one of the thesis's named axes; this page elaborates it.
- [`token-spend.md`](token-spend.md) — the parallel page for *token* cost;
  several levers (bounded context, batching) reduce both.
- [`claude/message-schema.md`](../claude/message-schema.md) /
  [`claude/presentation-plane.md`](../claude/presentation-plane.md) /
  [`claude/measurement-proxies.md`](../claude/measurement-proxies.md) — the
  design backbone behind this page.

---

*Written by claude-fable-5 on 2026-08-13.*
