---
title: Read-only advisory review agents
slug: review-agents
---

## Problem

A pipeline that lets one agent plan, decompose, and implement work with no
second opinion is a pipeline where a structural mistake — a decomposition
that hides a dependency, a design that puts a responsibility in the wrong
place, a workflow spec with an invariant that fails silently — ships exactly
as fast as everything else, with nothing catching it before it is committed.
A human reviewer catches this by asking "wait, why is this here" mid-review;
an agent under time and token pressure to finish its own task is structurally
worse at asking that question about its own work than a second, differently-
scoped agent is at asking it from outside. Without a dedicated, independent
review pass, that class of mistake is caught only by luck or by a human
happening to notice later, once it is more expensive to unwind.

## How it works

**The advisory family.** A small set of subagents, defined as Markdown files
under `claude/agents/`, exist purely to give a second opinion before
something durable gets committed. Each one:

- loads **cold** for every invocation — no memory of prior reviews, so its
  judgment is not anchored by what it said last time;
- is **read-only** — its tool access is limited to `Read`, `Grep`, `Glob`,
  and `Bash`, with no ability to edit code, write to a board, or modify a
  note; and
- is **advisory, not authoritative** — it surfaces findings for the calling
  workflow (and ultimately a human) to act on; it never mutates state
  itself, and authority runs one direction only.

Three agents currently make up the family:

- **architecture-reviewer** — an independent check on boundary, layering,
  and contract decisions before they are locked in: a new component, a
  change that crosses a module boundary, a shift in a public contract. Used
  before finalizing a design decision and during planning for any work that
  touches an architectural boundary.
- **requirements-auditor** — a sanity check on the *logical* groupings and
  *technical* decompositions a planning workflow produces, before that
  output becomes durable (a set of tracked work items, or a written plan).
  Checks that groupings make sense and that a decomposition's items, edges,
  and acceptance criteria hold together.
- **workflow-reviewer** — a review of the prose specifications that an agent
  itself executes as a procedure (the equivalent of a runbook or playbook a
  human would otherwise follow by hand). These specs typically have no
  automated tests and fail silently when an invariant is violated, so this
  agent's job is to catch an invariant violation the author, mid-edit,
  would not see.

Each agent's own spec states which model tier it should run on and why: an
agent whose findings gate something downstream (nothing else double-checks
its call) stays on the calling session's own model; an agent whose findings
are filtered by a human or another process before they take effect can
safely run on a smaller, cheaper tier.

**The capability probe.** Not every project that could use one of these
agents has it available — a project may not declare the agent, or the agent
definition may not be installed in that checkout. Rather than assume
availability and fail confusingly partway through a review step, the calling
workflow probes first: an agent is treated as available if and only if the
project's own configuration declares it (either named explicitly in a
project-level configuration section, or present as a file under
`.claude/agents/`). This is a single, reusable predicate — every call site
that wants a review pass runs the same check rather than each reinventing
its own availability logic.

**Legible degradation.** When the probe says an agent isn't available, the
calling workflow does not silently skip the review step and proceed as if
nothing happened — that would make a skipped gate look identical to a passed
one, which is worse than not having the gate at all. Instead it emits an
explicit, uniform notice — `skipped — <agent> unavailable` — into whatever
summary or log the workflow already produces, so a reader can tell the
difference between "reviewed and clean" and "never reviewed." The same
phrasing is used everywhere the pattern applies, so it is grep-able across a
whole pipeline run.

## Integration

These agents are invoked by the higher-level workflows that produce durable
state — a planning step before it writes a plan note, a build step before it
finalizes a change, a decision-capture step before a design choice is
locked. A calling workflow is responsible for running the capability probe,
invoking the agent with enough context to judge (the diff or plan under
review, plus any project-specific evaluation criteria it should also apply),
and folding the agent's findings — or its `skipped — <agent> unavailable`
notice — into its own step summary. The agents themselves have no
integration surface beyond being invoked with a prompt and returning text;
they hold no state between invocations.

## Installation — making the agents discoverable in a fresh clone

The agent (and command) definitions ship as **source** under `claude/agents/`
and `claude/commands/`, but Claude Code discovers project agents and commands
from a **project-scoped `.claude/agents/` and `.claude/commands/`** — not from
`claude/*`. On a fresh standalone-kernel clone nothing wires the source into a
live `.claude/`, so the capability probe evaluates FALSE for every lens and
every review degrades to all-skipped (temperloop#290).

The install path that closes that gap:

```sh
bash workflows/scripts/install/project-agents.sh
```

Run once from a fresh clone, it deploys one entry per source file into the
repo's own project-scoped `.claude/agents/` and `.claude/commands/` — by
default as symlinks back to the tracked source (so a later `git pull` needs no
re-run), or as detached real-file copies with `--copy`. It is **project-scoped**
(never writes under `~`, so it can't collide with a machine-surface
`temperloop install`), **idempotent** (an already-correct entry is left alone),
and **non-destructive** (a pre-existing non-managed file at a target is
reported and skipped, never clobbered). Deploy the agents into a *different*
working repo (adopting the kernel's review lenses there) with
`--project-dir DIR`; preview with `--dry-run`. Once it has run, the capability
probe resolves and the review lenses execute instead of skipping.

## Resource impact

Each invocation is a single subagent call scoped to read-only tools, priced
like any other model call at whichever tier that agent's definition
specifies (session-tier for a gating review, a cheaper fixed tier for a
purely advisory one). There is no added storage or background process — the
cost is bounded to the review pass itself, and skipped (unavailable) reviews
cost nothing beyond the one-line notice.

## Telemetry

None. A review agent's output lands directly in the calling workflow's own
step summary or PR/plan-note narrative rather than a separate structured
stream — there is no dedicated metrics or event log for review-agent
invocations today. The observable surface is the `skipped — <agent>
unavailable` notice pattern itself: its presence (or absence) in a workflow's
summary is how a reader notices a review pass that didn't run.
