---
title: pipeline-driver
slug: pipeline-driver
---

## Problem

The bug→PR pipeline (triage → assess → build) is designed to run under an
operator's direct approval at every gate. That's the right default for
anything risky, but it means even the safest, most mechanical pipeline actions
— clearing a label after an operator already answered a question, routing an
already-decomposed epic to its approval gate, driving a read-only spike to a
verdict — still sit idle until a human happens to notice and run the right
command by hand. Left fully manual, throughput on routine, low-risk work is
bottlenecked on operator attention even when there's no real judgment call
left to make. But the opposite failure is worse: letting *any* automation
merge code unsupervised is a real risk if the automation is wrong, so a
pipeline driver that doesn't structurally separate "safe to always automate"
from "must stay gated" would either bottleneck on the safe cases or expose
the codebase to ungated automated merges.

## How it works

A scheduled tick decides, per enabled board, what work is ready to move —
draining answered decisions, draining cleared clarifications, picking one
Operational Ready item to drive, and routing one Foundational Ready item to
its design/plan-approval gate. The tick itself is a thin, deterministic
scheduler: it re-uses the existing pipeline commands rather than
re-implementing any of their logic, and it only ever *decides what to call*.

Execution of that decision happens in three increasingly autonomous layers:

- **Level 5a — emit + notify only.** The tick's decision is logged and the
  operator is notified; a human executes every action by hand. This is the
  default, always-on baseline.
- **Level 5b — headless safe-tier auto-execution** (opt-in). A headless
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
- **Level 5c — headless merging tier** (opt-in, gated separately from 5b, and
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
to reason about: level 5b's ceiling is "no PR, no merge" enforced two
independent ways; level 5c's ceiling is "only through the existing gated
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

**Spawning an optional, out-of-tree command is gated twice, and refuses
legibly.** One tick action — the retrospection judge trigger — hands off to a
command that lives *outside* this kernel (an overlay `/retro`) by spawning it as
a nested headless session. Presence alone does not justify that spawn: a nested
session that cannot do the work can still end its turn and exit *success*, so a
judge that was installed but had no working unattended mode produced a run that
spent real time and money, judged nothing, and looked healthy from every
surface. The tick therefore requires the target command to **declare** the
capability it is about to be driven under (a marker line in the command's own
file — see the slash-command availability probe feature), and when that
declaration is absent it emits a skip action carrying a machine-readable reason
(`not-declared` — nothing installed; `headless-unsupported` — installed but never
claimed it can run unattended) instead of spawning. Never silence: either the
judge runs, or the tick says why it didn't.

**A nested spawn re-derives its credential; it never inherits one.** That judge
spawn is *two* levels deep — the cron process starts the safe driver, and the
driver starts the judge — and a headless agent session does not forward its
credential environment to a command it launches from its shell tool. So the
first hop authenticated and did real work while the second hop died before its
first turn on a host whose interactive login had expired; the only trace was a
failure counter nobody reads. The driver therefore no longer types that command
at all. Every judge-trigger action carries an absolute `spawn_cmd` pointing at
`pipeline-retro-judge-spawn.sh`, the one process that actually launches the
judge — and that script sources this checkout's own config ladder (including the
gitignored, mode-restricted local override where a host credential belongs) to
**re-derive** the credential at the spawn site rather than inherit it across a
hop that drops it. It classifies an authentication failure there by *shape*
rather than exit code (a failed nested session can still exit zero), announces it
on the same operator notification channel a tick uses, returns a distinct exit
code, and stamps a stable token into its outcome so the health detector below
reports it as its own verdict long after the notification is gone. The credential
value itself is never placed on an argv, printed, or logged: only its presence
and a source label are ever reported, and anything the child emits is passed
through a redaction step first.

**A dead loop is detectable, not a steady state.** `pipeline-retro-health.sh` is
the read-only companion detector: it reads the tick's own retro decisions out of
the pipeline stream against the judge's run stream and returns one of five
verdicts — `healthy`; `no-signal` (nothing was due — the genuine steady state);
`refused` (the tick declined, and why); `no-lake` (the history is unreadable
here); or `defect` (a trigger fired and produced nothing, sub-typed `auth` — the
spawn site could not authenticate, a host-credential problem with a one-line
remedy, named first so it is never re-diagnosed as a broken judge — then
`never-had-a-row` vs `stalled`). That distinction is the whole point: before it,
a zero-row run stream meant both "no retros were due" and "the judge has never
once run," and a dead loop hid inside the healthy reading for months. The nightly
tidy pass runs it and routes a `defect` verdict to the board as a defect.

## Integration

Consumes: the existing pipeline commands (triage, assess, build) it invokes
rather than reimplements; the worklist/board adapter for claim, status, and
close operations; the decision-queue backend for routing items that need
operator approval; the unattended build path's own merge gate for every
actual merge the merging tier performs.

Also consumes, read-only: the pipeline raw-lake stream and the overlay
retrospection run stream, which the retro-judge health detector compares to tell
"nothing was due" apart from "the judge never ran."

Produces: worklist mutations (claims, status moves, label changes) audited
by issue number so a reviewer can cross-check the driver's actual mutations
against board state; escalation labels and assignments for anything it
couldn't safely finish; pull requests and merges, exclusively through the
existing gated build path, never directly.

## Resource impact

Each headless drive session (a level 5b or 5c invocation) costs its own
model-token spend proportional to how many actions it was handed that tick,
separate from and in addition to the ordinary interactive pipeline spend.
The merging tier's per-tick cap is the direct lever on both blast radius and
spend — a low cap keeps a single tick's automated-merge exposure and cost
small regardless of how large the ready backlog is. Board/API cost is
bounded by the same per-item claim/status/close operations the manual
pipeline already performs; the driver adds no bulk board scans of its own.

## Telemetry

Every scheduled wake appends one record to the pipeline raw-lake stream,
distinguishing a declined wake from an executed tick from a drive
invocation, each carrying a wall-time duration. A drive outcome record
additionally reports attempts separately from outcomes at both layers — how
many actions were *handed to* the safe or merging driver that tick versus
how many it actually executed, merged, handed off, parked, refused, or
failed — plus the audited issue numbers each side-effect acted on, so a
reviewer can confirm the driver's reported counts against the worklist's
actual state rather than trusting the summary alone.
