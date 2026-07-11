---
title: funnel-driver
slug: funnel-driver
---

## Problem

The bug→PR pipeline (triage → assess → build) is designed to run under an
operator's direct approval at every gate. That's the right default for
anything risky, but it means even the safest, most mechanical funnel actions
— clearing a label after an operator already answered a question, routing an
already-decomposed epic to its approval gate, driving a read-only spike to a
verdict — still sit idle until a human happens to notice and run the right
command by hand. Left fully manual, throughput on routine, low-risk work is
bottlenecked on operator attention even when there's no real judgment call
left to make. But the opposite failure is worse: letting *any* automation
merge code unsupervised is a real risk if the automation is wrong, so a
funnel driver that doesn't structurally separate "safe to always automate"
from "must stay gated" would either bottleneck on the safe cases or expose
the codebase to ungated automated merges.

## How it works

A scheduled tick decides, per enabled board, what work is ready to move —
draining answered decisions, draining cleared clarifications, picking one
Operational Ready item to drive, and routing one Foundational Ready item to
its design/plan-approval gate. The tick itself is a thin, deterministic
scheduler: it re-uses the existing pipeline commands rather than
re-implementing any of their logic, and it only ever *decides what to call*.

Execution of that decision happens in three increasingly autonomous rungs:

- **Rung 5a — emit + notify only.** The tick's decision is logged and the
  operator is notified; a human executes every action by hand. This is the
  default, always-on baseline.
- **Rung 5b — headless safe-tier auto-execution** (opt-in). A headless
  session auto-executes only the actions that can **never** merge code:
  routing a foundational item to its approval gate, applying an answered
  decision, re-assigning on an unparseable reply, clearing a cleared
  clarification label, and driving a spike (which writes a verdict note and
  routes a follow-up issue, but opens no pull request) to completion. This
  tier is **structurally** incapable of merging anything — the merging tier
  of actions is filtered out of its input entirely before the headless
  session ever sees it, and the session's own instructions independently
  forbid opening a PR or merging under any circumstance. Two guards, not
  one.
- **Rung 5c — headless merging tier** (opt-in, gated separately from 5b, and
  rides on top of it — 5b being enabled is 5c's precondition). This tier
  drives the actions 5b deliberately leaves for the operator: items ready to
  become code changes. It drives each through the existing unattended build
  path and lets that path's own timed/modal merge gate decide whether the
  result actually merges. A clean, disjoint, low-risk change merges after
  its timed window; anything structurally risky still hard-blocks for
  explicit approval (routed to the decision queue when no operator is
  present). This tier never merges by any other route — no direct merge
  command, no bypass of that gate.

**The structural safe/merge split** is what makes this staged rollout safe
to reason about: rung 5b's ceiling is "no PR, no merge" enforced two
independent ways; rung 5c's ceiling is "only through the existing gated
build path," enforced by driving that path rather than re-implementing
merge logic. Enabling the merging tier is a **separate flag** from enabling
the safe tier specifically so that flipping one never silently flips the
other. The merging tier additionally bounds its own blast radius with a
**per-tick cap** — a configured maximum number of code items it will drive
to a merge attempt in any single tick, independent of how many are actually
ready. A code item that can't be safely finished in one tick (the headless
session's foreground CI/merge wait times out) is handed off rather than
abandoned: it's marked so the next tick resumes exactly where the previous
one left off, rather than re-driving into a duplicate pull request. Anything
the merging tier can't confidently drive to a merged, handed-off, or parked
outcome is escalated to the operator with a label that removes it from
future ticks' auto-drive pool, so a stuck item doesn't just keep re-failing
silently forever.

## Integration

Consumes: the existing pipeline commands (triage, assess, build) it invokes
rather than reimplements; the worklist/board adapter for claim, status, and
close operations; the decision-queue backend for routing items that need
operator approval; the unattended build path's own merge gate for every
actual merge the merging tier performs.

Produces: worklist mutations (claims, status moves, label changes) audited
by issue number so a reviewer can cross-check the driver's actual mutations
against board state; escalation labels and assignments for anything it
couldn't safely finish; pull requests and merges, exclusively through the
existing gated build path, never directly.

## Resource impact

Each headless drive session (a rung 5b or 5c invocation) costs its own
model-token spend proportional to how many actions it was handed that tick,
separate from and in addition to the ordinary interactive pipeline spend.
The merging tier's per-tick cap is the direct lever on both blast radius and
spend — a low cap keeps a single tick's automated-merge exposure and cost
small regardless of how large the ready backlog is. Board/API cost is
bounded by the same per-item claim/status/close operations the manual
pipeline already performs; the driver adds no bulk board scans of its own.

## Telemetry

Every scheduled wake appends one record to the funnel raw-lake stream,
distinguishing a declined wake from an executed tick from a drive
invocation, each carrying a wall-time duration. A drive outcome record
additionally reports attempts separately from outcomes at both rungs — how
many actions were *handed to* the safe or merging driver that tick versus
how many it actually executed, merged, handed off, parked, refused, or
failed — plus the audited issue numbers each side-effect acted on, so a
reviewer can confirm the driver's reported counts against the worklist's
actual state rather than trusting the summary alone.
