---
title: "0029: agent_declared — the subagent half of the capability probe"
---

## Status

Proposed

## Context

epic: Towheads/temperloop#1616 · issue: Towheads/temperloop#1462

`docs/adr/0008-command-declared-probe.md` shipped `command_declared` for
slash commands and closed with the observation that the kernel's capability
probe covered **subagents** only — an agent is available iff declared in
`CLAUDE.md § Subagents` or `.claude/agents/` ([[Decisions/foundation -
Project capability probes]]) — and that no equivalent existed for commands.
It did not say the reverse, which turned out to be the live defect: the
**subagent** predicate itself is stated as those two surfaces and nothing
else, and neither exists on the kernel's own dogfooding checkout.

`.claude/agents/` is gitignored — `workflows/scripts/install/project-agents.sh`
deploys it per-checkout, so a fresh clone has none — and the kernel's
`CLAUDE.md` carries no `## Subagents` heading. Yet all eleven agents are
installed and spawnable from `$HOME/.claude/agents/`. Read literally, the
predicate therefore returned **unavailable for every reviewer on the exact
checkout the kernel is built in**. `build.md` §3e's *mandatory*
`workflow-reviewer` pass and `/workshop` §3.3's adversarial panel both gate on
it, so both emitted all-skip lines for agents that would have spawned fine.

The irony is the point: a skip line that fires for an *available* agent is
itself a mandatory step silently not running — the same all-skip outcome as
temperloop#1387, reached by a second, independent route, and the class epic
temperloop#1616 exists to close.

A naive fix is worse than the bug. Making the probe answer "available" more
readily would report a reviewer that merely *ships as source* as spawnable,
so a caller would try to spawn it — and the kernel's degradation notice
deliberately has **two** forms selected by exactly that distinction
(`claude/message-schema.md` § Degradation notice): a bare `skipped — <agent>
unavailable` for an agent that does not exist anywhere, and a remedy-bearing
`skipped — <agent> available as source; run
workflows/scripts/install/project-agents.sh to enable` for one that ships but
is not installed. A boolean predicate cannot carry that; absence and
indeterminacy have to stay distinguishable.

## Decision

The kernel owns a shared helper, `workflows/scripts/lib/agent_declared.sh`,
that mirrors `command_declared.sh`'s resolution order rather than inventing a
new one — the same three file surfaces, in the same order, with `agents/` in
place of `commands/` — and preserves the canonical predicate's other clause
as a declaration surface probed first:

0. `$PWD/CLAUDE.md` § Subagents names `<name>` → **installed**
1. `$PWD/.claude/agents/<name>.md` → **installed**
2. `<checkout>/claude/agents/<name>.md` (or `…/reviewers/<name>.md`) →
   **source-only**
3. `$HOME/.claude/agents/<name>.md` → **installed**

Two functions, and the second is the one callers gate on:

- `agent_declared <name>` — the direct analogue of `command_declared`,
  answering **"source-or-installed present"** (true for both `installed` and
  `source-only`). Same semantics ADR 0008 fixed, same explicit non-claim: it
  does *not* answer "runtime-resolvable".
- `agent_declared_state <name>` — the three-valued answer, printed on stdout
  as `installed` / `source-only` / `absent`. `installed` is the **spawn
  gate**; the other two select the two degradation-notice forms above,
  one each.

Two contract details are load-bearing and are pinned by the suite:

- **A live surface outranks a provisional source hit.** Surface 2's answer is
  not returned until surface 3 has been checked and found empty, because an
  agent that both ships in the checkout and is installed on the host is
  *installed*. First-resolved-wins here would report `source-only` for every
  kernel-shipped reviewer on a host that has them installed — this exact bug,
  one layer in. (This is where `agent_declared` deliberately *diverges* from
  `command_declared_capability`'s first-resolved-file-wins rule, which answers
  a different question: which file a runtime resolution lands on.)
- **`absent` still means unavailable.** A fix that makes every agent look
  available is exactly as wrong as one that makes every agent look absent, so
  `absent` remains false from `agent_declared` and still fires the bare
  degradation notice.

`AGENT_DECLARED_OVERRIDE` is the fixture seam, matching
`COMMAND_DECLARED_OVERRIDE`'s shape: set (including set-but-empty) answers
entirely from the variable, as a space-separated list of `<name>` or
`<name>:<state>` tokens. An unrecognized state suffix warns and fails closed.

The reviewer-availability prose in `claude/commands/build.md` §3e and
`claude/commands/workshop.md` §3.3 cites this helper as the mechanical form
of the predicate they already describe.

## Consequences

Benefits: the mandatory `workflow-reviewer` pass and the `/workshop` panel run
on the kernel's own checkout instead of skipping; probe-gated agent behavior
becomes mechanically testable (a fixture can force all three answers); and the
two degradation-notice forms acquire a mechanical selector instead of being
chosen by eye at each call site.

Costs: a second availability helper to keep aligned with the first — the two
now share a resolution order that must be changed in both places if a new
deployment location appears — and the three-valued return means a caller must
branch on a string rather than an exit status. That is deliberate: an exit
code cannot carry three values, and collapsing to a boolean is what produced
the defect.

Accepted limits: the same latent false-positive ADR 0008 records applies here
in a narrower form — `agent_declared` reads true for a source-only agent by
design, which is why it must never gate a spawn alone. And surface 0 is a
static read of `$PWD/CLAUDE.md`; a project that declares its subagents
somewhere else entirely still needs a file surface.
